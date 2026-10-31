defmodule Cloud.Accounts.Changes.KeepApproverPasskey do
  @moduledoc """
  Refuses to remove a user's last passkey while they are an admin or approver
  of any tenant: without one they could no longer approve, and an account
  that can approve must always be able to.

  The count runs inside the destroy's transaction after the passkey rows are
  locked, so two concurrent removals cannot both see "one left".
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      user_id = changeset.data.user_id

      remaining =
        Cloud.Accounts.Passkey
        |> Ash.Query.filter(user_id == ^user_id)
        |> Ash.Query.lock(:for_update)
        |> Ash.read!(authorize?: false)
        |> length()

      if remaining <= 1 and approver?(user_id) do
        Ash.Changeset.add_error(changeset,
          field: :id,
          message: "an admin or approver must keep at least one passkey"
        )
      else
        changeset
      end
    end)
  end

  defp approver?(user_id) do
    Cloud.Accounts.list_memberships!(authorize?: false, query: [filter: [user_id: user_id]])
    |> Enum.any?(&(&1.role in [:admin, :approver]))
  end
end
