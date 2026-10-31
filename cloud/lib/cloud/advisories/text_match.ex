defmodule Cloud.Advisories.TextMatch do
  @moduledoc """
  Conservative matching of free-text advisories (ACSC) to catalog tools.

  - `cves/1` finds CVE ids written as `CVE-2026-1234`, `CVE 2026 1234` or
    `CVE-2026 1234` and normalises them to `CVE-2026-1234`.
  - `tool_ids/1` finds the catalog tools a text names: case-insensitive,
    whole words only (a letter or digit on either side is no match).
  - `exploitation/2` reads the (undocumented) signals in an alert's title
    and text.

  The names come from `Breakline.Catalog`: each tool's full name, its name
  without the vendor prefix, and the vendor when the vendor is the product
  (AnyDesk, TeamViewer, Splashtop, NinjaOne). Rejected as too noisy:

  - vendors with several products (`N-able`, `ConnectWise`, `Datto`): they
    would match every product of the vendor, including ones not in the
    catalog;
  - bare `Take Control`, an everyday phrase ("attackers take control of"),
    so N-able Take Control only matches by its full name;
  - bare `RMM` (from "Datto RMM"), which ACSC uses for the whole category.
  """

  alias Breakline.Catalog

  # names left after stripping the vendor that are too generic to match on
  @too_generic ["take control", "rmm"]

  @cve ~r/\bCVE[\s\-\x{2010}\x{2011}\x{2013}]+(\d{4})[\s\-\x{2010}\x{2011}\x{2013}]+(\d{4,7})\b/iu

  @doc """
  The distinct CVE ids in a text, normalised and sorted.

      iex> Cloud.Advisories.TextMatch.cves("fix CVE 2026 63077 and cve-2025-8875, CVE-2026 18556")
      ["CVE-2025-8875", "CVE-2026-18556", "CVE-2026-63077"]
  """
  @spec cves(String.t()) :: [String.t()]
  def cves(text) when is_binary(text) do
    @cve
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [year, number] -> "CVE-#{year}-#{number}" end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The names each catalog tool is matched by, as `[{tool_id, [name]}]`.
  """
  @spec names() :: [{String.t(), [String.t()]}]
  def names do
    for tool <- Catalog.tools() do
      {tool.id, tool_names(tool)}
    end
  end

  defp tool_names(tool) do
    stripped =
      case String.split(tool.name, tool.vendor <> " ", parts: 2) do
        ["", rest] -> rest
        _ -> nil
      end

    [
      tool.name,
      stripped && String.downcase(stripped) not in @too_generic && stripped,
      tool.vendor == tool.name && tool.vendor
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  The ids of the catalog tools a text names, sorted.

      iex> Cloud.Advisories.TextMatch.tool_ids("Active exploitation of N-able and N-central vulnerabilities")
      ["n_central"]
      iex> Cloud.Advisories.TextMatch.tool_ids("attackers take control of the RMM server")
      []
  """
  @spec tool_ids(String.t()) :: [String.t()]
  def tool_ids(text) when is_binary(text) do
    for {id, names} <- names(), Regex.match?(pattern(names), text), do: id
  end

  defp pattern(names) do
    alternatives = Enum.map_join(names, "|", &Regex.escape/1)
    Regex.compile!("(?<![\\p{L}\\p{N}])(?:#{alternatives})(?![\\p{L}\\p{N}])", "iu")
  end

  @not_known ~r/\b(?:not (?:currently |yet )?aware of (?:any )?(?:active )?exploitation|no (?:known |evidence of |reports? of )?active exploitation|not (?:known to be |been )?(?:actively )?exploited)\b/iu
  @active ~r/\b(?:active(?:ly)? exploit(?:ation|ed)|under exploitation|being exploited)\b/iu

  @doc """
  The exploitation signal of an ACSC item: `:not_known` when the text says
  there is no known active exploitation, `:active` when the title starts with
  "Active exploitation of" or the text says the issue is actively exploited,
  otherwise `:unknown`.
  """
  @spec exploitation(String.t(), String.t()) :: :active | :not_known | :unknown
  def exploitation(title, text) do
    cond do
      Regex.match?(@not_known, title <> " " <> text) -> :not_known
      String.starts_with?(String.downcase(title), "active exploitation of") -> :active
      Regex.match?(@active, title <> " " <> text) -> :active
      true -> :unknown
    end
  end
end
