defmodule CloudWeb.AuditExportPDFWebTest do
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

  defp put_env(key, value) do
    previous = Application.get_env(:cloud, key)
    Application.put_env(:cloud, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:cloud, key, previous),
        else: Application.delete_env(:cloud, key)
    end)
  end

  defp pdf_path(tenant_id),
    do: ~p"/audit/export.pdf?#{[tenant: tenant_id, from: "2026-10-01", to: "2026-12-31"]}"

  @tag :typst
  test "downloads the export as a pdf attachment and records it with format pdf", ctx do
    cloud_entry!(ctx.site, "test.one", actor: ctx.admin)
    gateway_chain!(ctx.site, [days_ago(1), DateTime.utc_now()])

    conn = ctx.conn |> log_in_user(ctx.approver) |> get(pdf_path(ctx.tenant.id))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/pdf"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="breakline-audit-#{ctx.tenant.slug}-2026-10-01-2026-12-31.pdf")
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert "%PDF-" <> _ = conn.resp_body

    assert [entry] = exported_entries(ctx.tenant.id)
    assert entry.actor_id == ctx.approver.id
    assert entry.entry["format"] == "pdf"
    assert entry.entry["from"] == "2026-10-01T00:00:00Z"
    assert entry.entry["site_ids"] == [ctx.site.id]
  end

  test "refuses anyone who is not an admin or approver of the tenant", ctx do
    foreign = org!()

    conn = ctx.conn |> log_in_user(foreign.admin) |> get(pdf_path(ctx.tenant.id))
    assert conn.status == 403
    refute conn.resp_body =~ ctx.tenant.name

    conn = build_conn() |> log_in_user(user!()) |> get(~p"/audit/export.pdf")
    assert conn.status == 403

    assert exported_entries(ctx.tenant.id) == []
  end

  @tag :capture_log
  test "a missing renderer is a 503 and records nothing", ctx do
    put_env(:typst_path, "/nonexistent/typst")

    conn = ctx.conn |> log_in_user(ctx.admin) |> get(pdf_path(ctx.tenant.id))

    assert conn.status == 503
    assert conn.resp_body =~ "PDF renderer is not installed"
    assert exported_entries(ctx.tenant.id) == []
  end

  test "too many records is a 422 asking for a shorter period, and /audit says so", ctx do
    for i <- 1..3, do: cloud_entry!(ctx.site, "test.#{i}")
    put_env(:audit_pdf_max_records, 2)

    conn = ctx.conn |> log_in_user(ctx.admin) |> get(pdf_path(ctx.tenant.id))

    assert conn.status == 422
    assert conn.resp_body =~ "Pick a shorter period"
    assert exported_entries(ctx.tenant.id) == []

    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.admin), ~p"/audit")
    assert has_element?(view, "#download-pdf[disabled]")
    assert has_element?(view, "#pdf-too-large", "more than the 2 one PDF can hold")
  end
end
