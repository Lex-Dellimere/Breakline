defmodule Cloud.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email
  """

  use AshAuthentication.Sender
  use CloudWeb, :verified_routes

  require Logger

  import Swoosh.Email

  alias Cloud.Mailer

  @impl true
  def send(user, token, _) do
    new()
    |> from(Mailer.from())
    |> to(to_string(user.email))
    |> subject("Reset your password")
    |> html_body(body(token: token))
    |> Mailer.deliver()
    |> log_failure()
  end

  defp body(params) do
    url = url(~p"/password-reset/#{params[:token]}")

    """
    <p>Click this link to reset your password:</p>
    <p><a href="#{url}">#{url}</a></p>
    """
  end

  # a failed send is logged, not raised: raising would fail the auth action itself
  # (D45). Cloud.Mailer.NotConfigured has already logged the recipient and subject
  defp log_failure({:ok, _}), do: :ok

  defp log_failure({:error, reason}) do
    Logger.warning("auth email not sent: #{inspect(reason)}")
    :ok
  end
end
