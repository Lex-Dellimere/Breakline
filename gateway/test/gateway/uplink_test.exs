defmodule Gateway.UplinkTest do
  # registered names, the fake clock and the dns snapshot are global; the test
  # process plays the cloud through Slipstream.SocketTest
  use Slipstream.SocketTest, async: false

  import ExUnit.CaptureLog
  import Gateway.TestSupport

  alias Gateway.Clock.Fake
  alias Gateway.DNS.Snapshot
  alias Gateway.{Enforcer, Events, Store, Uplink}

  @now ~U[2026-11-02 00:00:00Z]
  @topic "gateway:test-site"

  setup do
    Snapshot.clear()
    on_exit(&Snapshot.clear/0)

    {pub, priv} = keypair()
    start_supervised!({Fake, now: @now})
    start_supervised!({Gateway.Firewall.Server, impl: Gateway.Firewall.FakeImpl})
    start_supervised!(Events)
    dir = tmp_dir("uplink")
    start_supervised!({Store, data_dir: dir, clock: Fake})

    start_supervised!(
      {Enforcer,
       site_id: site(),
       public_keys: %{"k1" => b64(pub)},
       lan_interfaces: ["eth1"],
       dns_port: 5300,
       tick_ms: 60_000,
       retry_ms: 20,
       clock: Fake}
    )

    # wait for the enforcer's boot, then forget its boot events so each test starts
    # with an empty buffer
    Enforcer.status()
    Events.drain(10_000)

    %{priv: priv, dir: dir}
  end

  defp start_uplink(opts \\ []) do
    opts =
      Keyword.merge(
        [
          url: "wss://cloud.test/gateway/socket/websocket",
          certfile: "unused.pem",
          keyfile: "unused.key",
          cacertfile: "unused-ca.pem",
          site_id: site(),
          clock: Fake,
          test_mode?: true,
          sync_ms: 60_000,
          heartbeat_ms: 60_000,
          reply_timeout_ms: 60_000,
          backoff_min_ms: 10,
          backoff_max_ms: 40
        ],
        opts
      )

    start_supervised!({Uplink, opts})
  end

  defp join_reply(overrides \\ %{}) do
    Map.merge(
      %{
        "server_time" => DateTime.to_iso8601(@now),
        "heartbeat_ms" => 60_000,
        "audit_ack" => nil,
        "policy" => nil
      },
      overrides
    )
  end

  # connects and joins, returning the hello sent with the join
  defp join!(overrides \\ %{}) do
    accept_connect(Uplink)
    assert_join @topic, %{"hello" => hello}, {:ok, join_reply(overrides)}
    hello
  end

  # a signed command as it arrives over the wire: json-decoded, string keys
  defp wire(priv, version, attrs \\ []),
    do: priv |> signed(version, attrs) |> json() |> JSON.decode!()

  defp json_roundtrip?(term), do: term |> JSON.encode!() |> JSON.decode!() == term

  defp head_map({seq, hash}), do: %{"seq" => seq, "hash" => hash}

  defp audit!(n) do
    for i <- 1..n, do: {:ok, _} = Store.audit(%{"type" => "test", "n" => i})
    :ok
  end

  describe "connect and join" do
    test "the hello carries the versions and the audit chain head", %{priv: priv} do
      :ok = Enforcer.submit(wire(priv, 5))
      start_uplink()

      hello = join!()

      {seq, hash} = Store.audit_head()

      assert hello == %{
               "gateway_version" => "0.1.0",
               "last_version" => 5,
               "policy_version" => 5,
               "audit" => %{
                 "chain_id" => Store.audit_chain_id(),
                 "head" => %{"seq" => seq, "hash" => hash}
               }
             }

      assert hello["audit"]["chain_id"] == hd(Store.audit_records(0, 1))["hash"]
      assert json_roundtrip?(hello)

      # pushes are synchronous calls into the test process, so each one is taken
      # before the uplink answers a status call
      assert_push @topic, "heartbeat", _
      assert_push @topic, "events", _
      assert_push @topic, "audit", _
      assert %{connected?: true, joined?: true} = Uplink.status()
    end

    test "a fresh gateway says it has no policy" do
      start_uplink()
      hello = join!()
      assert %{"last_version" => 0, "policy_version" => nil} = hello
    end

    test "a policy in the join reply is submitted and its result pushed", %{priv: priv} do
      start_uplink()
      join!(%{"policy" => wire(priv, 3)})

      assert_push @topic, "policy_result", %{
        "policy_version" => 3,
        "result" => "applied",
        "reason" => nil
      }

      assert Enforcer.status().policy_version == 3
    end

    test "a join error is logged and retried with backoff" do
      start_uplink()
      accept_connect(Uplink)

      log =
        capture_log(fn ->
          assert_join @topic, _, {:error, %{"reason" => "unknown_site"}}
          assert eventually(fn -> Uplink.status().attempt == 1 end)
          assert %{joined?: false, connected?: true} = Uplink.status()
          assert_join @topic, %{"hello" => _}, {:ok, join_reply()}, 1000
        end)

      assert log =~ "uplink join refused: unknown_site"
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", _
      assert %{attempt: 0, joined?: true} = Uplink.status()
    end

    test "a disconnect reconnects and joins again" do
      start_uplink()
      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", _

      capture_log(fn ->
        disconnect(Uplink, :closed_by_remote)
        assert eventually(fn -> Uplink.status().connected? == false end)
      end)

      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", _
      assert %{joined?: true} = Uplink.status()
    end
  end

  describe "pushed policies" do
    test "are applied, and a replay is rejected", %{priv: priv} do
      start_uplink()
      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", _

      command = wire(priv, 4)
      push(Uplink, @topic, "policy", %{"command" => command})

      assert_push @topic, "policy_result", %{
        "policy_version" => 4,
        "result" => "applied",
        "reason" => nil
      }

      assert Enforcer.status().policy_version == 4

      capture_log(fn ->
        push(Uplink, @topic, "policy", %{"command" => command})

        assert_push @topic, "policy_result", %{
          "policy_version" => 4,
          "result" => "rejected",
          "reason" => "stale_version"
        }

        push(Uplink, @topic, "policy", %{"command" => wire(priv, 6, site_id: "other-site")})

        assert_push @topic, "policy_result", %{
          "policy_version" => 6,
          "result" => "rejected",
          "reason" => "site_mismatch"
        }

        push(Uplink, @topic, "policy", %{"command" => 42})

        assert_push @topic, "policy_result", %{
          "policy_version" => nil,
          "result" => "rejected",
          "reason" => "malformed"
        }
      end)

      assert Enforcer.status().policy_version == 4
    end
  end

  describe "heartbeat" do
    test "carries the enforcer status as json and repeats at heartbeat_ms" do
      start_uplink()
      join!(%{"heartbeat_ms" => 1000})

      assert_push @topic, "heartbeat", %{"status" => status, "sent_at" => sent_at} = payload
      assert json_roundtrip?(payload)
      assert sent_at == DateTime.to_iso8601(@now)

      assert %{
               "state" => "locked",
               "reason" => %{"rule" => "no_policy"},
               "policy_version" => nil,
               "last_version" => 0,
               "mode" => "monitor",
               "clock_synced" => true,
               "next_change" => nil,
               "last_applied_at" => last_applied_at,
               "firewall" => %{
                 "running" => true,
                 "impl" => "Gateway.Firewall.FakeImpl",
                 "in_sync" => true,
                 "last_error" => nil
               }
             } = status

      assert last_applied_at == DateTime.to_iso8601(@now)
      assert_push @topic, "audit", _
      assert Uplink.status().last_heartbeat_at == @now

      Fake.advance(1)
      assert_push @topic, "heartbeat", %{"sent_at" => later}, _, 2000
      assert later == DateTime.to_iso8601(DateTime.add(@now, 1))
    end

    test "describes an open window with its bounds", %{priv: priv} do
      # site-local times: @now is 11:00 in sydney
      window = %{id: "now", starts_at: ~N[2026-11-02 10:30:00], ends_at: ~N[2026-11-02 12:00:00]}
      :ok = Enforcer.submit(wire(priv, 2, one_off_windows: [window]))
      start_uplink()
      join!()

      assert_push @topic, "heartbeat", %{"status" => status} = payload
      assert json_roundtrip?(payload)
      assert %{"state" => "open", "reason" => %{"rule" => "window", "id" => "now"}} = status
      assert status["next_change"] == "2026-11-02T01:00:00Z"
      assert status["reason"]["ends_at"] == "2026-11-02T01:00:00Z"
    end
  end

  describe "events" do
    defp record_dns_events(n) do
      for i <- 0..(n - 1) do
        Events.record(%{
          type: :blocked,
          qname: "q#{i}.anydesk.com",
          qtype: :a,
          match: "anydesk",
          client: {192, 168, 1, rem(i, 256)},
          at: DateTime.add(@now, i)
        })
      end

      # a call returns only after the casts before it were handled
      Events.stats()
    end

    test "go in batches of 500, oldest first, and a batch is resent after a disconnect" do
      record_dns_events(501)
      start_uplink()
      join!()

      assert_push @topic, "heartbeat", _
      assert_push @topic, "events", %{"events" => batch} = payload, _ref
      assert_push @topic, "audit", _

      assert length(batch) == 500
      assert json_roundtrip?(payload)

      assert %{
               "type" => "blocked",
               "qname" => "q0.anydesk.com",
               "qtype" => "a",
               "match" => %{"kind" => "tool", "tag" => "anydesk"},
               "client" => "192.168.1.0",
               "at" => at,
               "id" => id
             } = hd(batch)

      assert at == DateTime.to_iso8601(@now)
      assert is_binary(id) and byte_size(id) == 32
      assert List.last(batch)["qname"] == "q499.anydesk.com"
      assert Uplink.status().events_in_flight == 500

      # no reply: the batch stays in flight across the disconnect
      capture_log(fn ->
        disconnect(Uplink, :closed_by_remote)
        assert eventually(fn -> Uplink.status().connected? == false end)
      end)

      assert Uplink.status().events_in_flight == 500

      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "events", %{"events" => ^batch}, ref
      assert_push @topic, "audit", _

      reply(Uplink, ref, {:ok, %{"accepted" => 500}})
      assert_push @topic, "events", %{"events" => [last]}, ref
      assert last["qname"] == "q500.anydesk.com"
      assert Uplink.status().events_in_flight == 1

      reply(Uplink, ref, {:ok, %{"accepted" => 1}})
      assert eventually(fn -> Uplink.status().events_in_flight == 0 end)
      assert Events.stats().size == 0
    end

    test "new events are picked up by the next sync" do
      start_uplink()
      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", _
      refute_push @topic, "events", _

      record_dns_events(2)
      send(Uplink, :sync)
      assert_push @topic, "events", %{"events" => [_, _]}, ref
      reply(Uplink, ref, {:ok, %{"accepted" => 2}})
      assert eventually(fn -> Uplink.status().events_in_flight == 0 end)
    end

    test "a refused batch is retried, then dropped after three refusals" do
      record_dns_events(1)
      start_uplink()
      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "events", %{"events" => batch}, ref
      assert_push @topic, "audit", _

      log =
        capture_log(fn ->
          reply(Uplink, ref, {:error, %{"reason" => "invalid"}})
          send(Uplink, :sync)
          assert_push @topic, "events", %{"events" => ^batch}, ref
          reply(Uplink, ref, {:error, %{"reason" => "invalid"}})
          send(Uplink, :sync)
          assert_push @topic, "events", %{"events" => ^batch}, ref
          reply(Uplink, ref, {:error, %{"reason" => "invalid"}})
          assert eventually(fn -> Uplink.status().events_in_flight == 0 end)
        end)

      assert log =~ "dropping 1 events"
    end

    test "enforcer events are json-safe", %{priv: priv} do
      start_uplink()
      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", _

      :ok = Enforcer.submit(wire(priv, 2))
      capture_log(fn -> {:error, _} = Enforcer.submit(wire(priv, 2)) end)
      Events.stats()

      send(Uplink, :sync)
      assert_push @topic, "events", %{"events" => events} = payload
      assert json_roundtrip?(payload)

      types = Enum.map(events, & &1["type"])
      assert types == ["policy_applied", "state_changed", "command_rejected"]

      assert %{"policy_version" => 2, "key_id" => "k1"} = Enum.at(events, 0)

      assert %{"locked" => true, "mode" => "enforce", "reason" => %{"rule" => "default"}} =
               Enum.at(events, 1)

      assert %{"reason" => %{"reason" => "stale_version"}} = Enum.at(events, 2)
    end
  end

  describe "audit" do
    test "sends the chain from seq 0 without an ack, then only new records" do
      start_uplink()
      join!()
      assert_push @topic, "heartbeat", _

      assert_push @topic, "audit", %{"chain_id" => chain_id, "records" => records} = payload, ref
      assert chain_id == Store.audit_chain_id()
      assert records == Store.audit_records(0, 200)
      assert hd(records)["seq"] == 0
      assert json_roundtrip?(payload)

      head = Store.audit_head()
      reply(Uplink, ref, {:ok, %{"head" => head_map(head)}})
      assert eventually(fn -> Uplink.status().audit_ack == head end)

      {seq, _} = head
      audit!(3)
      send(Uplink, :sync)
      assert_push @topic, "audit", %{"records" => new}, ref
      assert Enum.map(new, & &1["seq"]) == [seq + 1, seq + 2, seq + 3]

      # the cloud lost records: send again from where it says
      capture_log(fn ->
        reply(Uplink, ref, {:error, %{"reason" => "chain_mismatch", "expected_seq" => 1}})
        assert_push @topic, "audit", %{"chain_id" => ^chain_id, "records" => again}, ref
        assert hd(again)["seq"] == 1
        assert List.last(again)["seq"] == seq + 3
        assert Uplink.status().audit_ack == {0, hd(records)["hash"]}

        reply(Uplink, ref, {:ok, %{"head" => head_map(Store.audit_head())}})
      end)

      assert eventually(fn -> Uplink.status().audit_ack == Store.audit_head() end)
    end

    test "backs off when the cloud keeps refusing the same records" do
      start_uplink(audit_retry_ms: 300)
      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", %{"records" => [%{"seq" => 0} | _]}, ref

      capture_log(fn ->
        # first refusal at seq 0 is a normal resync: resend at once
        reply(Uplink, ref, {:error, %{"reason" => "chain_mismatch", "expected_seq" => 0}})
        assert_push @topic, "audit", %{"records" => [%{"seq" => 0} | _]}, ref

        # the same refusal again: no tight loop, wait audit_retry_ms first
        reply(Uplink, ref, {:error, %{"reason" => "chain_mismatch", "expected_seq" => 0}})
        refute_push @topic, "audit", _, 150
        assert_push @topic, "audit", %{"records" => [%{"seq" => 0} | _]}, ref, 1_000

        # a third refusal doubles the wait
        reply(Uplink, ref, {:error, %{"reason" => "chain_mismatch", "expected_seq" => 0}})
        refute_push @topic, "audit", _, 450
        assert_push @topic, "audit", %{"records" => [%{"seq" => 0} | _]}, ref, 1_000

        # an accepted batch clears the count
        reply(Uplink, ref, {:ok, %{"head" => head_map(Store.audit_head())}})
      end)

      assert eventually(fn -> Uplink.status().audit_ack == Store.audit_head() end)
    end

    test "starts after the ack from the join reply" do
      audit!(3)
      [r1] = Store.audit_records(1, 1)
      start_uplink()
      join!(%{"audit_ack" => %{"seq" => 1, "hash" => r1["hash"]}})
      assert_push @topic, "heartbeat", _

      assert_push @topic, "audit", %{"records" => records}
      assert hd(records)["seq"] == 2
      assert Uplink.status().audit_ack == {1, r1["hash"]}
    end

    test "an ack that does not match the local chain starts over from seq 0" do
      audit!(3)
      start_uplink()

      log =
        capture_log(fn ->
          join!(%{"audit_ack" => %{"seq" => 1, "hash" => String.duplicate("0", 64)}})
          assert_push @topic, "heartbeat", _
          assert_push @topic, "audit", %{"records" => records}
          assert hd(records)["seq"] == 0
        end)

      assert log =~ "does not match the local chain"
      assert Uplink.status().audit_ack == nil
    end

    test "sends at most 200 records per push" do
      audit!(250)
      {head_seq, _} = Store.audit_head()
      start_uplink()
      join!()
      assert_push @topic, "heartbeat", _

      assert_push @topic, "audit", %{"records" => first}, ref
      assert length(first) == 200
      last = List.last(first)
      reply(Uplink, ref, {:ok, %{"head" => %{"seq" => last["seq"], "hash" => last["hash"]}}})

      assert_push @topic, "audit", %{"records" => rest}
      assert hd(rest)["seq"] == 200
      assert List.last(rest)["seq"] == head_seq
    end

    test "a missing reply reconnects and sends again" do
      start_uplink(reply_timeout_ms: 100)
      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", %{"records" => records}

      log =
        capture_log(fn ->
          assert_disconnect 1000
          assert eventually(fn -> Uplink.status().connected? == false end)
        end)

      assert log =~ "no reply to a push"
      join!()
      assert_push @topic, "heartbeat", _
      assert_push @topic, "audit", %{"records" => ^records}
    end
  end

  describe "backoff/3" do
    test "doubles from the minimum, caps at the maximum, with jitter in the top quarter" do
      for attempt <- 0..40, _ <- 1..20 do
        base = min(60_000, 1000 * Integer.pow(2, min(attempt, 32)))
        delay = Uplink.backoff(attempt, 1000, 60_000)
        assert delay >= div(base * 3, 4) and delay <= base
      end

      assert Uplink.backoff(0, 1000, 60_000) <= 1000
      assert Uplink.backoff(100, 1000, 60_000) >= 45_000
    end
  end

  describe "config and status" do
    test "an invalid config is logged and the uplink does not start" do
      log =
        capture_log(fn ->
          assert :ignore =
                   Uplink.start_link(
                     url: "ws://cloud.test/socket/websocket",
                     certfile: "c",
                     keyfile: "k",
                     cacertfile: "ca",
                     site_id: site(),
                     test_mode?: true
                   )

          assert :ignore = Uplink.start_link(url: "wss://cloud.test/x", site_id: site())
        end)

      assert log =~ "must be a wss:// url"
      assert log =~ ":certfile, :keyfile and :cacertfile are required"
    end

    test "status says when the uplink is not running" do
      assert %{running?: false, connected?: false, joined?: false} = Uplink.status()
    end

    test "status before connecting" do
      start_uplink()

      assert %{
               running?: true,
               connected?: false,
               joined?: false,
               last_heartbeat_at: nil,
               events_in_flight: 0,
               audit_ack: nil,
               url: "wss://cloud.test/gateway/socket/websocket"
             } = Uplink.status()
    end
  end
end
