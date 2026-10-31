defmodule Cloud.Accounts.Passkey do
  @moduledoc """
  A user's registered passkey (a WebAuthn credential): the authenticator's
  credential id, its COSE public key and its signature counter.

  This is the credential resource of the `webauthn` strategy on
  `Cloud.Accounts.User`, which signs users in with it. Approving anything
  that opens a site's RMM channel needs a step-up assertion from one of the
  user's passkeys (`Cloud.Accounts.StepUps`).

  - `:create` only stores a credential that went through our own
    registration ceremony (`Cloud.Accounts.Passkeys.register/4`, which sets
    the context `passkey_ceremony: :verified` after `Wax.register/3`).
    The strategy's built-in add-credential and register flows are refused
    here, so a password session alone can never slip a passkey in beside the
    step-up checks.
  - `:destroy` needs a `:remove_passkey` step-up for this passkey and
    refuses the user's last passkey while they are an admin or approver.

  Users read and remove their own passkeys only.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Accounts.Changes.RequireStepUp

  postgres do
    table "passkeys"
    repo Cloud.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :for_user do
      description "Trusted: a user's passkeys, oldest first."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept [:credential_id, :public_key, :sign_count, :label, :user_id]
      change Cloud.Accounts.Changes.RequirePasskeyCeremony
    end

    update :update do
      description "Used by the webauthn strategy after a passkey sign in."
      primary? true
      accept [:sign_count, :label, :last_used_at]
    end

    update :record_use do
      description "Trusted: the new signature counter after a verified step-up."
      accept [:sign_count, :last_used_at]
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      transaction? true
      argument :step_up_id, :uuid

      change {RequireStepUp, purpose: :remove_passkey, subject: :id, params: [:id]}
      change Cloud.Accounts.Changes.KeepApproverPasskey
      change Cloud.Accounts.Changes.RecordPasskeyRemoved
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type([:read, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :credential_id, :binary do
      allow_nil? false
      public? true
    end

    attribute :public_key, AshAuthentication.Strategy.WebAuthn.CoseKey do
      allow_nil? false
      public? true
      sensitive? true
    end

    attribute :sign_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :label, :string do
      allow_nil? false
      default "Passkey"
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :last_used_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Cloud.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_credential_id, [:credential_id]
  end
end
