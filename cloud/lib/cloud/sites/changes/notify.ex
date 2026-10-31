defmodule Cloud.Sites.Changes.Notify do
  @moduledoc """
  Broadcasts a `Cloud.Sites.Notifications` event for the action's record
  once the action's transaction committed (an `after_transaction` hook), so
  a rolled-back action never notifies anyone.

      change {Cloud.Sites.Changes.Notify, type: :window_approved}
  """

  use Ash.Resource.Change

  alias Cloud.Sites.Notifications

  @impl true
  def init(opts) do
    if opts[:type] in Notifications.types(),
      do: {:ok, opts},
      else: {:error, "unknown notification type #{inspect(opts[:type])}"}
  end

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, record} ->
        Notifications.broadcast(opts[:type], record, context.actor)
        {:ok, record}

      _changeset, other ->
        other
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
