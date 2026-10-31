defmodule CloudWeb.RequestsLiveTest do
  use CloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.{Sites, SoftAuthenticator}
  alias Cloud.Sites.RequestLinks

  setup %{conn: conn} do
    %{tenant: tenant, admin: admin, approver: approver} = org = org!()
    site = site!(tenant, admin, %{name: "Liverpool lab"})

    contact =
      Sites.create_msp_contact!(%{name: "Alex at the MSP", email: "alex-#{unique()}@msp.example"},
        actor: admin,
        tenant: tenant
      )

    link =
      Sites.create_request_link!(%{site_id: site.id, msp_contact_id: contact.id},
        actor: admin,
        tenant: tenant
      )

    {:ok, window} =
      RequestLinks.request_window(link, %{
        starts_at: local_in(7200),
        ends_at: local_in(4 * 3600),
        reason: "CHG-9 firmware"
      })

    Map.merge(org, %{
      site: site,
      link: link,
      window: window,
      conn: log_in_user(conn, approver)
    })
  end

  defp local_in(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.shift_zone!("Australia/Sydney", Tz.TimeZoneDatabase)
    |> DateTime.to_naive()
    |> then(&%{&1 | second: 0, microsecond: {0, 0}})
  end

  defp answer(view, authenticator, overrides \\ []) do
    assert_push_event(view, "passkey:get", options)
    {authenticator, assertion} = SoftAuthenticator.assert(authenticator, options, overrides)
    render_hook(view, "passkey_assertion", Map.put(assertion, "ref", "step-up"))
    authenticator
  end

  test "lists pending requests with site, contact, times and reason", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/requests")

    card = "#pending-#{ctx.window.id}"
    assert has_element?(view, card, "Liverpool lab")
    assert has_element?(view, card, "Alex at the MSP")
    assert has_element?(view, card, "CHG-9 firmware")
    assert has_element?(view, card, Calendar.strftime(ctx.window.starts_at, "%H:%M"))
    assert has_element?(view, "#no-decided")
    # no passkey yet: no approve button, a pointer to add one
    refute has_element?(view, "#approve-#{ctx.window.id}")
    assert has_element?(view, "#passkey-needed")
  end

  test "approve runs a passkey step-up, then publishes", ctx do
    {authenticator, _} = passkey!(ctx.approver)
    Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(ctx.site.id))
    site_id = ctx.site.id
    {:ok, view, _html} = live(ctx.conn, ~p"/requests")

    view |> element("#approve-#{ctx.window.id}") |> render_click()
    assert has_element?(view, "#step-up-waiting")
    refute_received {:policy_published, _, _}

    answer(view, authenticator)
    assert_receive {:policy_published, ^site_id, 1}
    assert render(view) =~ "Approved: published policy v1"
    refute has_element?(view, "#pending-#{ctx.window.id}")
    assert has_element?(view, "#decided-#{ctx.window.id}")

    assert Sites.get_window!(ctx.window.id, tenant: ctx.tenant, authorize?: false).status ==
             :approved
  end

  test "a bad assertion approves nothing", ctx do
    {authenticator, _} = passkey!(ctx.approver)
    {:ok, view, _html} = live(ctx.conn, ~p"/requests")

    view |> element("#approve-#{ctx.window.id}") |> render_click()
    answer(view, authenticator, tamper_signature: true)
    assert render(view) =~ "The passkey response did not verify"
    assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0
    assert has_element?(view, "#pending-#{ctx.window.id}")
  end

  test "reject takes a note, needs no passkey and does not publish", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/requests")

    view
    |> form("#reject-form-#{ctx.window.id}", %{note: "try Saturday"})
    |> render_submit()

    assert render(view) =~ "Request rejected"
    assert has_element?(view, "#decided-#{ctx.window.id}", "try Saturday")
    refute_push_event(view, "passkey:get", _)

    window = Sites.get_window!(ctx.window.id, tenant: ctx.tenant, authorize?: false)
    assert window.status == :rejected
    assert window.rejected_by_id == ctx.approver.id
    assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0
  end

  test "new requests appear live", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/requests")

    {:ok, window} =
      RequestLinks.request_window(ctx.link, %{
        starts_at: local_in(9000),
        ends_at: local_in(10_800),
        reason: "second one"
      })

    assert has_element?(view, "#pending-#{window.id}", "second one")
  end

  test "other tenants' requests are neither shown nor decidable", ctx do
    other = org!()
    conn = log_in_user(build_conn(), other.approver)
    {:ok, view, _html} = live(conn, ~p"/requests")

    refute has_element?(view, "#pending-#{ctx.window.id}")
    assert has_element?(view, "#no-pending")

    render_click(view, "reject", %{"window_id" => ctx.window.id, "note" => ""})
    assert render(view) =~ "Request not found"

    render_click(view, "approve", %{"id" => ctx.window.id})
    assert render(view) =~ "Request not found"
    refute_push_event(view, "passkey:get", _)

    assert Sites.get_window!(ctx.window.id, tenant: ctx.tenant, authorize?: false).status ==
             :requested
  end
end
