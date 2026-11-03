defmodule CloudWeb.SitesLiveTest do
  # pubsub broadcasts reach the liveview process, which shares the sandbox
  use CloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.{Gateways, Sites, SoftAuthenticator}

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
    assert has_element?(view, "#access", "Access")
    refute render(view) =~ "phase 4"
    # the admin has no passkey yet: no open or unlock buttons, a link to add one
    refute has_element?(view, "#open-30")
    refute has_element?(view, "#unlock")
    assert has_element?(view, "#lock-now")
    assert has_element?(view, ~s(#passkey-needed a[href="/account/security"]))
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

    window = book!(recurring_attrs(ctx.site), ctx.admin, ctx.tenant)

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

  # the hook cannot run in LiveViewTest: these tests answer its pushes with a
  # software authenticator, which is what the browser and a passkey would send
  defp answer(view, authenticator, overrides \\ []) do
    assert_push_event(view, "passkey:get", options)
    {authenticator, assertion} = SoftAuthenticator.assert(authenticator, options, overrides)
    render_hook(view, "passkey_assertion", Map.put(assertion, "ref", "step-up"))
    authenticator
  end

  test "open and unlock run after a passkey step-up, lock runs straight away", ctx do
    {authenticator, _} = passkey!(ctx.admin)
    Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(ctx.site.id))
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
    site_id = ctx.site.id

    view |> element("#open-30") |> render_click()
    assert has_element?(view, "#step-up-waiting")
    refute_received {:policy_published, _, _}

    authenticator = answer(view, authenticator)
    assert_receive {:policy_published, ^site_id, 1}
    assert has_element?(view, "#site-versions", "v1")
    assert render(view) =~ "Opened for 30 minutes: published policy v1"
    refute has_element?(view, "#step-up-waiting")

    [window] = Sites.list_windows!(authorize?: false, tenant: ctx.tenant)
    assert NaiveDateTime.diff(window.ends_at, window.starts_at) in [1800, 1860]

    view |> element("#lock-now") |> render_click()
    assert_receive {:policy_published, ^site_id, 2}

    view |> element("#unlock") |> render_click()
    _authenticator = answer(view, authenticator)
    assert_receive {:policy_published, ^site_id, 3}
    assert render(view) =~ "Manual locks lifted: published policy v3"

    # nothing to lift: refused before any passkey prompt
    view |> element("#unlock") |> render_click()
    assert render(view) =~ "There is no manual lock to lift"
    refute_push_event(view, "passkey:get", _)
    assert Sites.get_site!(site_id, authorize?: false).policy_version == 3
  end

  test "a threat-feed lock is shown and an admin lifts it with a passkey", ctx do
    {authenticator, _} = passkey!(ctx.admin)
    site_id = ctx.site.id

    lock =
      Sites.create_advisory_lock!(
        %{site_id: site_id, source: "kev:CVE-2099-0001", reason: "CISA KEV CVE-2099-0001: test"},
        tenant: ctx.tenant,
        authorize?: false
      )

    Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(site_id))
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{site_id}")
    assert has_element?(view, "#feed-lock-#{lock.id}", "CISA KEV CVE-2099-0001: test")

    # unlock only lifts manual locks
    view |> element("#unlock") |> render_click()
    assert render(view) =~ "There is no manual lock to lift"

    view |> element("#lift-feed-lock-#{lock.id}") |> render_click()
    assert has_element?(view, "#step-up-waiting")
    _authenticator = answer(view, authenticator)
    assert_receive {:policy_published, ^site_id, 2}
    assert render(view) =~ "Lock lifted: published policy v2"
    refute has_element?(view, "#feed-lock-#{lock.id}")
    assert Ash.get!(Sites.AdvisoryLock, lock.id, authorize?: false, tenant: ctx.tenant).lifted_at
  end

  test "an approver sees a threat-feed lock but cannot lift it", ctx do
    lock =
      Sites.create_advisory_lock!(
        %{site_id: ctx.site.id, source: "kev:CVE-2099-0001", reason: "CISA KEV CVE-2099-0001"},
        tenant: ctx.tenant,
        authorize?: false
      )

    passkey!(ctx.approver)
    conn = log_in_user(build_conn(), ctx.approver)
    {:ok, view, _html} = live(conn, ~p"/sites/#{ctx.site.id}")
    assert has_element?(view, "#feed-lock-#{lock.id}")
    refute has_element?(view, "#lift-feed-lock-#{lock.id}")
  end

  test "a bad assertion or a cancelled prompt opens nothing", ctx do
    {authenticator, _} = passkey!(ctx.admin)
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")

    view |> element("#open-15") |> render_click()
    answer(view, authenticator, tamper_signature: true)
    assert render(view) =~ "The passkey response did not verify"

    view |> element("#open-60") |> render_click()
    assert_push_event(view, "passkey:get", _options)
    render_hook(view, "passkey_error", %{"ref" => "step-up", "name" => "NotAllowedError"})
    assert render(view) =~ "The passkey prompt was cancelled or timed out"

    # an assertion with nothing pending is ignored
    render_hook(view, "passkey_assertion", %{"ref" => "step-up"})
    assert render(view) =~ "There is no passkey approval waiting"

    assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0
  end

  test "an approver cannot lock", ctx do
    conn = log_in_user(build_conn(), ctx.approver)
    {:ok, view, _html} = live(conn, ~p"/sites/#{ctx.site.id}")

    view |> element("#lock-now") |> render_click()
    assert render(view) =~ "Your role does not allow that"
    assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0
  end

  describe "break-glass" do
    test "opens after a passkey step-up, shows who and until when, and revokes", ctx do
      {authenticator, _} = passkey!(ctx.approver)
      conn = log_in_user(build_conn(), ctx.approver)
      Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(ctx.site.id))
      site_id = ctx.site.id
      {:ok, view, _html} = live(conn, ~p"/sites/#{site_id}")

      refute has_element?(view, "#break-glass-active")
      for m <- [15, 30, 60, 120, 240], do: assert(has_element?(view, "#break-glass-#{m}"))

      view |> element("#break-glass-120") |> render_click()
      assert has_element?(view, "#step-up-waiting")
      refute_received {:policy_published, _, _}

      answer(view, authenticator)
      assert_receive {:policy_published, ^site_id, 1}
      assert render(view) =~ "Break-glass open for 2 hours: published policy v1"
      assert has_element?(view, "#break-glass-active")
      assert has_element?(view, "#break-glass-by", to_string(ctx.approver.email))

      [break_glass] = Sites.list_break_glasses!(tenant: ctx.tenant, authorize?: false)
      assert_in_delta DateTime.diff(break_glass.until, DateTime.utc_now()), 7200, 10

      # revoking closes access, so it needs no passkey
      view |> element("#revoke-break-glass") |> render_click()
      refute_push_event(view, "passkey:get", _)
      assert_receive {:policy_published, ^site_id, 2}
      refute has_element?(view, "#break-glass-active")
    end

    test "an unknown duration is refused before any prompt", ctx do
      passkey!(ctx.admin)
      {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")

      render_click(view, "break_glass", %{"minutes" => "600"})
      assert render(view) =~ "Unknown duration"
      refute_push_event(view, "passkey:get", _)
    end
  end

  describe "msp request links" do
    setup ctx do
      contact =
        Sites.create_msp_contact!(%{name: "Kim at the MSP", email: "kim-#{unique()}@msp.example"},
          actor: ctx.admin,
          tenant: ctx.tenant
        )

      %{contact: contact}
    end

    test "an admin sends a link by email and revokes it", ctx do
      import Swoosh.TestAssertions

      {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
      assert has_element?(view, "#request-links")

      view
      |> form("#send-link-form", link: %{msp_contact_id: ctx.contact.id})
      |> render_submit()

      assert render(view) =~ "Request link emailed"
      [link] = Sites.list_request_links!(actor: ctx.admin, tenant: ctx.tenant)
      assert has_element?(view, "#request-link-status-#{link.id}", "active")

      assert_email_sent(fn email ->
        assert email.to == [{"Kim at the MSP", to_string(ctx.contact.email)}]
        assert email.text_body =~ "/request/"
      end)

      view |> element("#revoke-link-#{link.id}") |> render_click()
      assert has_element?(view, "#request-link-status-#{link.id}", "revoked")
      refute has_element?(view, "#revoke-link-#{link.id}")
    end

    test "approvers see no link management", ctx do
      conn = log_in_user(build_conn(), ctx.approver)
      {:ok, view, _html} = live(conn, ~p"/sites/#{ctx.site.id}")
      refute has_element?(view, "#request-links")

      render_click(view, "send_link", %{"link" => %{"msp_contact_id" => ctx.contact.id}})
      assert render(view) =~ "Your role does not allow that"
      assert Sites.list_request_links!(tenant: ctx.tenant, authorize?: false) == []
    end
  end
end
