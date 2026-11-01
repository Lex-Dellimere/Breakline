import Config

# prod reads everything from the environment at boot:
#
#   BREAKLINE_SITE_ID           required, unless the box is enrolled (see below)
#   BREAKLINE_PUBLIC_KEYS       required with BREAKLINE_SITE_ID, "key_id=base64url,key_id2=base64url"
#   BREAKLINE_LAN_INTERFACES    required, "eth1" or "eth1,eth2"
#   BREAKLINE_UPSTREAMS         optional, "1.1.1.1,9.9.9.9:53" (port defaults to 53)
#   BREAKLINE_DATA_DIR          optional, default /var/lib/breakline
#   BREAKLINE_DEFAULT_MODE      optional, monitor (default) or enforce
#   BREAKLINE_DNS_IP            optional, address the resolver binds, default 0.0.0.0
#   BREAKLINE_UPLINK_URL        optional, "wss://host/gateway/socket/websocket"; without
#                               it the gateway runs with no uplink
#   BREAKLINE_UPLINK_CERT       required with the url, client certificate (pem)
#   BREAKLINE_UPLINK_KEY        required with the url, client key (pem)
#   BREAKLINE_UPLINK_CA         required with the url, ca of the cloud's server cert (pem)
#   BREAKLINE_UPLINK_SERVER_NAME optional, name to verify when it is not the url's host
#
# with BREAKLINE_SITE_ID set, the variables above are the whole config, exactly as before
# enrolment existed. without it, an enrolled box (Gateway.Enroll) takes the site id, the
# public keys and the uplink from <data_dir>/enrollment.json, <data_dir>/server_ca.pem and
# its identity in <data_dir>/identity/; any variable that is set still wins. a box that is
# not enrolled boots without raising, so `bin/gateway eval` works: it has no site, trusts
# no key (so it never accepts a policy and stays locked), has no uplink, and logs that it
# is not enrolled
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

  parse_keys = fn value ->
    value
    |> list.()
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [id, key] when id != "" and key != "" -> {id, key}
        _ -> raise "invalid BREAKLINE_PUBLIC_KEYS entry #{inspect(pair)}"
      end
    end)
  end

  data_dir = System.get_env("BREAKLINE_DATA_DIR", "/var/lib/breakline")

  # the file Gateway.Enroll writes, read the same way as Gateway.Enroll.read/1
  enrollment =
    with {:ok, bytes} <- File.read(Path.join(data_dir, "enrollment.json")),
         {:ok, %{"site_id" => id} = e} when is_binary(id) and id != "" <- JSON.decode(bytes) do
      e
    else
      _ -> nil
    end

  source =
    cond do
      System.get_env("BREAKLINE_SITE_ID") -> :env
      enrollment -> :enrollment
      true -> :unenrolled
    end

  {site_id, public_keys} =
    case source do
      :env ->
        {fetch!.("BREAKLINE_SITE_ID"), parse_keys.(fetch!.("BREAKLINE_PUBLIC_KEYS"))}

      :enrollment ->
        keys =
          case System.get_env("BREAKLINE_PUBLIC_KEYS") do
            nil -> enrollment["public_keys"]
            value -> parse_keys.(value)
          end

        {enrollment["site_id"], keys}

      # no site and no key: every command is refused and the box stays locked
      :unenrolled ->
        {"unenrolled", %{}}
    end

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

  # required as before, except that an enrolled or unenrolled box must still get as far
  # as `bin/gateway eval`; starting the gateway without it fails at boot
  lan_interfaces =
    case {source, System.get_env("BREAKLINE_LAN_INTERFACES")} do
      {:env, _} -> [lan_interfaces: list.(fetch!.("BREAKLINE_LAN_INTERFACES"))]
      {_, nil} -> []
      {_, value} -> [lan_interfaces: list.(value)]
    end

  config :gateway,
         [
           site_id: site_id,
           public_keys: public_keys,
           data_dir: data_dir,
           default_mode: mode,
           firewall_impl: Gateway.Firewall.NftImpl,
           firewall_impl_opts: [],
           unenrolled?: source == :unenrolled
         ] ++ lan_interfaces

  dns = [ip: parse_ip.(System.get_env("BREAKLINE_DNS_IP", "0.0.0.0")), port: 53]
  dns = if upstreams, do: Keyword.put(dns, :upstreams, upstreams), else: dns

  config :gateway, Gateway.DNS, dns

  identity = Path.join(data_dir, "identity")

  uplink =
    case {System.get_env("BREAKLINE_UPLINK_URL"), source} do
      {url, :enrollment} ->
        [
          url: url || enrollment["uplink_url"],
          certfile:
            System.get_env("BREAKLINE_UPLINK_CERT") || Path.join(identity, "gateway_cert.pem"),
          keyfile:
            System.get_env("BREAKLINE_UPLINK_KEY") || Path.join(identity, "gateway_key.pem"),
          cacertfile:
            System.get_env("BREAKLINE_UPLINK_CA") || Path.join(data_dir, "server_ca.pem"),
          server_name: System.get_env("BREAKLINE_UPLINK_SERVER_NAME") || enrollment["server_name"]
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      {_, :unenrolled} ->
        nil

      {nil, :env} ->
        nil

      {url, :env} ->
        uplink = [
          url: url,
          certfile: fetch!.("BREAKLINE_UPLINK_CERT"),
          keyfile: fetch!.("BREAKLINE_UPLINK_KEY"),
          cacertfile: fetch!.("BREAKLINE_UPLINK_CA")
        ]

        case System.get_env("BREAKLINE_UPLINK_SERVER_NAME") do
          nil -> uplink
          name -> Keyword.put(uplink, :server_name, name)
        end
    end

  if uplink, do: config(:gateway, :uplink, uplink)
end
