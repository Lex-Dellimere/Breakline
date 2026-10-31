defmodule Cloud.Sites.Validations.SiteHosts do
  @moduledoc """
  Validates `site_hosts`: each entry is a hostname, an ip address or a CIDR,
  the same classification `Gateway.Enforcer.split_site_hosts/1` makes.

  Hostnames are lowercase dns names (labels of letters, digits and hyphens).
  CIDRs need a prefix of at least /8 for ipv4 and /16 for ipv6, so a typo
  cannot make a locked site drop most of the internet.
  """

  use Ash.Resource.Validation

  @hostname ~r/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/

  @impl true
  def validate(changeset, _opts, _context) do
    hosts = Ash.Changeset.get_attribute(changeset, :site_hosts) || []

    case Enum.reject(hosts, &valid?/1) do
      [] -> :ok
      bad -> {:error, field: :site_hosts, message: "invalid hosts: #{Enum.join(bad, ", ")}"}
    end
  end

  @doc "Whether `host` is a valid hostname, ip address or CIDR."
  @spec valid?(String.t()) :: boolean()
  def valid?(host) when is_binary(host) do
    case String.split(host, "/") do
      [addr] -> ip?(addr) or Regex.match?(@hostname, addr)
      [addr, len] -> cidr?(addr, len)
      _ -> false
    end
  end

  def valid?(_), do: false

  defp cidr?(addr, len) do
    with {:ok, ip} <- parse_ip(addr),
         {n, ""} <- Integer.parse(len) do
      case tuple_size(ip) do
        4 -> n >= 8 and n <= 32
        8 -> n >= 16 and n <= 128
      end
    else
      _ -> false
    end
  end

  defp ip?(s), do: match?({:ok, _}, parse_ip(s))
  defp parse_ip(s), do: :inet.parse_strict_address(String.to_charlist(s))
end
