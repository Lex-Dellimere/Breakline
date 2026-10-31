defmodule Cloud.Sites.BreakGlassTest do
  use Cloud.DataCase, async: false

  import Cloud.Fixtures

  alias Cloud.Sites

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin, %{name: "Blacktown depot"})
    Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Advisories.notifications_topic(tenant.id))
    Map.put(org, :site, site)
  end

  defp create(site, user, until, step_up_id) do
    Sites.create_break_glass(%{site_id: site.id, until: until, step_up_id: step_up_id},
      actor: user,
      tenant: site.tenant_id
    )
  end

  defp from_now(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp messages(%{errors: errors}), do: Enum.map(errors, & &1.message)

  test "until is at most 4 hours from now and not in the past", ctx do
    too_late = from_now(4 * 3600 + 60)
    step_up = break_glass_step_up!(ctx.approver, ctx.site.id, too_late, ctx.tenant)
    assert {:error, error} = create(ctx.site, ctx.approver, too_late, step_up)
    assert "must be at most 4 hours from now" in messages(error)

    past = from_now(-60)
    step_up = break_glass_step_up!(ctx.approver, ctx.site.id, past, ctx.tenant)
    assert {:error, error} = create(ctx.site, ctx.approver, past, step_up)
    assert "must be in the future" in messages(error)

    assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0

    until = from_now(4 * 3600 - 5)
    step_up = break_glass_step_up!(ctx.approver, ctx.site.id, until, ctx.tenant)
    assert {:ok, _} = create(ctx.site, ctx.approver, until, step_up)
  end

  test "needs a step-up bound to the site and the exact until", ctx do
    until = from_now(1800)

    assert {:error, error} = create(ctx.site, ctx.approver, until, nil)
    assert Cloud.Accounts.StepUps.step_up_error?(error)

    other_until = break_glass_step_up!(ctx.approver, ctx.site.id, from_now(3600), ctx.tenant)
    assert {:error, error} = create(ctx.site, ctx.approver, until, other_until)
    assert "the action changed after it was approved" in messages(error)

    other_site = site!(ctx.tenant, ctx.admin)
    wrong_site = break_glass_step_up!(ctx.approver, other_site.id, until, ctx.tenant)
    assert {:error, _} = create(ctx.site, ctx.approver, until, wrong_site)

    open_step_up = open_step_up!(ctx.approver, ctx.site, 30)
    assert {:error, error} = create(ctx.site, ctx.approver, until, open_step_up)
    assert "the passkey approval was for a different kind of action" in messages(error)

    assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0
    refute_receive {:notification, _}, 50
  end

  test "opening and revoking publish, audit and notify", ctx do
    Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(ctx.site.id))
    site_id = ctx.site.id

    # a real ceremony with the software authenticator
    {authenticator, _} = passkey!(ctx.approver)
    until = from_now(3600)

    {_authenticator, step_up} =
      step_up!(
        ctx.approver,
        authenticator,
        :break_glass,
        site_id,
        %{site_id: site_id, until: until},
        tenant: ctx.tenant
      )

    {:ok, break_glass} = create(ctx.site, ctx.approver, until, step_up.id)
    assert_receive {:policy_published, ^site_id, 1}
    email = to_string(ctx.approver.email)
    id = break_glass.id

    assert_receive {:notification,
                    %{
                      type: :break_glass_opened,
                      site_id: ^site_id,
                      break_glass_id: ^id,
                      by: ^email,
                      site_name: "Blacktown depot"
                    }}

    {:ok, latest} = Sites.latest_policy_version(site_id, tenant: ctx.tenant, authorize?: false)
    assert latest.policy["break_glass"]

    Sites.revoke_break_glass!(break_glass, actor: ctx.approver, tenant: ctx.tenant)
    assert_receive {:policy_published, ^site_id, 2}
    assert_receive {:notification, %{type: :break_glass_revoked, break_glass_id: ^id}}

    {:ok, latest} = Sites.latest_policy_version(site_id, tenant: ctx.tenant, authorize?: false)
    refute latest.policy["break_glass"]

    actions =
      Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false)
      |> Enum.map(& &1.entry["action"])

    assert "break_glass.created" in actions
    assert "break_glass.revoked" in actions
  end
end
