defmodule Cloud.Accounts.Changes.RequirePasskeyCeremony do
  @moduledoc """
  Refuses to store a passkey unless `Cloud.Accounts.Passkeys.register/4`
  verified its attestation and set the changeset context
  `passkey_ceremony: :verified`.

  This keeps the webauthn strategy's own add-credential and register code
  paths (which have no step-up check) from creating passkeys.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.context[:passkey_ceremony] == :verified do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :credential_id,
        message: "passkeys are only stored by the passkey registration ceremony"
      )
    end
  end
end
