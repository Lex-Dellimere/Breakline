defmodule Cloud.Advisories.Changes.Notify do
  @moduledoc """
  Broadcasts `{:advisory, %{tenant_id:, site_id:, advisory_id:, status:}}` on
  the tenant's `Cloud.Advisories.notifications_topic/1` after a site advisory
  change commits.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, record} ->
        Phoenix.PubSub.broadcast(
          Cloud.PubSub,
          Cloud.Advisories.notifications_topic(record.tenant_id),
          {:advisory,
           %{
             tenant_id: record.tenant_id,
             site_id: record.site_id,
             advisory_id: record.advisory_id,
             status: record.status
           }}
        )

        {:ok, record}

      _changeset, other ->
        other
    end)
  end
end
