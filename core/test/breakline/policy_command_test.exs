defmodule Breakline.PolicyCommandTest do
  # the path a policy takes from cloud to gateway: policy -> signed command -> json on the
  # wire -> verify -> policy again, and the same schedule answer on both sides
  use ExUnit.Case, async: true

  alias Breakline.{AuditLog, Command, Policy, Schedule}
  alias Breakline.Command.Verifier

  setup do
    {:ok, policy} =
      Policy.new(
        site_id: "site-1",
        version: 4,
        mode: :enforce,
        time_zone: "Australia/Adelaide",
        tool_ids: ["n_central", "anydesk"],
        site_hosts: ["rmm.example.com.au"],
        recurring_windows: [
          %{id: "tue-evening", days: [2], starts: ~T[18:00:00], ends: ~T[20:00:00]}
        ],
        one_off_windows: [
          %{id: "dst-night", starts_at: ~N[2026-10-04 01:30:00], ends_at: ~N[2026-10-04 03:30:00]}
        ],
        advisory_locks: [
          %{
            id: "kev-1",
            reason: "n-central exploited",
            source: "kev:CVE-2026-18577",
            expires_at: ~U[2026-11-05 00:00:00Z]
          }
        ],
        break_glass: %{until: ~U[2026-10-31 10:00:00Z], approved_by: "approver-7"}
      )

    {pub, priv} = Command.generate_keypair()
    verifier = Verifier.new(site_id: "site-1", public_keys: %{"k1" => pub}, last_version: 3)
    %{policy: policy, priv: priv, verifier: verifier}
  end

  test "a signed policy survives the wire and rebuilds identically", ctx do
    now = ~U[2026-10-31 09:00:00Z]

    json =
      [
        type: "policy",
        site_id: ctx.policy.site_id,
        policy_version: ctx.policy.version,
        payload: Policy.to_map(ctx.policy),
        issued_at: now,
        ttl_seconds: 300
      ]
      |> Command.new!()
      |> Command.sign("k1", ctx.priv)
      |> Command.encode_wire()

    assert {:ok, command, verifier} = Command.verify(json, ctx.verifier, now)
    assert verifier.last_version == 4
    assert {:ok, received} = Policy.from_map(command.payload)
    assert received == ctx.policy

    for at <- [now, ~U[2026-10-04 00:00:00Z], ~U[2026-11-10 08:30:00Z], ~U[2026-11-06 00:00:00Z]] do
      assert Schedule.explain(received, at) == Schedule.explain(ctx.policy, at)
    end

    # the same json cannot be applied twice
    assert {:error, :stale_version} = Command.verify(json, verifier, now)
  end

  test "a tampered payload is rejected", ctx do
    now = ~U[2026-10-31 09:00:00Z]

    wire =
      Command.new!(
        type: "policy",
        site_id: "site-1",
        policy_version: 4,
        payload: Policy.to_map(ctx.policy),
        issued_at: now,
        ttl_seconds: 300
      )
      |> Command.sign("k1", ctx.priv)

    opened = put_in(wire, ["envelope", "payload", "advisory_locks"], [])
    assert {:error, :bad_signature} = Command.verify(opened, ctx.verifier, now)
  end

  test "policy maps are valid audit entries", ctx do
    chain =
      AuditLog.new()
      |> AuditLog.append(%{"action" => "policy_pushed", "policy" => Policy.to_map(ctx.policy)})
      |> AuditLog.append(%{"action" => "policy_applied", "version" => ctx.policy.version})

    assert :ok =
             AuditLog.verify_chain(AuditLog.records(chain), expected_head: AuditLog.head(chain))
  end
end
