defmodule Breakline.Catalog.Tool do
  @moduledoc """
  One remote-access tool in the catalog.

  `domains` are the names the gateway answers NXDOMAIN for while the tool is
  locked, each with the source it was taken from and its compiled
  `Breakline.Catalog.DomainPattern`. `ports` are the tool's service ports and
  `cidrs` any fixed address ranges. Each port has a `scope`: `:tool_ips` for a
  port shared with ordinary traffic (80, 443, 8443 and so on), which only
  matters towards the tool's own resolved IPs and CIDRs, and `:any` for a port
  only RMM tools use, which the gateway drops towards any destination while
  locked.
  `kev_keys` are the normalised CISA KEV vendor and product names that lock
  the tool, where a product of `"*"` matches any product from that vendor.
  `excluded` records patterns the sources list but the catalog deliberately
  does not block, with the reason.
  """

  alias Breakline.Catalog.DomainPattern

  @enforce_keys [:id, :name, :vendor, :domains, :ports, :cidrs, :kev_keys, :excluded]
  defstruct @enforce_keys

  @type domain :: %{pattern: String.t(), source: String.t(), compiled: DomainPattern.t()}
  @type port_scope :: :any | :tool_ips
  @type port_spec :: %{
          port: 1..65_535,
          proto: :tcp | :udp,
          scope: port_scope(),
          source: String.t()
        }
  @type kev_key :: %{vendor: String.t(), product: String.t()}
  @type excluded :: %{pattern: String.t(), source: String.t(), reason: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          vendor: String.t(),
          domains: [domain()],
          ports: [port_spec()],
          cidrs: [String.t()],
          kev_keys: [kev_key()],
          excluded: [excluded()]
        }
end
