import Config

# prod reads everything from the environment at boot:
#
#   BREAKLINE_SITE_ID           required
#   BREAKLINE_PUBLIC_KEYS       required, "key_id=base64url,key_id2=base64url"
#   BREAKLINE_LAN_INTERFACES    required, "eth1" or "eth1,eth2"
#   BREAKLINE_UPSTREAMS         optional, "1.1.1.1,9.9.9.9:53" (port defaults to 53)
#   BREAKLINE_DATA_DIR          optional, default /data/breakline
#   BREAKLINE_DEFAULT_MODE      optional, monitor (default) or enforce
#   BREAKLINE_DNS_IP            optional, address the resolver binds, default 0.0.0.0
if config_env() == :prod do
  fetch! = fn name ->
    System.get_env(name) || raise "environment variable #{name} is missing"
  end

  list = fn value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) end

  parse_ip = fn s ->
    case :inet.parse_strict_address(String.to_charlist(s)) do
      {:ok, ip} -> ip
      {:error, _} -> raise "invalid ip address #{inspect(s)}"
    end
  end

  public_keys =
    "BREAKLINE_PUBLIC_KEYS"
    |> fetch!.()
    |> list.()
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [id, key] when id != "" and key != "" -> {id, key}
        _ -> raise "invalid BREAKLINE_PUBLIC_KEYS entry #{inspect(pair)}"
      end
    end)

  upstreams =
    case System.get_env("BREAKLINE_UPSTREAMS") do
      nil ->
        nil

      value ->
        value
        |> list.()
        |> Enum.map(fn entry ->
          # an ipv6 upstream with a port is written [addr]:port
          case Regex.run(~r/^\[(.+)\]:(\d+)$|^([^:\[\]]+):(\d+)$/, entry) do
            [_, v6, port] -> {parse_ip.(v6), String.to_integer(port)}
            [_, "", "", v4, port] -> {parse_ip.(v4), String.to_integer(port)}
            _ -> {parse_ip.(entry), 53}
          end
        end)
    end

  mode =
    case System.get_env("BREAKLINE_DEFAULT_MODE", "monitor") do
      "monitor" -> :monitor
      "enforce" -> :enforce
      other -> raise "invalid BREAKLINE_DEFAULT_MODE #{inspect(other)}"
    end

  config :gateway,
    site_id: fetch!.("BREAKLINE_SITE_ID"),
    public_keys: public_keys,
    lan_interfaces: list.(fetch!.("BREAKLINE_LAN_INTERFACES")),
    data_dir: System.get_env("BREAKLINE_DATA_DIR", "/data/breakline"),
    default_mode: mode,
    firewall_impl: Gateway.Firewall.NftImpl,
    firewall_impl_opts: []

  dns = [ip: parse_ip.(System.get_env("BREAKLINE_DNS_IP", "0.0.0.0")), port: 53]
  dns = if upstreams, do: Keyword.put(dns, :upstreams, upstreams), else: dns

  config :gateway, Gateway.DNS, dns
end
