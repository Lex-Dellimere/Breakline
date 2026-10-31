defmodule Mix.Tasks.Cloud.Signer.Keygen do
  @shortdoc "Generates the cloud's ed25519 signing key file"

  @moduledoc """
  Generates an Ed25519 key pair for `Cloud.Signer.File` and writes it to the
  configured path (default `priv/keys/signer_ed25519.json`, git-ignored, mode
  0600), then prints the key id and public key.

      mix cloud.signer.keygen [--force]

  An existing key is kept unless `--force` is given. It also writes the public
  half alone next to it (`signer_ed25519.public.json`), in the same format
  without `private_key`, for gateways to trust.

  The file format matches `mix gateway.dev.keygen`. For dev and pilots only:
  production signs through a KMS or HSM backed `Cloud.Signer`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [force: :boolean])
    Mix.Task.run("app.config")
    path = Cloud.Signer.File.path()

    if File.exists?(path) and not Keyword.get(opts, :force, false) do
      Mix.raise("#{path} already exists, pass --force to replace it")
    end

    {pub, priv} = Breakline.Command.generate_keypair()

    key_id =
      "cloud-" <> (:crypto.hash(:sha256, pub) |> Base.encode16(case: :lower) |> binary_part(0, 8))

    public = %{"key_id" => key_id, "public_key" => b64(pub)}
    private = Map.put(public, "private_key", b64(priv))

    File.mkdir_p!(Path.dirname(path))
    # restrict the file before the private key goes in
    File.write!(path, "")
    File.chmod!(path, 0o600)
    File.write!(path, Breakline.CanonicalJSON.encode!(private) <> "\n")

    public_path = public_path(path)
    File.write!(public_path, Breakline.CanonicalJSON.encode!(public) <> "\n")

    Mix.shell().info("""
    wrote #{Path.relative_to_cwd(path)} and #{Path.relative_to_cwd(public_path)}
    key id:     #{key_id}
    public key: #{b64(pub)}
    """)
  end

  defp public_path(path) do
    Path.join(Path.dirname(path), Path.basename(path, ".json") <> ".public.json")
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
