defmodule Cloud.Notifications.Changes.EncryptTarget do
  @moduledoc """
  Validates a new channel's `target` argument for its kind
  (`Cloud.Notifications.Target`), then stores it encrypted
  (`target_ciphertext`) with its masked form (`target_hint`).
  """

  use Ash.Resource.Change

  alias Cloud.Notifications.{Target, Vault}

  @impl true
  def change(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    target = Ash.Changeset.get_argument(changeset, :target)

    case {kind, target} do
      {nil, _} ->
        changeset

      {kind, target} ->
        case Target.validate(kind, target) do
          {:ok, target} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:target_ciphertext, Vault.encrypt(target))
            |> Ash.Changeset.force_change_attribute(:target_hint, Target.mask(kind, target))

          {:error, message} ->
            Ash.Changeset.add_error(changeset, field: :target, message: message)
        end
    end
  end
end
