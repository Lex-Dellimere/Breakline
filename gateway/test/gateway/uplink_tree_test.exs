defmodule Gateway.UplinkTreeTest do
  # the whole tree from Gateway.Application.children/1, with a test-mode uplink
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
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

  test "an uplink crash loop never touches the firewall or the enforcer" do
    uplink = [
      url: "wss://cloud.test/gateway/socket/websocket",
      certfile: "c.pem",
      keyfile: "c.key",
      cacertfile: "ca.pem",
      test_mode?: true
    ]

    sup = start_tree(uplink: uplink)
    ids = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
    assert List.last(ids) == :uplink
    assert Uplink.status().running?

    firewall = Process.whereis(Gateway.Firewall.Server)
    enforcer = Process.whereis(Enforcer)

    # one crash: the uplink comes back
    first = Process.whereis(Uplink)
    Process.exit(first, :kill)
    assert eventually(fn -> (pid = Process.whereis(Uplink)) && pid != first end)

    # a crash loop: the uplink subtree gives up and stays down
    capture_log(fn ->
      Enum.reduce_while(1..20, nil, fn _, previous ->
        case eventually(fn -> next_uplink(sup, previous) end) do
          :gone ->
            {:halt, nil}

          pid ->
            Process.exit(pid, :kill)
            {:cont, pid}
        end
      end)

      assert eventually(fn -> not subtree_alive?(sup) end)
    end)

    assert Process.whereis(Gateway.Firewall.Server) == firewall
    assert Process.whereis(Enforcer) == enforcer
    assert Process.alive?(sup)
    assert %{state: :locked} = Enforcer.status()
  end

  # a restarted uplink (not the one just killed), or :gone once the subtree gave up
  defp next_uplink(sup, previous) do
    case Process.whereis(Uplink) do
      pid when is_pid(pid) and pid != previous -> pid
      _ -> if subtree_alive?(sup), do: nil, else: :gone
    end
  end

  defp subtree_alive?(sup) do
    Enum.any?(Supervisor.which_children(sup), fn
      {:uplink, pid, _, _} when is_pid(pid) -> true
      _ -> false
    end)
  end
end
