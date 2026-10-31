defmodule Gateway.Application do
  @moduledoc """
  The gateway's supervision tree.

  `Gateway.Supervisor` is `:one_for_one` with one subtree per concern, started in
  this order:

    1. firewall - `Gateway.Firewall.Server` with the configured implementation
    2. events - `Gateway.Events`, the in-memory event buffer
    3. enforcer - `Gateway.Store` then `Gateway.Enforcer`, `:rest_for_one`, so a
       store crash restarts the enforcer on fresh state from disk
    4. dns - `Gateway.DNS`, whose resolved RMM addresses go to the firewall and whose
       events go to `Gateway.Events`
    5. inbox - `Gateway.Dev.Inbox`, only when `:inbox_dir` is configured (dev)
    6. uplink - `Gateway.Uplink.Keeper`, which runs `Gateway.Uplink.Supervisor` and
       `Gateway.Uplink` under it, only when `config :gateway, :uplink` is set

  A crash in one subtree never restarts another: a DNS crash leaves the firewall
  server and its applied state alone, and a firewall restart is noticed by the
  enforcer, which applies the desired state again.

  The uplink's own supervisor restarts it at most 10 times a minute. When the uplink
  crashes more often, that supervisor gives up and the keeper starts it again after
  a cool-off (5 minutes by default, `:cool_off_ms` in the uplink config). The keeper
  traps the exit and never crashes itself, so an uplink crash loop never spends the
  restart intensity of the subtrees above it and never touches the firewall or the
  enforcer, and the uplink always comes back. The gateway keeps enforcing offline
  either way.

  With `config :gateway, start_children: false` (the test config) the application
  starts an empty supervisor and tests start what they need, for example the whole
  tree from `children/1`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = if Application.get_env(:gateway, :start_children, true), do: children(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Gateway.Supervisor)
  end

  @doc """
  Returns the top-level child specs, built from the `:gateway` application env with
  `overrides` (a keyword list using the same keys) taking precedence. A `:dns`
  override is merged into `config :gateway, Gateway.DNS`.
  """
  @spec children(keyword()) :: [Supervisor.child_spec()]
  def children(overrides \\ []) do
    {dns_overrides, overrides} = Keyword.pop(overrides, :dns, [])
    env = Keyword.merge(Application.get_all_env(:gateway), overrides)
    dns = Keyword.merge(Application.get_env(:gateway, Gateway.DNS, []), dns_overrides)
    clock = Keyword.get(env, :clock, Gateway.Clock.System)

    firewall = [
      {Gateway.Firewall.Server,
       impl: Keyword.get(env, :firewall_impl, Gateway.Firewall.FakeImpl),
       impl_opts: Keyword.get(env, :firewall_impl_opts, [])}
    ]

    enforcer_opts = [
      site_id: Keyword.fetch!(env, :site_id),
      public_keys: Keyword.get(env, :public_keys, %{}),
      default_mode: Keyword.get(env, :default_mode, :monitor),
      lan_interfaces: Keyword.fetch!(env, :lan_interfaces),
      dns_port: Keyword.get(env, :dns_port) || Keyword.get(dns, :port, 5300),
      tick_ms: Keyword.get(env, :tick_ms, 15_000),
      clock: clock
    ]

    enforcer = [
      {Gateway.Store, data_dir: Keyword.fetch!(env, :data_dir), clock: clock},
      {Gateway.Enforcer, enforcer_opts}
    ]

    dns_opts =
      dns
      |> Keyword.put(:name, Gateway.DNS.Supervisor)
      |> Keyword.put(:on_resolved, &__MODULE__.dns_resolved/1)
      |> Keyword.put(:on_event, &Gateway.Events.record/1)

    inbox =
      case Keyword.get(env, :inbox_dir) do
        nil -> []
        dir -> [{Gateway.Dev.Inbox, dir: dir}]
      end

    uplink =
      case Keyword.get(env, :uplink) do
        nil ->
          []

        opts ->
          opts = Keyword.merge([site_id: Keyword.fetch!(env, :site_id), clock: clock], opts)

          {keeper_opts, uplink_opts} =
            Keyword.split(opts, [:cool_off_ms, :max_restarts, :max_seconds])

          [
            subtree(
              :uplink,
              [{Gateway.Uplink.Keeper, [uplink: uplink_opts] ++ keeper_opts}],
              :one_for_one
            )
          ]
      end

    [
      subtree(:firewall, firewall, :one_for_one),
      {Gateway.Events, capacity: Keyword.get(env, :events_capacity, 10_000)},
      subtree(:enforcer, enforcer, :rest_for_one),
      {Gateway.DNS, dns_opts}
    ] ++ inbox ++ uplink
  end

  @doc """
  The resolver's `on_resolved` callback: hands resolved RMM addresses to the
  firewall. The firewall wants a string tag, so `{:site_host, host}` becomes
  `"site_host:" <> host`.
  """
  @spec dns_resolved([{:inet.ip_address(), non_neg_integer(), Gateway.DNS.Resolver.tag()}]) ::
          :ok
  def dns_resolved(entries) do
    entries
    |> Enum.map(fn
      {ip, ttl, {:site_host, host}} -> {ip, ttl, "site_host:" <> host}
      entry -> entry
    end)
    |> Gateway.Firewall.add_resolved()
  end

  defp subtree(id, children, strategy) do
    name = Module.concat(Gateway, Macro.camelize("#{id}_supervisor"))

    %{
      id: id,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: strategy, name: name]]}
    }
  end
end
