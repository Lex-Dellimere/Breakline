defmodule Cloud.Advisories.Changes.LockSite do
  @moduledoc """
  When the site advisory ends up with status `:when_status`, creates the
  site's advisory lock and publishes a new policy version, all in the
  action's transaction, and broadcasts the version after commit.

  The lock is created through the trusted path (`authorize?: false`), because
  the site advisory action has already been authorised: the poller's
  `:record` is trusted, and `:confirm_lock` needs an admin or approver.

  - KEV: source `"kev:<CVE>"`, reason `"CISA KEV <CVE>: <title>"`
  - ACSC: source `"acsc"`, reason `"ACSC: <title>"`

  The lock has no expiry; it holds until an admin lifts it.
  """

  use Ash.Resource.Change

  alias Cloud.Advisories.Advisory

  @max_reason 500

  @impl true
  def init(opts) do
    if is_atom(opts[:when_status]),
      do: {:ok, opts},
      else: {:error, "when_status is required"}
  end

  @impl true
  def change(changeset, opts, context) do
    if Ash.Changeset.get_attribute(changeset, :status) == opts[:when_status] do
      changeset
      |> Ash.Changeset.before_action(&create_lock/1)
      |> Ash.Changeset.after_action(fn _changeset, record -> publish(record, context.actor) end)
      |> Ash.Changeset.after_transaction(&broadcast/2)
    else
      changeset
    end
  end

  @doc "The advisory lock source and reason for an advisory."
  @spec lock_attrs(Advisory.t()) :: %{source: String.t(), reason: String.t()}
  def lock_attrs(%Advisory{source: :kev} = advisory) do
    %{
      source: "kev:" <> advisory.external_id,
      reason: truncate("CISA KEV #{advisory.external_id}: #{advisory.title}")
    }
  end

  def lock_attrs(%Advisory{source: :acsc} = advisory) do
    %{source: "acsc", reason: truncate("ACSC: #{advisory.title}")}
  end

  defp truncate(text), do: String.slice(text, 0, @max_reason)

  defp create_lock(changeset) do
    site_id = Ash.Changeset.get_attribute(changeset, :site_id)
    advisory_id = Ash.Changeset.get_attribute(changeset, :advisory_id)

    # the lock and its policy version are published once, below; the lock's own
    # publish hook is skipped so nothing broadcasts before this transaction commits
    with {:ok, advisory} <- Ash.get(Advisory, advisory_id, authorize?: false),
         {:ok, lock, _notifications} <-
           Cloud.Sites.create_advisory_lock(
             Map.put(lock_attrs(advisory), :site_id, site_id),
             tenant: changeset.to_tenant,
             authorize?: false,
             context: %{skip_publish?: true},
             return_notifications?: true
           ) do
      changeset
      |> Ash.Changeset.force_change_attribute(:advisory_lock_id, lock.id)
      |> Ash.Changeset.force_change_new_attribute(:decided_at, DateTime.utc_now())
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp publish(record, actor) do
    case Cloud.Policies.publish_in_transaction(record.site_id,
           published_by: actor,
           reason: "advisory lock"
         ) do
      {:ok, version} -> {:ok, Ash.Resource.put_metadata(record, :policy_version, version)}
      {:error, error} -> {:error, error}
    end
  end

  defp broadcast(_changeset, {:ok, record}) do
    case record.__metadata__[:policy_version] do
      nil -> :ok
      version -> Cloud.Policies.broadcast(version)
    end

    {:ok, record}
  end

  defp broadcast(_changeset, other), do: other
end
