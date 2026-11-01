defmodule Gateway.Traffic.BridgeNoNetfilterTest do
  # the bridge topology with br_netfilter's bridge-nf-call sysctls off in the
  # container's namespace: the inet hooks never see bridged packets
  use ExUnit.Case, async: true

  import Gateway.Traffic

  @moduletag :traffic
  @moduletag timeout: 300_000

  setup_all do
    {:ok, ctx: start!(:bridge, bridge_nf: false)}
  end

  test "nothing on the bridge is enforced, and the status says why", %{ctx: ctx} do
    lock!(ctx)

    assert status(ctx).firewall.host_problems == [
             {:bridge_netfilter_off, "br0", "bridge-nf-call-iptables"},
             {:bridge_netfilter_off, "br0", "bridge-nf-call-ip6tables"}
           ]

    # client dns reaches the rogue resolver and rmm ports pass: fail-open
    assert %{answers: ["192.0.2.66"]} = dig(ctx, "8.8.8.8", "boot.net.anydesk.com")

    assert_probes(ctx, %{
      {:tcp, "192.0.2.50", 6568} => :pass,
      {:tcp, "192.0.2.50", 853} => :pass,
      {:tcp, "1.1.1.1", 443} => :pass
    })
  end
end
