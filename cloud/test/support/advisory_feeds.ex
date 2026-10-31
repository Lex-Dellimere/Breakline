defmodule Cloud.AdvisoryFeeds do
  @moduledoc """
  Test helpers for the threat feeds: fixture documents from
  `test/fixtures/advisories/` and a `Req.Test` stub that serves them.

  `serve/1` takes a map of feed name to response: a body (served with an
  etag), `:not_modified` (304) or `{:status, code}`. Feeds left out answer
  404. Each request is sent to the test process as
  `{:feed_request, feed, headers}`.
  """

  @dir Path.expand("../fixtures/advisories", __DIR__)

  @paths %{
    "/sites/default/files/feeds/known_exploited_vulnerabilities.json" => :kev,
    "/rss/alerts" => :acsc_alerts,
    "/rss/advisories" => :acsc_advisories
  }

  @doc "A fixture file's contents."
  def fixture(name), do: File.read!(Path.join(@dir, name))

  @doc "The KEV fixture decoded."
  def kev_doc, do: Jason.decode!(fixture("kev.json"))

  @doc """
  The KEV fixture as json, without the entries whose cveID is in `drop`,
  plus `add` (a list of extra vulnerability maps, put first like new
  entries).
  """
  def kev_json(opts \\ []) do
    drop = Keyword.get(opts, :drop, [])
    add = Keyword.get(opts, :add, [])
    doc = kev_doc()
    vulns = add ++ Enum.reject(doc["vulnerabilities"], &(&1["cveID"] in drop))
    Jason.encode!(%{doc | "vulnerabilities" => vulns, "count" => length(vulns)})
  end

  @doc "A KEV vulnerability map like the feed's, for the given fields."
  def kev_vuln(cve, vendor, product, name \\ nil) do
    %{
      "cveID" => cve,
      "vendorProject" => vendor,
      "product" => product,
      "vulnerabilityName" => name || "#{vendor} #{product} vulnerability",
      "dateAdded" => "2026-10-31",
      "shortDescription" => "test entry",
      "requiredAction" => "Apply mitigations per vendor instructions.",
      "dueDate" => "2026-11-21",
      "knownRansomwareCampaignUse" => "Unknown",
      "notes" => "",
      "cwes" => []
    }
  end

  @doc "An ACSC RSS document with the given items (`%{title:, link:, description:, pub_date:}`)."
  def rss(items) do
    body =
      Enum.map_join(items, "\n", fn item ->
        """
        <item>
          <title>#{escape(item.title)}</title>
          <link>#{item.link}</link>
          <description>#{escape(item[:description] || "")}</description>
          <pubDate>#{item[:pub_date] || "Sat, 31 Oct 2026 09:00:00 +1100"}</pubDate>
          <dc:creator>Australian Cyber Security Centre (ACSC)</dc:creator>
          <guid isPermaLink="true">#{item.link}</guid>
        </item>
        """
      end)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
      <channel>
        <title>ASD's ACSC - Alerts RSS</title>
        <link>https://www.cyber.gov.au/</link>
        #{body}
      </channel>
    </rss>
    """
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "Stubs the feed urls, see the moduledoc."
  def serve(responses) do
    test = self()

    Req.Test.stub(Cloud.Advisories.HTTP, fn conn ->
      feed = Map.get(@paths, conn.request_path)
      send(test, {:feed_request, feed, conn.req_headers})

      case Map.get(responses, feed) do
        nil ->
          Plug.Conn.send_resp(conn, 404, "not found")

        :not_modified ->
          Plug.Conn.send_resp(conn, 304, "")

        {:status, status} ->
          Plug.Conn.send_resp(conn, status, "error")

        body when is_binary(body) ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s("#{feed}-#{:erlang.phash2(body)}"))
          |> Plug.Conn.put_resp_header("last-modified", "Fri, 30 Oct 2026 17:02:45 GMT")
          |> Plug.Conn.send_resp(200, body)
      end
    end)
  end
end
