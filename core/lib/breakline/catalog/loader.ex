defmodule Breakline.Catalog.Loader do
  @moduledoc """
  Parses and validates the curated catalog JSON into `Breakline.Catalog.Tool`
  structs.

  `Breakline.Catalog` calls this at compile time, so a malformed
  `tools.json` (an invalid domain pattern, port, protocol or CIDR, or a KEV
  key that is not already normalised, or a port scope other than `"any"` or
  `"tool_ips"`) fails the build instead of reaching a
  gateway.
  """

  alias Breakline.Catalog.{DomainPattern, Tool}

  @doc """
  Decodes catalog JSON and returns its tools sorted by id. Raises on any
  invalid entry.
  """
  @spec parse!(String.t()) :: [Tool.t()]
  def parse!(json) do
    json
    |> JSON.decode!()
    |> Map.fetch!("tools")
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, tool} -> tool!(id, tool) end)
  end

  @doc """
  Normalises a KEV vendor or product name: trims it, collapses inner
  whitespace to single spaces and downcases it.

      iex> Breakline.Catalog.Loader.normalise("  N-able   N-Central ")
      "n-able n-central"
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(value) do
    value |> String.split() |> Enum.join(" ") |> String.downcase()
  end

  defp tool!(id, t) do
    %Tool{
      id: id,
      name: Map.fetch!(t, "name"),
      vendor: Map.fetch!(t, "vendor"),
      domains: Enum.map(Map.fetch!(t, "domains"), &domain!/1),
      ports: Enum.map(Map.fetch!(t, "ports"), &port!(id, &1)),
      cidrs: Enum.map(Map.fetch!(t, "cidrs"), &cidr!/1),
      kev_keys: Enum.map(Map.fetch!(t, "kev_keys"), &kev_key!/1),
      excluded: Enum.map(Map.fetch!(t, "excluded"), &excluded!/1)
    }
  end

  defp domain!(d) do
    pattern = Map.fetch!(d, "pattern")

    %{
      pattern: pattern,
      source: Map.fetch!(d, "source"),
      compiled: DomainPattern.compile!(pattern)
    }
  end

  defp port!(id, p) do
    port = Map.fetch!(p, "port")

    unless is_integer(port) and port in 1..65_535 do
      raise ArgumentError, "invalid port #{inspect(port)} for #{id}"
    end

    proto =
      case Map.fetch!(p, "proto") do
        "tcp" -> :tcp
        "udp" -> :udp
        other -> raise ArgumentError, "invalid proto #{inspect(other)} for #{id}"
      end

    scope =
      case Map.get(p, "scope") do
        "any" -> :any
        "tool_ips" -> :tool_ips
        other -> raise ArgumentError, "invalid port scope #{inspect(other)} for #{id}"
      end

    %{port: port, proto: proto, scope: scope, source: Map.fetch!(p, "source")}
  end

  defp cidr!(cidr) do
    with [addr, len] <- String.split(cidr, "/"),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(addr)),
         {len, ""} <- Integer.parse(len),
         true <- len >= 0 and len <= if(tuple_size(ip) == 4, do: 32, else: 128) do
      cidr
    else
      _ -> raise ArgumentError, "invalid cidr #{inspect(cidr)}"
    end
  end

  defp kev_key!(k) do
    %{
      vendor: normalised!(Map.fetch!(k, "vendor")),
      product: normalised!(Map.fetch!(k, "product"))
    }
  end

  defp normalised!(value) do
    if normalise(value) == value do
      value
    else
      raise ArgumentError, "kev key #{inspect(value)} is not normalised"
    end
  end

  defp excluded!(e) do
    %{
      pattern: Map.fetch!(e, "pattern"),
      source: Map.fetch!(e, "source"),
      reason: Map.fetch!(e, "reason")
    }
  end
end
