defmodule Gateway.UplinkTreeTest do
  # the whole tree from Gateway.Application.children/1, with a test-mode uplink
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Slipstream.SocketTest
  import Gateway.TestSupport

  alias Gateway.Clock.Fake
  alias Gateway.DNS.Snapshot
  alias Gateway.{Enforcer, Uplink}

  @now ~U[2026-11-02 00:00:00Z]

  defp children(overrides) do
    {pub, _priv} = keypair()

    Gateway.Application.children(
      [
        site_id: site(),
        public_keys: %{"k1" => b64(pub)},
        lan_interfaces: ["eth1"],
        data_dir: tmp_dir("uplink-tree"),
        clock: Fake,
        tick_ms: 60_000,
        dns_port: 5300,
        firewall_impl: Gateway.Firewall.FakeImpl,
        inbox_dir: nil,
        dns: [port: 0, upstreams: [{{127, 0, 0, 1}, 1}], timeout_ms: 100]
      ] ++ overrides
    )
  end

  defp start_tree(overrides) do
    sup =
      start_supervised!(%{
        id: :gateway_tree,
        type: :supervisor,
        start: {Supervisor, :start_link, [children(overrides), [strategy: :one_for_one]]}
      })

    Enforcer.status()
    sup
  end

  setup do
    Snapshot.clear()
    on_exit(&Snapshot.clear/0)
    start_supervised!({Fake, now: @now})
    :ok
  end

  test "no uplink without uplink config" do
    sup = start_tree(uplink: nil)
    ids = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    refute :uplink in ids
    assert Uplink.status().running? == false
  end

  test "an uplink crash loop cools off and comes back, never touching the rest" do
    uplink = [
      url: "wss://cloud.test/gateway/socket/websocket",
      certfile: "c.pem",
      keyfile: "c.key",
      cacertfile: "ca.pem",
      test_mode?: true,
      backoff_min_ms: 10,
      backoff_max_ms: 40,
      cool_off_ms: 300,
      max_restarts: 3,
      max_seconds: 60
    ]

    sup = start_tree(uplink: uplink)
    ids = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
    assert List.last(ids) == :uplink
    assert %{running?: true, cool_offs: 0, cooling_off?: false} = Uplink.status()

    firewall = Process.whereis(Gateway.Firewall.Server)
    enforcer = Process.whereis(Enforcer)
    subtree = Process.whereis(Gateway.UplinkSupervisor)
    keeper = Process.whereis(Gateway.Uplink.Keeper)

    # one crash: the uplink's own supervisor restarts it at once
    first = Process.whereis(Uplink)
    Process.exit(first, :kill)
    assert eventually(fn -> (pid = Process.whereis(Uplink)) && pid != first end)

    # a crash loop: the uplink supervisor gives up and the keeper cools off
    log =
      capture_log(fn ->
        Enum.reduce_while(1..20, first, fn _, previous ->
          case eventually(fn -> next_uplink(previous) end) do
            :cooling_off ->
              {:halt, nil}

            pid ->
              Process.exit(pid, :kill)
              {:cont, pid}
          end
        end)

        assert %{running?: false, cool_offs: 1, cooling_off?: true} = Uplink.status()
      end)

    assert log =~ "uplink keeper: the uplink supervisor exited"
    assert log =~ "cool-off 1, starting it again in 300 ms"

    # nothing else moved
    assert Process.whereis(Gateway.Firewall.Server) == firewall
    assert Process.whereis(Enforcer) == enforcer
    assert Process.whereis(Gateway.UplinkSupervisor) == subtree
    assert Process.whereis(Gateway.Uplink.Keeper) == keeper
    assert %{state: :locked} = Enforcer.status()

    # after the cool-off the uplink is back, connects and joins again
    assert eventually(fn -> Process.whereis(Uplink) end, 2000)
    assert %{running?: true, cool_offs: 1, cooling_off?: false} = Uplink.status()

    accept_connect(Uplink)
    assert_join "gateway:test-site", %{"hello" => _}, {:ok, %{"heartbeat_ms" => 60_000}}
    assert_push "gateway:test-site", "heartbeat", _
    assert_push "gateway:test-site", "events", _
    # the enforcer's boot state change in the events brings an immediate heartbeat
    assert_push "gateway:test-site", "heartbeat", _
    assert_push "gateway:test-site", "audit", _
    assert %{joined?: true} = Uplink.status()
  end

  # a restarted uplink (not the one just killed), or :cooling_off once the keeper
  # has given up on it for now
  defp next_uplink(previous) do
    case Process.whereis(Uplink) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ ->
        if Gateway.Uplink.Keeper.info().cooling_off?, do: :cooling_off, else: nil
    end
  end
end
