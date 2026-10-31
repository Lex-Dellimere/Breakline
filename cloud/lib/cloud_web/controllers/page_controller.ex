defmodule CloudWeb.PageController do
  use CloudWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
