defmodule CloudWeb.AuditExportController do
  @moduledoc """
  `GET /audit/export.json?tenant=&from=&to=&site_ids=`: downloads a tenant's
  audit export (`Cloud.AuditExport`) as a json attachment, for the tenant's
  admins and approvers. The export is recorded in the tenant's cloud audit
  chain.

  `tenant` defaults to the first of the user's tenants by name; the period
  and sites are read by `CloudWeb.AuditParams`. A signed-out user is sent to
  sign in, anyone who is not an admin or approver of the tenant gets a 403
  and a bad period a 400.
  """

  use CloudWeb, :controller

  alias Cloud.AuditExport
  alias CloudWeb.AuditParams

  def show(conn, params) do
    case conn.assigns[:current_user] do
      nil -> conn |> put_flash(:error, "Sign in to export") |> redirect(to: ~p"/sign-in")
      user -> export(conn, user, params)
    end
  end

  defp export(conn, user, params) do
    tenant_id = params["tenant"] || default_tenant_id(user)

    with {:tenant, id} when is_binary(id) <- {:tenant, tenant_id},
         {:period, {:ok, from, to}} <- {:period, AuditParams.period(params, DateTime.utc_now())},
         {:ok, export} <-
           AuditExport.export(id,
             actor: user,
             from: from,
             to: to,
             site_ids: AuditParams.site_ids(params)
           ) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{AuditExport.filename(export)}")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, AuditExport.encode(export))
    else
      {:period, :error} -> send_resp(conn, 400, "invalid period")
      _ -> send_resp(conn, 403, "forbidden")
    end
  end

  defp default_tenant_id(user) do
    case CloudWeb.SitesLive.Data.tenants(user) do
      [tenant | _] -> tenant.id
      [] -> nil
    end
  end
end
