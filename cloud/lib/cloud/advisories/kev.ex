defmodule Cloud.Advisories.KEV do
  @moduledoc """
  CISA's Known Exploited Vulnerabilities catalogue (CC0), the primary
  advisory trigger.

  The feed is one json document, newest entries first. Each entry becomes an
  advisory with `external_id` = `cveID` and `tool_ids` from
  `Breakline.Catalog.kev_match/1`, which normalises the inconsistent vendor
  and product strings. Every KEV entry is by definition actively exploited.
  Entries without a well-formed `cveID` are skipped.
  """

  @url "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
  @cve ~r/^CVE-\d{4}-\d{4,7}$/

  @doc "The feed url."
  @spec url() :: String.t()
  def url, do: @url

  @doc "Fetches the feed with a conditional GET, see `Cloud.Advisories.HTTP.get/3`."
  @spec fetch(map(), keyword()) :: Cloud.Advisories.HTTP.result()
  def fetch(validators, opts \\ []), do: Cloud.Advisories.HTTP.get(@url, validators, opts)

  @doc """
  Parses the KEV json into advisory attribute maps (see
  `Cloud.Advisories.Advisory`), without `:baseline?`.
  """
  @spec parse(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"vulnerabilities" => vulns}} when is_list(vulns) ->
        {:ok, vulns |> Enum.flat_map(&entry/1) |> Enum.uniq_by(& &1.external_id)}

      {:ok, _} ->
        {:error, :unexpected_document}

      {:error, error} ->
        {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp entry(%{"cveID" => cve} = vuln) when is_binary(cve) do
    cve = String.trim(cve)

    if Regex.match?(@cve, cve) do
      vendor = string(vuln["vendorProject"])
      product = string(vuln["product"])

      [
        %{
          source: :kev,
          external_id: cve,
          title: title(vuln, cve, vendor, product),
          cves: [cve],
          vendor: vendor,
          product: product,
          tool_ids: Breakline.Catalog.kev_match(vuln),
          exploitation: :active,
          published_at: date(vuln["dateAdded"]),
          link:
            "https://www.cisa.gov/known-exploited-vulnerabilities-catalog?search_api_fulltext=" <>
              cve,
          raw: vuln
        }
      ]
    else
      []
    end
  end

  defp entry(_vuln), do: []

  defp title(vuln, cve, vendor, product) do
    case string(vuln["vulnerabilityName"]) do
      nil -> Enum.join(Enum.reject([vendor, product, cve], &is_nil/1), " ")
      name -> String.slice(name, 0, 1000)
    end
  end

  defp string(value) when is_binary(value) do
    case value |> String.split() |> Enum.join(" ") do
      "" -> nil
      value -> value
    end
  end

  defp string(_value), do: nil

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
      {:error, _} -> nil
    end
  end

  defp date(_value), do: nil
end
