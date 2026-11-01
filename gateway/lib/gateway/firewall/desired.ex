defmodule Gateway.Firewall.Desired do
  @moduledoc """
  The desired static firewall state: everything the static ruleset is built from.

  The Enforcer builds one of these from the current policy, the schedule and the
  catalog, and hands it to `Gateway.Firewall.apply_desired/1`. Resolved RMM
  addresses are not part of it; they reach the firewall separately through
  `Gateway.Firewall.add_resolved/1` and survive every apply.

  Fields:

    * `locked?` - whether the RMM channel is locked. When locked, traffic to the
      resolved RMM addresses, to `block_cidrs` and to `exclusive_ports` is dropped.
    * `mode` - `:enforce` drops, `:monitor` turns every drop into a counter and a
      log line and drops nothing. The DNS redirect applies in both modes, so client
      queries are still visible to the gateway resolver.
    * `lan_interfaces` - interface names (for example `["eth1"]`) whose incoming
      traffic is client traffic. At least one is required, because without it client
      DNS would not be redirected.
    * `dns_port` - the local port of the gateway resolver. Client udp and tcp port 53
      arriving on a LAN interface is redirected to it.
    * `block_cidrs` - IPv4 and IPv6 addresses or CIDRs dropped while locked (catalog
      CIDRs plus per-site self-hosted RMM hosts).
    * `exclusive_ports` - `%{port: port, proto: :tcp | :udp}` dropped towards any
      destination while locked (see `Breakline.Catalog.exclusive_ports/1`).
    * `doh_ips` - IPv4 and IPv6 addresses of known public DoH resolvers, always
      dropped on tcp and udp 443.
    * `locks_at` - for an open state, the instant (UTC, whole seconds) the schedule
      locks again, or nil when it is not known. The firewall then also loads the
      locked rules behind a kernel time guard, so the channel closes on time even
      when nothing applies the locked state (the BEAM is down). Always nil when
      locked.

  `new/1` normalises everything so equal inputs give equal structs: lists are
  deduplicated and sorted, CIDR host bits are cleared (which can only widen a block),
  a `/32` or `/128` becomes a plain address, and a CIDR or address already covered by
  a wider entry is dropped, because nftables rejects overlapping intervals. It also
  fills the derived `block4`, `block6`, `doh4` and `doh6` lists, split by family,
  which is what the implementations use. `block_cidrs` and `doh_ips` hold the same
  normalised entries in one list.
  """

  import Bitwise

  @enforce_keys [:locked?, :mode, :lan_interfaces, :dns_port]
  defstruct locked?: true,
            mode: :enforce,
            lan_interfaces: [],
            dns_port: nil,
            block_cidrs: [],
            exclusive_ports: [],
            doh_ips: [],
            locks_at: nil,
            block4: [],
            block6: [],
            doh4: [],
            doh6: []

  @type mode :: :enforce | :monitor
  @type port_spec :: %{port: 1..65_535, proto: :tcp | :udp}

  @type t :: %__MODULE__{
          locked?: boolean(),
          mode: mode(),
          lan_interfaces: [String.t()],
          dns_port: 1..65_535,
          block_cidrs: [String.t()],
          exclusive_ports: [port_spec()],
          doh_ips: [String.t()],
          locks_at: DateTime.t() | nil,
          block4: [String.t()],
          block6: [String.t()],
          doh4: [String.t()],
          doh6: [String.t()]
        }

  @typedoc "A validation failure: the field, the offending value and why."
  @type reason :: {atom(), term(), atom()}

  @fields [
    :locked?,
    :mode,
    :lan_interfaces,
    :dns_port,
    :block_cidrs,
    :exclusive_ports,
    :doh_ips,
    :locks_at
  ]

  @doc """
  Validates and normalises a desired state given as a map or keyword list with the
  fields listed in the moduledoc. `block_cidrs`, `exclusive_ports` and `doh_ips`
  default to empty lists.

  Returns `{:error, reasons}` with every problem found, never a partial struct.

      iex> {:ok, d} = Gateway.Firewall.Desired.new(locked?: true, mode: :enforce,
      ...>   lan_interfaces: ["eth1"], dns_port: 5353,
      ...>   block_cidrs: ["192.0.2.7/24", "192.0.2.9", "2001:db8::1"])
      iex> {d.block4, d.block6}
      {["192.0.2.0/24"], ["2001:db8::1"]}
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, [reason()]}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    unknown = for {k, v} <- attrs, k not in @fields, do: {k, v, :unknown_field}

    missing =
      for k <- [:locked?, :mode, :lan_interfaces, :dns_port],
          not Map.has_key?(attrs, k),
          do: {k, nil, :required}

    {block, block_errors} = addresses(:block_cidrs, Map.get(attrs, :block_cidrs, []), true)
    {doh, doh_errors} = addresses(:doh_ips, Map.get(attrs, :doh_ips, []), false)
    {ports, port_errors} = ports(Map.get(attrs, :exclusive_ports, []))

    errors =
      unknown ++
        missing ++
        check(attrs, :locked?, &is_boolean/1, :not_boolean) ++
        check(attrs, :mode, &(&1 in [:enforce, :monitor]), :invalid_mode) ++
        check(attrs, :dns_port, &port?/1, :invalid_port) ++
        check(attrs, :locks_at, &(is_nil(&1) or is_struct(&1, DateTime)), :not_a_datetime) ++
        interfaces(attrs) ++ block_errors ++ doh_errors ++ port_errors

    if errors == [] do
      {block4, block6} = split(block)
      {doh4, doh6} = split(doh)

      {:ok,
       %__MODULE__{
         locked?: attrs.locked?,
         mode: attrs.mode,
         lan_interfaces: attrs.lan_interfaces |> Enum.uniq() |> Enum.sort(),
         dns_port: attrs.dns_port,
         block_cidrs: Enum.map(block4 ++ block6, & &1.text),
         exclusive_ports: ports,
         doh_ips: Enum.map(doh4 ++ doh6, & &1.text),
         locks_at: locks_at(attrs),
         block4: Enum.map(block4, & &1.text),
         block6: Enum.map(block6, & &1.text),
         doh4: Enum.map(doh4, & &1.text),
         doh6: Enum.map(doh6, & &1.text)
       }}
    else
      {:error, errors}
    end
  end

  def new(other), do: {:error, [{:attrs, other, :not_a_map}]}

  # utc and whole seconds, which is what the kernel guard compares against
  defp locks_at(%{locked?: false, locks_at: %DateTime{} = at}),
    do:
      at
      |> DateTime.shift_zone!("Etc/UTC", Breakline.time_zone_database())
      |> DateTime.truncate(:second)

  defp locks_at(_), do: nil

  defp check(attrs, key, ok?, reason) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> if ok?.(value), do: [], else: [{key, value, reason}]
      :error -> []
    end
  end

  defp port?(p), do: is_integer(p) and p in 1..65_535

  defp interfaces(%{lan_interfaces: list}) when is_list(list) and list != [] do
    for name <- list, not interface?(name), do: {:lan_interfaces, name, :invalid_interface}
  end

  defp interfaces(%{lan_interfaces: other}), do: [{:lan_interfaces, other, :empty_or_not_list}]
  defp interfaces(_), do: []

  # linux interface names are at most 15 bytes and contain no slash, whitespace or nul.
  defp interface?(name) when is_binary(name) do
    byte_size(name) in 1..15 and String.printable?(name) and
      not String.contains?(name, ["/", " ", "\t", "\n", <<0>>, "\""])
  end

  defp interface?(_), do: false

  defp ports(list) when is_list(list) do
    {ok, errors} =
      Enum.reduce(list, {[], []}, fn
        %{port: port, proto: proto} = p, {ok, errors}
        when proto in [:tcp, :udp] and map_size(p) == 2 ->
          if port?(port),
            do: {[%{port: port, proto: proto} | ok], errors},
            else: {ok, [{:exclusive_ports, p, :invalid_port} | errors]}

        p, {ok, errors} ->
          {ok, [{:exclusive_ports, p, :invalid_port_spec} | errors]}
      end)

    {ok |> Enum.uniq() |> Enum.sort_by(&{&1.port, &1.proto}), Enum.reverse(errors)}
  end

  defp ports(other), do: {[], [{:exclusive_ports, other, :not_a_list}]}

  defp addresses(field, list, cidrs?) when is_list(list) do
    {ok, errors} =
      Enum.reduce(list, {[], []}, fn entry, {ok, errors} ->
        case parse(entry, cidrs?) do
          {:ok, net} -> {[net | ok], errors}
          {:error, reason} -> {ok, [{field, entry, reason} | errors]}
        end
      end)

    {ok |> Enum.uniq() |> minimise(), Enum.reverse(errors)}
  end

  defp addresses(field, other, _), do: {[], [{field, other, :not_a_list}]}

  # parses "addr" or "addr/len" into a net map, clearing host bits.
  defp parse(entry, cidrs?) when is_binary(entry) do
    case String.split(entry, "/") do
      [addr] -> with {:ok, ip} <- address(addr), do: {:ok, net(ip, max_len(ip))}
      [addr, len] when cidrs? -> with {:ok, ip} <- address(addr), do: prefix(ip, len)
      [_, _] -> {:error, :cidr_not_allowed}
      _ -> {:error, :invalid_address}
    end
  end

  defp parse(_entry, _cidrs?), do: {:error, :invalid_address}

  defp address(addr) do
    case :inet.parse_strict_address(String.to_charlist(addr)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, :invalid_address}
    end
  end

  defp prefix(ip, len) do
    case Integer.parse(len) do
      {n, ""} when n >= 0 ->
        if n <= max_len(ip), do: {:ok, net(ip, n)}, else: {:error, :invalid_prefix}

      _ ->
        {:error, :invalid_prefix}
    end
  end

  defp max_len(ip) when tuple_size(ip) == 4, do: 32
  defp max_len(ip) when tuple_size(ip) == 8, do: 128

  defp net(ip, len) do
    width = max_len(ip)
    int = to_int(ip)
    mask = bsl(1, width) - bsl(1, width - len)
    net_int = band(int, mask)
    net_ip = from_int(net_int, tuple_size(ip))
    addr = net_ip |> :inet.ntoa() |> to_string()
    text = if len == width, do: addr, else: "#{addr}/#{len}"
    %{family: tuple_size(ip), int: net_int, len: len, width: width, text: text}
  end

  defp to_int({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

  defp to_int(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(bsl(&2, 16) + &1))

  defp from_int(int, 4),
    do: {bsr(int, 24), band(bsr(int, 16), 255), band(bsr(int, 8), 255), band(int, 255)}

  defp from_int(int, 8),
    do: 7..0//-1 |> Enum.map(&band(bsr(int, &1 * 16), 0xFFFF)) |> List.to_tuple()

  # drops every entry covered by a wider (or equal) entry of the same family, so the
  # remaining intervals never overlap.
  defp minimise(nets) do
    nets
    |> Enum.sort_by(&{&1.family, &1.len, &1.int})
    |> Enum.reduce([], fn n, kept ->
      if Enum.any?(kept, &covers?(&1, n)), do: kept, else: [n | kept]
    end)
    |> Enum.sort_by(&{&1.family, &1.int, &1.len})
  end

  defp covers?(a, b) do
    a.family == b.family and a.len <= b.len and
      bsr(a.int, a.width - a.len) == bsr(b.int, b.width - a.len)
  end

  defp split(nets), do: Enum.split_with(nets, &(&1.family == 4))
end
