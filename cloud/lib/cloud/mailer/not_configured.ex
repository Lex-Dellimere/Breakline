defmodule Cloud.Mailer.NotConfigured do
  @moduledoc """
  The prod mail adapter when no provider is configured (no `POSTMARK_API_KEY`).

  It sends nothing and returns `{:error, :no_mail_provider}`, so callers that check
  the result (request links) can say the email was not sent, and logs one warning
  per email with its recipient and subject. Never the body: confirmation, reset and
  request links carry tokens.
  """
  use Swoosh.Adapter

  require Logger

  @impl true
  def deliver(%Swoosh.Email{} = email, _config) do
    to = Enum.map_join(email.to, ", ", fn {_name, address} -> address end)

    Logger.warning(
      "email not sent, no mail provider is configured (set POSTMARK_API_KEY): " <>
        "#{inspect(email.subject)} to #{to}"
    )

    {:error, :no_mail_provider}
  end
end
