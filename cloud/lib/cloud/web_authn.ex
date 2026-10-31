defmodule Cloud.WebAuthn do
  @moduledoc """
  The relying party settings every passkey ceremony uses, and the small codecs
  shared by registration, sign in and step-up.

  - `rp_id/0` is the bare host passkeys are bound to (`"localhost"` in dev and
    test). Changing it later invalidates every registered passkey.
  - `origin/0` is the full origin browsers report, `scheme://host[:port]`. It
    defaults to the browser endpoint's url and is set explicitly in prod.

  Both come from `config :cloud, :webauthn`. The strategy on
  `Cloud.Accounts.User` reads them through `Cloud.Secrets`, and the step-up
  ceremony (`Cloud.Accounts.StepUps`) uses the same values, so a passkey that
  signs in also approves.

  User verification (a PIN or biometric on the authenticator) is always
  required.
  """

  @doc "The relying party id, a bare host such as `\"localhost\"`."
  @spec rp_id() :: String.t()
  def rp_id, do: Keyword.fetch!(config(), :rp_id)

  @doc "The relying party name shown in the browser prompt."
  @spec rp_name() :: String.t()
  def rp_name, do: Keyword.get(config(), :rp_name, "Breakline")

  @doc "The origin browsers must report, by default the endpoint url."
  @spec origin() :: String.t()
  def origin, do: Keyword.get_lazy(config(), :origin, &CloudWeb.Endpoint.url/0)

  @doc "The user verification requirement, always `\"required\"`."
  @spec user_verification() :: String.t()
  def user_verification, do: "required"

  @doc "Base64url without padding, the encoding the browser hooks use."
  @spec encode64(binary()) :: String.t()
  def encode64(bytes) when is_binary(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "Decodes base64url with or without padding. Returns `:error` on bad input."
  @spec decode64(term()) :: {:ok, binary()} | :error
  def decode64(value) when is_binary(value),
    do: Base.url_decode64(String.trim_trailing(value, "="), padding: false)

  def decode64(_value), do: :error

  defp config, do: Application.get_env(:cloud, :webauthn, [])
end
