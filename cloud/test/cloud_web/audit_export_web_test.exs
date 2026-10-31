defmodule CloudWeb.AuditExportWebTest do
  use CloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cloud.Fixtures
  import Cloud.AuditFixtures

  setup %{conn: conn} do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin, %{name: "Parramatta clinic"})
    {site, _der} = gateway!(site)
    Map.merge(org, %{site: site, conn: conn})
  end

  defp exported_entries(tenant_id) do
    Cloud.Audit.audit_chain!(tenant: tenant_id, authorize?: false)
    |> Enum.filter(&(&1.entry["action"] == "audit.exported"))
  end

  # the download link's path and decoded query
  defp download(view) do
    href =
      view
      |> element("#download-json")
      |> render()
      |> then(&Regex.run(~r/href="([^"]+)"/, &1))
      |> List.last()
      |> String.replace("&amp;", "&")

    uri = URI.parse(href)
    %{path: uri.path, query: URI.decode_query(uri.query)}
  end

  describe "GET /audit/export.json" do
    test "downloads the export as a json attachment and records it", ctx do
      cloud_entry!(ctx.site, "test.one", actor: ctx.admin)
      gateway_chain!(ctx.site, [days_ago(1), DateTime.utc_now()])

      conn =
        ctx.conn
        |> log_in_user(ctx.approver)
        |> get(
          ~p"/audit/export.json?#{[tenant: ctx.tenant.id, from: "2026-10-01", to: "2026-12-31"]}"
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="breakline-audit-#{ctx.tenant.slug}-2026-10-01-2026-12-31.json")
             ]

      assert ~s({\n  "format": "breakline-audit-export/1") <> _ = conn.resp_body

      export = JSON.decode!(conn.resp_body)

      assert export["period"] == %{
               "from" => "2026-10-01T00:00:00Z",
               "to" => "2027-01-01T00:00:00Z"
             }

      assert export["exported_by"]["email"] == to_string(ctx.approver.email)
      assert export["verification"]["cloud"]["status"] == "intact"
      assert {:ok, _} = Breakline.AuditExport.verify(export)

      assert [entry] = exported_entries(ctx.tenant.id)
      assert entry.actor_id == ctx.approver.id
      assert entry.entry["from"] == "2026-10-01T00:00:00Z"
    end

    test "site_ids narrows the gateway chains", ctx do
      other = site!(ctx.tenant, ctx.admin, %{name: "Other"})

      conn =
        ctx.conn
        |> log_in_user(ctx.admin)
        |> get(~p"/audit/export.json?#{[tenant: ctx.tenant.id, site_ids: other.id]}")

      export = JSON.decode!(conn.resp_body)
      assert Enum.map(export["gateway_audit"], & &1["site_id"]) == [other.id]
    end

    test "refuses anyone who is not an admin or approver of the tenant", ctx do
      foreign = org!()

      conn =
        ctx.conn
        |> log_in_user(foreign.admin)
        |> get(~p"/audit/export.json?#{[tenant: ctx.tenant.id]}")

      assert conn.status == 403
      refute conn.resp_body =~ ctx.tenant.name
      assert exported_entries(ctx.tenant.id) == []

      conn = build_conn() |> log_in_user(user!()) |> get(~p"/audit/export.json")
      assert conn.status == 403

      conn = build_conn() |> log_in_user(foreign.admin) |> get(~p"/audit/export.json?tenant=nope")
      assert conn.status == 403
    end

    test "a bad period is a 400 and signed out users go to sign in", ctx do
      conn =
        ctx.conn
        |> log_in_user(ctx.admin)
        |> get(~p"/audit/export.json?#{[from: "2026-10-10", to: "2026-10-01"]}")

      assert conn.status == 400

      conn = get(build_conn(), ~p"/audit/export.json?#{[tenant: ctx.tenant.id]}")
      assert redirected_to(conn) == ~p"/sign-in"
    end
  end

  describe "/audit" do
    test "shows each chain's verification, a preview and the download link", ctx do
      cloud_entry!(ctx.site, "test.preview", actor: ctx.admin)
      gateway_chain!(ctx.site, [days_ago(1), DateTime.utc_now()])

      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.approver), ~p"/audit")

      assert has_element?(view, "#verification", "Cloud audit chain: intact")

      assert has_element?(
               view,
               "#verification",
               "Gateway chain of Parramatta clinic: intact, 2 records, head seq 1"
             )

      assert has_element?(view, "#preview-entries", "test.preview")
      assert has_element?(view, "#preview-gateways", "Parramatta clinic 2")

      assert %{path: "/audit/export.json", query: %{"tenant" => tenant_id}} = download(view)
      assert tenant_id == ctx.tenant.id

      assert has_element?(view, "#download-pdf[disabled]")

      # the preview is not an export
      assert exported_entries(ctx.tenant.id) == []
    end

    test "reports a broken chain with its seq", ctx do
      entry = cloud_entry!(ctx.site, "test.one")
      cloud_entry!(ctx.site, "test.two")
      tamper_cloud_entry!(ctx.tenant.id, entry.seq)

      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.admin), ~p"/audit")

      assert has_element?(
               view,
               "#verification",
               "Cloud audit chain: broken at seq #{entry.seq}: a record does not match its hash"
             )
    end

    test "the period and sites go into the url and the download", ctx do
      other = site!(ctx.tenant, ctx.admin, %{name: "Other"})
      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.admin), ~p"/audit?preset=custom")

      view
      |> form("#audit-form", audit: %{preset: "custom", from: "2026-10-01", to: "2026-10-31"})
      |> render_change(%{"audit" => %{"site_ids" => ["", other.id]}})

      assert_patch(
        view,
        ~p"/audit?#{[tenant: ctx.tenant.id, preset: "custom", from: "2026-10-01", to: "2026-10-31", site_ids: other.id]}"
      )

      %{query: query} = download(view)
      assert query["from"] == "2026-10-01T00:00:00Z"
      assert query["to"] == "2026-11-01T00:00:00Z"
      assert query["site_ids"] == other.id

      assert has_element?(
               view,
               "#verification",
               "Gateway chain of Other: no audit chain anchored yet"
             )

      refute has_element?(view, "#verification", "Parramatta clinic")

      {:ok, view, _html} =
        live(
          log_in_user(build_conn(), ctx.admin),
          ~p"/audit?preset=custom&from=2026-10-10&to=2026-10-01"
        )

      assert has_element?(view, "#period-error")
    end

    test "a user with no tenant is sent away" do
      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(log_in_user(build_conn(), user!()), ~p"/audit")
    end

    test "the tenant picker shows only the user's tenants", ctx do
      second = org!()
      member!(ctx.admin, second.tenant, :approver)
      foreign = org!()

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.admin), ~p"/audit?tenant=#{foreign.tenant.id}")

      assert has_element?(view, "#tenant-#{ctx.tenant.id}")
      assert has_element?(view, "#tenant-#{second.tenant.id}")
      refute has_element?(view, "#tenant-#{foreign.tenant.id}")
      refute render(view) =~ foreign.tenant.name
    end
  end
end
