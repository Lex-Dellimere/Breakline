defmodule CloudWeb.GatewayPresence do
  @moduledoc """
  Tracks which sites have a gateway joined to `CloudWeb.GatewayChannel`. Each
  joined channel tracks itself on `topic/1` of its site, keyed by the site id,
  and is untracked when its process exits, whether it left cleanly or not.

  The UI subscribes to `topic/1` and gets a `%Phoenix.Socket.Broadcast{event:
  "presence_diff"}` whenever a gateway joins or goes away.
  """

  use Phoenix.Presence, otp_app: :cloud, pubsub_server: Cloud.PubSub

  @doc "The presence topic of a site."
  @spec topic(String.t()) :: String.t()
  def topic(site_id), do: "gateway_presence:" <> site_id

  @doc "Whether a gateway is joined for the site right now."
  @spec connected?(String.t()) :: boolean()
  def connected?(site_id), do: site_id |> topic() |> list() |> map_size() > 0
end
