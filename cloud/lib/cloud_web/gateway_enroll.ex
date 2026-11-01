defmodule CloudWeb.GatewayEnroll do
  @moduledoc """
  `POST /gateway/enroll` on `CloudWeb.GatewayEndpoint`: a gateway box trades
  a one-time enrolment code for its site's settings, and the certificate it
  presented in this TLS session becomes the site's pinned gateway identity
  (`Cloud.Sites.GatewayEnrollments`).

  The request is json, at most 4 KB: `{"code": "ABCD-EFGH-..."}`. Anything
  else in the body is ignored; in particular a fingerprint sent in the body is
  never used. The fingerprint is always that of the client certificate of the
  TLS session (`Plug.Conn.get_peer_data/1`), which the TLS handshake proved
  the box holds the key for.

  Answers, all json:

    * 200 with `Cloud.Sites.GatewayEnrollments.answer/1`
    * 400 `{"error": "bad_request"}` for a body that is not such json
    * 403 `{"error": "invalid_code"}` for an unknown, malformed, used,
      cancelled or expired code (one answer for all of them)
    * 409 `{"error": "certificate_in_use"}` when another site pins the
      certificate
    * 429 `{"error": "rate_limited"}` past 20 attempts per client ip in 10
      minutes (`config :cloud, CloudWeb.GatewayEnroll, rate_limit: {20,
      600_000}`)

  After a successful enrolment the site's previously connected gateway, if
  any, is disconnected; it can no longer reconnect because its certificate
  is no longer pinned.

  A plug route rather than a socket topic, so `CloudWeb.GatewaySocket` keeps
  refusing every certificate no site pins: an unpinned box gets one request
  and one answer here, never an open websocket.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Cloud.Sites.GatewayEnrollments

  @max_body 4096
  @default_limit {20, :timer.minutes(10)}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["gateway", "enroll"]} = conn, _opts) do
    conn |> enroll() |> halt()
  end

  def call(conn, _opts), do: conn

  defp enroll(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    {limit, window_ms} =
      Application.get_env(:cloud, __MODULE__, [])[:rate_limit] || @default_limit

    with :ok <- CloudWeb.RateLimit.hit({:gateway_enroll, ip}, limit, window_ms),
         {:ok, der} <- peer_cert(conn),
         {:ok, code, conn} <- read_code(conn),
         {:ok, %{site: site, replaced_fingerprint: replaced}} <-
           GatewayEnrollments.enroll(code, der, ip) do
      if replaced && replaced != site.gateway_cert_fingerprint do
        CloudWeb.GatewayEndpoint.broadcast("gateway_socket:" <> site.id, "disconnect", %{})
      end

      Logger.info("gateway enrolled for site #{site.id} from #{ip}")
      json(conn, 200, GatewayEnrollments.answer(site))
    else
      {:error, :rate_limited} ->
        Logger.warning("gateway enrolment rate limited for #{ip}")
        json(conn, 429, %{"error" => "rate_limited"})

      {:error, :no_certificate} ->
        json(conn, 400, %{"error" => "no_certificate"})

      {:error, :bad_request, conn} ->
        json(conn, 400, %{"error" => "bad_request"})

      {:error, :certificate_in_use} ->
        Logger.warning("gateway enrolment from #{ip} refused: certificate pinned elsewhere")
        json(conn, 409, %{"error" => "certificate_in_use"})

      {:error, reason} ->
        Logger.warning("gateway enrolment from #{ip} refused: #{inspect(reason)}")
        json(conn, 403, %{"error" => "invalid_code"})
    end
  end

  defp peer_cert(conn) do
    case get_peer_data(conn) do
      %{ssl_cert: der} when is_binary(der) -> {:ok, der}
      _ -> {:error, :no_certificate}
    end
  end

  defp read_code(conn) do
    case read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        case JSON.decode(body) do
          {:ok, %{"code" => code}} when is_binary(code) and byte_size(code) <= 200 ->
            {:ok, code, conn}

          _ ->
            {:error, :bad_request, conn}
        end

      {:more, _partial, conn} ->
        {:error, :bad_request, conn}

      {:error, _reason} ->
        {:error, :bad_request, conn}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(body))
  end
end
