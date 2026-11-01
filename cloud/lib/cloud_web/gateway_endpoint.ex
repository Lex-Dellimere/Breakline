defmodule CloudWeb.GatewayEndpoint do
  @moduledoc """
  The endpoint gateways dial: https only, with mutual TLS, serving nothing but
  `CloudWeb.GatewaySocket` at `/gateway/socket` and the one-time enrolment
  request `POST /gateway/enroll` (`CloudWeb.GatewayEnroll`). There is no
  router, no session, no static files and no browser traffic, so the browser
  endpoint's attack surface is never reachable through the gateway port and
  the other way round.

  The listener is configured in `config/` (`https:` with Bandit's TLS options
  in `thousand_island_options: [transport_options: ...]`, see
  `CloudWeb.GatewayTLS`): `verify: :verify_peer` and `fail_if_no_peer_cert:
  true`, so a client without a certificate never completes the handshake.
  Gateway certificates are self-signed; the handshake proves the client holds
  the key, and the site pin decides what it may do. Bandit puts the client
  certificate's DER into `Plug.Conn.get_peer_data/1` as `:ssl_cert`, which
  Phoenix hands to the socket as `connect_info.peer_data`. An unpinned
  certificate can only enrol.

  Dev listens on `127.0.0.1:4011` with the certificates from `mix
  cloud.dev.pki`; prod reads the port and pem paths from the environment (see
  `config/runtime.exs`).
  """

  use Phoenix.Endpoint, otp_app: :cloud

  socket "/gateway/socket", CloudWeb.GatewaySocket,
    websocket: [connect_info: [:peer_data]],
    longpoll: false

  plug CloudWeb.GatewayEnroll
  plug :not_found

  @doc false
  def not_found(conn, _opts) do
    conn
    |> Plug.Conn.send_resp(404, "not found")
    |> Plug.Conn.halt()
  end
end
