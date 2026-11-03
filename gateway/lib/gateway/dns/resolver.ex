defmodule Gateway.DNS.Resolver do
  @moduledoc """
  Decides what to answer for one client packet. It runs inside a query task,
  never in the listener.

  Order of checks for a standard query with one question, on the normalised
  name (lowercase, one trailing dot removed):

    1. DoH/DoT hostnames and canary names from `Gateway.DoH` always get
       NXDOMAIN and a `:doh_blocked` event, whatever the lock state.
    2. A catalog match for the snapshot's tools, or an exact site hostname.
       Locked and enforcing: NXDOMAIN, a `:blocked` event, and a background
       "shadow" lookup whose A/AAAA records go to `on_resolved`, so the
       firewall's ip set stays current. Locked and monitoring: forward, a
       `:would_block` event, records to `on_resolved`. Open: forward, records
       to `on_resolved`.
    3. Anything else is forwarded and the upstream bytes are returned
       unchanged. The answer's CNAME targets are then checked the same way, so
       a vanity name CNAMEd into a catalog domain is caught: NXDOMAIN when
       locked and enforcing, and its A/AAAA records go to `on_resolved`
       either way.

  A query with any other opcode gets NOTIMP: a client resolver has no reason to
  send notify, update or status, and forwarding them unchecked would be a way
  around the checks below. A standard query with
  zero or several questions gets FORMERR, because forwarding it would let a
  second question slip past the checks. Packets that do not decode get
  FORMERR. Packets shorter than a header, or with QR set, are dropped.
  """

  require Record
  require Logger

  alias Gateway.DNS.{Packet, Snapshot, Upstream}

  @hrl "kernel/src/inet_dns.hrl"
  Record.defrecordp(:dns_rec, Record.extract(:dns_rec, from_lib: @hrl))
  Record.defrecordp(:dns_header, Record.extract(:dns_header, from_lib: @hrl))
  Record.defrecordp(:dns_query, Record.extract(:dns_query, from_lib: @hrl))
  Record.defrecordp(:dns_rr, Record.extract(:dns_rr, from_lib: @hrl))
  Record.defrecordp(:dns_rr_opt, Record.extract(:dns_rr_opt, from_lib: @hrl))

  @typedoc "What a name matched: a catalog tool id or a per-site hostname."
  @type tag :: String.t() | {:site_host, String.t()}

  @type ctx :: %{
          required(:upstreams) => [Upstream.upstream()],
          required(:timeout_ms) => pos_integer(),
          required(:on_resolved) => ([{:inet.ip_address(), non_neg_integer(), tag()}] -> any()),
          required(:on_event) => (map() -> any()),
          required(:task_sup) => GenServer.server(),
          required(:client) => :inet.ip_address(),
          required(:transport) => :udp | :tcp
        }

  @doc "Returns the reply bytes for a client packet, or `:drop` to send nothing."
  @spec handle(binary(), ctx()) :: {:reply, binary()} | :drop
  def handle(packet, ctx) do
    if Packet.query?(packet) do
      case safe_decode(packet) do
        {:ok, msg} -> dispatch(packet, msg, ctx)
        :error -> {:reply, Packet.formerr(packet)}
      end
    else
      :drop
    end
  end

  defp safe_decode(packet) do
    case :inet_dns.decode(packet) do
      {:ok, msg} -> {:ok, msg}
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  defp dispatch(packet, msg, ctx) do
    header = dns_rec(msg, :header)

    case {dns_header(header, :opcode), dns_rec(msg, :qdlist)} do
      {:query, [question]} -> decide(packet, msg, question, ctx)
      {:query, _} -> {:reply, Packet.formerr(packet)}
      {_other, _} -> {:reply, Packet.notimp(packet)}
    end
  end

  defp decide(packet, msg, question, ctx) do
    name = question |> dns_query(:domain) |> to_name()
    qtype = dns_query(question, :type)
    snap = Snapshot.get()

    with :nomatch <- Gateway.DoH.match(name),
         :nomatch <- classify(name, snap) do
      plain(packet, msg, name, qtype, snap, ctx)
    else
      {:doh, _} = match ->
        event(ctx, :doh_blocked, name, qtype, match)
        {:reply, Packet.nxdomain(packet)}

      {:canary, _} = match ->
        event(ctx, :doh_blocked, name, qtype, match)
        {:reply, Packet.nxdomain(packet)}

      {:ok, tag} ->
        matched(packet, msg, name, qtype, tag, snap, ctx)
    end
  end

  # case 2: the question name itself is a catalog domain or a site host
  defp matched(packet, msg, name, qtype, tag, snap, ctx) do
    case state(snap) do
      :enforce ->
        event(ctx, :blocked, name, qtype, tag)
        shadow(name, tag, ctx)
        {:reply, Packet.nxdomain(packet)}

      :monitor ->
        event(ctx, :would_block, name, qtype, tag)
        forward_and_record(packet, msg, tag, ctx)

      :open ->
        forward_and_record(packet, msg, tag, ctx)
    end
  end

  # case 3: forward, then look for a cname into a blocked name
  defp plain(packet, msg, name, qtype, snap, ctx) do
    case Upstream.query(packet, ctx.upstreams, ctx.timeout_ms) do
      {:ok, result} ->
        answers = answers(result.full)

        case cname_match(answers, snap) do
          nil ->
            {:reply, pick(result, msg, ctx)}

          {target, tag} ->
            record(ctx, answers, tag)
            match = {:cname, target, tag}

            case state(snap) do
              :enforce ->
                event(ctx, :blocked, name, qtype, match)
                {:reply, Packet.nxdomain(packet)}

              :monitor ->
                event(ctx, :would_block, name, qtype, match)
                {:reply, pick(result, msg, ctx)}

              :open ->
                {:reply, pick(result, msg, ctx)}
            end
        end

      :error ->
        {:reply, Packet.servfail(packet)}
    end
  end

  defp forward_and_record(packet, msg, tag, ctx) do
    case Upstream.query(packet, ctx.upstreams, ctx.timeout_ms) do
      {:ok, result} ->
        record(ctx, answers(result.full), tag)
        {:reply, pick(result, msg, ctx)}

      :error ->
        {:reply, Packet.servfail(packet)}
    end
  end

  # the client already has its nxdomain; this only keeps the firewall's ip set
  # current. it asks for both a and aaaa whatever the client asked, so an https
  # or txt query still refreshes both address families.
  defp shadow(name, tag, ctx) do
    fun = fn ->
      for type <- [:a, :aaaa] do
        case Upstream.query(shadow_query(name, type), ctx.upstreams, ctx.timeout_ms) do
          {:ok, result} -> record(ctx, answers(result.full), tag)
          :error -> :ok
        end
      end
    end

    case Task.Supervisor.start_child(ctx.task_sup, fun) do
      {:ok, _pid} -> :ok
      {:error, _} -> :ok
    end
  catch
    _, _ -> :ok
  end

  defp shadow_query(name, type) do
    <<id::16>> = :crypto.strong_rand_bytes(2)

    :inet_dns.encode(
      dns_rec(
        header: dns_header(id: id, opcode: :query, rd: true),
        qdlist: [dns_query(domain: :erlang.binary_to_list(name), type: type, class: :in)]
      )
    )
  end

  defp state(%Snapshot{locked?: false}), do: :open
  defp state(%Snapshot{mode: :monitor}), do: :monitor
  defp state(%Snapshot{}), do: :enforce

  defp classify(name, snap) do
    cond do
      name in snap.site_hostnames -> {:ok, {:site_host, name}}
      name == "" -> :nomatch
      true -> Breakline.Catalog.match_domain(name, snap.tool_ids)
    end
  end

  defp cname_match(answers, snap) do
    Enum.find_value(answers, fn rr ->
      if dns_rr(rr, :type) == :cname do
        target = rr |> dns_rr(:data) |> to_name()

        case classify(target, snap) do
          {:ok, tag} -> {target, tag}
          :nomatch -> nil
        end
      end
    end)
  end

  defp answers(reply) do
    case safe_decode(reply) do
      {:ok, msg} -> dns_rec(msg, :anlist)
      :error -> []
    end
  end

  defp record(ctx, answers, tag) do
    entries =
      for rr <- answers, dns_rr(rr, :type) in [:a, :aaaa], is_tuple(dns_rr(rr, :data)) do
        {dns_rr(rr, :data), dns_rr(rr, :ttl), tag}
      end

    if entries != [], do: safe(ctx.on_resolved, entries)
  end

  defp event(ctx, type, name, qtype, match) do
    safe(ctx.on_event, %{
      type: type,
      qname: name,
      qtype: qtype,
      match: match,
      channel: channel(name, match),
      client: ctx.client,
      at: DateTime.utc_now()
    })
  end

  # the catalog channel of the matched name (the cname target for a cname match),
  # recorded for the pilots only; nil for site hosts and doh
  defp channel(_name, {:cname, target, tool_id}) when is_binary(tool_id),
    do: channel(target, tool_id)

  defp channel(name, tool_id) when is_binary(tool_id) do
    case Breakline.Catalog.match_domain_channel(name, [tool_id]) do
      {:ok, {_, channel}} -> channel
      :nomatch -> nil
    end
  end

  defp channel(_name, _match), do: nil

  defp safe(fun, arg) do
    fun.(arg)
  rescue
    e -> Logger.warning("dns callback raised: " <> Exception.message(e))
  catch
    kind, reason -> Logger.warning("dns callback failed: #{inspect({kind, reason})}")
  end

  # a udp client gets the full answer only if it fits the buffer it advertised
  defp pick(%{full: full, truncated: nil}, _msg, _ctx), do: full
  defp pick(%{full: full}, _msg, %{transport: :tcp}), do: full

  defp pick(%{full: full, truncated: truncated}, msg, _ctx) do
    if byte_size(full) <= udp_limit(msg), do: full, else: truncated
  end

  defp udp_limit(msg) do
    Enum.find_value(dns_rec(msg, :arlist), 512, fn
      rr when Record.is_record(rr, :dns_rr_opt) -> max(dns_rr_opt(rr, :udp_payload_size), 512)
      _ -> nil
    end)
  end

  defp to_name(domain) when is_list(domain) do
    domain |> :erlang.list_to_binary() |> Snapshot.normalize()
  rescue
    _ -> ""
  end

  defp to_name(_), do: ""
end
