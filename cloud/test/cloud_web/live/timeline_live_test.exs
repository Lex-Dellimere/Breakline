defmodule CloudWeb.TimelineLiveTest do
  # pubsub broadcasts reach the liveview process, which shares the sandbox
  use CloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.Gateways
  alias CloudWeb.SitesLive.TimelineData

  setup %{conn: conn} do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin, %{name: "Parramatta clinic"})
    Map.merge(org, %{site: site, conn: log_in_user(conn, admin)})
  end

  defp event!(site, type, at, data \\ %{}) do
    Gateways.create_event!(%{site_id: site.id, type: type, at: at, data: data},
      tenant: site.tenant_id,
      authorize?: false
    )
  end

  defp delivery!(site, at) do
    Ash.Seed.seed!(Cloud.Notifications.Delivery, %{
      tenant_id: site.tenant_id,
      site_id: site.id,
      kind: :slack,
      channel_name: "IT channel",
      target_hint: "hooks.slack.com",
      event_type: :break_glass_opened,
      status: :sent,
      inserted_at: at,
      updated_at: at
    })
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp dom_order(html, ids) do
    ids
    |> Enum.map(fn id -> {id, :binary.match(html, ~s(id="items-#{id}"))} end)
    |> Enum.reject(&(elem(&1, 1) == :nomatch))
    |> Enum.sort_by(fn {_, {pos, _}} -> pos end)
    |> Enum.map(&elem(&1, 0))
  end

  test "signed out users are sent to sign in", ctx do
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(build_conn(), ~p"/sites/#{ctx.site.id}/timeline")
  end

  test "the site page links to its timeline", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
    assert has_element?(view, ~s(a#site-timeline-link[href="/sites/#{ctx.site.id}/timeline"]))
  end

  test "merges every kind newest first, in the site's time zone", ctx do
    old = event!(ctx.site, "blocked", ago(3 * 3600), %{"qname" => "relay.anydesk.com"})
    # a break-glass: an audit entry, a policy version
    break_glass!(ctx.site, DateTime.add(DateTime.utc_now(), 1800, :second), ctx.admin)
    newest = delivery!(ctx.site, DateTime.add(DateTime.utc_now(), 5, :second))

    [entry] =
      Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false)
      |> Enum.filter(&(&1.entry["action"] == "break_glass.created"))

    [version] = Cloud.Sites.list_policy_versions!(tenant: ctx.tenant.id, authorize?: false)

    {:ok, view, html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}/timeline")

    ids = [
      "notification-#{newest.id}",
      "policy-#{version.id}",
      "audit-#{entry.id}",
      "gateway-#{old.id}"
    ]

    assert dom_order(html, ids) == ids

    assert has_element?(view, "#items-gateway-#{old.id}", "relay.anydesk.com")
    assert has_element?(view, "#items-gateway-#{old.id}", "Gateway")

    local = CloudWeb.SitesLive.Presenter.local_time(old.at, "Australia/Sydney", "%d %b %H:%M:%S")
    assert has_element?(view, "#items-gateway-#{old.id}", local)

    assert has_element?(view, "#items-policy-#{version.id}", "published v1: break-glass opened")
    assert has_element?(view, "#items-policy-#{version.id}", to_string(ctx.admin.email))
    assert has_element?(view, "#items-audit-#{entry.id}", "break glass created")
    assert has_element?(view, "#items-audit-#{entry.id}", to_string(ctx.admin.email))

    assert has_element?(
             view,
             "#items-notification-#{newest.id}",
             "Break-glass opened to IT channel"
           )

    # the publish entry is shown as the policy version, not twice
    refute render(view) =~ "policy published"
  end

  test "filters by kind", ctx do
    event = event!(ctx.site, "state_changed", ago(60), %{"locked" => true, "mode" => "enforce"})
    break_glass!(ctx.site, DateTime.add(DateTime.utc_now(), 1800, :second), ctx.admin)

    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}/timeline")
    assert has_element?(view, ~s(#timeline li[data-kind="policy"]))

    view |> element("#filter-gateway") |> render_click()
    assert_patch(view, ~p"/sites/#{ctx.site.id}/timeline?kind=gateway")
    assert has_element?(view, "#items-gateway-#{event.id}")
    refute has_element?(view, ~s(#timeline li[data-kind="policy"]))
    refute has_element?(view, ~s(#timeline li[data-kind="audit"]))

    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}/timeline?kind=policy")
    assert has_element?(view, ~s(#timeline li[data-kind="policy"]))
    refute has_element?(view, "#items-gateway-#{event.id}")
  end

  test "load older pages through ties without gaps or repeats", ctx do
    same = ago(600)

    events =
      for i <- 1..60,
          do:
            event!(ctx.site, "blocked", if(i <= 55, do: same, else: ago(i)), %{"qname" => "q#{i}"})

    {:ok, view, html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}/timeline")
    assert length(Regex.scan(~r/id="items-gateway-/, html)) == 50
    assert has_element?(view, "#load-older")

    html = view |> element("#load-older") |> render_click()
    shown = Regex.scan(~r/id="items-(gateway-[0-9a-f-]+)"/, html) |> Enum.map(&List.last/1)

    assert length(shown) == 60
    assert Enum.sort(shown) == Enum.sort(Enum.map(events, &"gateway-#{&1.id}"))
    refute has_element?(view, "#load-older")
  end

  test "pages of one item cover exactly what one big page shows", ctx do
    at = ago(120)
    for i <- 1..4, do: event!(ctx.site, "blocked", at, %{"qname" => "q#{i}"})
    break_glass!(ctx.site, DateTime.add(DateTime.utc_now(), 1800, :second), ctx.admin)
    delivery!(ctx.site, at)

    kinds = TimelineData.kinds()
    {all, false} = TimelineData.page(ctx.admin, ctx.site, kinds, nil, 100, role: :admin)

    walked =
      Stream.unfold(nil, fn
        :done ->
          nil

        cursor ->
          case TimelineData.page(ctx.admin, ctx.site, kinds, cursor, 1, role: :admin) do
            {[item], true} -> {item, item.cursor}
            {[item], false} -> {item, :done}
            {[], _} -> nil
          end
      end)
      |> Enum.to_list()

    assert length(all) == 7
    assert Enum.map(walked, & &1.id) == Enum.map(all, & &1.id)
  end

  test "new gateway events appear live", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}/timeline")
    assert has_element?(view, "#timeline-empty")

    event = event!(ctx.site, "blocked", DateTime.utc_now(), %{"qname" => "live.example"})
    Gateways.broadcast_ui(ctx.site.id, {:gateway_events, ctx.site.id, [event]})

    assert has_element?(view, "#items-gateway-#{event.id}", "live.example")
  end

  test "approvers see no notification deliveries", ctx do
    delivery = delivery!(ctx.site, ago(30))
    conn = log_in_user(build_conn(), ctx.approver)

    {:ok, view, _html} = live(conn, ~p"/sites/#{ctx.site.id}/timeline")
    refute has_element?(view, "#items-notification-#{delivery.id}")

    {:ok, view, _html} = live(conn, ~p"/sites/#{ctx.site.id}/timeline?kind=notification")
    assert has_element?(view, "#timeline-admin-only")
  end

  test "only the site's own records, and only for members", ctx do
    other_site = site!(ctx.tenant, ctx.admin, %{name: "Other site"})
    hidden_event = event!(other_site, "blocked", ago(10), %{"qname" => "other.example"})
    break_glass!(other_site, DateTime.add(DateTime.utc_now(), 1800, :second), ctx.admin)

    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}/timeline")
    refute has_element?(view, "#items-gateway-#{hidden_event.id}")
    refute has_element?(view, ~s(#timeline li[data-kind="audit"]))
    refute has_element?(view, ~s(#timeline li[data-kind="policy"]))

    foreign = org!()
    hidden = site!(foreign.tenant, foreign.admin)

    for id <- [hidden.id, Ash.UUID.generate(), "not-a-uuid"] do
      assert {:error, {:live_redirect, %{to: "/sites", flash: %{"error" => "Site not found"}}}} =
               live(ctx.conn, ~p"/sites/#{id}/timeline")
    end
  end
end
