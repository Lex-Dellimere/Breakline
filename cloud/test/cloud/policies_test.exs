defmodule Cloud.PoliciesTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias Breakline.{Command, Policy}
  alias Cloud.{Policies, Sites}

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin)
    org |> Map.put(:site, site) |> Map.put(:opts, actor: admin, tenant: tenant)
  end

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds)

  describe "publish/2" do
    test "increments the version and stores exactly Policy.to_map output", %{site: site} = ctx do
      Phoenix.PubSub.subscribe(Cloud.PubSub, Policies.topic(site.id))

      assert {:ok, v1} = Policies.publish(site.id, published_by: ctx.admin, reason: "first")
      assert {:ok, v2} = Policies.publish(site.id, reason: "second")

      assert {v1.version, v2.version} == {1, 2}
      assert v1.published_by_id == ctx.admin.id
      assert v2.published_by_id == nil
      assert v2.reason == "second"
      assert Sites.get_site!(site.id, ctx.opts).policy_version == 2

      assert_receive {:policy_published, site_id, 1}
      assert site_id == site.id
      assert_receive {:policy_published, _, 2}

      stored = Sites.get_site!(site.id, ctx.opts)

      [latest | _] =
        Sites.list_policy_versions!(Keyword.put(ctx.opts, :query, sort: [version: :desc]))

      assert {:ok, policy} = Policy.from_map(latest.policy)
      assert Policy.to_map(policy) == latest.policy

      assert %Policy{
               site_id: id,
               version: 2,
               mode: :enforce,
               time_zone: "Australia/Sydney",
               tool_ids: ["anydesk", "screenconnect"],
               site_hosts: ["rmm.example.com.au", "203.0.113.0/24"],
               recurring_windows: [],
               one_off_windows: [],
               advisory_locks: [],
               break_glass: nil
             } = policy

      assert id == stored.id
    end

    test "an unknown site is an error" do
      assert {:error, _} = Policies.publish(Ash.UUID.generate(), reason: "x")
    end

    test "includes only approved windows, active locks and the current break-glass",
         %{site: site, opts: opts} = ctx do
      approver_opts = [actor: ctx.approver, tenant: ctx.tenant]

      approved = Sites.request_window!(recurring_attrs(site), opts)
      approved = Sites.approve_window!(approved, approver_opts)
      _requested = Sites.request_window!(recurring_attrs(site, %{days: [6]}), opts)

      rejected = Sites.request_window!(recurring_attrs(site, %{days: [7]}), opts)
      Sites.reject_window!(rejected, approver_opts)

      cancelled = Sites.create_approved_window!(one_off_attrs(site), approver_opts)
      Sites.cancel_window!(cancelled, approver_opts)

      future = Sites.create_approved_window!(one_off_attrs(site), approver_opts)

      long_ago =
        Sites.create_approved_window!(
          one_off_attrs(site, %{
            starts_at: ~N[2020-01-01 09:00:00],
            ends_at: ~N[2020-01-01 10:00:00]
          }),
          approver_opts
        )

      lock_open_ended =
        Sites.create_advisory_lock!(
          %{site_id: site.id, reason: "kev", source: "kev:CVE-2026-1"},
          opts
        )

      lock_expiring =
        Sites.create_advisory_lock!(
          %{site_id: site.id, reason: "acsc", source: "acsc", expires_at: later(3600)},
          opts
        )

      lifted =
        Sites.create_advisory_lock!(%{site_id: site.id, reason: "m", source: "manual"}, opts)

      Sites.lift_advisory_lock!(lifted, opts)

      _expired =
        Sites.create_advisory_lock!(
          %{site_id: site.id, reason: "old", source: "manual", expires_at: later(-60)},
          opts
        )

      bg_older = Sites.create_break_glass!(%{site_id: site.id, until: later(3600)}, approver_opts)
      bg_newer = Sites.create_break_glass!(%{site_id: site.id, until: later(1800)}, approver_opts)

      Ash.Seed.seed!(Cloud.Sites.BreakGlass, %{
        tenant_id: ctx.tenant.id,
        site_id: site.id,
        approved_by_id: ctx.approver.id,
        until: later(-60)
      })

      {:ok, version} = Policies.publish(site.id, reason: "check")
      {:ok, policy} = Policy.from_map(version.policy)

      assert Enum.map(policy.recurring_windows, & &1.id) == [approved.id]
      assert [%{id: future_id}] = policy.one_off_windows
      assert future_id == future.id
      refute long_ago.id in Enum.map(policy.one_off_windows, & &1.id)

      assert Enum.map(policy.advisory_locks, & &1.id) == [lock_open_ended.id, lock_expiring.id]

      assert [%{source: "kev:CVE-2026-1", expires_at: nil}, %{source: "acsc"}] =
               policy.advisory_locks

      assert policy.break_glass.until == DateTime.truncate(bg_newer.until, :second)
      assert policy.break_glass.approved_by == to_string(ctx.approver.email)

      # revoking the newest makes the older one current again
      revoked = Sites.revoke_break_glass!(bg_newer, approver_opts)
      {:ok, policy} = Policy.from_map(revoked.__metadata__.policy_version.policy)
      assert policy.break_glass.until == DateTime.truncate(bg_older.until, :second)
    end

    test "policy-changing actions publish in the same transaction",
         %{site: site, opts: opts} = ctx do
      Phoenix.PubSub.subscribe(Cloud.PubSub, Policies.topic(site.id))

      window = Sites.request_window!(recurring_attrs(site), opts)
      assert Sites.get_site!(site.id, opts).policy_version == 0
      refute_received {:policy_published, _, _}

      approved = Sites.approve_window!(window, actor: ctx.approver, tenant: ctx.tenant)
      assert %{version: 1, reason: "window approved"} = approved.__metadata__.policy_version
      assert approved.__metadata__.policy_version.published_by_id == ctx.approver.id
      assert_receive {:policy_published, _, 1}

      updated = Sites.update_site!(site, %{mode: :monitor}, opts)
      assert %{version: 2} = updated.__metadata__.policy_version
      assert updated.__metadata__.policy_version.policy["mode"] == "monitor"
      assert_receive {:policy_published, _, 2}
    end

    test "a failed action publishes nothing", %{site: site, opts: opts} do
      assert {:error, _} = Sites.update_site(site, %{tool_ids: ["nope"]}, opts)
      assert Sites.get_site!(site.id, opts).policy_version == 0
      assert Sites.list_policy_versions!(opts) == []
    end
  end

  describe "command_for/2" do
    test "needs a published version", %{site: site} do
      assert {:error, :not_published} = Policies.command_for(site.id)
      assert {:error, :not_found} = Policies.command_for(Ash.UUID.generate())
    end

    test "signs the latest version so a gateway verifies it and rebuilds the policy",
         %{site: site} do
      {:ok, _} = Policies.publish(site.id, reason: "one")
      {:ok, latest} = Policies.publish(site.id, reason: "two")

      assert {:ok, wire} = Policies.command_for(site.id)
      verifier = Cloud.Signer.verifier(site.id)

      assert {:ok, command, verifier} = Command.verify(wire, verifier, DateTime.utc_now())
      assert command.type == "policy"
      assert command.site_id == site.id
      assert command.policy_version == 2
      assert command.key_id == Cloud.Signer.key_id()
      assert DateTime.diff(command.expires_at, command.issued_at) == 600

      assert {:ok, policy} = Policy.from_map(command.payload)
      assert {:ok, ^policy} = Policy.from_map(latest.policy)
      assert policy.version == 2 and policy.site_id == site.id

      # json transport round trip verifies too
      json = Command.encode_wire(wire)

      assert {:ok, _, _} =
               Command.verify(json, Cloud.Signer.verifier(site.id), DateTime.utc_now())

      # the same command is a replay for the gateway that applied it
      assert {:error, :stale_version} = Command.verify(wire, verifier, DateTime.utc_now())
      # and it is bound to its site
      assert {:error, :wrong_site} =
               Command.verify(
                 wire,
                 Cloud.Signer.verifier(Ash.UUID.generate()),
                 DateTime.utc_now()
               )
    end

    test "re-signing gives a fresh nonce and expiry for the same version", %{site: site} do
      {:ok, _} = Policies.publish(site.id, reason: "one")
      issued = ~U[2026-10-31 09:00:00Z]

      {:ok, first} = Policies.command_for(site.id, now: issued)

      {:ok, second} =
        Policies.command_for(site.id, now: DateTime.add(issued, 3600), ttl_seconds: 120)

      assert first["envelope"]["policy_version"] == second["envelope"]["policy_version"]
      assert first["envelope"]["payload"] == second["envelope"]["payload"]
      assert first["envelope"]["nonce"] != second["envelope"]["nonce"]
      assert first["envelope"]["expires_at"] == "2026-10-31T09:10:00Z"
      assert second["envelope"]["expires_at"] == "2026-10-31T10:02:00Z"

      # a gateway that comes online late only accepts the fresh one
      late = DateTime.add(issued, 3630)
      assert {:error, :expired} = Command.verify(first, Cloud.Signer.verifier(site.id), late)
      assert {:ok, _, _} = Command.verify(second, Cloud.Signer.verifier(site.id), late)
    end
  end
end
