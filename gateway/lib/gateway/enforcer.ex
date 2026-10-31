defmodule Gateway.Enforcer do
  @moduledoc """
  Turns the last accepted signed policy into firewall and DNS state, and keeps doing
  so on its own, offline, for as long as the gateway runs.

  ## Policy

  `submit/1` accepts a signed command (wire map or JSON bytes). It must pass
  `Breakline.Command.verify/3` at the clock's current time, be of type `"policy"`,
  carry a payload that `Breakline.Policy.from_map/1` accepts, and that payload's
  `site_id` and `version` must equal the command's site and `policy_version`. The
  command and the new verifier state are persisted through `Gateway.Store` before the
  policy is applied, so a crash can never leave an applied policy whose version a
  restart would forget (threat model T4). Rejections are audited with their reason.

  At boot the persisted command is checked again with
  `Breakline.Command.authenticate/2` (signature, key and site, but not expiry: an
  accepted policy stays enforced after its command expires) and the same payload
  checks. Anything missing or invalid means no policy. The verifier's `last_version`
  is the larger of the persisted one and the persisted command's version, so losing
  `verifier.json` cannot reopen a replay of an older command.

  ## Evaluation

  The state is evaluated at boot, on every tick (`:tick_ms`, default 15 s), at the
  schedule's next change when that is sooner, on every policy change, and when the
  firewall server restarts. The channel is locked when the clock is not synchronised
  (`{:locked, :clock_unsynced}`), when there is no policy (`{:locked, :no_policy}`),
  or when `Breakline.Schedule.explain/2` says so. Without a policy the mode is the
  configured `:default_mode` and every catalog tool is covered.

  Each evaluation builds a `Gateway.Firewall.Desired` and applies it when it differs
  from the last successful apply, or when the firewall server's pid changed (a
  restarted server holds no desired state of its own). It publishes a
  `Gateway.DNS.Snapshot` when that changed. Every change of lock state, mode, clock
  sync or policy version is audited as `state_changed` and recorded as an event.

  Per-site `site_hosts` that parse as an ip address or CIDR go to the firewall's
  block list; the rest are hostnames for the resolver.

  ## Options

    * `:site_id` (required) and `:public_keys` (`%{key_id => base64url public key}`)
    * `:default_mode` - `:monitor` (default) or `:enforce`, used while there is no policy
    * `:lan_interfaces` (required, non-empty) and `:dns_port` (default 53), for the
      firewall's DNS redirect
    * `:tick_ms` (default 15_000) and `:retry_ms` (default 500, for a missing or
      failing firewall server)
    * `:clock` - a `Gateway.Clock` module, default `Gateway.Clock.System`
    * `:store`, `:firewall`, `:events` - the servers to use, by default the
      registered `Gateway.Store`, `Gateway.Firewall.Server` and `Gateway.Events`
    * `:name` - defaults to this module
  """

  use GenServer

  require Logger

  alias Breakline.{Catalog, Command, Policy, Schedule}
  alias Breakline.Command.Verifier
  alias Gateway.{Events, Firewall, Store}
  alias Gateway.DNS.Snapshot
  alias Gateway.Firewall.Desired

  @type reason ::
          {:locked, :clock_unsynced}
          | {:locked, :no_policy}
          | Schedule.explanation()

  @type submit_error ::
          Command.verify_error()
          | :unsupported_type
          | {:invalid_policy, [Policy.reason()]}
          | :site_mismatch
          | :version_mismatch
          | {:persist_failed, term()}

  @type status :: %{
          state: :open | :locked,
          reason: reason(),
          policy_version: non_neg_integer() | nil,
          last_version: non_neg_integer(),
          mode: :enforce | :monitor,
          clock_synced?: boolean(),
          next_change: DateTime.t() | nil,
          last_applied_at: DateTime.t() | nil,
          firewall: map()
        }

  @doc "Returns a child spec. See the moduledoc for options."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the enforcer. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Verifies, persists and applies a signed policy command. Returns `:ok` or the
  reason it was rejected; see the moduledoc.
  """
  @spec submit(Command.wire() | binary(), GenServer.server()) :: :ok | {:error, submit_error()}
  def submit(wire_or_json, server \\ __MODULE__),
    do: GenServer.call(server, {:submit, wire_or_json})

  @doc """
  Returns the current state: `:state`, `:reason`, `:policy_version` (nil without a
  policy), `:last_version` (the verifier's), `:mode`, `:clock_synced?`,
  `:next_change`, `:last_applied_at` and a `:firewall` summary.
  """
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Evaluates the state now, synchronously. The periodic tick does the same."
  @spec evaluate(GenServer.server()) :: :ok
  def evaluate(server \\ __MODULE__), do: GenServer.call(server, :evaluate)

  @doc """
  Describes a lock reason as a json-compatible map with a `"rule"` key, for the
  audit log and the uplink.
  """
  @spec describe_reason(reason()) :: map()
  def describe_reason({:locked, :clock_unsynced}), do: %{"rule" => "clock_unsynced"}
  def describe_reason({:locked, :no_policy}), do: %{"rule" => "no_policy"}
  def describe_reason({:locked, :default}), do: %{"rule" => "default"}

  def describe_reason({:locked, {:advisory_lock, lock}}) do
    %{
      "rule" => "advisory_lock",
      "id" => lock.id,
      "source" => lock.source,
      "reason" => lock.reason,
      "expires_at" => lock.expires_at && DateTime.to_iso8601(lock.expires_at)
    }
  end

  def describe_reason({:open, {:break_glass, bg}}) do
    %{
      "rule" => "break_glass",
      "until" => DateTime.to_iso8601(bg.until),
      "approved_by" => bg.approved_by
    }
  end

  def describe_reason({:open, {:window, id, {s, e}}}) do
    %{
      "rule" => "window",
      "id" => id,
      "starts_at" => DateTime.to_iso8601(s),
      "ends_at" => DateTime.to_iso8601(e)
    }
  end

  @doc """
  Splits per-site hosts into `{block_cidrs, hostnames}`: entries that parse as an ip
  address or a CIDR, and the rest. A malformed CIDR (a `/` that does not parse) is
  dropped from both, with a warning.
  """
  @spec split_site_hosts([String.t()]) :: {[String.t()], [String.t()]}
  def split_site_hosts(hosts) do
    Enum.reduce(Enum.reverse(hosts), {[], []}, fn host, {cidrs, names} ->
      case classify_host(host) do
        :address ->
          {[host | cidrs], names}

        :hostname ->
          {cidrs, [host | names]}

        :invalid ->
          Logger.warning("ignoring malformed site host #{inspect(host)}")
          {cidrs, names}
      end
    end)
  end

  defp classify_host(host) do
    case String.split(host, "/") do
      [addr] ->
        if ip?(addr), do: :address, else: :hostname

      [addr, len] ->
        with {:ok, ip} <- parse_ip(addr),
             {n, ""} <- Integer.parse(len),
             true <- n >= 0 and n <= if(tuple_size(ip) == 4, do: 32, else: 128) do
          :address
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp ip?(s), do: match?({:ok, _}, parse_ip(s))
  defp parse_ip(s), do: :inet.parse_strict_address(String.to_charlist(s))

  # server

  @impl true
  def init(opts) do
    config = config(opts)
    verifier = Verifier.new(site_id: config.site_id, public_keys: config.public_keys)

    # fail at boot, not on the first evaluation, when the firewall config is unusable
    {:ok, _} = build_desired(config, true, config.default_mode, Catalog.ids(), [])

    {verifier, verifier_note} = load_verifier(verifier, config.store)
    {policy, key_id, boot_note} = load_policy(verifier, config.store)

    verifier =
      if policy && policy.version > verifier.last_version,
        do: %{verifier | last_version: policy.version},
        else: verifier

    state = %{
      config: config,
      verifier: verifier,
      policy: policy,
      key_id: key_id,
      eval: nil,
      reason: nil,
      next_change: nil,
      snapshot: nil,
      applied: nil,
      last_applied_at: nil,
      last_apply_error: nil,
      fw_pid: nil,
      fw_ref: nil,
      timer: nil
    }

    {:ok, state, {:continue, {:boot, verifier_note, boot_note}}}
  end

  @impl true
  def handle_continue({:boot, verifier_note, boot_note}, s) do
    audit(s, %{
      "type" => "enforcer_started",
      "policy_version" => s.policy && s.policy.version,
      "last_version" => s.verifier.last_version,
      "command" => boot_note,
      "verifier" => verifier_note
    })

    {:noreply, run_evaluation(s)}
  end

  @impl true
  def handle_call({:submit, input}, _from, s) do
    now = s.config.clock.now()

    case accept(input, s, now) do
      {:ok, policy, command, verifier} ->
        audit(s, %{
          "type" => "policy_applied",
          "policy_version" => policy.version,
          "key_id" => command.key_id
        })

        event(s, %{type: :policy_applied, policy_version: policy.version, key_id: command.key_id})
        s = %{s | policy: policy, key_id: command.key_id, verifier: verifier}
        {:reply, :ok, run_evaluation(s)}

      {:error, reason} ->
        Logger.warning("rejected command: #{inspect(reason)}")
        audit(s, Map.put(rejection(reason), "type", "command_rejected"))
        event(s, %{type: :command_rejected, reason: reason})
        {:reply, {:error, reason}, s}
    end
  end

  def handle_call(:status, _from, s) do
    {locked?, mode, synced?, version} = s.eval

    status = %{
      state: if(locked?, do: :locked, else: :open),
      reason: s.reason,
      policy_version: version,
      last_version: s.verifier.last_version,
      mode: mode,
      clock_synced?: synced?,
      next_change: s.next_change,
      last_applied_at: s.last_applied_at,
      firewall: firewall_summary(s)
    }

    {:reply, status, s}
  end

  def handle_call(:evaluate, _from, s), do: {:reply, :ok, run_evaluation(s)}

  @impl true
  def handle_info(:evaluate, s), do: {:noreply, run_evaluation(%{s | timer: nil})}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{fw_ref: ref} = s) do
    Logger.warning("firewall server went down (#{inspect(reason)}), will re-apply")
    s = %{s | fw_pid: nil, fw_ref: nil, applied: nil}
    {:noreply, schedule(s, s.config.retry_ms)}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # accepting a command

  defp accept(input, s, now) do
    with {:ok, command, verifier} <- Command.verify(input, s.verifier, now),
         :ok <- check_type(command),
         {:ok, policy} <- parse_policy(command),
         :ok <- check_policy(policy, command),
         :ok <- persist(input, verifier, s.config.store) do
      {:ok, policy, command, verifier}
    end
  end

  defp check_type(%Command{type: "policy"}), do: :ok
  defp check_type(_), do: {:error, :unsupported_type}

  defp parse_policy(command) do
    case Policy.from_map(command.payload) do
      {:ok, policy} -> {:ok, policy}
      {:error, reasons} -> {:error, {:invalid_policy, reasons}}
    end
  end

  defp check_policy(%Policy{site_id: site} = p, %Command{site_id: site} = c) do
    if p.version == c.policy_version, do: :ok, else: {:error, :version_mismatch}
  end

  defp check_policy(_policy, _command), do: {:error, :site_mismatch}

  defp persist(input, verifier, store) do
    bytes = if is_binary(input), do: input, else: Command.encode_wire(input)

    # the command first: should the verifier write fail, boot still raises
    # last_version to the persisted command's version
    with :ok <- Store.save_command(bytes, store),
         :ok <- Store.save_verifier_state(verifier, store) do
      :ok
    else
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  defp rejection({:invalid_policy, reasons}),
    do: %{"reason" => "invalid_policy", "details" => inspect(reasons)}

  defp rejection({:persist_failed, reason}),
    do: %{"reason" => "persist_failed", "details" => inspect(reason)}

  defp rejection(reason) when is_atom(reason), do: %{"reason" => Atom.to_string(reason)}

  # boot

  defp load_verifier(verifier, store) do
    case Store.load_verifier_state(store) do
      {:ok, %{last_version: v, seen_nonces: n}} ->
        {%{verifier | last_version: v, seen_nonces: n}, "loaded"}

      :none ->
        {verifier, "none"}

      {:error, reason} ->
        Logger.error("unreadable verifier state (#{inspect(reason)}), starting from version 0")
        {verifier, "unreadable"}
    end
  end

  defp load_policy(verifier, store) do
    with {:ok, bytes} <- Store.load_command(store),
         {:ok, command} <- Command.authenticate(bytes, verifier),
         :ok <- check_type(command),
         {:ok, policy} <- parse_policy(command),
         :ok <- check_policy(policy, command) do
      {policy, command.key_id, "loaded"}
    else
      :none ->
        {nil, nil, "none"}

      {:error, reason} ->
        Logger.error("ignoring persisted command: #{inspect(reason)}")
        {nil, nil, "rejected: #{rejection(reason)["reason"]}"}
    end
  end

  # evaluation

  defp run_evaluation(s) do
    c = s.config
    now = c.clock.now()
    synced? = c.clock.synced?() == true
    policy = s.policy

    reason =
      cond do
        not synced? -> {:locked, :clock_unsynced}
        policy == nil -> {:locked, :no_policy}
        true -> Schedule.explain(policy, now)
      end

    locked? = elem(reason, 0) == :locked
    mode = if policy, do: policy.mode, else: c.default_mode
    tool_ids = if policy, do: policy.tool_ids, else: Catalog.ids()
    {block_hosts, hostnames} = split_site_hosts(if policy, do: policy.site_hosts, else: [])
    next_change = if synced? and policy, do: Schedule.next_change(policy, now)

    {:ok, desired} = build_desired(c, locked?, mode, tool_ids, block_hosts)

    snapshot = %Snapshot{
      locked?: locked?,
      mode: mode,
      tool_ids: tool_ids,
      site_hostnames: hostnames
    }

    if snapshot != s.snapshot, do: Snapshot.put(snapshot)

    eval = {locked?, mode, synced?, policy && policy.version}
    if eval != s.eval, do: transition(s, eval, reason, now)

    s = %{s | snapshot: snapshot, eval: eval, reason: reason, next_change: next_change}
    s = s |> track_firewall() |> apply_firewall(desired, now)

    retry? = s.applied != desired
    delay = next_delay(c, now, next_change, retry?)
    schedule(s, delay)
  end

  defp build_desired(c, locked?, mode, tool_ids, block_hosts) do
    Desired.new(
      locked?: locked?,
      mode: mode,
      lan_interfaces: c.lan_interfaces,
      dns_port: c.dns_port,
      block_cidrs: Catalog.cidrs(tool_ids) ++ block_hosts,
      exclusive_ports: Catalog.exclusive_ports(tool_ids),
      doh_ips: Gateway.DoH.ips()
    )
  end

  defp transition(s, {locked?, mode, synced?, version} = eval, reason, now) do
    previous =
      case s.eval do
        nil ->
          nil

        {pl, pm, ps, pv} ->
          %{
            "state" => state_name(pl),
            "mode" => Atom.to_string(pm),
            "clock_synced" => ps,
            "policy_version" => pv
          }
      end

    Logger.info(
      "state #{state_name(locked?)} (#{describe_reason(reason)["rule"]}), mode #{mode}, " <>
        "clock_synced #{synced?}, policy #{inspect(version)}"
    )

    audit(s, %{
      "type" => "state_changed",
      "state" => state_name(locked?),
      "mode" => Atom.to_string(mode),
      "clock_synced" => synced?,
      "policy_version" => version,
      "reason" => describe_reason(reason),
      "previous" => previous
    })

    event(s, %{
      type: :state_changed,
      at: now,
      locked?: locked?,
      mode: mode,
      clock_synced?: synced?,
      policy_version: version,
      reason: reason
    })

    eval
  end

  defp state_name(true), do: "locked"
  defp state_name(false), do: "open"

  # a restarted firewall server holds no desired state, so a changed pid forces an apply
  defp track_firewall(s) do
    case Process.whereis(s.config.firewall) do
      pid when pid == s.fw_pid ->
        s

      nil ->
        demonitor(s)

      pid ->
        s = demonitor(s)
        %{s | fw_pid: pid, fw_ref: Process.monitor(pid)}
    end
  end

  defp demonitor(%{fw_ref: nil} = s), do: %{s | fw_pid: nil, applied: nil}

  defp demonitor(s) do
    Process.demonitor(s.fw_ref, [:flush])
    %{s | fw_pid: nil, fw_ref: nil, applied: nil}
  end

  defp apply_firewall(%{fw_pid: nil} = s, _desired, _now), do: s
  defp apply_firewall(%{applied: desired} = s, desired, _now), do: s

  defp apply_firewall(s, desired, now) do
    result =
      try do
        Firewall.apply_desired(desired, s.config.firewall)
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    case result do
      :ok ->
        %{s | applied: desired, last_applied_at: now, last_apply_error: nil}

      {:error, reason} ->
        Logger.error("firewall apply failed: #{inspect(reason)}")
        %{s | applied: nil, last_apply_error: reason}
    end
  end

  defp next_delay(c, now, next_change, retry?) do
    candidates =
      [c.tick_ms] ++
        if(next_change, do: [max(DateTime.diff(next_change, now, :millisecond), 0)], else: []) ++
        if(retry?, do: [c.retry_ms], else: [])

    Enum.min(candidates)
  end

  defp schedule(s, delay) do
    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | timer: Process.send_after(self(), :evaluate, delay)}
  end

  defp firewall_summary(s) do
    snapshot =
      try do
        Firewall.snapshot(s.config.firewall)
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    case snapshot do
      %{} = snap ->
        impl_state = snap.state

        %{
          running?: true,
          impl: snap.impl,
          in_sync?: s.applied != nil and snap.desired == s.applied,
          apply_count: Map.get(impl_state, :apply_count),
          resolved_count: resolved_count(impl_state),
          last_error: snap.last_error || s.last_apply_error
        }

      {:error, _} ->
        %{running?: false, in_sync?: false, last_error: s.last_apply_error}
    end
  end

  defp resolved_count(%{resolved: resolved}) when is_map(resolved), do: map_size(resolved)
  defp resolved_count(%{resolved_count: n}), do: n
  defp resolved_count(_), do: nil

  # side channels

  defp audit(s, entry) do
    entry = Map.put(entry, "at", DateTime.to_iso8601(s.config.clock.now()))

    case Store.audit(entry, s.config.store) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("audit write failed: #{inspect(reason)}")
    end
  catch
    :exit, reason -> Logger.error("audit write failed: #{inspect(reason)}")
  end

  defp event(s, event) do
    event = Map.put_new_lazy(event, :at, fn -> s.config.clock.now() end)
    Events.record(event, s.config.events)
  end

  # config

  defp config(opts) do
    site_id = Keyword.fetch!(opts, :site_id)
    lan = Keyword.fetch!(opts, :lan_interfaces)
    mode = Keyword.get(opts, :default_mode, :monitor)

    unless is_binary(site_id) and site_id != "", do: raise(ArgumentError, "invalid :site_id")
    unless mode in [:enforce, :monitor], do: raise(ArgumentError, "invalid :default_mode")

    %{
      site_id: site_id,
      public_keys: decode_keys(Keyword.get(opts, :public_keys, %{})),
      default_mode: mode,
      lan_interfaces: lan,
      dns_port: Keyword.get(opts, :dns_port, 53),
      tick_ms: Keyword.get(opts, :tick_ms, 15_000),
      retry_ms: Keyword.get(opts, :retry_ms, 500),
      clock: Keyword.get(opts, :clock, Gateway.Clock.System),
      store: Keyword.get(opts, :store, Store),
      firewall: Keyword.get(opts, :firewall, Gateway.Firewall.Server),
      events: Keyword.get(opts, :events, Events)
    }
  end

  defp decode_keys(keys) do
    if keys == %{},
      do: Logger.warning("no public keys configured: every command will be rejected")

    Map.new(keys, fn {id, b64} ->
      case Base.url_decode64(b64, padding: false) do
        {:ok, <<_::binary-size(32)>> = key} -> {to_string(id), key}
        _ -> raise ArgumentError, "invalid public key for #{inspect(id)}"
      end
    end)
  end
end
