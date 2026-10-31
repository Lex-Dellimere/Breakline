defmodule CloudWeb.RequestLogTest do
  # changes the global logger level, so it cannot run alongside other tests
  use CloudWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Cloud.Fixtures

  alias Cloud.Sites

  setup do
    %{tenant: tenant, admin: admin} = org!()
    site = site!(tenant, admin)

    contact =
      Sites.create_msp_contact!(%{name: "Sam", email: "sam-#{unique()}@msp.example"},
        actor: admin,
        tenant: tenant
      )

    link =
      Sites.create_request_link!(%{site_id: site.id, msp_contact_id: contact.id},
        actor: admin,
        tenant: tenant
      )

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    %{token: link.__metadata__.token}
  end

  test "a request link's token never reaches the log", %{conn: conn, token: token} do
    conn =
      Plug.Test.put_peer_data(conn, %{address: {10, 9, 9, 9}, port: 4000, ssl_cert: nil})

    log =
      capture_log([level: :debug], fn ->
        {:ok, view, _html} = live(conn, ~p"/request/#{token}")
        assert render(view) =~ "request"
        # a bad token takes the same path
        get(conn, ~p"/request/#{"not-" <> token}")
      end)

    # the request was logged, just without its path
    assert log =~ "Processing with CloudWeb.RequestLive.Show"
    assert log =~ "MOUNT CloudWeb.RequestLive.Show"
    refute log =~ token
    refute log =~ "GET /request"
  end

  test "other requests are still logged", %{conn: conn} do
    log = capture_log([level: :debug], fn -> get(conn, ~p"/sign-in") end)
    assert log =~ "GET /sign-in"
  end
end
