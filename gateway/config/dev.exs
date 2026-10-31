import Config

# dev runs on a normal linux host: fake firewall, resolver on a high port, state under
# gateway/tmp/dev (git-ignored). keys come from `mix gateway.dev.keygen`.
dev_dir = Path.expand("../tmp/dev", __DIR__)
key_file = Path.expand("../priv/keys/dev_ed25519.json", __DIR__)

public_keys =
  with {:ok, bytes} <- File.read(key_file),
       {:ok, %{"key_id" => id, "public_key" => pub}} <- JSON.decode(bytes) do
    %{id => pub}
  else
    _ -> %{}
  end

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

# the uplink to a local cloud, off by default so dev keeps using the inbox. the cloud
# listens on 4011 with mutual tls and the certificates are generated into priv/keys/
# (git-ignored). uncomment to connect:
#
# keys_dir = Path.expand("../priv/keys", __DIR__)
#
# config :gateway, :uplink,
#   url: "wss://localhost:4011/gateway/socket/websocket",
#   certfile: Path.join(keys_dir, "gateway_cert.pem"),
#   keyfile: Path.join(keys_dir, "gateway_key.pem"),
#   cacertfile: Path.join(keys_dir, "ca_cert.pem"),
#   server_name: "localhost"
