defmodule CloudWeb.GatewayEnrollmentLiveTest do
  use CloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.Sites
  alias Cloud.Sites.GatewayEnrollments
  alias Cloud.SoftAuthenticator

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: dir} do
    {:ok, pki} = Cloud.DevPKI.generate(dir)
    previous = Application.get_env(:cloud, :gateway_enrollment)

    Application.put_env(:cloud, :gateway_enrollment,
      url: "https://gw.example.test:4011",
      ca_certfile: pki.ca_cert
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:cloud, :gateway_enrollment, previous),
        else: Application.delete_env(:cloud, :gateway_enrollment)
    end)

    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin, %{name: "Parramatta clinic"})
    Map.merge(org, %{site: site, conn: log_in_user(conn, admin)})
  end

  defp answer(view, authenticator) do
    assert_push_event(view, "passkey:get", options)
    {_authenticator, assertion} = SoftAuthenticator.assert(authenticator, options)
    render_hook(view, "passkey_assertion", Map.put(assertion, "ref", "step-up"))
  end

  test "an admin enrols a gateway after a passkey step-up and sees the command once", ctx do
    {authenticator, _} = passkey!(ctx.admin)
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")

    assert has_element?(view, "#gateway-pin", "No gateway box is enrolled")
    refute has_element?(view, "#enroll-replaces")
    refute has_element?(view, "#enroll-command")

    view |> element("#enroll-gateway") |> render_click()
    answer(view, authenticator)

    assert has_element?(view, "#enroll-command")
    command = view |> element("#enroll-command") |> render()

    assert [_, code] =
             Regex.run(
               ~r/sudo breakline-gateway enroll https:\/\/gw\.example\.test:4011 ([A-Z2-7-]{39}) --ca-sha256 [0-9a-f]{64}/,
               command
             )

    assert command =~ GatewayEnrollments.ca_sha256()
    assert has_element?(view, "#enroll-pending")

    [enrollment] = Sites.list_gateway_enrollments!(actor: ctx.admin, tenant: ctx.tenant)
    assert enrollment.code_hash == GatewayEnrollments.hash_code(code)

    # after a reload the code is gone from the page, only its pending state remains
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
    refute has_element?(view, "#enroll-command")
    assert has_element?(view, "#enroll-pending")

    view |> element("#cancel-enrollment") |> render_click()
    refute has_element?(view, "#enroll-pending")
    assert {:error, :invalid} = GatewayEnrollments.enroll(code, "cert", nil)
  end

  test "enrolling without a verified passkey issues nothing", ctx do
    {authenticator, _} = passkey!(ctx.admin)
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")

    view |> element("#enroll-gateway") |> render_click()
    assert_push_event(view, "passkey:get", options)

    {_authenticator, assertion} =
      SoftAuthenticator.assert(authenticator, options, tamper_signature: true)

    render_hook(view, "passkey_assertion", Map.put(assertion, "ref", "step-up"))
    refute has_element?(view, "#enroll-command")
    assert [] = Sites.list_gateway_enrollments!(actor: ctx.admin, tenant: ctx.tenant)
  end

  test "a site with a gateway says plainly that enrolling replaces it", ctx do
    {authenticator, _} = passkey!(ctx.admin)
    {_site, _der} = gateway!(ctx.site)
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")

    assert has_element?(view, "#gateway-pin", "Enrolled box")
    assert has_element?(view, "#enroll-replaces", "replaces the current box")
    assert has_element?(view, "#enroll-gateway", "Enrol a replacement gateway")

    view |> element("#enroll-gateway") |> render_click()
    answer(view, authenticator)
    assert has_element?(view, "#enroll-command")
  end

  test "without a passkey the admin is pointed at the security page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
    refute has_element?(view, "#enroll-gateway")
    assert has_element?(view, ~s(#enroll-passkey-needed a[href="/account/security"]))
  end

  test "approvers do not see the card", ctx do
    conn = log_in_user(build_conn(), ctx.approver)
    passkey!(ctx.approver)
    {:ok, view, _html} = live(conn, ~p"/sites/#{ctx.site.id}")
    refute has_element?(view, "#gateway-enrollment")

    # and the event alone gets them nowhere
    render_click(view, "enroll_gateway", %{})
    assert [] = Sites.list_gateway_enrollments!(actor: ctx.admin, tenant: ctx.tenant)
  end

  test "an unconfigured server says enrolment is not set up", ctx do
    Application.delete_env(:cloud, :gateway_enrollment)
    passkey!(ctx.admin)
    {:ok, view, _html} = live(ctx.conn, ~p"/sites/#{ctx.site.id}")
    assert has_element?(view, "#enroll-unavailable")
    refute has_element?(view, "#enroll-gateway")
  end
end
