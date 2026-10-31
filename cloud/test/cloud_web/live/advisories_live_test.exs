defmodule CloudWeb.AdvisoriesLiveTest do
  # pubsub broadcasts reach the liveview process, which shares the sandbox
  use CloudWeb.ConnCase, async: false
  use Oban.Testing, repo: Cloud.Repo

  import Phoenix.LiveViewTest
  import Cloud.AdvisoryFeeds
  import Cloud.Fixtures

  alias Cloud.{Accounts, Advisories, Sites}

  @moduletag :capture_log
  @trusted [authorize?: false]

  setup %{conn: conn} do
    org = org!()
    Accounts.update_tenant_settings!(org.tenant, %{advisory_mode: :ask}, @trusted)
    site = site!(org.tenant, org.admin, %{name: "Parramatta clinic", tool_ids: ["n_central"]})

    other = org!()

    other_site =
      site!(other.tenant, other.admin, %{name: "Somebody else's site", tool_ids: ["n_central"]})

    # kev baseline without one n-central entry, then that entry arrives
    serve(%{kev: kev_json(drop: ["CVE-2026-18556"])})
    {:ok, _} = Advisories.poll(:kev)
    serve(%{kev: kev_json()})
    {:ok, _} = Advisories.poll(:kev)

    [pending] = Advisories.list_site_advisories!([tenant: org.tenant] ++ @trusted)
    [other_locked] = Advisories.list_site_advisories!([tenant: other.tenant] ++ @trusted)

    Map.merge(org, %{
      site: site,
      other: other,
      other_site: other_site,
      pending: pending,
      other_locked: other_locked,
      conn: log_in_user(conn, org.approver)
    })
  end

  test "signed out users are sent to sign in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/advisories")
  end

  test "lists the user's tenants' advisories only", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/advisories")

    assert has_element?(view, "#pending #pending-#{ctx.pending.id}", "Parramatta clinic")
    assert has_element?(view, "#pending-#{ctx.pending.id}", "CVE-2026-18556")
    assert has_element?(view, "#pending-#{ctx.pending.id}", "Source: CISA KEV")
    assert has_element?(view, "#status-#{ctx.pending.id}", "Pending")
    assert has_element?(view, "#no-decided")
    refute has_element?(view, "#decided-#{ctx.other_locked.id}")
    refute render(view) =~ "Somebody else"
  end

  test "the nav links to the page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/sites")
    assert has_element?(view, "#nav-advisories")
  end

  test "confirm lock locks the site and moves it to recent decisions", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/advisories")
    view |> element("#confirm-#{ctx.pending.id}") |> render_click()

    assert has_element?(view, "#decided-#{ctx.pending.id}", "You confirmed the lock")
    refute has_element?(view, "#pending-#{ctx.pending.id}")
    assert [_lock] = Sites.list_advisory_locks!([tenant: ctx.tenant] ++ @trusted)
    assert {:ok, %{version: 1}} = Cloud.Policies.latest_policy_version(ctx.site.id)
  end

  test "dismiss leaves the site alone", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/advisories")
    view |> element("#dismiss-#{ctx.pending.id}") |> render_click()

    assert has_element?(view, "#decided-#{ctx.pending.id}", "You dismissed it")
    assert has_element?(view, "#status-#{ctx.pending.id}", "Dismissed")
    assert Sites.list_advisory_locks!([tenant: ctx.tenant] ++ @trusted) == []
  end

  test "another tenant's advisory cannot be decided by id", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/advisories")
    render_click(view, "dismiss", %{"id" => ctx.other_locked.id})
    render_click(view, "confirm", %{"id" => ctx.other_locked.id})
    render_click(view, "confirm", %{"id" => "not-a-uuid"})

    assert [%{status: :locked}] =
             Advisories.list_site_advisories!([tenant: ctx.other.tenant] ++ @trusted)

    assert [%{status: :pending}] =
             Advisories.list_site_advisories!([tenant: ctx.tenant] ++ @trusted)
  end

  test "acsc advisories carry the attribution and update live", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/advisories")

    serve(%{acsc_alerts: rss([])})
    {:ok, _} = Advisories.poll(:acsc_alerts)

    serve(%{
      acsc_alerts:
        rss([
          %{
            title: "Active exploitation of N-central servers",
            link: "https://www.cyber.gov.au/alert/n-central-servers"
          }
        ])
    })

    {:ok, %{acted: acted}} = Advisories.poll(:acsc_alerts)
    assert ctx.site.id in Enum.map(acted, & &1.site_id)

    assert render(view) =~ "Source: ACSC, CC BY 4.0"

    assert has_element?(
             view,
             ~s(#pending a[href="https://www.cyber.gov.au/alert/n-central-servers"])
           )
  end

  test "the dev poll button queues the feed jobs", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/advisories")
    view |> element("#poll-now") |> render_click()
    assert_enqueued(worker: Cloud.Advisories.Feed.AshOban.ActionWorker.PollKev)
  end
end
