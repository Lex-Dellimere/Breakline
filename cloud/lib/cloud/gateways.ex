defmodule Cloud.Gateways do
  @moduledoc """
  What site gateways report back: events and copies of their audit chain.
  Both are tenant-scoped; writes come only from the gateway channel.

  `cert_fingerprint/1` is how a gateway's client certificate is pinned to its
  site, and `ui_topic/1` is the PubSub topic the gateway channel reports live
  changes on for the UI.
  """

  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Cloud.Gateways.Event do
      define :create_event, action: :create
      define :list_events, action: :read
    end

    resource Cloud.Gateways.AuditRecord do
      define :create_audit_record, action: :create
      define :list_audit_records, action: :read
    end
  end

  @doc """
  The fingerprint a site pins for its gateway: the sha256 of the client
  certificate DER, lowercase hex.
  """
  @spec cert_fingerprint(binary()) :: String.t()
  def cert_fingerprint(der) when is_binary(der),
    do: :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)

  @doc """
  The PubSub topic on which the gateway channel reports a site's live gateway
  changes: `{:gateway_heartbeat, site_id, status, seen_at}`,
  `{:gateway_events, site_id, [event]}` (newest first). Whether a gateway is
  connected is tracked with `CloudWeb.GatewayPresence`.
  """
  @spec ui_topic(String.t()) :: String.t()
  def ui_topic(site_id), do: "gateway_ui:" <> site_id

  @doc "Broadcasts a message on `ui_topic/1` of a site."
  @spec broadcast_ui(String.t(), term()) :: :ok | {:error, term()}
  def broadcast_ui(site_id, message),
    do: Phoenix.PubSub.broadcast(Cloud.PubSub, ui_topic(site_id), message)
end
