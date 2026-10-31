defmodule Cloud.Secrets do
  @moduledoc """
  Runtime values for the authentication strategies of `Cloud.Accounts.User`:
  the token signing secret and the passkey relying party settings
  (`Cloud.WebAuthn`).
  """

  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Cloud.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:cloud, :token_signing_secret)
  end

  def secret_for(
        [:authentication, :strategies, :webauthn, key],
        Cloud.Accounts.User,
        _opts,
        _context
      ) do
    case key do
      :rp_id -> {:ok, Cloud.WebAuthn.rp_id()}
      :rp_name -> {:ok, Cloud.WebAuthn.rp_name()}
      :origin -> {:ok, Cloud.WebAuthn.origin()}
      _ -> :error
    end
  end
end
