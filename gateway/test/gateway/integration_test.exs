defmodule Gateway.IntegrationTest do
  # the whole tree, with its registered names, the fake clock and the dns snapshot
  use ExUnit.Case, async: false

  import Gateway.TestSupport

  alias Gateway.Clock.Fake
  alias Gateway.DNS.Snapshot
  alias Gateway.{Enforcer, Events, FakeUpstream}

  # monday 2 november 2026, 11:00 in sydney
  @now ~U[2026-11-02 00:00:00Z]

  @answers %{
    "boot.net.anydesk.com" => [
      {:a, "boot.net.anydesk.com", {10, 0, 0, 1}, 60},
      {:aaaa, "boot.net.anydesk.com", {0xFD00, 0, 0, 0, 0, 0, 0, 1}, 60}
    ],
    "rmm.client.example" => [{:a, "rmm.client.example", {10, 0, 0, 3}, 120}],
    "example.com" => [{:a, "example.com", {93, 184, 216, 34}, 300}]
  }

  setup do
    Snapshot.clear()
    on_exit(&Snapshot.clear/0)

    {pub, priv} = keypair()
    start_supervised!({Fake, now: @now})
    upstream = FakeUpstream.start(@answers)
    dir = tmp_dir("integration")

    children =
      Gateway.Application.children(
        site_id: site(),
        public_keys: %{"k1" => b64(pub)},
        lan_interfaces: ["eth1"],
        data_dir: dir,
        clock: Fake,
        tick_ms: 60_000,
        dns_port: 5300,
        default_mode: :enforce,
        firewall_impl: Gateway.Firewall.FakeImpl,
        inbox_dir: nil,
        dns: [port: 0, upstreams: [upstream], timeout_ms: 500]
      )

    sup =
      start_supervised!(%{
        id: :gateway_tree,
        type: :supervisor,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
      })

    # wait for the enforcer's boot evaluation
    Enforcer.status()

    %{sup: sup, priv: priv, dir: dir, port: Gateway.DNS.port(Gateway.DNS.Supervisor)}
  end

  defp resolved_ips do
    %{state: %{resolved: resolved}} = Gateway.Firewall.snapshot()
    resolved
  end

  test "the tree starts its subtrees in order", %{sup: sup} do
    ids = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
    assert ids == [:firewall, Gateway.Events, :enforcer, Gateway.DNS.Supervisor]
  end

  test "locked names get nxdomain and their shadow ips reach the firewall; opening resolves",
       ctx do
    reply = FakeUpstream.query(ctx.port, "boot.net.anydesk.com")
    assert FakeUpstream.rcode(reply) == 3

    resolved =
      eventually(fn ->
        r = resolved_ips()
        map_size(r) == 2 && r
      end)

    assert %{tool_id: "anydesk"} = resolved[{10, 0, 0, 1}]
    assert %{tool_id: "anydesk"} = resolved[{0xFD00, 0, 0, 0, 0, 0, 0, 1}]

    assert eventually(fn ->
             Enum.find(Events.recent(), &(&1[:type] == :blocked))
           end).qname == "boot.net.anydesk.com"

    # ordinary names are untouched
    assert {:a, {93, 184, 216, 34}} in FakeUpstream.answers(
             FakeUpstream.query(ctx.port, "example.com")
           )

    window = %{
      id: "now",
      starts_at: ~N[2026-11-02 10:30:00],
      ends_at: ~N[2026-11-02 12:00:00]
    }

    assert :ok = Enforcer.submit(signed(ctx.priv, 1, one_off_windows: [window]))
    assert Enforcer.status().state == :open
    refute fake_desired().locked?

    reply = FakeUpstream.query(ctx.port, "boot.net.anydesk.com")
    assert FakeUpstream.rcode(reply) == 0
    assert {:a, {10, 0, 0, 1}} in FakeUpstream.answers(reply)
  end

  test "site hostnames are blocked and tagged for the firewall", ctx do
    assert :ok = Enforcer.submit(signed(ctx.priv, 1, site_hosts: ["rmm.client.example"]))

    reply = FakeUpstream.query(ctx.port, "rmm.client.example")
    assert FakeUpstream.rcode(reply) == 3

    assert %{tool_id: "site_host:rmm.client.example"} =
             eventually(fn -> resolved_ips()[{10, 0, 0, 3}] end)
  end

  test "killing the dns server leaves the firewall alone" do
    fw = Process.whereis(Gateway.Firewall.Server)
    before = Gateway.Firewall.snapshot()

    {_, dns_server, _, _} =
      Gateway.DNS.Supervisor
      |> Supervisor.which_children()
      |> Enum.find(fn {id, _, _, _} -> id == Gateway.DNS.Server end)

    Process.exit(dns_server, :kill)
    eventually(fn -> port_if_restarted(dns_server) end)

    # and the whole dns subtree
    dns_sup = Process.whereis(Gateway.DNS.Supervisor)
    Process.exit(dns_sup, :kill)

    new_port =
      eventually(fn ->
        pid = Process.whereis(Gateway.DNS.Supervisor)
        pid && pid != dns_sup && Gateway.DNS.port(pid)
      end)

    assert Process.whereis(Gateway.Firewall.Server) == fw
    assert Gateway.Firewall.snapshot() == before
    assert FakeUpstream.rcode(FakeUpstream.query(new_port, "boot.net.anydesk.com")) == 3
  end

  test "killing the firewall server makes the enforcer re-apply", _ctx do
    fw = Process.whereis(Gateway.Firewall.Server)
    desired = fake_desired()
    assert desired.locked?

    Process.exit(fw, :kill)

    eventually(fn ->
      pid = Process.whereis(Gateway.Firewall.Server)
      pid && pid != fw && fake_desired() == desired
    end)

    assert Enforcer.status().firewall.in_sync?
  end

  test "the audit file verifies after a run", ctx do
    assert :ok = Enforcer.submit(signed(ctx.priv, 1))
    assert {:error, :stale_version} = Enforcer.submit(signed(ctx.priv, 1))
    Fake.set_synced(false)
    Enforcer.evaluate()

    types = audit_types(ctx.dir)

    assert types == [
             "enforcer_started",
             "state_changed",
             "policy_applied",
             "state_changed",
             "command_rejected",
             "state_changed"
           ]
  end

  defp port_if_restarted(old) do
    case Supervisor.which_children(Gateway.DNS.Supervisor)
         |> Enum.find(fn {id, _, _, _} -> id == Gateway.DNS.Server end) do
      {_, pid, _, _} when is_pid(pid) and pid != old -> Gateway.DNS.Server.port(pid)
      _ -> nil
    end
  end
end
