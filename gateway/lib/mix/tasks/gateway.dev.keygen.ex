defmodule Mix.Tasks.Gateway.Dev.Keygen do
  @shortdoc "Generates the dev ed25519 signing key pair"

  @moduledoc """
  Generates an Ed25519 key pair for signing dev policies and writes it to
  `priv/keys/dev_ed25519.json` (git-ignored, mode 0600), then prints the key id and
  public key. The dev config trusts this public key; restart the gateway after
  generating a new one.

      mix gateway.dev.keygen [--force]

  An existing key is kept unless `--force` is given. Dev only: production keys live
  with the cloud signer, and the gateway only ever holds public keys.
  """

  use Mix.Task

  @default_path "priv/keys/dev_ed25519.json"

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [force: :boolean])
    Mix.Task.run("app.config")
    path = Application.get_env(:gateway, :dev_key_file, Path.expand(@default_path))

    if File.exists?(path) and not Keyword.get(opts, :force, false) do
      Mix.raise("#{path} already exists, pass --force to replace it")
    end

    {pub, priv} = Breakline.Command.generate_keypair()

    key_id =
      "dev-" <> (:crypto.hash(:sha256, pub) |> Base.encode16(case: :lower) |> binary_part(0, 8))

    json =
      Breakline.CanonicalJSON.encode!(%{
        "key_id" => key_id,
        "public_key" => b64(pub),
        "private_key" => b64(priv)
      })

    File.mkdir_p!(Path.dirname(path))
    # restrict the file before the private key goes in
    File.write!(path, "")
    File.chmod!(path, 0o600)
    File.write!(path, json <> "\n")

    Mix.shell().info("""
    wrote #{Path.relative_to_cwd(path)}
    key id:     #{key_id}
    public key: #{b64(pub)}
    """)
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
