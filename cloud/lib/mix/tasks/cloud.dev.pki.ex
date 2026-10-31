defmodule Mix.Tasks.Cloud.Dev.Pki do
  @shortdoc "Creates the dev CA and the gateway endpoint's server certificate"

  @moduledoc """
  Creates a dev certificate authority and a server certificate for
  `CloudWeb.GatewayEndpoint` (for `localhost` and `127.0.0.1`) with the
  `openssl` command line tool, in `priv/keys/` (git-ignored):

      mix cloud.dev.pki [--force]

  Existing files are kept unless `--force` is given. Replacing the CA
  invalidates every gateway certificate issued with
  `mix cloud.dev.gateway_cert`. For dev only, see `Cloud.DevPKI`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [force: :boolean])
    dir = keys_dir()

    case Cloud.DevPKI.generate(dir, force: Keyword.get(opts, :force, false)) do
      {:ok, paths} ->
        Mix.shell().info("""
        wrote the dev ca and the gateway endpoint certificate:
          #{Path.relative_to_cwd(paths.ca_cert)}
          #{Path.relative_to_cwd(paths.server_cert)} (localhost, 127.0.0.1)
        """)

      {:error, :exists} ->
        Mix.shell().info(
          "#{Path.relative_to_cwd(dir)} already has a dev ca, pass --force to replace it"
        )

      {:error, reason} ->
        Mix.raise("could not create the dev pki: #{inspect(reason)}")
    end
  end

  @doc false
  def keys_dir, do: Path.expand("priv/keys")
end
