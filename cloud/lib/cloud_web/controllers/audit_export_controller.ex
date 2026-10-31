defmodule CloudWeb.AuditExportController do
  @moduledoc """
  `GET /audit/export.json?tenant=&from=&to=&site_ids=`: downloads a tenant's
  audit export (`Cloud.AuditExport`) as a json attachment, for the tenant's
  admins and approvers. The export is recorded in the tenant's cloud audit
  chain.

  `GET /audit/export.pdf` takes the same params and access rules and
  downloads the same export rendered as a PDF report
  (`Cloud.AuditExport.PDF`), recorded with format `"pdf"` once the PDF
  exists. A period with more records than one PDF holds gets a 422 asking
  for a shorter period; a render that fails or times out gets a 503.

  `tenant` defaults to the first of the user's tenants by name; the period
  and sites are read by `CloudWeb.AuditParams`. A signed-out user is sent to
  sign in, anyone who is not an admin or approver of the tenant gets a 403
  and a bad period a 400.
  """

  use CloudWeb, :controller

  require Logger

  alias Cloud.AuditExport
  alias Cloud.AuditExport.PDF
  alias CloudWeb.AuditParams

  def show(conn, params), do: with_user(conn, params, &json/3)

  def pdf(conn, params), do: with_user(conn, params, &pdf/3)

  defp with_user(conn, params, fun) do
    case conn.assigns[:current_user] do
      nil -> conn |> put_flash(:error, "Sign in to export") |> redirect(to: ~p"/sign-in")
      user -> fun.(conn, user, params)
    end
  end

  defp json(conn, user, params) do
    with {:ok, tenant_id, opts} <- export_opts(user, params),
         {:ok, export} <- AuditExport.export(tenant_id, opts) do
      send_download(
        conn,
        "application/json",
        AuditExport.filename(export),
        AuditExport.encode(export)
      )
    else
      error -> error_resp(conn, error)
    end
  end

  defp pdf(conn, user, params) do
    with {:ok, tenant_id, opts} <- export_opts(user, params),
         {:ok, export, pdf} <- AuditExport.export_pdf(tenant_id, opts) do
      send_download(conn, "application/pdf", AuditExport.filename(export, "pdf"), pdf)
    else
      error -> error_resp(conn, error)
    end
  end

  defp export_opts(user, params) do
    tenant_id = params["tenant"] || default_tenant_id(user)

    with {:tenant, id} when is_binary(id) <- {:tenant, tenant_id},
         {:period, {:ok, from, to}} <- {:period, AuditParams.period(params, DateTime.utc_now())} do
      {:ok, id, [actor: user, from: from, to: to, site_ids: AuditParams.site_ids(params)]}
    end
  end

  defp send_download(conn, content_type, filename, body) do
    conn
    |> put_resp_content_type(content_type, if(content_type == "application/json", do: "utf-8"))
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, body)
  end

  defp error_resp(conn, {:period, :error}), do: send_resp(conn, 400, "invalid period")

  defp error_resp(conn, {:error, {:too_many_records, _, _} = reason}),
    do: plain(conn, 422, PDF.message(reason))

  defp error_resp(conn, {:error, reason})
       when reason == :timeout or reason == :timeout_missing or
              (is_tuple(reason) and elem(reason, 0) in [:typst_missing, :typst_failed, :io]) do
    Logger.error("audit pdf render failed: #{inspect(reason)}")
    plain(conn, 503, PDF.message(reason))
  end

  defp error_resp(conn, _error), do: send_resp(conn, 403, "forbidden")

  defp plain(conn, status, message) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, message)
  end

  defp default_tenant_id(user) do
    case CloudWeb.SitesLive.Data.tenants(user) do
      [tenant | _] -> tenant.id
      [] -> nil
    end
  end
end
