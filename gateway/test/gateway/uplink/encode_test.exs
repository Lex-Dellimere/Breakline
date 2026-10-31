defmodule Gateway.Uplink.EncodeTest do
  use ExUnit.Case, async: true

  alias Gateway.Uplink.Encode

  @at ~U[2026-11-02 00:00:00.123456Z]

  defp roundtrip(term), do: term |> JSON.encode!() |> JSON.decode!()

  describe "event/2" do
    test "dns matches become maps with a kind" do
      cases = [
        {"anydesk", %{"kind" => "tool", "tag" => "anydesk"}},
        {{:site_host, "rmm.example.com"},
         %{
           "kind" => "site_host",
           "name" => "rmm.example.com",
           "tag" => "site_host:rmm.example.com"
         }},
        {{:cname, "relay.anydesk.com", "anydesk"},
         %{"kind" => "cname", "name" => "relay.anydesk.com", "tag" => "anydesk"}},
        {{:cname, "rmm.example.com", {:site_host, "rmm.example.com"}},
         %{"kind" => "cname", "name" => "rmm.example.com", "tag" => "site_host:rmm.example.com"}},
        {{:doh, "dns.google"}, %{"kind" => "doh", "name" => "dns.google"}},
        {{:canary, "use-application-dns.net"},
         %{"kind" => "canary", "name" => "use-application-dns.net"}}
      ]

      for {match, expected} <- cases do
        event = %{
          type: :blocked,
          qname: "x",
          qtype: :a,
          match: match,
          client: {10, 0, 0, 1},
          at: @at
        }

        encoded = Encode.event(event, "id1")
        assert encoded["match"] == expected
        assert roundtrip(encoded) == encoded
      end
    end

    test "addresses, times and atoms become strings" do
      event = %{
        type: :would_block,
        qname: "boot.net.anydesk.com",
        qtype: :aaaa,
        match: "anydesk",
        client: {0xFD00, 0, 0, 0, 0, 0, 0, 1},
        at: @at
      }

      assert Encode.event(event, "abc") == %{
               "id" => "abc",
               "type" => "would_block",
               "qname" => "boot.net.anydesk.com",
               "qtype" => "aaaa",
               "match" => %{"kind" => "tool", "tag" => "anydesk"},
               "client" => "fd00::1",
               "at" => "2026-11-02T00:00:00.123456Z"
             }

      # an unknown qtype stays a number
      assert Encode.event(%{event | qtype: 65})["qtype"] == 65
    end

    test "state changes describe the reason, rejections name it" do
      changed = %{
        type: :state_changed,
        at: @at,
        locked?: false,
        mode: :enforce,
        clock_synced?: true,
        policy_version: 3,
        reason: {:open, {:window, "w1", {~U[2026-11-02 00:00:00Z], ~U[2026-11-02 01:00:00Z]}}}
      }

      encoded = Encode.event(changed)
      assert roundtrip(encoded) == encoded

      assert %{
               "locked" => false,
               "clock_synced" => true,
               "reason" => %{
                 "rule" => "window",
                 "id" => "w1",
                 "starts_at" => "2026-11-02T00:00:00Z",
                 "ends_at" => "2026-11-02T01:00:00Z"
               }
             } = encoded

      rejected = %{type: :command_rejected, at: @at, reason: {:invalid_policy, [{:bad, :thing}]}}
      encoded = Encode.event(rejected)
      assert roundtrip(encoded) == encoded
      assert %{"reason" => %{"reason" => "invalid_policy", "details" => details}} = encoded
      assert details =~ "bad"

      assert Encode.event(%{rejected | reason: :expired})["reason"] == %{"reason" => "expired"}
    end
  end

  describe "status/1" do
    test "is json-safe, firewall errors included" do
      status = %{
        state: :locked,
        reason: {:locked, :clock_unsynced},
        policy_version: nil,
        last_version: 0,
        mode: :monitor,
        clock_synced?: false,
        next_change: nil,
        last_applied_at: nil,
        firewall: %{
          running?: true,
          impl: Gateway.Firewall.NftImpl,
          in_sync?: false,
          apply_count: 2,
          resolved_count: nil,
          last_error: {:nft_failed, 1, "Error: syntax"}
        }
      }

      encoded = Encode.status(status)
      assert roundtrip(encoded) == encoded

      assert encoded == %{
               "state" => "locked",
               "reason" => %{"rule" => "clock_unsynced"},
               "policy_version" => nil,
               "last_version" => 0,
               "mode" => "monitor",
               "clock_synced" => false,
               "next_change" => nil,
               "last_applied_at" => nil,
               "firewall" => %{
                 "running" => true,
                 "impl" => "Gateway.Firewall.NftImpl",
                 "in_sync" => false,
                 "apply_count" => 2,
                 "resolved_count" => nil,
                 "last_error" => ~s({:nft_failed, 1, "Error: syntax"})
               }
             }
    end

    test "a stopped firewall has a smaller summary" do
      status = %{
        state: :locked,
        reason: {:locked, :no_policy},
        policy_version: nil,
        last_version: 0,
        mode: :monitor,
        clock_synced?: true,
        next_change: nil,
        last_applied_at: nil,
        firewall: %{running?: false, in_sync?: false, last_error: nil}
      }

      assert Encode.status(status)["firewall"] == %{
               "running" => false,
               "in_sync" => false,
               "last_error" => nil
             }
    end
  end

  describe "json_safe/1" do
    test "handles terms json has no type for" do
      value = %{
        :a? => {1, :two, "three"},
        "list" => [self(), make_ref(), [1 | 2]],
        :date => ~D[2026-11-02],
        :naive => ~N[2026-11-02 10:00:00],
        :module => Gateway.Uplink,
        1 => :ok
      }

      encoded = Encode.json_safe(value)
      assert roundtrip(encoded) == encoded
      assert encoded["a"] == [1, "two", "three"]
      assert encoded["date"] == "2026-11-02"
      assert encoded["naive"] == "2026-11-02T10:00:00"
      assert encoded["module"] == "Gateway.Uplink"
      assert encoded["1"] == "ok"
      assert [pid, ref, improper] = encoded["list"]
      assert pid =~ "#PID" and ref =~ "#Reference" and improper == "[1 | 2]"
    end

    test "a 4-tuple that is not an address stays a list" do
      assert Encode.json_safe({1, 2, 3, 999}) == [1, 2, 3, 999]
      assert Encode.json_safe({127, 0, 0, 1}) == "127.0.0.1"
    end
  end

  test "rejection_reason/1 gives the short name" do
    assert Encode.rejection_reason(:stale_version) == "stale_version"
    assert Encode.rejection_reason({:invalid_policy, []}) == "invalid_policy"
    assert Encode.rejection_reason({:persist_failed, :enospc}) == "persist_failed"
  end
end
