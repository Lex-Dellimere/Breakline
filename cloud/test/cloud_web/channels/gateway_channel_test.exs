defmodule CloudWeb.GatewayChannelTest do
  # presence and pubsub are global, and channel processes share the sandbox
  use CloudWeb.ChannelCase, async: false

  import Cloud.Fixtures

  alias Breakline.{AuditLog, Command}
  alias Cloud.{Access, Gateways, Sites}
  alias CloudWeb.{GatewayChannel, GatewayPresence, GatewaySocket}

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    {site, der} = tenant |> site!(admin) |> gateway!()
    Map.merge(org, %{site: site, der: der})
  end

  defp gateway_socket(der) do
    connect(GatewaySocket, %{}, connect_info: %{peer_data: %{ssl_cert: der}})
  end

  defp hello(overrides \\ %{}) do
    %{
      "hello" =>
        Map.merge(
          %{
            "gateway_version" => "0.1.0",
            "last_version" => 0,
            "policy_version" => nil,
            "audit" => %{"chain_id" => nil, "head" => nil}
          },
          overrides
        )
    }
  end

  defp join!(ctx, params \\ hello()) do
    {:ok, socket} = gateway_socket(ctx.der)

    {:ok, reply, channel} =
      subscribe_and_join(socket, GatewayChannel, "gateway:" <> ctx.site.id, params)

    {reply, channel}
  end

  defp chain(n, tag \\ "a") do
    0..(n - 1)
    |> Enum.reduce(AuditLog.new(), &AuditLog.append(&2, %{"event" => tag, "n" => &1}))
    |> AuditLog.records()
  end

  defp site(ctx), do: Sites.get_site!(ctx.site.id, authorize?: false)

  describe "connect" do
    test "needs a client certificate a site has pinned", ctx do
      assert :error = connect(GatewaySocket, %{}, connect_info: %{})
      assert :error = connect(GatewaySocket, %{}, connect_info: %{peer_data: %{ssl_cert: nil}})
      assert :error = gateway_socket(:crypto.strong_rand_bytes(200))

      # params cannot pick a site
      assert :error =
               connect(GatewaySocket, %{"site_id" => ctx.site.id},
                 connect_info: %{peer_data: %{ssl_cert: "other"}}
               )

      assert {:ok, socket} = gateway_socket(ctx.der)
      assert socket.assigns.site_id == ctx.site.id
      assert socket.assigns.tenant_id == ctx.tenant.id
      assert GatewaySocket.id(socket) == "gateway_socket:" <> ctx.site.id
    end
  end

  describe "join" do
    test "only the socket's own site", ctx do
      other = site!(ctx.tenant, ctx.admin)
      {:ok, socket} = gateway_socket(ctx.der)

      assert {:error, %{reason: "site_mismatch"}} =
               subscribe_and_join(socket, GatewayChannel, "gateway:" <> other.id, hello())
    end

    test "reply without a policy when nothing newer is published", ctx do
      {reply, _channel} = join!(ctx)

      assert %{"heartbeat_ms" => 30_000, "audit_ack" => nil, "policy" => nil} = reply
      assert {:ok, _, _} = DateTime.from_iso8601(reply["server_time"])

      {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "test")
      {reply, _channel} = join!(ctx, hello(%{"last_version" => 1}))
      assert reply["policy"] == nil
    end

    test "reply carries a signed policy newer than the gateway's", ctx do
      {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "test")
      {:ok, _} = Access.open_now(ctx.site.id, 30, ctx.admin)

      {reply, _channel} = join!(ctx, hello(%{"last_version" => 1}))
      assert %{"envelope" => _} = wire = reply["policy"]

      assert {:ok, command, _} =
               Command.verify(wire, Cloud.Signer.verifier(ctx.site.id), DateTime.utc_now())

      assert command.policy_version == 2
    end

    test "is tracked in presence while joined", ctx do
      refute GatewayPresence.connected?(ctx.site.id)
      Phoenix.PubSub.subscribe(Cloud.PubSub, GatewayPresence.topic(ctx.site.id))
      {_reply, channel} = join!(ctx)

      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{joins: joins}}
      assert Map.has_key?(joins, ctx.site.id)
      assert GatewayPresence.connected?(ctx.site.id)

      Process.unlink(channel.channel_pid)
      ref = leave(channel)
      assert_reply ref, :ok
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{leaves: leaves}}
      assert Map.has_key?(leaves, ctx.site.id)
    end
  end

  test "a published policy is pushed signed", ctx do
    {_reply, _channel} = join!(ctx)
    {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "test")

    assert_push "policy", %{"command" => wire}

    assert {:ok, command, _} =
             Command.verify(wire, Cloud.Signer.verifier(ctx.site.id), DateTime.utc_now())

    assert command.policy_version == 1
    assert command.site_id == ctx.site.id
  end

  test "a heartbeat is stored on the site and broadcast", ctx do
    Phoenix.PubSub.subscribe(Cloud.PubSub, Gateways.ui_topic(ctx.site.id))
    {_reply, channel} = join!(ctx)
    status = %{"state" => "locked", "reason" => %{"rule" => "default"}, "policy_version" => 3}

    ref = push(channel, "heartbeat", %{"status" => status, "sent_at" => "2026-10-31T00:00:00Z"})
    assert_reply ref, :ok

    site_id = ctx.site.id
    assert_receive {:gateway_heartbeat, ^site_id, ^status, %DateTime{}}
    site = site(ctx)
    assert site.gateway_status == status
    assert site.gateway_last_seen_at
  end

  describe "events" do
    test "are stored once per id", ctx do
      {_reply, channel} = join!(ctx)

      event = fn id, type ->
        %{"id" => id, "type" => type, "at" => "2026-10-31T01:02:03Z", "qname" => "x.anydesk.com"}
      end

      ref =
        push(channel, "events", %{"events" => [event.("a", "blocked"), event.("b", "blocked")]})

      assert_reply ref, :ok, %{"accepted" => 2}

      ref =
        push(channel, "events", %{
          "events" => [event.("a", "blocked"), event.("c", "would_block"), event.("c", "x"), 7]
        })

      assert_reply ref, :ok, %{"accepted" => 1}

      events =
        Gateways.list_events!(tenant: ctx.tenant.id, authorize?: false, query: [sort: :event_id])

      assert Enum.map(events, & &1.event_id) == ["a", "b", "c"]
      [a | _] = events
      assert a.type == "blocked"
      assert a.at == ~U[2026-10-31 01:02:03.000000Z]
      assert a.data["qname"] == "x.anydesk.com"
      refute Map.has_key?(a.data, "id")
    end

    test "more than 500 in one push are refused", ctx do
      {_reply, channel} = join!(ctx)
      many = for i <- 1..501, do: %{"id" => "e#{i}", "type" => "blocked"}
      ref = push(channel, "events", %{"events" => many})
      assert_reply ref, :error, %{"reason" => "too_many", "max" => 500}
    end

    test "a policy result is stored as an event", ctx do
      Phoenix.PubSub.subscribe(Cloud.PubSub, Gateways.ui_topic(ctx.site.id))
      {_reply, channel} = join!(ctx)

      payload = %{"policy_version" => 4, "result" => "rejected", "reason" => "stale_version"}
      ref = push(channel, "policy_result", payload)
      assert_reply ref, :ok

      assert [event] = Gateways.list_events!(tenant: ctx.tenant.id, authorize?: false)
      assert event.type == "policy_result"
      assert event.data == payload
      assert_receive {:gateway_events, _, [%{type: "policy_result"}]}
    end
  end

  describe "audit" do
    test "batches continue the anchored head", ctx do
      records = chain(5)
      chain_id = hd(records)["hash"]
      {_reply, channel} = join!(ctx, hello(%{"audit" => %{"chain_id" => chain_id}}))

      # the new chain was recorded for the ui and anchored with no head
      assert [%{type: "audit_chain_reset"}] =
               Gateways.list_events!(tenant: ctx.tenant.id, authorize?: false)

      ref = push(channel, "audit", %{"chain_id" => chain_id, "records" => Enum.take(records, 3)})
      head2 = %{"seq" => 2, "hash" => Enum.at(records, 2)["hash"]}
      assert_reply ref, :ok, %{"head" => ^head2}

      ref = push(channel, "audit", %{"chain_id" => chain_id, "records" => Enum.drop(records, 3)})
      head4 = %{"seq" => 4, "hash" => Enum.at(records, 4)["hash"]}
      assert_reply ref, :ok, %{"head" => ^head4}

      site = site(ctx)
      assert site.gateway_audit_chain_id == chain_id
      assert site.gateway_audit_head == head4

      stored =
        Gateways.list_audit_records!(
          tenant: ctx.tenant.id,
          authorize?: false,
          query: [sort: :seq]
        )

      assert Enum.map(stored, & &1.seq) == [0, 1, 2, 3, 4]
      assert Enum.map(stored, & &1.record) == records

      # a rejoin gets the anchored head back, and no new reset event
      {reply, _channel} = join!(ctx, hello(%{"audit" => %{"chain_id" => chain_id}}))
      assert reply["audit_ack"] == head4
      assert length(Gateways.list_events!(tenant: ctx.tenant.id, authorize?: false)) == 1
    end

    test "a gap, an overlap or a forgery is a chain_mismatch", ctx do
      records = chain(6)
      chain_id = hd(records)["hash"]
      {_reply, channel} = join!(ctx, hello(%{"audit" => %{"chain_id" => chain_id}}))

      ref = push(channel, "audit", %{"chain_id" => chain_id, "records" => Enum.take(records, 2)})
      assert_reply ref, :ok, %{"head" => %{"seq" => 1}}

      for bad <- [
            Enum.drop(records, 3),
            Enum.drop(records, 1),
            List.update_at(Enum.drop(records, 2), 1, &put_in(&1, ["entry", "n"], 99)),
            []
          ] do
        ref = push(channel, "audit", %{"chain_id" => chain_id, "records" => bad})
        assert_reply ref, :error, %{"reason" => "chain_mismatch", "expected_seq" => 2}
      end

      # a chain that does not start with its own record 0
      other = chain(2)
      ref = push(channel, "audit", %{"chain_id" => "not-the-hash", "records" => other})
      assert_reply ref, :error, %{"reason" => "chain_mismatch", "expected_seq" => 0}

      assert site(ctx).gateway_audit_head == %{"seq" => 1, "hash" => Enum.at(records, 1)["hash"]}

      many = chain(201)
      ref = push(channel, "audit", %{"chain_id" => hd(many)["hash"], "records" => many})
      assert_reply ref, :error, %{"reason" => "too_many", "max" => 200}
    end

    test "a reset chain starts over from seq 0", ctx do
      old = chain(2)
      {_reply, channel} = join!(ctx, hello(%{"audit" => %{"chain_id" => hd(old)["hash"]}}))
      ref = push(channel, "audit", %{"chain_id" => hd(old)["hash"], "records" => old})
      assert_reply ref, :ok, %{"head" => %{"seq" => 1}}

      new = chain(3, "b")
      new_id = hd(new)["hash"]
      refute new_id == hd(old)["hash"]
      {reply, channel} = join!(ctx, hello(%{"audit" => %{"chain_id" => new_id}}))
      assert reply["audit_ack"] == nil

      ref = push(channel, "audit", %{"chain_id" => new_id, "records" => new})
      assert_reply ref, :ok, %{"head" => %{"seq" => 2}}
      assert site(ctx).gateway_audit_chain_id == new_id
    end
  end
end
