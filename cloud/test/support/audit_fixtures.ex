defmodule Cloud.AuditFixtures do
  @moduledoc """
  Builds audit chains for tests: cloud audit entries at given times, and a
  gateway audit chain uplinked through `Cloud.Gateways.Ingest` as a gateway
  would send it.
  """

  alias Breakline.AuditLog

  @doc "Appends a cloud audit entry for `site` at `at` (default now) as `actor`."
  def cloud_entry!(site, action, opts \\ []) do
    {:ok, entry} =
      Cloud.Audit.record(site.tenant_id, action, %{site_id: site.id},
        actor: opts[:actor],
        at: Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)
      )

    entry
  end

  @doc """
  Uplinks a gateway audit chain for `site` with one record per time in
  `times` (newest last) and returns the chain's records.
  """
  def gateway_chain!(site, times) do
    records =
      times
      |> Enum.reduce(AuditLog.new(), fn at, chain ->
        AuditLog.append(chain, %{"type" => "state_changed", "at" => DateTime.to_iso8601(at)})
      end)
      |> AuditLog.records()

    chain_id = hd(records)["hash"]

    {:ok, _head} =
      Cloud.Gateways.Ingest.audit(
        %{site_id: site.id, tenant_id: site.tenant_id},
        chain_id,
        records
      )

    records
  end

  @doc "Changes the action of the tenant's cloud audit entry at `seq` in the database."
  def tamper_cloud_entry!(tenant_id, seq) do
    Cloud.Repo.query!(
      "UPDATE audit_entries SET entry = jsonb_set(entry, '{action}', '\"forged\"') " <>
        "WHERE tenant_id = $1 AND seq = $2",
      [Ecto.UUID.dump!(tenant_id), seq]
    )
  end

  @doc "Changes the entry type of the site's stored gateway audit record at `seq`."
  def tamper_gateway_record!(site_id, seq) do
    Cloud.Repo.query!(
      "UPDATE gateway_audit_records SET record = jsonb_set(record, '{entry,type}', '\"forged\"') " <>
        "WHERE site_id = $1 AND seq = $2",
      [Ecto.UUID.dump!(site_id), seq]
    )
  end

  @doc "Now minus `days`."
  def days_ago(days), do: DateTime.add(DateTime.utc_now(), -round(days * 86_400), :second)
end
