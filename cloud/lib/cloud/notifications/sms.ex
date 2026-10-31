defmodule Cloud.Notifications.SMS do
  @moduledoc """
  The behaviour an SMS provider adapter implements, and the entry point the
  delivery worker calls.

  The adapter is `config :cloud, Cloud.Notifications.SMS, adapter: ...`.
  Dev and test use `Cloud.Notifications.SMS.Dev`, which sends nothing and
  keeps the last messages for the `/dev/sms` page. No real provider is
  chosen yet.

  ## Adding a provider

  Write a module that implements `c:deliver/2`: post `body` to `to` (an
  E.164 number) through the provider's API with `Req`, return `:ok` when the
  provider accepted the message and `{:error, reason}` otherwise. Use a
  short reason such as `{:http_status, 503}` and never put the provider's
  credentials or the number in it, because the reason is stored as the
  delivery's last error. Read the credentials from the environment in
  `config/runtime.exs`, set the adapter there for prod, and stub the
  provider in tests with `Req.Test`, as `Cloud.Notifications.Webhook` does.
  A `{:http_status, status}` error with a 4xx status other than 408 and
  429 is treated as permanent; anything else is retried by the worker (5
  attempts with backoff).
  """

  @doc "Sends `body` to the phone number `to` (E.164)."
  @callback deliver(to :: String.t(), body :: String.t()) :: :ok | {:error, term()}

  @doc "Sends an SMS through the configured adapter."
  @spec deliver(String.t(), String.t()) :: :ok | {:error, term()}
  def deliver(to, body), do: adapter().deliver(to, body)

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter do
    :cloud
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, Cloud.Notifications.SMS.Dev)
  end
end
