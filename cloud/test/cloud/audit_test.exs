defmodule Cloud.AuditTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias Cloud.{Access, Audit, Sites}

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    Map.put(org, :site, site!(tenant, admin))
  end

  defp entries(tenant), do: Audit.audit_chain!(tenant: tenant, authorize?: false)
  defp actions(tenant), do: Enum.map(entries(tenant), & &1.entry["action"])

  test "an empty chain verifies", %{tenant: tenant} do
    assert entries(tenant) == []
    assert :ok = Audit.verify(tenant.id)
  end

  test "actions append their entries in order in the same transaction", ctx do
    window =
      Sites.request_window!(recurring_attrs(ctx.site), actor: ctx.admin, tenant: ctx.tenant)

    approve!(window, ctx.approver)
    {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "suspicious")
    {:ok, _} = Access.unlock(ctx.site.id, ctx.admin, unlock_step_up!(ctx.admin, ctx.site))

    assert actions(ctx.tenant) == [
             "window.requested",
             "window.approved",
             "policy.published",
             "access.lock_now",
             "policy.published",
             "advisory_lock.lifted",
             "policy.published",
             "access.unlock"
           ]

    entries = entries(ctx.tenant)
    assert Enum.map(entries, & &1.seq) == Enum.to_list(0..7)

    approved = Enum.at(entries, 1)
    assert approved.actor_id == ctx.approver.id
    assert approved.entry["actor_id"] == ctx.approver.id
    assert approved.entry["id"] == window.id
    assert approved.entry["site_id"] == ctx.site.id
    assert %{"version" => 1, "reason" => "window approved"} = Enum.at(entries, 2).entry

    assert :ok = Audit.verify(ctx.tenant.id)
  end

  test "a failed action leaves no entry", ctx do
    assert {:error, _} = Access.open_now(ctx.site.id, 30, ctx.admin, nil)
    assert {:error, %Ash.Error.Forbidden{}} = Access.lock_now(ctx.site.id, ctx.approver, "x")
    assert entries(ctx.tenant) == []
  end

  test "the chains of two tenants are separate", ctx do
    other = org!()
    other_site = site!(other.tenant, other.admin)
    {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "a")
    {:ok, _} = Access.lock_now(other_site.id, other.admin, "b")

    assert [%{seq: 0}, %{seq: 1}] = entries(ctx.tenant)
    assert [%{seq: 0}, %{seq: 1}] = entries(other.tenant)
    assert :ok = Audit.verify(ctx.tenant.id)
    assert :ok = Audit.verify(other.tenant.id)
  end

  test "members read their tenant's chain, others read nothing", ctx do
    {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, "a")
    assert [_, _] = Audit.audit_chain!(actor: ctx.approver, tenant: ctx.tenant)
    assert [] = Audit.audit_chain!(actor: org!().admin, tenant: ctx.tenant)
  end

  test "entries carry no secrets", ctx do
    {authenticator, _} = passkey!(ctx.admin)

    {_, _step_up} =
      step_up!(ctx.admin, authenticator, :lift_lock, ctx.site.id, %{site_id: ctx.site.id},
        tenant: ctx.tenant
      )

    json = entries(ctx.tenant) |> Enum.map(& &1.entry) |> Jason.encode!()
    refute json =~ "challenge"
    refute json =~ "signature"
    refute json =~ "public_key"
  end

  describe "verify" do
    setup ctx do
      for reason <- ~w(a b c), do: {:ok, _} = Access.lock_now(ctx.site.id, ctx.admin, reason)
      assert :ok = Audit.verify(ctx.tenant.id)
      :ok
    end

    test "detects an edited entry", ctx do
      [_, _, target | _] = entries(ctx.tenant)

      Repo.query!(
        "update audit_entries set entry = jsonb_set(entry, '{reason}', '\"edited\"') where id = $1",
        [Ecto.UUID.dump!(target.id)]
      )

      assert {:error, {:broken_at, 2, :hash_mismatch}} = Audit.verify(ctx.tenant.id)
    end

    test "detects a deleted entry", ctx do
      [_, target | _] = entries(ctx.tenant)
      Repo.query!("delete from audit_entries where id = $1", [Ecto.UUID.dump!(target.id)])
      assert {:error, {:broken_at, 1, :seq_gap}} = Audit.verify(ctx.tenant.id)
    end

    test "detects a cut-off tail against the head", ctx do
      last = List.last(entries(ctx.tenant))
      Repo.query!("delete from audit_entries where id = $1", [Ecto.UUID.dump!(last.id)])
      assert {:error, {:broken_at, 5, :truncated}} = Audit.verify(ctx.tenant.id)
    end
  end
end
