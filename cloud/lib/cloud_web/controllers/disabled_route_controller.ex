defmodule CloudWeb.DisabledRouteController do
  @moduledoc """
  Answers 404 for authentication strategy routes the cloud does not serve
  (see the router).
  """

  use CloudWeb, :controller

  def not_found(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not found")
  end
end
