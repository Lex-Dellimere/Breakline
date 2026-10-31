defmodule CloudWeb.NotificationsLiveTest do
  # delivery broadcasts reach the liveview process, which shares the sandbox
  use CloudWeb.ConnCase, async: false
  use Oban.Testing, repo: Cloud.Repo

  import Phoenix.LiveViewTest
  import Cloud.Fixtures
  import Cloud.NotificationFixtures

  alias Cloud.Notifications
  alias Cloud.Notifications.Worker

  @moduletag :capture_log

  setup %{conn: conn} do
    org = org!()
    other = org!()
    Map.merge(org, %{other: other, conn: log_in_user(conn, org.admin)})
  end

  test "signed out users are sent to sign in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(build_conn(), ~p"/settings/notifications")
  end

  test "approvers and members of other tenants are refused", ctx do
    for user <- [ctx.approver, user!()] do
      conn = log_in_user(build_conn(), user)

      assert {:error, {:live_redirect, %{to: "/sites", flash: %{"error" => error}}}} =
               live(conn, ~p"/settings/notifications")

      assert error =~ "admin"
    end
  end

  test "an admin of one tenant never sees another tenant's channels", ctx do
    theirs = channel!(ctx.other.tenant, ctx.other.admin, %{name: "Their Slack"})
    mine = channel!(ctx.tenant, ctx.admin, %{name: "My Slack"})

    {:ok, view, _html} = live(ctx.conn, ~p"/settings/notifications?tenant=#{ctx.other.tenant.id}")
    assert has_element?(view, "#channels-#{mine.id}", "My Slack")
    refute has_element?(view, "#channels-#{theirs.id}")
    refute render(view) =~ "Their Slack"

    # acting on another tenant's channel id finds nothing
    render_click(view, "remove", %{"id" => theirs.id})
    assert [_] = Notifications.list_channels!(tenant: ctx.other.tenant, authorize?: false)
    render_click(view, "test", %{"id" => theirs.id})
    assert Notifications.list_deliveries!(tenant: ctx.other.tenant, authorize?: false) == []
  end

  test "the nav links to the page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/sites")
    assert has_element?(view, ~s(#nav-notifications[href="/settings/notifications"]))
  end

  test "adds a channel and shows only its masked target", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings/notifications")
    assert has_element?(view, "#no-channels")
    assert has_element?(view, "#fallback-note")

    view
    |> form("#channel-form",
      channel: %{
        kind: "slack",
        name: "IT team",
        target: slack_url(),
        event_types: ["advisory_locked", "window_requested"]
      }
    )
    |> render_submit()

    [channel] = Notifications.list_channels!(tenant: ctx.tenant, authorize?: false)
    assert channel.name == "IT team"
    assert channel.event_types == [:advisory_locked, :window_requested]
    assert channel.created_by_id == ctx.admin.id

    html = render(view)
    assert has_element?(view, "#channels-#{channel.id}", "IT team")
    assert has_element?(view, "#target-#{channel.id}", "hooks.slack.com")
    refute html =~ slack_secret()
    refute html =~ "T0ABC1234"
  end

  test "shows validation errors for a bad target or no event types", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/settings/notifications")

    html =
      view
      |> form("#channel-form",
        channel: %{
          kind: "slack",
          name: "x",
          target: "https://hooks.slack.com.evil.example/services/a/b/c",
          event_types: ["advisory_locked"]
        }
      )
      |> render_submit()

    assert html =~ "Slack incoming webhook"

    view
    |> form("#channel-form",
      channel: %{kind: "email", name: "x", target: "ops@example.com", event_types: []}
    )
    |> render_submit()

    assert Notifications.list_channels!(tenant: ctx.tenant, authorize?: false) == []
  end

  test "enable, disable, send test and remove", ctx do
    stub_webhooks(200)
    channel = channel!(ctx.tenant, ctx.admin, %{name: "Ops"})
    {:ok, view, _html} = live(ctx.conn, ~p"/settings/notifications")

    view |> element("#toggle-#{channel.id}") |> render_click()
    assert has_element?(view, "#state-#{channel.id}", "Disabled")
    view |> element("#toggle-#{channel.id}") |> render_click()
    assert has_element?(view, "#state-#{channel.id}", "Enabled")

    view |> element("#test-#{channel.id}") |> render_click()
    [delivery] = Notifications.list_deliveries!(tenant: ctx.tenant, authorize?: false)
    assert has_element?(view, "#delivery-#{delivery.id}", "Queued")

    # the worker's status broadcast updates the page
    [job] = all_enqueued(worker: Worker)
    assert :ok = perform_job(Worker, job.args)
    assert_received {:webhook, "hooks.slack.com", _, _, %{"text" => text}}
    assert text =~ "/sites"
    _ = render(view)
    assert has_element?(view, "#delivery-#{delivery.id}", "Sent")

    view |> element("#remove-#{channel.id}") |> render_click()
    refute has_element?(view, "#channels-#{channel.id}")
    assert has_element?(view, "#no-channels")
    # the delivery history stays
    assert has_element?(view, "#delivery-#{delivery.id}")
  end

  test "an admin of several tenants picks one", ctx do
    member!(ctx.admin, ctx.other.tenant, :admin)
    channel!(ctx.other.tenant, ctx.other.admin, %{name: "Other Slack"})

    # tenants are listed by name and the first is the default; test names are random,
    # so pin the starting tenant instead of relying on which name sorts first
    {:ok, view, _html} = live(ctx.conn, ~p"/settings/notifications?tenant=#{ctx.tenant.id}")
    assert has_element?(view, "#tenant-picker")
    refute render(view) =~ "Other Slack"

    view |> element("#tenant-#{ctx.other.tenant.id}") |> render_click()
    assert render(view) =~ "Other Slack"
  end

  # /dev routes are mounted in dev only, so the page is rendered on its own
  test "the dev sms page lists the dev adapter's messages", ctx do
    Cloud.Notifications.SMS.Dev.clear()

    :ok =
      Cloud.Notifications.SMS.deliver("+61400000000", "Breakline: hello. Review: http://x/sites")

    {:ok, view, _html} = live_isolated(ctx.conn, CloudWeb.DevLive.Sms)
    assert has_element?(view, "#sms-messages", "Breakline: hello")

    view |> element("#sms-clear") |> render_click()
    assert has_element?(view, "#no-sms")
  end
end
