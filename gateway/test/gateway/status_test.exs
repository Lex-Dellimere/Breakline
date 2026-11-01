defmodule Gateway.StatusTest do
  use ExUnit.Case, async: true

  alias Gateway.Status

  @enforcer %{
    state: :locked,
    reason: {:locked, :no_policy},
    policy_version: nil,
    last_version: 0,
    mode: :monitor,
    clock_synced?: true,
    next_change: nil,
    last_applied_at: ~U[2026-11-01 00:00:00Z],
    firewall: %{
      running?: true,
      impl: Gateway.Firewall.NftImpl,
      in_sync?: true,
      apply_count: 2,
      resolved_count: 7,
      last_error: nil
    }
  }

  @uplink %{
    running?: false,
    connected?: false,
    joined?: false,
    url: nil,
    last_heartbeat_at: nil,
    events_in_flight: 0,
    audit_ack: nil,
    chain_id: nil,
    attempt: 0,
    last_error: nil,
    cool_offs: 0,
    cooling_off?: false
  }

  test "a fresh pilot box: locked with no policy, monitor, no uplink" do
    text = Status.format(@enforcer, Map.put(@uplink, :configured?, false))

    assert text =~ ~r/state:\s+locked \(no_policy\)/
    assert text =~ ~r/mode:\s+monitor/
    assert text =~ ~r/policy version:\s+none \(last accepted 0\)/
    assert text =~ ~r/clock synced:\s+yes/
    assert text =~ ~r/last applied:\s+2026-11-01T00:00:00Z/
    assert text =~ ~r/firewall:\s+NftImpl, in sync, 2 applies, 7 resolved ips/
    assert text =~ ~r/status:\s+not configured/
  end

  test "an open window and a joined uplink" do
    enforcer = %{
      @enforcer
      | state: :open,
        reason: {:open, {:window, "w1", {~U[2026-11-01 00:00:00Z], ~U[2026-11-01 02:00:00Z]}}},
        policy_version: 12,
        next_change: ~U[2026-11-01 02:00:00Z]
    }

    uplink = %{
      @uplink
      | running?: true,
        connected?: true,
        joined?: true,
        url: "wss://cloud.example/gateway/socket/websocket",
        audit_ack: {41, "abc"}
    }

    text = Status.format(enforcer, Map.put(uplink, :configured?, true))

    assert text =~ "open (window: ends_at 2026-11-01T02:00:00Z, id w1, starts_at"
    assert text =~ ~r/policy version:\s+12\n/
    assert text =~ ~r/status:\s+connected, joined/
    assert text =~ ~r/audit ack:\s+seq 41/
    refute text =~ "last error"
  end

  test "a stopped enforcer, an unsynced clock and a failing uplink" do
    text =
      Status.format(
        nil,
        Map.merge(@uplink, %{
          running?: true,
          attempt: 3,
          last_error: :econnrefused,
          configured?: true
        })
      )

    assert text =~ ~r/enforcer\n  state:\s+not running/
    assert text =~ ~r/status:\s+disconnected \(attempt 3\)/
    assert text =~ ~r/last error:\s+:econnrefused/

    text =
      Status.format(
        %{@enforcer | clock_synced?: false, reason: {:locked, :clock_unsynced}},
        Map.put(@uplink, :configured?, true)
      )

    assert text =~ ~r/state:\s+locked \(clock_unsynced\)/
    assert text =~ ~r/clock synced:\s+no/
    assert text =~ ~r/status:\s+not running/
  end
end
