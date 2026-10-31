defmodule Cloud.Signer do
  @moduledoc """
  Signs `Breakline.Command`s for gateways with the cloud's Ed25519 key.

  The implementation is chosen by config:

      config :cloud, :signer, Cloud.Signer.File

  `Cloud.Signer.File` reads a key file and is meant for dev and pilots. In
  production the private key should not sit on the application host: replace
  it with an implementation backed by a KMS or HSM that signs the canonical
  envelope without ever exporting the key (threat model T8). Gateways only
  ever hold the public key.

  Implementations provide:

  - `key_id/0`: the key id written into every signed envelope
  - `public_key/0`: the raw 32 byte public key
  - `sign/1`: signs a command and returns the wire map of
    `Breakline.Command.sign/3`
  """

  @callback key_id() :: String.t()
  @callback public_key() :: Breakline.Command.public_key()
  @callback sign(Breakline.Command.t()) :: Breakline.Command.wire()

  @doc "The configured signer module."
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:cloud, :signer)

  @doc "The configured signer's key id."
  @spec key_id() :: String.t()
  def key_id, do: impl().key_id()

  @doc "The configured signer's raw 32 byte public key."
  @spec public_key() :: Breakline.Command.public_key()
  def public_key, do: impl().public_key()

  @doc "Signs a command with the configured signer."
  @spec sign(Breakline.Command.t()) :: Breakline.Command.wire()
  def sign(%Breakline.Command{} = command), do: impl().sign(command)

  @doc """
  A `Breakline.Command.Verifier` for `site_id` that trusts the configured
  signer's public key, as a gateway for that site would.
  """
  @spec verifier(String.t(), keyword()) :: Breakline.Command.Verifier.t()
  def verifier(site_id, opts \\ []) do
    Breakline.Command.Verifier.new(
      Keyword.merge([site_id: site_id, public_keys: %{key_id() => public_key()}], opts)
    )
  end
end
