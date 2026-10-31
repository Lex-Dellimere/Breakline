defmodule CloudWeb.AccountSecurityLiveTest do
  use CloudWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.Accounts.{Passkeys, Totp, User}
  alias Cloud.SoftAuthenticator

  # the hook cannot run in LiveViewTest: answer its pushes like a browser would
  defp answer_create(view, authenticator) do
    assert_push_event(view, "passkey:create", options)
    attestation = SoftAuthenticator.attest(authenticator, options)
    render_hook(view, "passkey_attestation", Map.put(attestation, "ref", "register"))
  end

  defp answer_get(view, authenticator) do
    assert_push_event(view, "passkey:get", options)
    {authenticator, assertion} = SoftAuthenticator.assert(authenticator, options)
    render_hook(view, "passkey_assertion", Map.put(assertion, "ref", "step-up"))
    authenticator
  end

  setup %{conn: conn} do
    %{tenant: tenant, approver: approver} = org!()
    %{tenant: tenant, user: approver, conn: log_in_user(conn, approver)}
  end

  test "signed out users are sent to sign in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/account/security")
  end

  test "renders the passkey and totp sections", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account/security")
    assert has_element?(view, "#passkeys-card")
    assert has_element?(view, "#no-passkeys")
    assert has_element?(view, "#add-passkey-form")
    assert has_element?(view, "#passkey-ceremony")
    assert has_element?(view, "#totp-off")
    assert has_element?(view, "#totp-begin")
  end

  test "the first passkey registers with the ceremony alone", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account/security")
    authenticator = SoftAuthenticator.new()

    view |> form("#add-passkey-form", passkey: %{label: "work laptop"}) |> render_submit()
    assert has_element?(view, "#passkey-waiting")
    html = answer_create(view, authenticator)

    assert html =~ ~s(Passkey &quot;work laptop&quot; added)
    assert [passkey] = Passkeys.list(ctx.user)
    assert has_element?(view, "#passkeys-#{passkey.id}", "work laptop")
    assert has_element?(view, "#passkeys-#{passkey.id}", "last used never")
  end

  test "a second passkey first needs an assertion from the first", ctx do
    {authenticator, _} = passkey!(ctx.user)
    {:ok, view, _html} = live(ctx.conn, ~p"/account/security")

    view |> form("#add-passkey-form", passkey: %{label: "phone"}) |> render_submit()
    refute_push_event(view, "passkey:create", _)
    answer_get(view, authenticator)
    answer_create(view, SoftAuthenticator.new())

    assert length(Passkeys.list(ctx.user)) == 2
  end

  test "an approver cannot remove their last passkey", ctx do
    {_authenticator, passkey} = passkey!(ctx.user)
    {:ok, view, _html} = live(ctx.conn, ~p"/account/security")

    view |> element("#remove-#{passkey.id}") |> render_click()
    assert render(view) =~ "you must keep at least one passkey"
    refute_push_event(view, "passkey:get", _)
    assert [_] = Passkeys.list(ctx.user)
  end

  test "removing a passkey asks another passkey", ctx do
    {first_authenticator, first} = passkey!(ctx.user)

    {_, add} =
      step_up!(ctx.user, first_authenticator, :register_passkey, ctx.user.id, %{
        user_id: ctx.user.id
      })

    {second_authenticator, _second} = passkey!(ctx.user, step_up_id: add.id)
    {:ok, view, _html} = live(ctx.conn, ~p"/account/security")

    view |> element("#remove-#{first.id}") |> render_click()
    answer_get(view, second_authenticator)

    assert render(view) =~ "Passkey removed"
    refute has_element?(view, "#passkeys-#{first.id}")
    assert [_] = Passkeys.list(ctx.user)
  end

  test "a cancelled registration prompt stores nothing", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account/security")
    view |> form("#add-passkey-form", passkey: %{label: "x"}) |> render_submit()
    assert_push_event(view, "passkey:create", _)

    render_hook(view, "passkey_error", %{"ref" => "register", "name" => "NotAllowedError"})
    assert render(view) =~ "The passkey prompt was cancelled or timed out"
    assert Passkeys.list(ctx.user) == []
  end

  test "totp setup shows the uri and turns on with a code", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account/security")
    view |> element("#totp-begin") |> render_click()

    assert has_element?(view, "#totp-uri", "otpauth://totp/Breakline:")

    secret_b32 =
      view
      |> element("#totp-secret")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    secret = Base.decode32!(secret_b32, padding: false)

    view |> form("#totp-confirm-form", totp: %{code: "000000x"}) |> render_submit()
    assert render(view) =~ "That code did not match"

    view
    |> form("#totp-confirm-form", totp: %{code: NimbleTOTP.verification_code(secret)})
    |> render_submit()

    assert has_element?(view, "#totp-on")
    assert Totp.enabled?(ctx.user)

    # turning it off needs a fresh code
    Ash.Seed.update!(Ash.get!(User, ctx.user.id, authorize?: false), %{
      last_totp_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })

    view
    |> form("#totp-disable-form", totp: %{code: NimbleTOTP.verification_code(secret)})
    |> render_submit()

    assert has_element?(view, "#totp-off")
    refute Totp.enabled?(ctx.user)
  end
end
