defmodule Mix.Tasks.Breakline.Catalog.Snapshot do
  @shortdoc "Fetches the LOLRMM tool records the catalog is curated from"

  @moduledoc """
  Fetches the LOLRMM per-tool records that `priv/catalog/tools.json` is curated
  from and writes them to `priv/catalog/lolrmm_snapshot.json`.

  This is a development task that needs network access. It is run by hand when
  the curated catalog is reviewed, and its output is committed so that the
  provenance tests can check every LOLRMM-sourced domain against it offline.
  Each tool record is stored in full, including its `References` and
  `Acknowledgement`, as the LOLRMM project asks reusers to preserve them.

      mix breakline.catalog.snapshot
  """

  use Mix.Task

  # inets, ssl and public_key are started at run time only; core does not depend on them
  @compile {:no_warn_undefined, [:httpc, :public_key]}

  @base_url "https://lolrmm.io/api/tools/"
  @source "https://lolrmm.io/api/tools/<slug>.json (github.com/magicsword-io/LOLRMM)"

  @slugs ~w(
    anydesk
    beanywhere
    centrastage-now-datto
    connectwise-control
    n-able-advanced-monitoring-agent
    n-able-n-central
    n-able-remote-access-software
    ninjaone-formerly-ninjarmm
    ninjarmm
    screenconnect
    splashtop
    splashtop-beta
    splashtop-remote
    teamviewer
  )

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    # mix prunes code paths to declared deps, so add these otp apps back first
    Enum.each([:inets, :public_key, :ssl], &Mix.ensure_application!/1)
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    tools = Map.new(@slugs, fn slug -> {slug, fetch!(slug)} end)

    snapshot = %{
      "source" => @source,
      "license" => "Apache-2.0",
      "fetched_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "tools" => tools
    }

    path = Path.join([File.cwd!(), "priv", "catalog", "lolrmm_snapshot.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [pretty(snapshot, 0), "\n"])
    Mix.shell().info("wrote #{map_size(tools)} tools to #{Path.relative_to_cwd(path)}")
  end

  defp fetch!(slug) do
    url = String.to_charlist(@base_url <> slug <> ".json")

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {url, []}, [ssl: ssl, timeout: 30_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        JSON.decode!(body)

      {:ok, {{_, status, _}, _headers, _body}} ->
        Mix.raise("lolrmm returned http #{status} for #{slug}")

      {:error, reason} ->
        Mix.raise("fetching #{slug} failed: #{inspect(reason)}")
    end
  end

  # sorted keys and two-space indent so snapshot diffs stay readable
  defp pretty(map, _depth) when is_map(map) and map_size(map) == 0, do: "{}"

  defp pretty(map, depth) when is_map(map) do
    pad = indent(depth + 1)

    entries =
      map
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> [pad, JSON.encode!(k), ": ", pretty(v, depth + 1)] end)
      |> Enum.intersperse(",\n")

    ["{\n", entries, "\n", indent(depth), "}"]
  end

  defp pretty([], _depth), do: "[]"

  defp pretty(list, depth) when is_list(list) do
    pad = indent(depth + 1)
    entries = list |> Enum.map(&[pad, pretty(&1, depth + 1)]) |> Enum.intersperse(",\n")
    ["[\n", entries, "\n", indent(depth), "]"]
  end

  defp pretty(value, _depth), do: JSON.encode!(value)

  defp indent(depth), do: String.duplicate("  ", depth)
end
