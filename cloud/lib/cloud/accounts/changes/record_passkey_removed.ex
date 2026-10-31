defmodule Cloud.Accounts.Changes.RecordPasskeyRemoved do
  @moduledoc """
  Appends a `"passkey.removed"` audit entry to every tenant the passkey's
  user belongs to, in the destroy's transaction.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, passkey ->
      fields = %{passkey_id: passkey.id, user_id: passkey.user_id, label: passkey.label}

      case Cloud.Audit.append_all(
             Cloud.Audit.tenant_ids(passkey.user_id),
             "passkey.removed",
             fields,
             actor: context.actor
           ) do
        :ok -> {:ok, passkey}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
