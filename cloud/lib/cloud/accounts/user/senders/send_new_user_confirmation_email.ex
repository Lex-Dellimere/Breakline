defmodule Cloud.Accounts.User.Senders.SendNewUserConfirmationEmail do
  @moduledoc """
  Sends an email for a new user to confirm their email address.
  """

  use AshAuthentication.Sender
  use CloudWeb, :verified_routes

  require Logger

  import Swoosh.Email

  alias Cloud.Mailer

  @impl true
  def send(user, token, opts) do
    new()
    |> from(Mailer.from())
    |> to(to_string(user.email))
    |> subject(subject(opts))
    |> html_body(body(token, opts))
    |> Mailer.deliver()
    |> log_failure()
  end

  # `opts[:confirmation_type]` is `:identity_link` when an OAuth2/OIDC
  # sign-in whose email matches this already-registered account is
  # asking to be linked (the strategy's `on_untrusted_email_match
  # :confirm`). Confirming grants that provider login access to this
  # account, so make the copy unambiguous about who is asking.
  defp subject(opts) do
    case opts[:confirmation_type] do
      :identity_link -> "Confirm linking your #{opts[:provider]} login"
      _ -> "Confirm your email address"
    end
  end

  defp body(token, opts) do
    url = url(~p"/confirm_new_user/#{token}")

    case opts[:confirmation_type] do
      :identity_link ->
        """
        <p>Someone signed in with #{opts[:provider]} using your email
        address and wants to link it to your account.</p>
        <p>If this was you, confirm here: <a href="#{url}">#{url}</a></p>
        <p>If it wasn't you, ignore this email - nothing has changed.</p>
        """

      _ ->
        """
        <p>Click this link to confirm your email:</p>
        <p><a href="#{url}">#{url}</a></p>
        """
    end
  end

  # a failed send is logged, not raised: raising would fail the auth action itself
  # (D45). Cloud.Mailer.NotConfigured has already logged the recipient and subject
  defp log_failure({:ok, _}), do: :ok

  defp log_failure({:error, reason}) do
    Logger.warning("auth email not sent: #{inspect(reason)}")
    :ok
  end
end
