defmodule CloudWeb.RequestLiveTest do
  use CloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.Sites
  alias Cloud.Sites.RequestLinks

  setup %{conn: conn} do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin, %{name: "Penrith surgery", time_zone: "Australia/Adelaide"})

    contact =
      Sites.create_msp_contact!(%{name: "Sam at the MSP", email: "sam-#{unique()}@msp.example"},
        actor: admin,
        tenant: tenant
      )

    link =
      Sites.create_request_link!(%{site_id: site.id, msp_contact_id: contact.id},
        actor: admin,
        tenant: tenant
      )

    Map.merge(org, %{
      site: site,
      contact: contact,
      link: link,
      token: link.__metadata__.token,
      conn: with_ip(conn)
    })
  end

  # each test gets its own client ip, so the per-ip lookup limit is per test
  defp with_ip(conn) do
    n = unique()

    Plug.Test.put_peer_data(conn, %{
      address: {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)},
      port: 4000,
      ssl_cert: nil
    })
  end

  defp local_input(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.shift_zone!("Australia/Adelaide", Tz.TimeZoneDatabase)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> binary_part(0, 16)
  end

  defp submit(view, attrs) do
    view
    |> form("#request-form",
      request:
        Map.merge(
          %{
            starts_at: local_input(3600),
            ends_at: local_input(3 * 3600),
            reason: "INC-77 update the scanner"
          },
          attrs
        )
    )
    |> render_submit()
  end

  test "a valid link shows the site, its zone and the form, without signing in", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/request/#{ctx.token}")

    assert has_element?(view, "#request-site", "Penrith surgery")
    assert has_element?(view, "#request-time-zone", "Australia/Adelaide")
    assert has_element?(view, "#request-time-zone", "Sam at the MSP")
    assert has_element?(view, "#request-form")
    assert has_element?(view, "#no-requests")
    # nothing on the page approves or opens
    refute has_element?(view, "[phx-click=approve]")
    refute has_element?(view, "#passkey-ceremony")
  end

  test "unknown, malformed, expired and revoked links get the same generic page", ctx do
    {other, _} = RequestLinks.new_token()

    for token <- [other, "nope", String.duplicate("a", 43)] do
      {:ok, view, html} = live(ctx.conn, ~p"/request/#{token}")
      assert has_element?(view, "#link-invalid")
      refute html =~ "Penrith"
    end

    Ash.Seed.update!(ctx.link, %{expires_at: DateTime.add(DateTime.utc_now(), -1)})
    {:ok, view, expired_html} = live(ctx.conn, ~p"/request/#{ctx.token}")
    assert has_element?(view, "#link-invalid")
    refute expired_html =~ "Penrith"

    Ash.Seed.update!(ctx.link, %{expires_at: DateTime.add(DateTime.utc_now(), 3600)})
    Sites.revoke_request_link!(ctx.link, actor: ctx.admin, tenant: ctx.tenant)
    {:ok, view, revoked_html} = live(ctx.conn, ~p"/request/#{ctx.token}")
    assert has_element?(view, "#link-invalid")

    # the pages say the same thing, whatever the reason
    strip = fn html ->
      html |> LazyHTML.from_document() |> LazyHTML.query("#link-invalid") |> LazyHTML.text()
    end

    assert strip.(revoked_html) == strip.(expired_html)
  end

  test "submitting creates a requested window shown in the contact's list", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/request/#{ctx.token}")
    submit(view, %{})

    assert render(view) =~ "Request sent"
    [window] = Sites.list_windows!(tenant: ctx.tenant, authorize?: false)
    assert window.status == :requested
    assert window.requested_by_id == ctx.contact.id
    assert window.reason == "INC-77 update the scanner"
    assert has_element?(view, "#requests-#{window.id}-status", "Waiting")
    assert Sites.get_site!(ctx.site.id, authorize?: false).policy_version == 0

    # the approver's decision shows up live
    Sites.reject_window!(window, %{note: "not during clinic hours"},
      actor: ctx.approver,
      tenant: ctx.tenant
    )

    assert has_element?(view, "#requests-#{window.id}-status", "Rejected")
    assert render(view) =~ "not during clinic hours"
  end

  test "validation errors are shown and nothing is created", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/request/#{ctx.token}")

    html = submit(view, %{starts_at: local_input(-7200), ends_at: local_input(3600)})
    assert html =~ "must not be in the past"

    html = submit(view, %{ends_at: local_input(15 * 3600)})
    assert html =~ "must be at most 12 hours after the start"

    html = submit(view, %{starts_at: local_input(7200), ends_at: local_input(3600)})
    assert html =~ "must be after starts_at"

    assert Sites.list_windows!(tenant: ctx.tenant, authorize?: false) == []
  end

  test "the pending cap is shown on the form", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/request/#{ctx.token}")
    for _ <- 1..3, do: submit(view, %{})

    html = submit(view, %{})
    assert html =~ "already has 3 requests waiting"
    assert length(Sites.list_windows!(tenant: ctx.tenant, authorize?: false)) == 3
  end

  test "a link revoked while the page is open stops at the next submit", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/request/#{ctx.token}")
    Sites.revoke_request_link!(ctx.link, actor: ctx.admin, tenant: ctx.tenant)

    submit(view, %{})
    assert has_element?(view, "#link-invalid")
    assert Sites.list_windows!(tenant: ctx.tenant, authorize?: false) == []
  end

  test "token lookups are rate limited per ip with the same generic page", ctx do
    {limit, _window} = CloudWeb.RequestLive.Show.rate_limit()
    {other, _} = RequestLinks.new_token()

    # each live/2 is two lookups: the static render and the connected mount
    for _ <- 1..div(limit, 2), do: live(ctx.conn, ~p"/request/#{other}")

    {:ok, view, _html} = live(ctx.conn, ~p"/request/#{ctx.token}")
    assert has_element?(view, "#link-invalid")

    # another client is not affected
    {:ok, view, _html} = live(with_ip(build_conn()), ~p"/request/#{ctx.token}")
    assert has_element?(view, "#request-form")
  end
end
