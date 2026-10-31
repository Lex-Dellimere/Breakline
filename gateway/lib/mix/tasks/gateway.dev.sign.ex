defmodule Mix.Tasks.Gateway.Dev.Sign do
  @shortdoc "Signs a dev policy into a command file"

  @moduledoc """
  Builds a policy from a file, validates it, signs it with the dev key from
  `mix gateway.dev.keygen` and writes the wire json.

      mix gateway.dev.sign <policy.exs | policy.json> [--version N] [--ttl S] [--out PATH]

  An `.exs` file is evaluated at sign time (so it can compute windows around now) and
  must return the attrs for `Breakline.Policy.new/1`, as a keyword list or atom keyed
  map. A `.json` file holds the string keyed form of `Breakline.Policy.to_map/1`.
  Either may leave out `site_id` (the configured dev site is used) and `version`.

    * `--version` - the policy and command version. Defaults to the current unix
      time, which keeps increasing between runs without tracking state.
    * `--ttl` - command validity in seconds, default 3600 (the gateway accepts at
      most 86_400). This is only how long the command may be accepted; an accepted
      policy stays enforced after it.
    * `--out` - where to write. Defaults to the dev inbox (`config :gateway,
      :inbox_dir`), where a running dev gateway picks it up within 2 seconds. The
      file is written to a temporary name and renamed, so the inbox never sees half
      of it.

  Dev only.
  """

  use Mix.Task

  alias Breakline.{Command, Policy}

  @impl true
  def run(args) do
    {opts, files} =
      OptionParser.parse!(args, strict: [version: :integer, ttl: :integer, out: :string])

    file =
      case files do
        [file] -> file
        _ -> Mix.raise("usage: mix gateway.dev.sign <policy.exs|policy.json> [--version N]")
      end

    Mix.Task.run("app.config")

    version = Keyword.get_lazy(opts, :version, fn -> System.os_time(:second) end)
    ttl = Keyword.get(opts, :ttl, 3600)
    site_id = Application.fetch_env!(:gateway, :site_id)
    {key_id, priv} = load_key()

    policy =
      case build_policy(file, site_id, version) do
        {:ok, policy} -> policy
        {:error, reasons} -> Mix.raise("invalid policy #{file}: #{inspect(reasons)}")
      end

    command =
      Command.new!(
        type: "policy",
        site_id: policy.site_id,
        policy_version: policy.version,
        ttl_seconds: ttl,
        payload: Policy.to_map(policy)
      )

    json = command |> Command.sign(key_id, priv) |> Command.encode_wire()
    out = Keyword.get_lazy(opts, :out, fn -> default_out(file, version) end)
    File.mkdir_p!(Path.dirname(out))

    # the .json name appears only on rename, so the inbox never reads a partial file
    tmp = out <> ".tmp"
    File.write!(tmp, json)
    File.rename!(tmp, out)

    Mix.shell().info(
      "signed #{Path.basename(file)} as version #{version} for #{policy.site_id} " <>
        "(key #{key_id}, valid #{ttl}s): #{Path.relative_to_cwd(out)}"
    )
  end

  @doc false
  @spec build_policy(Path.t(), String.t(), non_neg_integer()) ::
          {:ok, Policy.t()} | {:error, term()}
  def build_policy(file, site_id, version) do
    case Path.extname(file) do
      ".exs" ->
        {attrs, _binding} = Code.eval_file(file)

        attrs
        |> Map.new()
        |> Map.put_new(:site_id, site_id)
        |> Map.put(:version, version)
        |> Policy.new()

      ".json" ->
        with {:ok, map} when is_map(map) <- JSON.decode(File.read!(file)) do
          map
          |> Map.put_new("site_id", site_id)
          |> Map.put("version", version)
          |> Policy.from_map()
        else
          _ -> {:error, :invalid_json}
        end

      other ->
        {:error, {:unsupported_extension, other}}
    end
  end

  defp load_key do
    path = Application.get_env(:gateway, :dev_key_file, Path.expand("priv/keys/dev_ed25519.json"))

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"key_id" => id, "private_key" => b64}} <- JSON.decode(bytes),
         {:ok, priv} <- Base.url_decode64(b64, padding: false) do
      {id, priv}
    else
      _ -> Mix.raise("no dev key at #{path}, run mix gateway.dev.keygen first")
    end
  end

  defp default_out(file, version) do
    dir =
      Application.get_env(:gateway, :inbox_dir) ||
        Mix.raise("no :inbox_dir configured, pass --out")

    Path.join(dir, "#{Path.basename(file, Path.extname(file))}-v#{version}.json")
  end
end
