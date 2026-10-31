defmodule Gateway.Uplink do
  @moduledoc """
  The gateway's only link to the cloud: an outbound websocket to Phoenix Channels
  over mutual TLS, through `Slipstream`. The gateway never listens for the cloud;
  every connection starts here.

  The uplink only carries messages. Enforcement never depends on it: offline, the
  Enforcer keeps applying the last accepted policy, and the uplink logs and retries.
  It talks to the Enforcer, the Store and the event buffer only through their public
  calls, and catches their exits, so neither a crash of the uplink nor of one of them
  takes the other down.

  ## Protocol

  The uplink joins `gateway:<site_id>` with

      {"hello": {"gateway_version": "0.1.0", "last_version": 7, "policy_version": 7,
                 "audit": {"chain_id": hex | null, "head": {"seq": n, "hash": hex} | null}}}

  and the cloud replies `{"server_time", "heartbeat_ms", "audit_ack", "policy"}`. A
  `"policy"` in the reply is handled like a pushed one. A join error is logged and
  the join is retried with backoff.

    * `"policy"` from the cloud, `{"command": <signed wire map>}`: handed to
      `Gateway.Enforcer.submit/1`, answered with a `"policy_result"` push
      `{"policy_version", "result": "applied" | "rejected", "reason"}`.
    * `"heartbeat"` to the cloud every `heartbeat_ms` (from the join reply, 30 s
      by default): `{"status": <enforcer status>, "sent_at": iso8601}`.
    * `"events"` to the cloud: `{"events": [...]}`, at most 500 per push, oldest
      first. A batch stays in flight until the cloud replies ok and is sent again
      after a timeout or a reconnect, so delivery is at least once; each event
      carries an `"id"` so the cloud can drop a duplicate.
    * `"audit"` to the cloud: `{"chain_id", "records": [...]}`, at most 200 records
      after the cloud's last ack. An ok reply `{"head": {"seq", "hash"}}` moves the
      ack; `{"reason": "chain_mismatch", "expected_seq": n}` sends again from `n`.

  Encoding to json-safe maps is in `Gateway.Uplink.Encode`.

  ## Timing

  A reply that does not arrive within `:reply_timeout_ms` (30 s) means the link is
  stuck: the uplink disconnects, reconnects and sends again. Reconnects and rejoins
  wait with exponential backoff and jitter (`backoff/3`), from `:backoff_min_ms`
  (1 s) to `:backoff_max_ms` (60 s), and the backoff resets on a successful join.
  New events and audit records are picked up every `:sync_ms` (2 s) and right after
  each ok reply.

  ## Options

    * `:url` (required) - a `wss://` url, e.g.
      `wss://localhost:4011/gateway/socket/websocket`
    * `:certfile`, `:keyfile`, `:cacertfile` (required) - the gateway's client
      certificate and key, and the CA that signed the cloud's server certificate
    * `:server_name` - the name the server certificate must carry, when it differs
      from the url's host
    * `:site_id` (required) and `:clock` (a `Gateway.Clock`)
    * `:enforcer`, `:store`, `:events` - the servers to use, by default the
      registered `Gateway.Enforcer`, `Gateway.Store` and `Gateway.Events`
    * `:heartbeat_ms`, `:sync_ms`, `:reply_timeout_ms`, `:backoff_min_ms`,
      `:backoff_max_ms` - see above
    * `:test_mode?` - for `Slipstream.SocketTest`, opens no connection
    * `:name` - defaults to this module

  An invalid configuration is logged and the uplink does not start (`:ignore`), so
  it can never stop the rest of the gateway from booting.
  """

  use Slipstream

  require Logger

  alias Gateway.{Enforcer, Events, Store}
  alias Gateway.Uplink.Encode

  @events_batch 500
  @audit_batch 200
  @clock_skew_warn_s 300
  @max_event_failures 3

  @type status :: %{
          running?: boolean(),
          connected?: boolean(),
          joined?: boolean(),
          url: String.t() | nil,
          last_heartbeat_at: DateTime.t() | nil,
          events_in_flight: non_neg_integer(),
          audit_ack: {non_neg_integer(), String.t()} | nil,
          chain_id: String.t() | nil,
          attempt: non_neg_integer(),
          last_error: term()
        }

  # every handle_info clause sits here, right after `use Slipstream`, whose own
  # handle_info clauses (for slipstream events) must stay grouped with ours

  @impl Slipstream
  def handle_info(:reconnect, socket) do
    socket = assign(socket, :retry_timer, nil)

    if connected?(socket) do
      {:noreply, socket}
    else
      {:ok, socket} = connect(socket, socket.assigns.slipstream)
      {:noreply, socket}
    end
  end

  def handle_info(:rejoin, socket) do
    socket = assign(socket, :retry_timer, nil)

    if connected?(socket) and not joined?(socket, socket.assigns.c.topic),
      do: {:noreply, join_topic(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:heartbeat, socket), do: {:noreply, send_heartbeat(socket)}

  def handle_info(:sync, socket) do
    socket = assign(socket, :sync_timer, nil)
    {:noreply, socket |> sync() |> schedule_sync()}
  end

  def handle_info({:reply_timeout, ref}, socket) do
    a = socket.assigns

    if in_flight?(a.events, ref) or in_flight?(a.audit_flight, ref) do
      Logger.warning("uplink: no reply to a push within #{a.c.reply_timeout_ms} ms, reconnecting")
      {:noreply, socket |> assign(:last_error, :reply_timeout) |> drop_session() |> disconnect()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "Returns a child spec. See the moduledoc for options."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the uplink. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the uplink's state for the dev CLI: `:connected?`, `:joined?`,
  `:last_heartbeat_at`, `:events_in_flight` (the size of the unacknowledged batch),
  `:audit_ack` (the cloud's last acknowledged `{seq, hash}`), and `:chain_id`,
  `:attempt`, `:last_error` and `:url`. When the uplink is not running, `:running?`
  is false.
  """
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ ->
      %{
        running?: false,
        connected?: false,
        joined?: false,
        url: nil,
        last_heartbeat_at: nil,
        events_in_flight: 0,
        audit_ack: nil,
        chain_id: nil,
        attempt: 0,
        last_error: nil
      }
  end

  @doc """
  The delay before retry number `attempt` (0 for the first): `min_ms * 2^attempt`
  capped at `max_ms`, then a random value between three quarters of that and all
  of it, so gateways that lost the cloud together do not come back in lockstep.
  """
  @spec backoff(non_neg_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def backoff(attempt, min_ms, max_ms) when is_integer(attempt) and attempt >= 0 do
    base = min(max_ms, min_ms * Integer.pow(2, min(attempt, 32)))
    low = div(base * 3, 4)
    max(low + :rand.uniform(base - low + 1) - 1, 1)
  end

  @doc """
  The `Mint.HTTP.connect/4` options for the mutual TLS connection: the client
  certificate and key, peer verification against `cacertfile` only, and hostname
  verification against `server_name` (or the url's host) through SNI and the OTP
  https match function, TLS 1.3 or 1.2.
  """
  @spec mint_opts(map() | keyword()) :: keyword()
  def mint_opts(c) do
    c = Map.new(c)
    host = c[:server_name] || URI.parse(c.url).host

    [
      protocols: [:http1],
      transport_opts: [
        certfile: c.certfile,
        keyfile: c.keyfile,
        cacertfile: c.cacertfile,
        verify: :verify_peer,
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        versions: [:"tlsv1.3", :"tlsv1.2"],
        depth: 4
      ]
    ]
  end

  # init and status

  @impl Slipstream
  def init(opts) do
    with {:ok, c} <- config(opts),
         slip = slipstream_opts(c),
         {:ok, _} <- Slipstream.Configuration.validate(slip) do
      warn_missing_files(c)

      socket =
        new_socket()
        |> assign(
          c: c,
          slipstream: slip,
          attempt: 0,
          retry_timer: nil,
          heartbeat_ms: c.heartbeat_ms,
          heartbeat_timer: nil,
          sync_timer: nil,
          last_heartbeat_at: nil,
          chain_id: nil,
          audit_ack: nil,
          audit_next: 0,
          audit_flight: nil,
          events: nil,
          last_error: nil
        )

      Logger.info("uplink connecting to #{c.url}")
      {:ok, socket} = connect(socket, slip)
      {:ok, socket}
    else
      {:error, reason} ->
        Logger.error("uplink not started, invalid config: #{format_error(reason)}")
        :ignore
    end
  end

  @impl Slipstream
  def handle_call(:status, _from, socket) do
    a = socket.assigns

    status = %{
      running?: true,
      connected?: connected?(socket),
      joined?: joined?(socket, a.c.topic),
      url: a.c.url,
      last_heartbeat_at: a.last_heartbeat_at,
      events_in_flight: if(a.events, do: length(a.events.batch), else: 0),
      audit_ack: a.audit_ack,
      chain_id: a.chain_id,
      attempt: a.attempt,
      last_error: a.last_error
    }

    {:reply, status, socket}
  end

  # connection and join

  @impl Slipstream
  def handle_connect(socket) do
    Logger.info("uplink connected")
    {:ok, join_topic(socket)}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("uplink disconnected: #{inspect(reason)}")

    {:ok,
     socket
     |> assign(:last_error, {:disconnected, reason})
     |> drop_session()
     |> schedule_retry(:reconnect)}
  end

  @impl Slipstream
  def handle_join(_topic, response, socket) do
    response = if is_map(response), do: response, else: %{}
    Logger.info("uplink joined #{socket.assigns.c.topic}")
    check_server_time(response["server_time"], socket.assigns.c.clock)

    heartbeat_ms =
      case response["heartbeat_ms"] do
        ms when is_integer(ms) and ms >= 1000 -> ms
        _ -> socket.assigns.c.heartbeat_ms
      end

    socket =
      socket
      |> assign(attempt: 0, last_error: nil, heartbeat_ms: heartbeat_ms)
      |> accept_ack(response["audit_ack"])

    socket =
      case response["policy"] do
        nil -> socket
        wire -> handle_policy(wire, socket)
      end

    {:ok, socket |> send_heartbeat() |> sync() |> schedule_sync()}
  end

  @impl Slipstream
  def handle_topic_close(_topic, reason, socket) do
    case reason do
      {:failed_to_join, %{"reason" => r}} -> Logger.warning("uplink join refused: #{r}")
      {:failed_to_join, other} -> Logger.warning("uplink join refused: #{inspect(other)}")
      other -> Logger.warning("uplink channel closed: #{inspect(other)}")
    end

    {:ok,
     socket
     |> assign(:last_error, reason)
     |> drop_session()
     |> schedule_retry(:rejoin)}
  end

  @impl Slipstream
  def handle_leave(_topic, socket), do: {:ok, socket |> drop_session() |> schedule_retry(:rejoin)}

  defp join_topic(socket) do
    c = socket.assigns.c

    case hello(c) do
      {:ok, params, chain_id} ->
        socket |> assign(:chain_id, chain_id) |> join(c.topic, params)

      {:error, reason} ->
        Logger.warning("uplink cannot build its hello yet: #{inspect(reason)}")
        socket |> assign(:last_error, {:hello, reason}) |> schedule_retry(:rejoin)
    end
  end

  defp hello(c) do
    status = Enforcer.status(c.enforcer)
    chain_id = Store.audit_chain_id(c.store)

    head =
      case Store.audit_head(c.store) do
        nil -> nil
        {seq, hash} -> %{"seq" => seq, "hash" => hash}
      end

    params = %{
      "hello" => %{
        "gateway_version" => gateway_version(),
        "last_version" => status.last_version,
        "policy_version" => status.policy_version,
        "audit" => %{"chain_id" => chain_id, "head" => head}
      }
    }

    {:ok, params, chain_id}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp gateway_version do
    case Application.spec(:gateway, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp check_server_time(time, clock) when is_binary(time) do
    with {:ok, server, _} <- DateTime.from_iso8601(time) do
      skew = DateTime.diff(server, clock.now())

      if abs(skew) > @clock_skew_warn_s,
        do: Logger.warning("uplink: cloud clock differs from ours by #{skew} s")
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp check_server_time(_time, _clock), do: :ok

  # the cloud's ack is only trusted when it matches a record of our own chain;
  # anything else starts the sync over from seq 0, and the cloud answers with
  # chain_mismatch should it disagree
  defp accept_ack(socket, %{"seq" => seq, "hash" => hash}) when is_integer(seq) and seq >= 0 do
    case audit_records(socket.assigns.c, seq, 1) do
      [%{"seq" => ^seq, "hash" => ^hash}] ->
        assign(socket, audit_ack: {seq, hash}, audit_next: seq + 1)

      _ ->
        Logger.warning("uplink: cloud audit ack #{seq} does not match the local chain")
        assign(socket, audit_ack: nil, audit_next: 0)
    end
  end

  defp accept_ack(socket, _ack), do: assign(socket, audit_ack: nil, audit_next: 0)

  # forgets everything that belongs to one joined session; an events batch is kept
  # (without its ref) so it is sent again once joined
  defp drop_session(socket) do
    a = socket.assigns
    cancel(a.heartbeat_timer)
    cancel(a.sync_timer)
    if a.audit_flight, do: cancel(a.audit_flight.timer)

    events =
      case a.events do
        nil ->
          nil

        batch ->
          cancel(batch.timer)
          %{batch | ref: nil, timer: nil}
      end

    assign(socket, heartbeat_timer: nil, sync_timer: nil, audit_flight: nil, events: events)
  end

  defp schedule_retry(socket, what) do
    a = socket.assigns
    cancel(a.retry_timer)
    delay = backoff(a.attempt, a.c.backoff_min_ms, a.c.backoff_max_ms)
    Logger.info("uplink #{what} in #{delay} ms")
    timer = Process.send_after(self(), what, delay)
    assign(socket, retry_timer: timer, attempt: a.attempt + 1)
  end

  # policy

  @impl Slipstream
  def handle_message(_topic, "policy", %{"command" => wire}, socket) do
    {:ok, handle_policy(wire, socket)}
  end

  def handle_message(_topic, event, _payload, socket) do
    Logger.warning("uplink: ignoring unknown message #{inspect(event)}")
    {:ok, socket}
  end

  defp handle_policy(wire, socket) do
    c = socket.assigns.c

    result =
      if is_map(wire) or is_binary(wire) do
        try do
          Enforcer.submit(wire, c.enforcer)
        catch
          :exit, _ -> {:error, :enforcer_unavailable}
        end
      else
        {:error, :malformed}
      end

    # the version the command claims, whether or not it was accepted
    version =
      case wire do
        %{"envelope" => %{"policy_version" => v}} when is_integer(v) -> v
        _ -> nil
      end

    payload =
      case result do
        :ok ->
          Logger.info("uplink: applied policy #{version}")
          %{"policy_version" => version, "result" => "applied", "reason" => nil}

        {:error, reason} ->
          r = Encode.rejection_reason(reason)
          Logger.warning("uplink: rejected policy #{inspect(version)}: #{r}")
          %{"policy_version" => version, "result" => "rejected", "reason" => r}
      end

    case push_msg(socket, "policy_result", payload) do
      {:ok, _ref} -> :ok
      {:error, reason} -> Logger.warning("uplink: policy_result not sent: #{inspect(reason)}")
    end

    socket
  end

  # heartbeat

  defp send_heartbeat(socket) do
    a = socket.assigns
    cancel(a.heartbeat_timer)
    now = a.c.clock.now()

    status =
      try do
        Encode.status(Enforcer.status(a.c.enforcer))
      catch
        :exit, _ -> nil
      end

    socket =
      case push_msg(socket, "heartbeat", %{
             "status" => status,
             "sent_at" => DateTime.to_iso8601(now)
           }) do
        {:ok, _ref} ->
          assign(socket, :last_heartbeat_at, now)

        {:error, reason} ->
          Logger.warning("uplink: heartbeat not sent: #{inspect(reason)}")
          socket
      end

    assign(socket, :heartbeat_timer, Process.send_after(self(), :heartbeat, a.heartbeat_ms))
  end

  # events and audit

  defp sync(socket) do
    if joined?(socket, socket.assigns.c.topic),
      do: socket |> sync_events() |> sync_audit(),
      else: socket
  end

  defp schedule_sync(socket) do
    a = socket.assigns
    cancel(a.sync_timer)

    if joined?(socket, a.c.topic),
      do: assign(socket, :sync_timer, Process.send_after(self(), :sync, a.c.sync_ms)),
      else: assign(socket, :sync_timer, nil)
  end

  defp sync_events(%{assigns: %{events: %{ref: ref}}} = socket) when ref != nil, do: socket

  defp sync_events(socket) do
    a = socket.assigns
    batch = a.events || take_events(a.c)

    if batch do
      case push_msg(socket, "events", %{"events" => batch.batch}) do
        {:ok, ref} ->
          timer = Process.send_after(self(), {:reply_timeout, ref}, a.c.reply_timeout_ms)
          assign(socket, :events, %{batch | ref: ref, timer: timer})

        {:error, reason} ->
          Logger.warning("uplink: events not sent: #{inspect(reason)}")
          assign(socket, :events, batch)
      end
    else
      socket
    end
  end

  defp take_events(c) do
    events =
      try do
        Events.drain(@events_batch, c.events)
      catch
        :exit, _ -> []
      end

    case events do
      [] ->
        nil

      events ->
        batch = Enum.map(events, &Encode.event(&1, event_id()))
        %{batch: batch, ref: nil, timer: nil, failures: 0}
    end
  end

  defp event_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp sync_audit(%{assigns: %{audit_flight: flight}} = socket) when flight != nil, do: socket

  defp sync_audit(socket) do
    c = socket.assigns.c

    case audit_state(c) do
      {:ok, chain_id, head} ->
        socket = maybe_new_chain(socket, chain_id)
        next = socket.assigns.audit_next

        case head do
          {head_seq, _} when head_seq >= next -> push_audit(socket, chain_id, next)
          _ -> socket
        end

      :error ->
        socket
    end
  end

  defp audit_state(c) do
    {:ok, Store.audit_chain_id(c.store), Store.audit_head(c.store)}
  catch
    :exit, _ -> :error
  end

  defp maybe_new_chain(socket, chain_id) do
    if chain_id == socket.assigns.chain_id do
      socket
    else
      Logger.warning("uplink: the audit chain was reset, sending the new chain from seq 0")
      assign(socket, chain_id: chain_id, audit_ack: nil, audit_next: 0)
    end
  end

  defp push_audit(socket, chain_id, next) do
    c = socket.assigns.c

    case audit_records(c, next, @audit_batch) do
      [] ->
        socket

      records ->
        last = List.last(records)

        case push_msg(socket, "audit", %{"chain_id" => chain_id, "records" => records}) do
          {:ok, ref} ->
            timer = Process.send_after(self(), {:reply_timeout, ref}, c.reply_timeout_ms)
            flight = %{ref: ref, timer: timer, last: {last["seq"], last["hash"]}}
            assign(socket, :audit_flight, flight)

          {:error, reason} ->
            Logger.warning("uplink: audit records not sent: #{inspect(reason)}")
            socket
        end
    end
  end

  defp audit_records(c, from_seq, limit) do
    Store.audit_records(from_seq, limit, c.store)
  catch
    :exit, _ -> []
  end

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    a = socket.assigns

    cond do
      in_flight?(a.events, ref) -> {:ok, events_reply(reply, socket)}
      in_flight?(a.audit_flight, ref) -> {:ok, audit_reply(reply, socket)}
      true -> {:ok, socket}
    end
  end

  defp events_reply(reply, socket) do
    batch = socket.assigns.events
    cancel(batch.timer)

    if ok_reply?(reply) do
      socket |> assign(:events, nil) |> sync_events()
    else
      events_refused(reply, batch, socket)
    end
  end

  defp ok_reply?(:ok), do: true
  defp ok_reply?({:ok, _}), do: true
  defp ok_reply?(_), do: false

  defp events_refused(error, batch, socket) do
    case error do
      error ->
        failures = batch.failures + 1

        if failures >= @max_event_failures do
          Logger.error(
            "uplink: cloud refused an events batch #{failures} times, dropping " <>
              "#{length(batch.batch)} events: #{inspect(error)}"
          )

          assign(socket, :events, nil)
        else
          Logger.warning("uplink: cloud refused an events batch: #{inspect(error)}")
          assign(socket, :events, %{batch | ref: nil, timer: nil, failures: failures})
        end
    end
  end

  defp audit_reply(reply, socket) do
    flight = socket.assigns.audit_flight
    cancel(flight.timer)
    socket = assign(socket, :audit_flight, nil)

    case reply do
      {:ok, %{"head" => %{"seq" => seq, "hash" => hash}}} when is_integer(seq) and seq >= 0 ->
        if {seq, hash} != flight.last,
          do: Logger.warning("uplink: cloud audit head #{seq} is not the last record sent")

        socket |> assign(audit_ack: {seq, hash}, audit_next: seq + 1) |> sync_audit()

      {:error, %{"reason" => "chain_mismatch", "expected_seq" => seq}}
      when is_integer(seq) and seq >= 0 ->
        Logger.warning("uplink: audit chain mismatch, sending again from seq #{seq}")

        socket
        |> assign(audit_ack: ack_before(socket.assigns.c, seq), audit_next: seq)
        |> sync_audit()

      other ->
        Logger.warning("uplink: unexpected audit reply: #{inspect(other)}")
        socket
    end
  end

  defp ack_before(_c, 0), do: nil

  defp ack_before(c, seq) do
    case audit_records(c, seq - 1, 1) do
      [%{"seq" => s, "hash" => h}] -> {s, h}
      _ -> nil
    end
  end

  # helpers

  defp in_flight?(%{ref: ref}, ref) when ref != nil, do: true
  defp in_flight?(_, _), do: false

  defp push_msg(socket, event, payload) do
    push(socket, socket.assigns.c.topic, event, payload)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp cancel(nil), do: :ok

  defp cancel(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  # config

  defp config(opts) do
    c = %{
      url: Keyword.get(opts, :url),
      certfile: Keyword.get(opts, :certfile),
      keyfile: Keyword.get(opts, :keyfile),
      cacertfile: Keyword.get(opts, :cacertfile),
      server_name: Keyword.get(opts, :server_name),
      site_id: Keyword.get(opts, :site_id),
      clock: Keyword.get(opts, :clock, Gateway.Clock.System),
      enforcer: Keyword.get(opts, :enforcer, Enforcer),
      store: Keyword.get(opts, :store, Store),
      events: Keyword.get(opts, :events, Events),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 30_000),
      sync_ms: Keyword.get(opts, :sync_ms, 2_000),
      reply_timeout_ms: Keyword.get(opts, :reply_timeout_ms, 30_000),
      backoff_min_ms: Keyword.get(opts, :backoff_min_ms, 1_000),
      backoff_max_ms: Keyword.get(opts, :backoff_max_ms, 60_000),
      test_mode?: Keyword.get(opts, :test_mode?, false)
    }

    cond do
      not (is_binary(c.site_id) and c.site_id != "") ->
        {:error, "missing :site_id"}

      not wss_url?(c.url) ->
        {:error, ":url must be a wss:// url with a host, got #{inspect(c.url)}"}

      not Enum.all?([c.certfile, c.keyfile, c.cacertfile], &(is_binary(&1) and &1 != "")) ->
        {:error, ":certfile, :keyfile and :cacertfile are required"}

      not (is_nil(c.server_name) or (is_binary(c.server_name) and c.server_name != "")) ->
        {:error, ":server_name must be a non-empty string"}

      not Enum.all?(
        [c.heartbeat_ms, c.sync_ms, c.reply_timeout_ms, c.backoff_min_ms, c.backoff_max_ms],
        &(is_integer(&1) and &1 > 0)
      ) ->
        {:error, "timings must be positive integers"}

      true ->
        {:ok, Map.put(c, :topic, "gateway:" <> c.site_id)}
    end
  end

  defp wss_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp wss_url?(_), do: false

  defp slipstream_opts(c) do
    [
      uri: c.url,
      mint_opts: mint_opts(c),
      json_parser: JSON,
      test_mode?: c.test_mode?
    ]
  end

  defp warn_missing_files(%{test_mode?: true}), do: :ok

  defp warn_missing_files(c) do
    for file <- [c.certfile, c.keyfile, c.cacertfile], not File.exists?(file) do
      Logger.warning("uplink: #{file} does not exist, connecting will fail until it does")
    end

    :ok
  end

  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
