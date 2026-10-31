defmodule CloudWeb.DashboardLiveTest do
  # pubsub broadcasts reach the liveview process, which shares the sandbox
  use CloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Breakline.Policy
  alias Cloud.{Gateways, Sites}
  alias Cloud.Sites.RequestLinks
  alias CloudWeb.DashboardLive.Data

  setup %{conn: conn} do
    %{tenant: tenant, admin: admin} = org = org!(%{name: "B tenant"})
    open = site!(tenant, admin, %{name: "Alpha clinic"})
    locked = site!(tenant, admin, %{name: "Bravo lab"})
    Map.merge(org, %{open: open, locked: locked, conn: log_in_user(conn, admin)})
  end

  defp org!(attrs) do
    tenant = tenant!(attrs)
    admin = user!()
    approver = user!()
    member!(admin, tenant, :admin)
    member!(approver, tenant, :approver)
    %{tenant: tenant, admin: admin, approver: approver}
  end

  defp heartbeat(site, status) do
    site = Sites.record_heartbeat!(site, status, authorize?: false)

    Gateways.broadcast_ui(
      site.id,
      {:gateway_heartbeat, site.id, site.gateway_status, site.gateway_last_seen_at}
    )

    site
  end

  defp pending_request!(site, admin) do
    contact =
      Sites.create_msp_contact!(%{name: "Alex", email: "alex-#{unique()}@msp.example"},
        actor: admin,
        tenant: site.tenant_id
      )

    link =
      Sites.create_request_link!(%{site_id: site.id, msp_contact_id: contact.id},
        actor: admin,
        tenant: site.tenant_id
      )

    local = fn seconds ->
      DateTime.utc_now()
      |> DateTime.add(seconds, :second)
      |> DateTime.shift_zone!(site.time_zone, Tz.TimeZoneDatabase)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> Map.put(:second, 0)
    end

    {:ok, window} =
      RequestLinks.request_window(link, %{
        starts_at: local.(7200),
        ends_at: local.(3 * 3600),
        reason: "patching"
      })

    window
  end

  defp pending_advisory!(site) do
    advisory =
      Ash.Seed.seed!(Cloud.Advisories.Advisory, %{
        source: :kev,
        external_id: "CVE-2026-#{unique()}",
        title: "Remote access tool exploited",
        first_seen_at: DateTime.utc_now()
      })

    Ash.Seed.seed!(Cloud.Advisories.SiteAdvisory, %{
      tenant_id: site.tenant_id,
      site_id: site.id,
      advisory_id: advisory.id,
      status: :pending
    })
  end

  test "signed out users are sent to sign in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/dashboard")
  end

  test "the brand and the first nav link go to the dashboard", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/sites")
    assert has_element?(view, ~s(#brand[href="/dashboard"]))
    assert has_element?(view, ~s(#main-nav a#nav-dashboard[href="/dashboard"]))
    assert has_element?(view, ~s(#main-nav a#nav-audit[href="/audit"]))

    html = build_conn() |> get(~p"/") |> html_response(200)
    assert html =~ ~s(href="/" id="brand")
  end

  test "a signed-in user visiting sign in lands on the dashboard", ctx do
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(ctx.conn, ~p"/sign-in")
  end

  test "counters and one card per site", ctx do
    heartbeat(ctx.open, %{
      "state" => "open",
      "mode" => "enforce",
      "reason" => %{"rule" => "break_glass", "until" => "2030-01-01T00:00:00Z"},
      "policy_version" => 0
    })

    heartbeat(ctx.locked, %{
      "state" => "locked",
      "mode" => "monitor",
      "reason" => %{"rule" => "clock_unsynced"},
      "policy_version" => 0
    })

    until = DateTime.add(DateTime.utc_now(), 3600, :second)
    break_glass!(ctx.open, until, ctx.admin)
    pending_request!(ctx.locked, ctx.admin)
    pending_advisory!(ctx.locked)

    other = org!(%{name: "Other"})
    hidden = site!(other.tenant, other.admin, %{name: "Somebody else's site"})
    pending_request!(hidden, other.admin)

    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard")

    assert has_element?(view, "#count-open", "1")
    assert has_element?(view, "#count-locked", "1")
    assert has_element?(view, "#count-offline", "2")
    assert has_element?(view, "#count-requests", "1")
    assert has_element?(view, "#count-advisories", "1")
    assert has_element?(view, "#count-break-glass", "1")
    assert has_element?(view, ~s(a[href="/requests"] #count-requests))
    assert has_element?(view, ~s(a[href="/advisories"] #count-advisories))

    assert has_element?(view, "#dash-state-#{ctx.open.id}", "Open")
    assert has_element?(view, "#dash-reason-#{ctx.locked.id}", "Locked: gateway clock not synced")
    assert has_element?(view, "#dash-connected-#{ctx.locked.id}", "Offline")
    assert has_element?(view, "#dash-gateway-#{ctx.locked.id}", "last seen")
    assert has_element?(view, "#dash-mode-#{ctx.locked.id}", "monitor")
    assert has_element?(view, "#dash-break-glass-#{ctx.open.id}", "Break-glass open until")
    refute has_element?(view, "#dash-break-glass-#{ctx.locked.id}")
    # break-glass published a policy
    assert has_element?(view, "#dash-versions-#{ctx.open.id}", "v1")
    assert has_element?(view, ~s(#dash-site-#{ctx.open.id} a[href="/sites/#{ctx.open.id}"]))

    assert has_element?(
             view,
             ~s(a#dash-timeline-#{ctx.open.id}[href="/sites/#{ctx.open.id}/timeline"])
           )

    refute has_element?(view, "#dash-site-#{hidden.id}")
    refute render(view) =~ "Somebody else"
  end

  test "upcoming windows come from the published policy", ctx do
    book!(
      recurring_attrs(ctx.open, %{
        days: [1, 2, 3, 4, 5, 6, 7],
        starts: ~T[09:00:00],
        ends: ~T[10:30:00]
      }),
      ctx.admin,
      ctx.tenant
    )

    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard")

    assert has_element?(view, "#dash-windows-#{ctx.open.id}", "09:00–10:30")
    assert has_element?(view, "#dash-windows-#{ctx.open.id}", "recurring")
    assert has_element?(view, "#dash-no-windows-#{ctx.locked.id}")
  end

  test "the tenant picker switches tenants, defaulting to the first by name", ctx do
    first = org!(%{name: "A tenant"})
    member!(ctx.admin, first.tenant, :approver)
    first_site = site!(first.tenant, first.admin, %{name: "First tenant site"})

    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard")
    assert has_element?(view, "#tenant-picker")
    assert has_element?(view, "#dashboard-tenant", "A tenant")
    assert has_element?(view, "#dash-site-#{first_site.id}")
    refute has_element?(view, "#dash-site-#{ctx.open.id}")

    view |> element("#tenant-#{ctx.tenant.id}") |> render_click()
    assert_patch(view, ~p"/dashboard?tenant=#{ctx.tenant.id}")
    assert has_element?(view, "#dash-site-#{ctx.open.id}")
    refute has_element?(view, "#dash-site-#{first_site.id}")

    # a tenant the user is not a member of falls back to the default
    other = org!(%{name: "0 not mine"})
    hidden = site!(other.tenant, other.admin)
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard?tenant=#{other.tenant.id}")
    assert has_element?(view, "#dashboard-tenant", "A tenant")
    refute has_element?(view, "#dash-site-#{hidden.id}")
  end

  test "a heartbeat updates the card and the counters live", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard")
    assert has_element?(view, "#count-open", "0")

    heartbeat(ctx.open, %{"state" => "open", "policy_version" => 0})

    assert has_element?(view, "#dash-state-#{ctx.open.id}", "Open")
    assert has_element?(view, "#count-open", "1")
  end

  test "a new request updates the counter live", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/dashboard")
    assert has_element?(view, "#count-requests", "0")

    pending_request!(ctx.open, ctx.admin)

    assert has_element?(view, "#count-requests", "1")
  end

  describe "upcoming_windows/3" do
    defp sydney_policy(windows) do
      {:ok, policy} =
        Policy.new(
          site_id: "site",
          version: 1,
          mode: :enforce,
          time_zone: "Australia/Sydney",
          recurring_windows: windows
        )

      policy
    end

    defp local(dt), do: DateTime.shift_zone!(dt, "Australia/Sydney", Tz.TimeZoneDatabase)

    test "keeps local times across the end of daylight saving" do
      # clocks go back from 03:00 AEDT to 02:00 AEST on sunday 4 april 2027
      policy =
        sydney_policy([
          %{id: "night", days: [1, 2, 3, 4, 5, 6, 7], starts: ~T[01:00:00], ends: ~T[04:00:00]}
        ])

      now = ~U[2027-04-01 00:00:00Z]
      occurrences = Data.upcoming_windows(policy, now)

      assert length(occurrences) == 7

      assert Enum.all?(
               occurrences,
               &(local(&1.starts_at).hour == 1 and local(&1.ends_at).hour == 4)
             )

      durations =
        Map.new(
          occurrences,
          &{DateTime.to_date(local(&1.starts_at)), DateTime.diff(&1.ends_at, &1.starts_at, :hour)}
        )

      # the night of the change is an hour longer in real time
      assert durations[~D[2027-04-04]] == 4
      assert durations[~D[2027-04-03]] == 3
      assert durations[~D[2027-04-05]] == 3

      change = Enum.find(occurrences, &(DateTime.to_date(local(&1.starts_at)) == ~D[2027-04-04]))
      assert local(change.starts_at).utc_offset + local(change.starts_at).std_offset == 11 * 3600
      assert local(change.ends_at).utc_offset + local(change.ends_at).std_offset == 10 * 3600

      assert CloudWeb.SitesLive.Presenter.local_range(
               change.starts_at,
               change.ends_at,
               "Australia/Sydney"
             ) ==
               "Sun 04 Apr 01:00–04:00"
    end

    test "a start in the skipped hour opens at the transition" do
      # clocks go forward from 02:00 AEST to 03:00 AEDT on sunday 4 october 2026
      policy =
        sydney_policy([%{id: "early", days: [7], starts: ~T[02:30:00], ends: ~T[05:00:00]}])

      [occurrence] = Data.upcoming_windows(policy, ~U[2026-10-01 00:00:00Z])

      assert occurrence.starts_at == ~U[2026-10-03 16:00:00Z]
      assert local(occurrence.starts_at).hour == 3
      assert occurrence.kind == :recurring
      refute occurrence.active?
    end

    test "marks a running occurrence and returns nothing without a policy" do
      policy =
        sydney_policy([
          %{id: "day", days: [1, 2, 3, 4, 5, 6, 7], starts: ~T[09:00:00], ends: ~T[17:00:00]}
        ])

      now = ~U[2026-11-02 01:00:00Z]
      assert [%{active?: true} | rest] = Data.upcoming_windows(policy, now)
      assert Enum.all?(rest, &(not &1.active?))
      assert Data.upcoming_windows(nil, now) == []
    end
  end
end
