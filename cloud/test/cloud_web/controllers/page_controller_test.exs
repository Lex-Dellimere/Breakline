defmodule CloudWeb.PageControllerTest do
  use CloudWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Remote access stays closed until you open it."
  end

  describe "landing page background" do
    test "renders one decorative, hidden canvas behind the hero", %{conn: conn} do
      doc = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

      canvas = LazyHTML.query(doc, "#hero > canvas#landing-crawl")
      assert Enum.count(canvas) == 1
      assert LazyHTML.attribute(canvas, "aria-hidden") == ["true"]
      assert LazyHTML.attribute(canvas, "data-crawl") == ["hero"]
      assert [class] = LazyHTML.attribute(canvas, "class")
      assert class =~ "pointer-events-none"

      # the canvas is the only element the animation module looks for
      assert Enum.count(LazyHTML.query(doc, "[data-crawl]")) == 1
      # it is purely decorative: no text, no children
      assert LazyHTML.text(canvas) |> String.trim() == ""
    end

    test "the rest of the hero still uses mishka components", %{conn: conn} do
      doc = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
      copy = LazyHTML.query(doc, "#hero-copy")

      assert Enum.count(copy) == 1
      assert LazyHTML.text(LazyHTML.query(copy, "h1")) =~ "Remote access stays closed"
      # mishka button_link renders anchors with its default button classes
      links = LazyHTML.query(copy, "a[href='/register'], a[href='/sign-in']")
      assert Enum.count(links) == 2

      for class <- LazyHTML.attribute(links, "class") do
        assert class =~ "phx-submit-loading:opacity-75 cursor-pointer"
      end

      # the feature cards are mishka cards (role=region wrappers)
      assert Enum.count(LazyHTML.query(doc, "section.grid > div[role=region]")) == 3
    end

    test "other pages do not render it", %{conn: conn} do
      html = conn |> get(~p"/sign-in") |> html_response(200)
      doc = LazyHTML.from_document(html)
      assert Enum.empty?(LazyHTML.query(doc, "[data-crawl]"))
    end
  end
end
