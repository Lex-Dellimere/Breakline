defmodule Cloud.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Cloud.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:cloud, :token_signing_secret)
  end
end
