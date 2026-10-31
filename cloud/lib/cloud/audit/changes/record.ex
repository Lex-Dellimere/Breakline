defmodule Cloud.Audit.Changes.Record do
  @moduledoc """
  Appends a `Cloud.Audit` entry for the action's record in the action's own
  transaction (an `after_action` hook), so the record and its audit entry
  commit or roll back together.

      change {Cloud.Audit.Changes.Record, action: "window.approved", fields: [:site_id, :kind]}

  Options:

  - `:action`: the entry's `"action"` (required)
  - `:fields`: record fields copied into the entry (the record's `id` is
    always included)
  - `:arguments`: action arguments copied into the entry
  - `:extra`: a constant map merged into the entry
  - `:tenant_field`: the record field holding the tenant id (default
    `:tenant_id`)

  The actor of the action becomes the entry's actor. Trusted callers can
  rename the entry and add fields through the changeset context:
  `audit_action: "access.open_now"` and `audit_fields: %{minutes: 30}`.
  `skip_audit?: true` skips the entry, for callers that record one entry
  for several records themselves.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    if is_binary(opts[:action]),
      do:
        {:ok,
         opts
         |> Keyword.put_new(:fields, [])
         |> Keyword.put_new(:arguments, [])
         |> Keyword.put_new(:extra, %{})
         |> Keyword.put_new(:tenant_field, :tenant_id)},
      else: {:error, "action is required"}
  end

  @impl true
  def change(changeset, opts, context) do
    if changeset.context[:skip_audit?] do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn changeset, record ->
        append(changeset, record, opts, context)
      end)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp append(changeset, record, opts, context) do
    action = changeset.context[:audit_action] || opts[:action]

    arguments = Map.new(opts[:arguments], &{&1, Ash.Changeset.get_argument(changeset, &1)})

    fields =
      record
      |> Map.take(opts[:fields])
      |> Map.put(:id, record.id)
      |> Map.merge(arguments)
      |> Map.merge(opts[:extra])
      |> Map.merge(changeset.context[:audit_fields] || %{})

    case Cloud.Audit.append(Map.fetch!(record, opts[:tenant_field]), action, fields,
           actor: context.actor
         ) do
      {:ok, _entry} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end
end
