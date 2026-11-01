defmodule CloudWeb.GatewaySocket do
  @moduledoc """
  The socket a site gateway connects to, through `CloudWeb.GatewayEndpoint`.

  A gateway authenticates with its TLS client certificate only: the TLS layer
  has already checked that the client holds the key of its (self-signed)
  certificate, and `connect/3` takes the certificate DER from `connect_info.peer_data.ssl_cert`,
  fingerprints it (sha256, lowercase hex) and looks up the site that pinned
  that fingerprint (`Cloud.Sites.Site` `:by_gateway_fingerprint`, a trusted
  read). No certificate, or a certificate no site has pinned, refuses the
  connection; an unpinned certificate can only enrol
  (`CloudWeb.GatewayEnroll`). Socket params are ignored, so nothing the gateway sends can
  choose its site or tenant.

  The socket's id is `"gateway_socket:<site_id>"`, so a site's gateway can be
  disconnected with `CloudWeb.GatewayEndpoint.broadcast(id, "disconnect", %{})`.
  """

  use Phoenix.Socket

  require Logger

  channel "gateway:*", CloudWeb.GatewayChannel

  @impl true
  def connect(_params, socket, connect_info) do
    with %{ssl_cert: der} when is_binary(der) <- connect_info[:peer_data],
         fingerprint = Cloud.Gateways.cert_fingerprint(der),
         {:ok, site} <- site_for(fingerprint) do
      {:ok, assign(socket, site_id: site.id, tenant_id: site.tenant_id)}
    else
      %{} ->
        Logger.warning("gateway socket refused: no client certificate")
        :error

      nil ->
        Logger.warning("gateway socket refused: no peer data")
        :error

      {:error, fingerprint} ->
        Logger.warning("gateway socket refused: no site pins certificate #{fingerprint}")
        :error
    end
  end

  @impl true
  def id(socket), do: "gateway_socket:" <> socket.assigns.site_id

  defp site_for(fingerprint) do
    case Cloud.Sites.get_site_by_gateway_fingerprint(fingerprint,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %Cloud.Sites.Site{} = site} -> {:ok, site}
      _ -> {:error, fingerprint}
    end
  end
end
