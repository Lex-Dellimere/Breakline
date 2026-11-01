defmodule CloudWeb.PageControllerTest do
  use CloudWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "A lock outside your RMM."
  end

  describe "pilot contact" do
    setup do
      previous = Application.get_env(:cloud, :contact_email)
      on_exit(fn -> Application.put_env(:cloud, :contact_email, previous) end)
    end

    test "without a configured address it says pilots are by invitation", %{conn: conn} do
      Application.delete_env(:cloud, :contact_email)
      doc = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
      contact = LazyHTML.query(doc, "#pilot-contact")

      assert LazyHTML.text(contact) =~ "by invitation"
      assert Enum.empty?(LazyHTML.query(contact, "a"))
    end

    test "with an address it offers a walkthrough by email", %{conn: conn} do
      Application.put_env(:cloud, :contact_email, "pilots@breakline.test")
      doc = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.attribute(LazyHTML.query(doc, "#pilot-contact a"), "href") ==
               ["mailto:pilots@breakline.test"]
    end
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
      assert LazyHTML.text(LazyHTML.query(copy, "h1")) =~ "A lock outside your RMM"
      # mishka button_link renders anchors with its default button classes
      links = LazyHTML.query(copy, "a[href='#pilot'], a[href='/sign-in']")
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
