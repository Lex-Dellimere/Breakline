defmodule Cloud.Notifications.Vault do
  @moduledoc """
  Encrypts channel targets at rest.

  Webhook URLs carry their own secret (anyone holding a Slack or Teams
  webhook URL can post to the channel), so `Cloud.Notifications.Channel`
  stores every target encrypted with `Plug.Crypto.MessageEncryptor`
  (AES-256-GCM, authenticated). Email addresses and phone numbers go through
  the same path, so there is one rule for all targets.

  The keys are derived with `Plug.Crypto.KeyGenerator` (PBKDF2-SHA256) from
  a root secret and fixed salts. The root secret is `config :cloud,
  :notifications_key` when set (from `NOTIFICATIONS_KEY` in prod) and the
  endpoint's `secret_key_base` otherwise. Changing the root secret makes the
  stored targets undecryptable: their channels fail to deliver until they
  are added again. Key rotation is later work.
  """

  @encrypt_salt "breakline notification target encryption v1"
  @sign_salt "breakline notification target signing v1"

  @doc "Encrypts `plain` and returns the ciphertext as a url-safe string."
  @spec encrypt(String.t()) :: String.t()
  def encrypt(plain) when is_binary(plain) do
    {secret, sign_secret} = keys()
    Plug.Crypto.MessageEncryptor.encrypt(plain, secret, sign_secret)
  end

  @doc "Decrypts what `encrypt/1` returned: `{:ok, plain}` or `:error`."
  @spec decrypt(String.t() | nil) :: {:ok, String.t()} | :error
  def decrypt(ciphertext) when is_binary(ciphertext) do
    {secret, sign_secret} = keys()
    Plug.Crypto.MessageEncryptor.decrypt(ciphertext, secret, sign_secret)
  end

  def decrypt(_ciphertext), do: :error

  defp keys do
    root = root_secret()

    {Plug.Crypto.KeyGenerator.generate(root, @encrypt_salt, length: 32, cache: Plug.Crypto.Keys),
     Plug.Crypto.KeyGenerator.generate(root, @sign_salt, length: 32, cache: Plug.Crypto.Keys)}
  end

  defp root_secret do
    case Application.get_env(:cloud, :notifications_key) do
      key when is_binary(key) and byte_size(key) >= 32 -> key
      nil -> CloudWeb.Endpoint.config(:secret_key_base)
      _ -> raise ArgumentError, "the notifications key must be at least 32 bytes"
    end
  end
end
