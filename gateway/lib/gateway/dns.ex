defmodule Gateway.DNS do
  @moduledoc """
  The gateway's DNS resolver. All client DNS is redirected here by the
  firewall, so this is where catalog domains are refused while the RMM channel
  is locked.

  `start_link/1` starts a supervisor with a query `Task.Supervisor` and a
  `Gateway.DNS.Server` that listens on UDP and, unless `tcp: false`, on TCP at
  the same ip and port. The decision rules are in `Gateway.DNS.Resolver`; the
  lock state comes from `Gateway.DNS.Snapshot`.

  ## Options

    * `:name` - optional name for the supervisor
    * `:ip` - address to bind, default `{127, 0, 0, 1}`
    * `:port` - port to bind, default `5300`; `0` picks a free port, see `port/1`
    * `:upstreams` - `[{ip_tuple, port}]` tried in order, default Cloudflare
      then Quad9 on port 53
    * `:timeout_ms` - per-upstream timeout, default `2000`
    * `:tcp` - also listen on TCP, default `true`
    * `:tcp_idle_ms` - close idle TCP connections after this long, default `10_000`
    * `:max_tasks` - concurrent queries and TCP connections, default `1024`;
      beyond it UDP packets are dropped and connections closed
    * `:on_resolved` - called with `[{ip_tuple, ttl_seconds, tag}]` for the
      A/AAAA records of every catalog or site-host answer, where `tag` is the
      tool id or `{:site_host, host}`
    * `:on_event` - called with an event map for `:blocked`, `:would_block`
      and `:doh_blocked`. `:channel` is the catalog channel of the matched
      name (the cname target for a cname match), and nil for site hosts and
      DoH

  Both callbacks run in query tasks. Exceptions in them are logged and
  swallowed, and a slow callback only delays its own query.

  Defaults are also read from `config :gateway, Gateway.DNS, ...`, with
  explicit options taking precedence.
  """

  use Supervisor

  @defaults [
    ip: {127, 0, 0, 1},
    port: 5300,
    upstreams: [{{1, 1, 1, 1}, 53}, {{9, 9, 9, 9}, 53}],
    timeout_ms: 2000,
    tcp: true,
    tcp_idle_ms: 10_000,
    max_tasks: 1024
  ]

  @typedoc "An upstream resolver."
  @type upstream :: {:inet.ip_address(), :inet.port_number()}

  @typedoc "Event passed to `:on_event`."
  @type event :: %{
          type: :blocked | :would_block | :doh_blocked,
          qname: String.t(),
          qtype: atom() | non_neg_integer(),
          match:
            String.t()
            | {:site_host, String.t()}
            | {:cname, String.t(), String.t() | {:site_host, String.t()}}
            | {:doh, String.t()}
            | {:canary, String.t()},
          channel: :control | :management | :both | nil,
          client: :inet.ip_address() | nil,
          at: DateTime.t()
        }

  @doc "Starts the resolver supervisor. See the module doc for options."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    sup_opts = if name, do: [name: name], else: []
    Supervisor.start_link(__MODULE__, opts, sup_opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Returns the port the resolver listens on, for tests that bind port 0."
  @spec port(Supervisor.supervisor()) :: :inet.port_number()
  def port(sup) do
    {_, pid, _, _} =
      sup
      |> Supervisor.which_children()
      |> Enum.find(fn {id, _, _, _} -> id == Gateway.DNS.Server end)

    Gateway.DNS.Server.port(pid)
  end

  @impl true
  def init(opts) do
    opts =
      @defaults
      |> Keyword.merge(Application.get_env(:gateway, __MODULE__, []))
      |> Keyword.merge(opts)
      |> Keyword.put_new(:on_resolved, &noop/1)
      |> Keyword.put_new(:on_event, &noop/1)

    # the server finds its sibling task supervisor once the supervisor is up,
    # so neither child needs a global name
    children = [
      {Task.Supervisor, max_children: opts[:max_tasks]},
      {Gateway.DNS.Server, Keyword.put(opts, :sup, self())}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp noop(_), do: :ok
end
