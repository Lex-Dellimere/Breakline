defmodule Cloud.Signer.File do
  @moduledoc """
  A `Cloud.Signer` that reads an Ed25519 key from a JSON file, for dev and
  pilots only. Production should use a KMS or HSM backed signer instead.

  The file is the format `mix gateway.dev.keygen` writes, so a dev gateway
  can trust the cloud's key directly:

      {"key_id":"cloud-1a2b3c4d","private_key":"<base64url>","public_key":"<base64url>"}

  Keys are 32 raw bytes, base64url without padding. Generate the file with
  `mix cloud.signer.keygen`. The path comes from

      config :cloud, Cloud.Signer.File, path: "priv/keys/signer_ed25519.json"

  The key is read once and cached in `:persistent_term`, keyed by path, so a
  regenerated key is picked up after a restart.
  """

  @behaviour Cloud.Signer

  @default_path "priv/keys/signer_ed25519.json"

  @impl true
  def key_id, do: key().key_id

  @impl true
  def public_key, do: key().public_key

  @impl true
  def sign(%Breakline.Command{} = command) do
    %{key_id: key_id, private_key: private_key} = key()
    Breakline.Command.sign(command, key_id, private_key)
  end

  @doc "The configured key file path."
  @spec path() :: Path.t()
  def path do
    :cloud
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:path, @default_path)
    |> Path.expand()
  end

  @doc """
  Reads and decodes a key file. Returns
  `{:ok, %{key_id: _, public_key: _, private_key: _}}` with raw key bytes.
  """
  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{"key_id" => key_id, "public_key" => pub, "private_key" => priv}}
         when is_binary(key_id) and key_id != "" <- JSON.decode(json),
         {:ok, <<_::256>> = pub} <- Base.url_decode64(pub, padding: false),
         {:ok, <<_::256>> = priv} <- Base.url_decode64(priv, padding: false),
         :ok <- check_pair(pub, priv) do
      {:ok, %{key_id: key_id, public_key: pub, private_key: priv}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_key_file}
    end
  end

  defp check_pair(pub, priv) do
    # the public key must belong to the private key, or every signature would fail to verify
    case :crypto.generate_key(:eddsa, :ed25519, priv) do
      {^pub, _} -> :ok
      _ -> {:error, :key_mismatch}
    end
  end

  defp key do
    path = path()

    case :persistent_term.get({__MODULE__, path}, nil) do
      nil ->
        case read(path) do
          {:ok, key} ->
            :persistent_term.put({__MODULE__, path}, key)
            key

          {:error, reason} ->
            raise "cannot load signer key from #{path}: #{inspect(reason)}, " <>
                    "run `mix cloud.signer.keygen`"
        end

      key ->
        key
    end
  end
end
