defmodule CloudWeb.PageController do
  use CloudWeb, :controller

  # the landing page shows a contact address for pilots only once one is configured
  # (`config :cloud, :contact_email`, prod: CONTACT_EMAIL)
  def home(conn, _params) do
    render(conn, :home, contact_email: Application.get_env(:cloud, :contact_email))
  end
end
