defmodule Cloud.Sites.Changes.Publish do
  @moduledoc """
  Publishes a new policy version for the record's site in the same
  transaction as the action, so a change that affects the policy (an approved
  window, a lock, a break-glass, a site edit) can never be saved without being
  published.

  Options:

  - `:site_field`: the record field holding the site id (default `:site_id`,
    `:id` for the site itself)
  - `:reason`: the `reason` stored on the `Cloud.Sites.PolicyVersion`

  The actor becomes `published_by` when it is a user. The new policy version
  is put in the record's metadata as `:policy_version`, and
  `{:policy_published, site_id, version}` is broadcast after the transaction
  commits (see `Cloud.Policies.publish/2`).

  Trusted server code that changes several records and publishes once itself
  (for example `Cloud.Access.unlock/2`) sets the changeset context
  `skip_publish?: true`.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    if is_binary(opts[:reason]),
      do: {:ok, Keyword.put_new(opts, :site_field, :site_id)},
      else: {:error, "reason is required"}
  end

  @impl true
  def change(changeset, opts, context) do
    if changeset.context[:skip_publish?] do
      changeset
    else
      publish(changeset, opts, context)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp publish(changeset, opts, context) do
    changeset
    |> Ash.Changeset.after_action(fn _changeset, record ->
      site_id = Map.fetch!(record, opts[:site_field])

      case Cloud.Policies.publish_in_transaction(site_id,
             published_by: context.actor,
             reason: opts[:reason]
           ) do
        {:ok, version} -> {:ok, Ash.Resource.put_metadata(record, :policy_version, version)}
        {:error, error} -> {:error, error}
      end
    end)
    |> Ash.Changeset.after_transaction(fn
      _changeset, {:ok, record} ->
        case record.__metadata__[:policy_version] do
          nil -> :ok
          version -> Cloud.Policies.broadcast(version)
        end

        {:ok, record}

      _changeset, other ->
        other
    end)
  end
end
