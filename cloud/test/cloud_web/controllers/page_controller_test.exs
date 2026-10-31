defmodule CloudWeb.PageControllerTest do
  use CloudWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Remote access stays closed until you open it."
  end
end
