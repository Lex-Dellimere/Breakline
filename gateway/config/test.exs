import Config

# tests start the processes they need, including the whole tree from
# Gateway.Application.children/1
config :gateway,
  start_children: false,
  site_id: "test-site",
  lan_interfaces: ["eth1"],
  firewall_impl: Gateway.Firewall.FakeImpl

config :logger, level: :warning
