defmodule Mix.Tasks.Cloud.Dev.GatewayCert do
  @shortdoc "Issues a dev gateway client certificate and pins it on a site"

  @moduledoc """
  Issues a client certificate for a site's gateway, signed by the dev CA of
  `mix cloud.dev.pki`, and wires a local gateway checkout up to this cloud:

      mix cloud.dev.gateway_cert <site_id> [--gateway-dir ../gateway]

  It writes into `<gateway-dir>/priv/keys/` (git-ignored):

    * `gateway_cert.pem` and `gateway_key.pem`: the client certificate (common
      name = the site id) and its key
    * `ca_cert.pem`: the dev CA, which signed the cloud's server certificate
    * `site.json`: `{"site_id": ...}`
    * `cloud_signer.public.json`: the public half of the cloud signer key
      (`mix cloud.signer.keygen`), for the gateway to trust

  and pins the certificate's sha256 fingerprint on the site through the
  site's `:assign_gateway` action, which replaces any earlier certificate.
  `gateway/config/dev.exs` picks these files up and enables the uplink. For
  dev only.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: [gateway_dir: :string])

    site_id =
      case argv do
        [id] -> id
        _ -> Mix.raise("usage: mix cloud.dev.gateway_cert <site_id> [--gateway-dir DIR]")
      end

    Mix.Task.run("app.start")

    ca_dir = Mix.Tasks.Cloud.Dev.Pki.keys_dir()

    out =
      opts |> Keyword.get(:gateway_dir, "../gateway") |> Path.expand() |> Path.join("priv/keys")

    signer_public = signer_public_path()

    site =
      case Cloud.Sites.get_site(site_id, authorize?: false, not_found_error?: false) do
        {:ok, %{} = site} -> site
        _ -> Mix.raise("no site #{site_id}")
      end

    unless File.exists?(signer_public) do
      Mix.raise("#{signer_public} is missing, run `mix cloud.signer.keygen` first")
    end

    cert = Path.join(out, "gateway_cert.pem")

    fingerprint =
      case Cloud.DevPKI.issue_client(ca_dir, site.id, cert, Path.join(out, "gateway_key.pem")) do
        {:ok, fingerprint} -> fingerprint
        {:error, :no_ca} -> Mix.raise("no dev ca in #{ca_dir}, run `mix cloud.dev.pki` first")
        {:error, reason} -> Mix.raise("could not issue the certificate: #{inspect(reason)}")
      end

    File.cp!(Cloud.DevPKI.paths(ca_dir).ca_cert, Path.join(out, "ca_cert.pem"))
    File.cp!(signer_public, Path.join(out, "cloud_signer.public.json"))
    File.write!(Path.join(out, "site.json"), JSON.encode!(%{"site_id" => site.id}) <> "\n")

    # trusted dev path: whoever runs this task owns the dev database
    Cloud.Sites.assign_gateway!(site, fingerprint, authorize?: false)

    Mix.shell().info("""
    issued a gateway certificate for #{site.name} (#{site.id})
    fingerprint #{fingerprint}
    wrote gateway_cert.pem, gateway_key.pem, ca_cert.pem, site.json and
    cloud_signer.public.json to #{out}
    """)
  end

  defp signer_public_path do
    path = Cloud.Signer.File.path()
    Path.join(Path.dirname(path), Path.basename(path, ".json") <> ".public.json")
  end
end
