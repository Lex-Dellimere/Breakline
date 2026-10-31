defmodule Cloud.Sites.TenantIsolationTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias Cloud.Sites

  setup do
    a = org!()
    b = org!()
    site = site!(a.tenant, a.admin)

    window =
      Sites.request_window!(recurring_attrs(site), actor: a.admin, tenant: a.tenant)

    {:ok, _} = Cloud.Policies.publish(site.id, reason: "test")
    %{a: a, b: b, site: site, window: window}
  end

  test "members of tenant a can read its records", %{a: a, site: site} do
    for actor <- [a.admin, a.approver] do
      assert [%{id: id}] = Sites.list_sites!(actor: actor, tenant: a.tenant)
      assert id == site.id
      assert [_] = Sites.list_windows!(actor: actor, tenant: a.tenant)
      assert [%{version: 1}] = Sites.list_policy_versions!(actor: actor, tenant: a.tenant)
    end
  end

  # forbidden reads are filtered to nothing rather than raising
  test "a member of tenant b reads nothing of tenant a with a's tenant", %{a: a, b: b} do
    for actor <- [b.admin, b.approver] do
      assert {:ok, []} = Sites.list_sites(actor: actor, tenant: a.tenant)
      assert {:ok, []} = Sites.list_windows(actor: actor, tenant: a.tenant)

      assert {:ok, []} = Sites.list_policy_versions(actor: actor, tenant: a.tenant)
    end
  end

  test "a member of tenant b sees nothing of tenant a in its own tenant", %{b: b, site: site} do
    assert [] = Sites.list_sites!(actor: b.admin, tenant: b.tenant)
    assert [] = Sites.list_windows!(actor: b.admin, tenant: b.tenant)
    assert [] = Sites.list_policy_versions!(actor: b.admin, tenant: b.tenant)
    assert {:error, _} = Sites.get_site(site.id, actor: b.admin, tenant: b.tenant)
  end

  test "reads without a tenant return nothing to actors", %{a: a} do
    assert {:ok, []} = Sites.list_sites(actor: a.admin)
  end

  test "a member of tenant b cannot change tenant a's records", %{a: a, b: b} = ctx do
    # records as tenant a's members see them carry tenant a
    site = Sites.get_site!(ctx.site.id, actor: a.admin, tenant: a.tenant)
    window = Sites.get_window!(ctx.window.id, actor: a.admin, tenant: a.tenant)

    assert {:error, %Ash.Error.Forbidden{}} =
             Sites.update_site(site, %{name: "pwned"}, actor: b.admin)

    assert {:error, %Ash.Error.Forbidden{}} = Sites.approve_window(window, actor: b.admin)
    assert {:error, %Ash.Error.Forbidden{}} = Sites.approve_window(window, actor: b.approver)

    assert {:error, %Ash.Error.Forbidden{}} =
             Sites.create_advisory_lock(%{site_id: site.id, reason: "x", source: "manual"},
               actor: b.admin,
               tenant: a.tenant
             )

    assert {:error, _} =
             Sites.update_site(site, %{name: "pwned"}, actor: b.admin, tenant: b.tenant)

    assert Sites.get_site!(site.id, authorize?: false).name == site.name
    assert Sites.get_window!(window.id, authorize?: false, tenant: a.tenant).status == :requested
  end

  test "records in tenant b cannot point at tenant a's site", %{b: b, site: site} do
    assert {:error, _} =
             Sites.request_window(recurring_attrs(site), actor: b.admin, tenant: b.tenant)

    assert {:error, _} =
             Sites.create_advisory_lock(%{site_id: site.id, reason: "x", source: "manual"},
               actor: b.admin,
               tenant: b.tenant
             )

    assert Sites.get_site!(site.id, authorize?: false).policy_version == 1
  end

  test "approvers cannot create or edit sites or manage locks and contacts", %{a: a, site: site} do
    opts = [actor: a.approver, tenant: a.tenant]

    assert {:error, %Ash.Error.Forbidden{}} =
             Sites.create_site(%{name: "x", time_zone: "Australia/Sydney"}, opts)

    assert {:error, %Ash.Error.Forbidden{}} = Sites.update_site(site, %{name: "y"}, opts)

    assert {:error, %Ash.Error.Forbidden{}} =
             Sites.create_advisory_lock(%{site_id: site.id, reason: "x", source: "manual"}, opts)

    assert {:error, %Ash.Error.Forbidden{}} =
             Sites.create_msp_contact(%{name: "x", email: "x@example.test"}, opts)

    assert {:error, %Ash.Error.Forbidden{}} = Sites.request_window(recurring_attrs(site), opts)
  end

  test "approvers can approve windows and open break-glass", %{a: a, window: window, site: site} do
    opts = [actor: a.approver, tenant: a.tenant]

    assert {:ok, %{status: :approved}} =
             Sites.approve_window(
               window,
               %{step_up_id: approve_step_up!(a.approver, window)},
               opts
             )

    until = DateTime.add(DateTime.utc_now(), 600)

    assert {:ok, _} =
             Sites.create_break_glass(
               %{
                 site_id: site.id,
                 until: until,
                 step_up_id: break_glass_step_up!(a.approver, site.id, until, a.tenant)
               },
               opts
             )
  end

  test "nobody without a membership can act, and policy versions are append only",
       %{a: a} = ctx do
    stranger = user!()

    assert {:ok, []} = Sites.list_sites(actor: stranger, tenant: a.tenant)
    assert {:ok, []} = Sites.list_sites(tenant: a.tenant)

    assert {:error, %Ash.Error.Forbidden{}} =
             Sites.create_policy_version(
               %{site_id: ctx.site.id, version: 99, policy: %{}, reason: "forged"},
               actor: a.admin,
               tenant: a.tenant
             )

    actions = Ash.Resource.Info.actions(Cloud.Sites.PolicyVersion) |> Enum.map(& &1.type)
    assert Enum.sort(Enum.uniq(actions)) == [:create, :read]
  end

  test "tenants are visible to their members only", %{a: a, b: b} do
    assert [%{id: id}] = Cloud.Accounts.list_tenants!(actor: a.admin)
    assert id == a.tenant.id
    assert {:error, _} = Cloud.Accounts.get_tenant(a.tenant.id, actor: b.admin)

    assert {:error, %Ash.Error.Forbidden{}} =
             Cloud.Accounts.update_tenant_settings(a.tenant, %{advisory_mode: :ask},
               actor: a.approver
             )

    assert {:ok, %{advisory_mode: :ask}} =
             Cloud.Accounts.update_tenant_settings(a.tenant, %{advisory_mode: :ask},
               actor: a.admin
             )
  end
end
