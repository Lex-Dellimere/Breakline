defmodule CloudWeb.AuthLiveTest do
  use CloudWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Cloud.Accounts.User

  @password "correct horse battery"

  defp register_user!(email) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :register,
        %{
          "email" => email,
          "password" => @password,
          "password_confirmation" => @password
        },
        []
      )

    user
  end

  defp user_exists?(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.exists?(authorize?: false)
  end

  describe "sign in" do
    test "renders the mishka sign in form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/sign-in")

      assert html =~ "Sign in"
      assert has_element?(view, "form#user-password-sign-in-with-password")
      assert has_element?(view, ~s(input[name="user[email]"]))
      assert has_element?(view, ~s(input[name="user[password]"]))
      assert has_element?(view, ~s(a[href="/register"]))
      assert has_element?(view, ~s(a[href="/reset"]))
    end

    test "shows an error for wrong credentials", %{conn: conn} do
      register_user!("someone@example.com")
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> form("#user-password-sign-in-with-password",
          user: %{email: "someone@example.com", password: "not the password"}
        )
        |> render_submit()

      assert html =~ "Email or password was incorrect"
      refute has_element?(view, ~s(form[phx-trigger-action] input[name="token"][value]))
    end

    test "valid credentials post a sign in token to the strategy route", %{conn: conn} do
      register_user!("valid@example.com")
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      form =
        form(view, "#user-password-sign-in-with-password",
          user: %{email: "valid@example.com", password: @password}
        )

      render_submit(form)

      token_form = form(view, "#user-password-sign-in-with-password-with-token")
      conn = follow_trigger_action(token_form, conn)

      assert conn.method == "POST"
      assert conn.request_path == "/auth/user/password/sign_in_with_token"
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "register" do
    test "renders the mishka register form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/register")

      assert html =~ "Create an account"
      assert has_element?(view, "form#user-password-register-with-password")
      assert has_element?(view, ~s(input[name="user[password_confirmation]"]))
    end

    test "shows errors for invalid input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#user-password-register-with-password",
          user: %{email: "new@example.com", password: "short", password_confirmation: "other"}
        )
        |> render_submit()

      assert html =~ "length must be greater than or equal to 8"
      refute user_exists?("new@example.com")
    end

    test "valid input creates the user and signs them in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      result =
        view
        |> form("#user-password-register-with-password",
          user: %{email: "new@example.com", password: @password, password_confirmation: @password}
        )
        |> render_submit()

      assert {:error, {:redirect, %{to: to}}} = result
      assert to =~ "/auth/user/password/sign_in_with_token?token="
      assert user_exists?("new@example.com")
    end
  end

  test "reset request page renders and always answers the same", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reset")

    html =
      view
      |> form("#user-password-request-password-reset-token",
        user: %{email: "nobody@example.com"}
      )
      |> render_submit()

    assert html =~ "If an account exists for that email"
  end

  test "sign out page renders a delete form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sign-out")
    assert has_element?(view, ~s(form#sign-out-form input[name="_method"][value="delete"]))
  end
end
