defmodule Breakline.Catalog do
  @moduledoc """
  The catalog of RMM and remote-access tools Breakline can gate.

  The catalog is curated in `priv/catalog/tools.json` and loaded at compile
  time, so lookups never touch the filesystem. Its domains are seeded from the
  LOLRMM project (Apache-2.0, see `priv/catalog/NOTICE`), whose records are
  vendored in `priv/catalog/lolrmm_snapshot.json`, and topped up from vendor
  documentation where LOLRMM coverage is thin.

  Tool ids are strings shared with the cloud and the gateway: `"n_central"`,
  `"take_control"`, `"screenconnect"`, `"ninjaone"`, `"datto_rmm"`,
  `"anydesk"`, `"teamviewer"` and `"splashtop"`.

  Self-hosted RMM servers are not in the catalog. They are configured per site
  as hosts or addresses.
  """

  alias Breakline.Catalog.{DomainPattern, Loader, Tool}

  @tools_path Path.join([__DIR__, "..", "..", "priv", "catalog", "tools.json"]) |> Path.expand()
  @external_resource @tools_path

  @tools @tools_path |> File.read!() |> Loader.parse!()

  @by_id Map.new(@tools, &{&1.id, &1})
  @ids Enum.map(@tools, & &1.id)

  @typedoc "A catalog tool id such as `\"anydesk\"`."
  @type tool_id :: String.t()

  @typedoc "A CISA KEV vulnerability record as decoded from the feed, with string keys."
  @type kev_vuln :: %{optional(String.t()) => term()}

  @doc "Returns every tool in the catalog, ordered by id."
  @spec tools() :: [Tool.t()]
  def tools, do: @tools

  @doc "Returns every tool id in the catalog, in sorted order."
  @spec ids() :: [tool_id()]
  def ids, do: @ids

  @doc """
  Looks up a tool by id.

      iex> {:ok, tool} = Breakline.Catalog.get("anydesk")
      iex> tool.name
      "AnyDesk"
      iex> Breakline.Catalog.get("nope")
      :error
  """
  @spec get(tool_id()) :: {:ok, Tool.t()} | :error
  def get(id), do: Map.fetch(@by_id, id)

  @doc """
  Returns the first of `tool_ids` whose domains match the query name, or
  `:nomatch`. Unknown ids are ignored. Matching ignores case and one trailing
  dot, as described in `Breakline.Catalog.DomainPattern`.

      iex> Breakline.Catalog.match_domain("relay-1a2b.net.anydesk.com.")
      {:ok, "anydesk"}
      iex> Breakline.Catalog.match_domain("relay-1a2b.net.anydesk.com", ["teamviewer"])
      :nomatch
  """
  @spec match_domain(String.t(), [tool_id()]) :: {:ok, tool_id()} | :nomatch
  def match_domain(qname, tool_ids \\ @ids) when is_binary(qname) do
    tool_ids
    |> Enum.find_value(:nomatch, fn id ->
      with {:ok, tool} <- get(id),
           true <- Enum.any?(tool.domains, &DomainPattern.match?(&1.compiled, qname)) do
        {:ok, id}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Returns the ids of the tools a CISA KEV record applies to, in sorted order.

  `vendorProject` and `product` are normalised by trimming, collapsing inner
  whitespace and downcasing, because the feed is inconsistent (N-able appears
  as both `N-Central` and `N-central`). A tool matches when one of its KEV keys
  names the vendor and either the same product or `"*"`. A remote-control tool that
  another console launches carries that console's key too, so an N-central record
  also closes Take Control (D47).

      iex> Breakline.Catalog.kev_match(%{"vendorProject" => "N-able ", "product" => "N-Central"})
      ["n_central", "take_control"]
  """
  @spec kev_match(kev_vuln()) :: [tool_id()]
  def kev_match(%{"vendorProject" => vendor, "product" => product})
      when is_binary(vendor) and is_binary(product) do
    vendor = Loader.normalise(vendor)
    product = Loader.normalise(product)

    for tool <- @tools,
        Enum.any?(tool.kev_keys, &(&1.vendor == vendor and &1.product in [product, "*"])),
        do: tool.id
  end

  def kev_match(_vuln), do: []

  @doc """
  Returns the distinct ports of the given tools, sorted by port and protocol.
  Unknown ids are ignored.
  """
  @spec ports([tool_id()]) :: [%{port: 1..65_535, proto: :tcp | :udp}]
  def ports(tool_ids) do
    tool_ids
    |> known_tools()
    |> Enum.flat_map(& &1.ports)
    |> Enum.map(&Map.take(&1, [:port, :proto]))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.port, &1.proto})
  end

  @doc """
  Returns the distinct ports of the given tools that only RMM tools use (scope
  `:any`), sorted by port and protocol. The gateway drops these towards any
  destination while locked. Unknown ids are ignored.

      iex> Breakline.Catalog.exclusive_ports(["anydesk", "n_central"])
      [%{port: 6568, proto: :tcp}, %{port: 7070, proto: :tcp}]
  """
  @spec exclusive_ports([tool_id()]) :: [%{port: 1..65_535, proto: :tcp | :udp}]
  def exclusive_ports(tool_ids) do
    tool_ids
    |> known_tools()
    |> Enum.flat_map(& &1.ports)
    |> Enum.filter(&(&1.scope == :any))
    |> Enum.map(&Map.take(&1, [:port, :proto]))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.port, &1.proto})
  end

  @doc """
  Returns the distinct CIDRs of the given tools, sorted. Unknown ids are
  ignored.
  """
  @spec cidrs([tool_id()]) :: [String.t()]
  def cidrs(tool_ids) do
    tool_ids
    |> known_tools()
    |> Enum.flat_map(& &1.cidrs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp known_tools(tool_ids) do
    for id <- tool_ids, {:ok, tool} <- [get(id)], do: tool
  end
end
