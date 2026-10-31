defmodule CloudWeb.SitesLiveTest do
  # pubsub broadcasts reach the liveview process, which shares the sandbox
  use CloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.{Gateways, Sites}

  setup %{conn: conn} do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin, %{name: "Parramatta clinic"})
    Map.merge(org, %{site: site, conn: log_in_user(conn, admin)})
  end

  defp heartbeat(site, status) do
    site = Sites.record_heartbeat!(site, status, authorize?: false)

    Gateways.broadcast_ui(
      site.id,
      {:gateway_heartbeat, site.id, site.gateway_status, site.gateway_last_seen_at}
    )

    site
  end

  test "signed out users are sent to sign in", ctx do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/sites")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(build_conn(), ~p"/sites/#{ctx.site.id}")
  end

  test "the index lists the user's sites only", ctx do
    other = org!()
    hidden = site!(other.tenant, other.admin, %{name: "Somebody else's site"})

    {:ok, view, _html} = live(ctx.conn, ~p"/sites")
    assert has_element?(view, "#site-#{ctx.site.id}", "Parramatta clinic")
    assert has_element?(view, "#site-state-#{ctx.site.id}", "Unknown")
    assert has_element?(view, "#site-connected-#{ctx.site.id}", "Offline")
    refute has_element?(view, "#site-#{hidden.id}")
  end

  test "the index updates live on a heartbeat", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/sites")
    heartbeat(ctx.site, %{"state" => "open", "policy_version" => 0})
    assert has_element?(view, "#site-state-#{ctx.site.id}", "Open")
  end

  test "the show page renders the state and its reason", ctx do
    heartbeat(ctx.site, %{
      "state" => "locked",
      "mode" => "enforce",
      "reason" => %{"rule" => "clock_unsynced"},
      "policy_version" => 0
    })

    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
    assert has_element?(view, "#site-name", "Parramatta clinic")
    assert has_element?(view, "#site-state", "Locked")
    assert has_element?(view, "#site-reason", "Locked: gateway clock not synced")
    assert has_element?(view, "#site-connected", "Offline")
    assert has_element?(view, "#demo-actions", "passkey approval arrives in phase 4")
    assert has_element?(view, "#no-events")
  end

  test "another tenant's site is not found", ctx do
    other = org!()
    hidden = site!(other.tenant, other.admin)

    for id <- [hidden.id, Ash.UUID.generate(), "not-a-uuid"] do
      assert {:error, {:live_redirect, %{to: "/sites", flash: %{"error" => "Site not found"}}}} =
               live(ctx.conn, ~p"/sites/#{id}")
    end
  end

  test "updates live on heartbeats and events", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
    assert has_element?(view, "#site-reason", "No heartbeat yet")

    window =
      Sites.create_approved_window!(recurring_attrs(ctx.site),
        actor: ctx.admin,
        tenant: ctx.tenant
      )

    heartbeat(ctx.site, %{
      "state" => "open",
      "mode" => "enforce",
      "policy_version" => 1,
      "reason" => %{
        "rule" => "window",
        "id" => window.id,
        "starts_at" => "2026-11-02T11:00:00Z",
        "ends_at" => "2026-11-02T15:00:00Z"
      }
    })

    # the window was published (v1), so the page reloaded the windows
    assert has_element?(view, "#site-reason", "Open: window weeknights until 02:00")
    assert has_element?(view, "#site-state", "Open")
    assert has_element?(view, "#site-versions", "applied")

    {:ok, event} =
      Gateways.create_event(
        %{
          site_id: ctx.site.id,
          type: "blocked",
          at: DateTime.utc_now(),
          data: %{"qname" => "boot.net.anydesk.com"}
        },
        tenant: ctx.tenant,
        authorize?: false
      )

    Gateways.broadcast_ui(ctx.site.id, {:gateway_events, ctx.site.id, [event]})
    assert has_element?(view, "#site-events", "boot.net.anydesk.com")
  end

  test "demo actions publish a new policy", ctx do
    Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(ctx.site.id))
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
    site_id = ctx.site.id

    view |> element("#open-30") |> render_click()
    assert_receive {:policy_published, ^site_id, 1}
    assert has_element?(view, "#site-versions", "v1")

    view |> element("#lock-now") |> render_click()
    assert_receive {:policy_published, ^site_id, 2}

    view |> element("#unlock") |> render_click()
    assert_receive {:policy_published, ^site_id, 3}

    assert render(view) =~ "Manual locks lifted: published policy v3"

    view |> element("#unlock") |> render_click()
    assert render(view) =~ "There is no manual lock to lift"
    assert Sites.get_site!(site_id, authorize?: false).policy_version == 3
  end

  test "an approver cannot lock", ctx do
    conn = log_in_user(build_conn(), ctx.approver)
    {:ok, view, _html} = live(conn, ~p"/sites/#{ctx.site.id}")

    view |> element("#lock-now") |> render_click()
    assert render(view) =~ "Your role does not allow that"
    assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0
  end
end
