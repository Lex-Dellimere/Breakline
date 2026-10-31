defmodule CloudWeb.AuthController do
  @moduledoc """
  Finishes the strategy routes of `auth_routes`.

  Only these activities create a session:

  - `{:password, :sign_in_with_token}`: the token is released by
    `CloudWeb.AuthLive.SignIn` only after the TOTP step, for users with TOTP
  - `{:webauthn, :sign_in_with_token}`: a passkey sign in
  - `{:password, :reset}` and `{:confirm_new_user, :confirm}`, for users
    without TOTP; users with TOTP are sent to sign in instead, so a reset
    link alone never skips the second factor

  Anything else (for example the plain password `sign_in` route, which would
  skip TOTP) is refused.
  """

  use CloudWeb, :controller
  use AshAuthentication.Phoenix.Controller

  @session_activities [{:password, :sign_in_with_token}, {:webauthn, :sign_in_with_token}]
  @link_activities [{:password, :reset}, {:confirm_new_user, :confirm}]

  def success(conn, activity, user, token) when activity in @session_activities,
    do: sign_in(conn, activity, user, token)

  def success(conn, activity, user, token) when activity in @link_activities do
    if Cloud.Accounts.Totp.enabled?(user) do
      conn
      |> put_flash(:info, success_message(activity) <> ". Sign in to continue.")
      |> redirect(to: ~p"/sign-in")
    else
      sign_in(conn, activity, user, token)
    end
  end

  def success(conn, _activity, _user, _token) do
    conn
    |> put_flash(:error, "Sign in from the sign in page")
    |> redirect(to: ~p"/sign-in")
  end

  defp success_message({:confirm_new_user, :confirm}),
    do: "Your email address has now been confirmed"

  defp success_message({:password, :reset}), do: "Your password has successfully been reset"
  defp success_message(_activity), do: "You are now signed in"

  defp sign_in(conn, activity, user, token) do
    return_to = get_session(conn, :return_to) || ~p"/dashboard"

    message = success_message(activity)

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    |> set_live_socket_id(token)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  def failure(conn, activity, reason) do
    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          """
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """

        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
         }} ->
          """
          An account with this email already exists. We've sent a link to that
          address - confirm it to finish linking this provider to your account.
          """

        {{:password, _}, _} ->
          "Incorrect email or password"

        {{:webauthn, _}, _} ->
          "The passkey sign in did not work"

        _ ->
          "Authentication failed"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session(:cloud)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end
end
