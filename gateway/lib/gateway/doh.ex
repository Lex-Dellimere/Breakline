defmodule Gateway.DoH do
  @moduledoc """
  Known public DNS-over-HTTPS and DNS-over-TLS resolvers, plus the canary names
  that tell clients to fall back to network DNS.

  The list lives in `priv/doh/resolvers.json` and is read at compile time. Every
  entry names the provider page it was checked against. Hostnames are refused
  by the gateway resolver with NXDOMAIN whatever the lock state, so a browser
  cannot bootstrap its own DoH session and slip past `Gateway.DNS`. The ip
  addresses are for the firewall, which drops them on 443 and 853.

  A hostname starting with `*.` matches any name below that suffix but never
  the bare suffix, the same rule as `Breakline.Catalog`.
  """

  @path Path.expand("../../priv/doh/resolvers.json", __DIR__)
  @external_resource @path

  @data @path |> File.read!() |> JSON.decode!()

  @providers @data["providers"]
  @hostnames @providers |> Enum.flat_map(& &1["hostnames"]) |> Enum.map(&String.downcase/1)
  @ips @providers |> Enum.flat_map(&(&1["ipv4"] ++ &1["ipv6"]))
  @canaries @data["canaries"] |> Enum.map(&String.downcase(&1["name"]))

  @exact @hostnames |> Enum.reject(&String.starts_with?(&1, "*.")) |> MapSet.new()
  @suffixes @hostnames
            |> Enum.filter(&String.starts_with?(&1, "*."))
            |> Enum.map(&String.trim_leading(&1, "*"))
  @canary_set MapSet.new(@canaries)

  for ip <- @ips do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, _} -> :ok
      {:error, _} -> raise "invalid ip #{inspect(ip)} in #{@path}"
    end
  end

  @typedoc "Why a name is refused: a DoH/DoT hostname or a canary name."
  @type match :: {:doh, String.t()} | {:canary, String.t()}

  @doc "Returns the provider entries as decoded from the json file."
  @spec providers() :: [map()]
  def providers, do: @providers

  @doc "Returns every DoH/DoT hostname, lowercased, including `*.` patterns."
  @spec hostnames() :: [String.t()]
  def hostnames, do: @hostnames

  @doc "Returns every documented resolver ip address as a string, v4 and v6."
  @spec ips() :: [String.t()]
  def ips, do: @ips

  @doc "Returns the canary names that must always answer NXDOMAIN."
  @spec canaries() :: [String.t()]
  def canaries, do: @canaries

  @doc """
  Checks a normalised query name (lowercase, no trailing dot) against the
  hostnames and canaries.

      iex> Gateway.DoH.match("dns.google")
      {:doh, "dns.google"}
      iex> Gateway.DoH.match("mask.icloud.com")
      {:canary, "mask.icloud.com"}
      iex> Gateway.DoH.match("example.com")
      :nomatch
  """
  @spec match(String.t()) :: match() | :nomatch
  def match(name) when is_binary(name) do
    cond do
      MapSet.member?(@canary_set, name) -> {:canary, name}
      MapSet.member?(@exact, name) -> {:doh, name}
      Enum.any?(@suffixes, &suffix_match?(name, &1)) -> {:doh, name}
      true -> :nomatch
    end
  end

  # the suffix keeps its leading dot, so "x.dns.nextdns.io" matches ".dns.nextdns.io"
  # and the bare "dns.nextdns.io" does not
  defp suffix_match?(name, suffix) do
    String.ends_with?(name, suffix) and byte_size(name) > byte_size(suffix)
  end
end
