import Config

# dev runs on a normal linux host: fake firewall, resolver on a high port, state under
# gateway/tmp/dev (git-ignored). keys come from `mix gateway.dev.keygen`.
dev_dir = Path.expand("../tmp/dev", __DIR__)
key_file = Path.expand("../priv/keys/dev_ed25519.json", __DIR__)

read_key = fn path ->
  with {:ok, bytes} <- File.read(path),
       {:ok, %{"key_id" => id, "public_key" => pub}} <- JSON.decode(bytes) do
    %{id => pub}
  else
    _ -> %{}
  end
end

public_keys = read_key.(key_file)

config :gateway,
  site_id: "dev-site",
  public_keys: public_keys,
  dev_key_file: key_file,
  firewall_impl: Gateway.Firewall.FakeImpl,
  firewall_impl_opts: [],
  lan_interfaces: ["eth1"],
  data_dir: dev_dir,
  inbox_dir: Path.join(dev_dir, "inbox"),
  default_mode: :monitor,
  tick_ms: 15_000

config :gateway, Gateway.DNS,
  ip: {127, 0, 0, 1},
  port: 5300

# the uplink to a local cloud on 4011, wired up by `mix cloud.dev.gateway_cert <site_id>`
# in cloud/, which writes into priv/keys/ (git-ignored): the client certificate and key,
# the dev ca, site.json and the cloud signer's public key. with all of them present the
# gateway takes that site id, trusts the cloud's key as well as the dev key, and dials
# the cloud. without them dev runs on the inbox alone, as before
keys_dir = Path.expand("../priv/keys", __DIR__)

uplink_files =
  ~w(gateway_cert.pem gateway_key.pem ca_cert.pem site.json cloud_signer.public.json)

cloud_site_id =
  with true <- Enum.all?(uplink_files, &File.exists?(Path.join(keys_dir, &1))),
       {:ok, bytes} <- File.read(Path.join(keys_dir, "site.json")),
       {:ok, %{"site_id" => id}} when is_binary(id) and id != "" <- JSON.decode(bytes) do
    id
  else
    _ -> nil
  end

enrolled_dir = Path.expand("../tmp/dev_enrolled", __DIR__)

# a dev box enrolled with `mix gateway.enroll` (the real handshake) wins over the
# priv/keys shortcut. its state lives in the enrolment's own directory
enrollment =
  with {:ok, bytes} <- File.read(Path.join(enrolled_dir, "enrollment.json")),
       {:ok, %{"site_id" => id} = e} when is_binary(id) and id != "" <- JSON.decode(bytes) do
    e
  else
    _ -> nil
  end

cond do
  enrollment ->
    config :gateway,
      site_id: enrollment["site_id"],
      public_keys: Map.merge(public_keys, enrollment["public_keys"] || %{}),
      data_dir: enrolled_dir,
      inbox_dir: Path.join(enrolled_dir, "inbox")

    config :gateway, :uplink,
      url: enrollment["uplink_url"],
      certfile: Path.join(enrolled_dir, "identity/gateway_cert.pem"),
      keyfile: Path.join(enrolled_dir, "identity/gateway_key.pem"),
      cacertfile: Path.join(enrolled_dir, "server_ca.pem"),
      server_name: enrollment["server_name"]

  cloud_site_id ->
    # the cloud site's state lives apart from the inbox demo's dev-site state, whose
    # version floor (unix time versions) would refuse the cloud's policy versions
    uplink_dir = Path.expand("../tmp/dev_uplink", __DIR__)

    config :gateway,
      site_id: cloud_site_id,
      public_keys:
        Map.merge(public_keys, read_key.(Path.join(keys_dir, "cloud_signer.public.json"))),
      data_dir: uplink_dir,
      inbox_dir: Path.join(uplink_dir, "inbox")

    config :gateway, :uplink,
      url: "wss://localhost:4011/gateway/socket/websocket",
      certfile: Path.join(keys_dir, "gateway_cert.pem"),
      keyfile: Path.join(keys_dir, "gateway_key.pem"),
      cacertfile: Path.join(keys_dir, "ca_cert.pem"),
      server_name: "localhost"

  true ->
    :ok
end
