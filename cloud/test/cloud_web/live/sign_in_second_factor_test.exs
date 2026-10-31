defmodule CloudWeb.SignInSecondFactorTest do
  use CloudWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.Accounts.{Totp, User}
  alias Cloud.SoftAuthenticator

  @password "correct horse battery"

  defp register_user!(email) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :register,
        %{"email" => email, "password" => @password, "password_confirmation" => @password},
        []
      )

    user
  end

  defp enable_totp!(user) do
    {:ok, setup} = Totp.begin_setup(user)
    secret = Base.decode32!(setup.secret, padding: false)
    {:ok, _} = Totp.confirm_setup(user, setup.setup_token, NimbleTOTP.verification_code(secret))

    # the setup code counts as used; pretend that was a minute ago
    Ash.Seed.update!(Ash.get!(User, user.id, authorize?: false), %{
      last_totp_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })

    secret
  end

  defp submit_password(view, email) do
    view
    |> form("#user-password-sign-in-with-password", user: %{email: email, password: @password})
    |> render_submit()
  end

  describe "totp" do
    test "a correct password asks for a code before any token leaves", %{conn: conn} do
      user = register_user!("totp@example.com")
      secret = enable_totp!(user)
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      submit_password(view, "totp@example.com")
      assert has_element?(view, "#totp-sign-in-form")
      refute has_element?(view, ~s(input[name="token"][value]))

      view |> form("#totp-sign-in-form", totp: %{code: "000000x"}) |> render_submit()
      assert render(view) =~ "That code was not right"
      refute has_element?(view, ~s(input[name="token"][value]))

      view
      |> form("#totp-sign-in-form", totp: %{code: NimbleTOTP.verification_code(secret)})
      |> render_submit()

      conn =
        follow_trigger_action(form(view, "#user-password-sign-in-with-password-with-token"), conn)

      assert conn.request_path == "/auth/user/password/sign_in_with_token"
      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, "user_token")
    end

    test "too many wrong codes send the user back to the password", %{conn: conn} do
      user = register_user!("locked@example.com")
      _secret = enable_totp!(user)
      {:ok, view, _html} = live(conn, ~p"/sign-in")
      submit_password(view, "locked@example.com")

      for _ <- 1..Totp.max_failures() do
        view |> form("#totp-sign-in-form", totp: %{code: "abcdef"}) |> render_submit()
      end

      view |> form("#totp-sign-in-form", totp: %{code: "abcdef"}) |> render_submit()
      assert render(view) =~ "Too many wrong codes"
      refute has_element?(view, "#totp-sign-in-form")
    end

    test "users without totp sign in with the password alone", %{conn: conn} do
      register_user!("plain@example.com")
      {:ok, view, _html} = live(conn, ~p"/sign-in")
      submit_password(view, "plain@example.com")
      refute has_element?(view, "#totp-sign-in-form")

      conn =
        follow_trigger_action(form(view, "#user-password-sign-in-with-password-with-token"), conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "the plain password route never creates a session", %{conn: conn} do
      user = register_user!("route@example.com")
      enable_totp!(user)

      conn =
        conn
        |> init_test_session(%{})
        |> post("/auth/user/password/sign_in", %{
          "user" => %{"email" => "route@example.com", "password" => @password}
        })

      assert redirected_to(conn) == ~p"/sign-in"
      refute get_session(conn, "user_token")
    end
  end

  test "a passkey signs in without a password or code", %{conn: conn} do
    user = register_user!("passkey@example.com")
    enable_totp!(user)
    {authenticator, _} = passkey!(user)
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    view |> element("#passkey-sign-in") |> render_click()
    assert_push_event(view, "passkey:get", options)
    assert options.allow_credentials == []
    {_, assertion} = SoftAuthenticator.assert(authenticator, options)
    render_hook(view, "passkey_assertion", Map.put(assertion, "ref", "sign-in"))

    conn =
      follow_trigger_action(form(view, "#user-password-sign-in-with-password-with-token"), conn)

    assert conn.request_path == "/auth/user/webauthn/sign_in_with_token"
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, "user_token")
  end

  test "a bad passkey assertion does not sign in", %{conn: conn} do
    user = register_user!("badkey@example.com")
    {authenticator, _} = passkey!(user)
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    view |> element("#passkey-sign-in") |> render_click()
    assert_push_event(view, "passkey:get", options)
    {_, assertion} = SoftAuthenticator.assert(authenticator, options, tamper_signature: true)
    render_hook(view, "passkey_assertion", Map.put(assertion, "ref", "sign-in"))

    assert render(view) =~ "That passkey could not sign you in"
    refute has_element?(view, ~s(input[name="token"][value]))
  end

  test "strategy routes we do not serve answer 404", %{conn: conn} do
    for path <- [
          "/auth/user/totp/setup",
          "/auth/user/totp/confirm_setup",
          "/auth/user/totp/verify",
          "/auth/user/webauthn/add_credential",
          "/auth/user/webauthn/add_credential_challenge"
        ] do
      assert conn |> post(path, %{}) |> response(404), path
    end
  end
end
