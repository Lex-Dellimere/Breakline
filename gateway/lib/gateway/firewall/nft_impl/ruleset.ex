defmodule Gateway.Firewall.NftImpl.Ruleset do
  @moduledoc """
  Builds nftables JSON documents (libnftables-json(5)) for `nft -j -f`.

  Every document only touches `table inet breakline` and is applied as one atomic
  transaction. `build/2` produces the static ruleset:

    * `add table` and `add set` for `rmm4` / `rmm6` (`flags timeout`). These are no-ops
      when the objects exist, and those two sets are never flushed, so the resolved
      addresses survive every apply.
    * the static sets `block4` / `block6` (`flags interval`) and `doh4` / `doh6`, added,
      flushed and refilled.
    * the base chains `prerouting` (nat, hook prerouting, priority dstnat = -100) and
      `forward` (filter, hook forward, priority filter - 10 = -10, policy accept), added,
      flushed and rebuilt.

  Rules:

    * prerouting: udp and tcp dport 53 arriving on a LAN interface is redirected to
      the gateway resolver's port, in both modes.
    * forward, always: tcp and udp dport 853 (DoT, DoQ); tcp and udp dport 443 to
      `@doh4` / `@doh6`.
    * forward, when locked: daddr `@rmm4` / `@rmm6`; daddr `@block4` / `@block6`; tcp and
      udp dport in the exclusive ports. There is no conntrack state match before these,
      so established sessions are cut as soon as the lock starts.

  Every drop rule has a counter. In `:monitor` mode a drop rule becomes a counter and
  `log prefix "breakline would-block <reason> "` with no verdict, so the packet
  continues to the accept policy.

  The output is deterministic: the same `Gateway.Firewall.Desired` always gives an
  equal term, and `JSON.encode!/1` of it always gives the same bytes.
  """

  alias Gateway.Firewall.Desired

  @family "inet"
  @table "breakline"
  @log_prefix "breakline would-block"

  # numeric values of the named priorities: dstnat is -100, filter is 0.
  @prio_dstnat -100
  @prio_forward -10

  @doc "The nftables table family this module manages."
  @spec family() :: String.t()
  def family, do: @family

  @doc "The nftables table name this module manages."
  @spec table() :: String.t()
  def table, do: @table

  @doc """
  Builds the static ruleset document for a desired state. `opts` is reserved and
  currently unused.
  """
  @spec build(Desired.t(), keyword()) :: map()
  def build(%Desired{} = d, _opts \\ []) do
    commands =
      [add(table_obj())] ++
        rmm_sets() ++
        static_sets(d) ++
        chains() ++
        Enum.map(prerouting_rules(d), &add(rule("prerouting", &1))) ++
        Enum.map(forward_rules(d), &add(rule("forward", &1)))

    %{"nftables" => commands}
  end

  @doc """
  Builds the document that adds resolved addresses to `rmm4` / `rmm6`. Takes
  `{ip_tuple, timeout_seconds}` pairs whose timeouts are already clamped. Duplicate
  addresses keep the longest timeout. The table and the two sets are added first (a
  no-op when they exist) so the document also works before the first apply.
  """
  @spec resolved([{:inet.ip_address(), pos_integer()}]) :: map()
  def resolved(entries) do
    by_ip =
      entries
      |> Enum.group_by(fn {ip, _} -> ip end, fn {_, t} -> t end)
      |> Enum.map(fn {ip, ts} -> {ip, Enum.max(ts)} end)
      |> Enum.sort()

    {v4, v6} = Enum.split_with(by_ip, fn {ip, _} -> tuple_size(ip) == 4 end)

    elements =
      for {name, list} <- [{"rmm4", v4}, {"rmm6", v6}], list != [] do
        elem = for {ip, t} <- list, do: %{"elem" => %{"val" => ntoa(ip), "timeout" => t}}
        add(%{"element" => obj(name) |> Map.put("elem", elem)})
      end

    %{"nftables" => [add(table_obj())] ++ rmm_sets() ++ elements}
  end

  defp rmm_sets do
    [
      add(%{"set" => set_obj("rmm4", "ipv4_addr", ["timeout"])}),
      add(%{"set" => set_obj("rmm6", "ipv6_addr", ["timeout"])})
    ]
  end

  defp static_sets(d) do
    sets = [
      {"block4", "ipv4_addr", ["interval"], d.block4},
      {"block6", "ipv6_addr", ["interval"], d.block6},
      {"doh4", "ipv4_addr", [], d.doh4},
      {"doh6", "ipv6_addr", [], d.doh6}
    ]

    adds = for {name, type, flags, _} <- sets, do: add(%{"set" => set_obj(name, type, flags)})
    flushes = for {name, _, _, _} <- sets, do: %{"flush" => %{"set" => obj(name)}}

    fills =
      for {name, _, _, elems} <- sets, elems != [] do
        add(%{"element" => obj(name) |> Map.put("elem", Enum.map(elems, &element/1))})
      end

    adds ++ flushes ++ fills
  end

  defp chains do
    [
      add(%{"chain" => chain_obj("prerouting", "nat", "prerouting", @prio_dstnat)}),
      add(%{"chain" => chain_obj("forward", "filter", "forward", @prio_forward)}),
      %{"flush" => %{"chain" => chain_ref("prerouting")}},
      %{"flush" => %{"chain" => chain_ref("forward")}}
    ]
  end

  defp prerouting_rules(d) do
    for proto <- ["udp", "tcp"] do
      [
        match(meta("iifname"), %{"set" => d.lan_interfaces}),
        match(payload(proto, "dport"), 53),
        counter(),
        %{"redirect" => %{"port" => d.dns_port}}
      ]
    end
  end

  defp forward_rules(d) do
    dot = for proto <- ["tcp", "udp"], do: drop(d, "dot", [match(payload(proto, "dport"), 853)])

    doh =
      for {l3, set} <- [{"ip", "@doh4"}, {"ip6", "@doh6"}], proto <- ["tcp", "udp"] do
        drop(d, "doh", [match(payload(l3, "daddr"), set), match(payload(proto, "dport"), 443)])
      end

    if d.locked? do
      dot ++ doh ++ locked_rules(d)
    else
      dot ++ doh
    end
  end

  defp locked_rules(d) do
    addr =
      for {reason, l3, set} <- [
            {"rmm", "ip", "@rmm4"},
            {"rmm", "ip6", "@rmm6"},
            {"block", "ip", "@block4"},
            {"block", "ip6", "@block6"}
          ] do
        drop(d, reason, [match(payload(l3, "daddr"), set)])
      end

    ports =
      Enum.flat_map([:tcp, :udp], fn proto ->
        case for %{port: p, proto: ^proto} <- d.exclusive_ports, do: p do
          [] ->
            []

          ps ->
            [drop(d, "port", [match(payload(Atom.to_string(proto), "dport"), %{"set" => ps})])]
        end
      end)

    addr ++ ports
  end

  defp drop(%Desired{mode: :enforce}, _reason, matches),
    do: matches ++ [counter(), %{"drop" => nil}]

  defp drop(%Desired{mode: :monitor}, reason, matches) do
    matches ++ [counter(), %{"log" => %{"prefix" => "#{@log_prefix} #{reason} "}}]
  end

  defp element(text) do
    case String.split(text, "/") do
      [addr] -> addr
      [addr, len] -> %{"prefix" => %{"addr" => addr, "len" => String.to_integer(len)}}
    end
  end

  defp add(obj), do: %{"add" => obj}
  defp table_obj, do: %{"table" => %{"family" => @family, "name" => @table}}
  defp obj(name), do: %{"family" => @family, "table" => @table, "name" => name}

  defp set_obj(name, type, []), do: obj(name) |> Map.put("type", type)
  defp set_obj(name, type, flags), do: set_obj(name, type, []) |> Map.put("flags", flags)

  defp chain_ref(name), do: obj(name)

  defp chain_obj(name, type, hook, prio) do
    Map.merge(obj(name), %{"type" => type, "hook" => hook, "prio" => prio, "policy" => "accept"})
  end

  defp rule(chain, expr) do
    %{"rule" => %{"family" => @family, "table" => @table, "chain" => chain, "expr" => expr}}
  end

  defp match(left, right), do: %{"match" => %{"op" => "==", "left" => left, "right" => right}}
  defp meta(key), do: %{"meta" => %{"key" => key}}
  defp payload(proto, field), do: %{"payload" => %{"protocol" => proto, "field" => field}}
  defp counter, do: %{"counter" => nil}

  defp ntoa(ip), do: ip |> :inet.ntoa() |> to_string()
end
