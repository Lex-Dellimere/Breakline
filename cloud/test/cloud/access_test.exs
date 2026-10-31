defmodule Cloud.AccessTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures

  alias Breakline.{Policy, Schedule}
  alias Cloud.{Access, Sites}

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    Map.put(org, :site, site!(tenant, admin))
  end

  defp state_now(version) do
    {:ok, policy} = Policy.from_map(version.policy)
    Schedule.state_at(policy, DateTime.utc_now())
  end

  test "local_span rounds outward to whole minutes in the site zone" do
    now = ~U[2026-10-31 09:15:42.123456Z]
    # sydney is utc+11 in daylight time
    assert Access.local_span(now, 30, "Australia/Sydney") ==
             {~N[2026-10-31 20:15:00], ~N[2026-10-31 20:46:00]}

    assert Access.local_span(~U[2026-10-31 09:15:00Z], 30, "Australia/Sydney") ==
             {~N[2026-10-31 20:15:00], ~N[2026-10-31 20:45:00]}

    assert Access.local_span(~U[2026-10-31 09:15:00Z], 60, "Australia/Brisbane") ==
             {~N[2026-10-31 19:15:00], ~N[2026-10-31 20:15:00]}
  end

  test "open_now books an approved one-off window and publishes", %{site: site} = ctx do
    assert {:ok, %{window: window, policy_version: version}} =
             Access.open_now(site.id, 30, ctx.approver, open_step_up!(ctx.approver, site, 30))

    assert window.status == :approved
    assert window.kind == :one_off
    assert window.approved_by_id == ctx.approver.id
    assert NaiveDateTime.diff(window.ends_at, window.starts_at) in [1800, 1860]
    assert version.version == 1
    assert version.published_by_id == ctx.approver.id
    assert [%{"id" => id}] = version.policy["one_off_windows"]
    assert id == window.id
    assert state_now(version) == :open
  end

  test "lock_now locks over an open window and unlock lifts it", %{site: site} = ctx do
    {:ok, _} = Access.open_now(site.id, 60, ctx.admin, open_step_up!(ctx.admin, site, 60))

    assert {:ok, %{lock: lock, policy_version: v2}} =
             Access.lock_now(site.id, ctx.admin, "suspicious login")

    assert lock.source == "manual" and lock.expires_at == nil
    assert v2.version == 2
    assert state_now(v2) == :locked

    # a feed lock is not lifted by unlock
    feed =
      Sites.create_advisory_lock!(%{site_id: site.id, reason: "kev", source: "kev:CVE-2026-9"},
        authorize?: false,
        tenant: site.tenant_id
      )

    {:ok, _} = Access.lock_now(site.id, ctx.admin, "second")

    Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(site.id))

    assert {:ok, %{locks: lifted, policy_version: v5}} =
             Access.unlock(site.id, ctx.admin, unlock_step_up!(ctx.admin, site))

    assert length(lifted) == 2
    assert Enum.all?(lifted, &(&1.lifted_at && &1.lifted_by_id == ctx.admin.id))
    # one publish for both lifts
    assert v5.version == 5
    assert v5.reason == "manual lock lifted"
    assert_receive {:policy_published, _, 5}
    assert [%{"id" => id}] = v5.policy["advisory_locks"]
    assert id == feed.id
    assert state_now(v5) == :locked

    assert {:error, :no_manual_lock} =
             Access.unlock(site.id, ctx.admin, unlock_step_up!(ctx.admin, site))
  end

  test "roles are enforced", %{site: site} = ctx do
    stranger = user!()

    assert {:error, %Ash.Error.Forbidden{}} =
             Access.open_now(site.id, 30, stranger, open_step_up!(stranger, site, 30))

    assert {:error, %Ash.Error.Forbidden{}} = Access.lock_now(site.id, ctx.approver, "x")

    {:ok, _} = Access.lock_now(site.id, ctx.admin, "x")

    assert {:error, %Ash.Error.Forbidden{}} =
             Access.unlock(site.id, ctx.approver, unlock_step_up!(ctx.approver, site))

    assert Sites.get_site!(site.id, authorize?: false).policy_version == 1

    assert {:error, :not_found} = Access.lock_now(Ash.UUID.generate(), ctx.admin, "x")
  end
end
