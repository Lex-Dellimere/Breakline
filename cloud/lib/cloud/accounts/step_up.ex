defmodule Cloud.Accounts.StepUp do
  @moduledoc """
  A passkey assertion bound to one action (threat model T5).

  `Cloud.Accounts.StepUps.begin/5` creates it with a fresh challenge for one
  `purpose`, `subject_id` and `payload_hash` (the sha256 of the action's
  canonical parameters). The browser signs the challenge with one of the
  user's passkeys, `Cloud.Accounts.StepUps.verify/3` checks the assertion and
  sets `verified_at`, and the action itself consumes it (`consumed_at`)
  through `Cloud.Accounts.Changes.RequireStepUp`.

  A step-up lives for two minutes, is verified at most once and consumed at
  most once. A failed verification sets `failed_at` and the step-up is dead;
  the user starts again. `allowed_credential_ids` are the passkeys that may
  answer it.

  `tenant_id` is the tenant the action runs in, nil for account-level
  purposes (`:remove_passkey`, `:register_passkey`).

  Trusted only: there are no actor policies, everything goes through
  `Cloud.Accounts.StepUps` with `authorize?: false`.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @purposes [
    :open_window,
    :approve_window,
    :break_glass,
    :lift_lock,
    :remove_passkey,
    :register_passkey
  ]

  @doc "The purposes a step-up can be for."
  def purposes, do: @purposes

  postgres do
    table "step_ups"
    repo Cloud.Repo

    references do
      reference :user, on_delete: :delete
      reference :tenant, on_delete: :delete
      reference :passkey, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    read :lock do
      description "Trusted: one step-up with a row lock, for verifying or consuming it."
      get_by [:id]
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    create :begin do
      description "Trusted: a new step-up, see `Cloud.Accounts.StepUps.begin/5`."

      accept [
        :user_id,
        :tenant_id,
        :purpose,
        :subject_id,
        :payload_hash,
        :challenge,
        :allowed_credential_ids,
        :expires_at
      ]
    end

    update :mark_verified do
      accept [:passkey_id]
      change set_attribute(:verified_at, &DateTime.utc_now/0)
    end

    update :mark_failed do
      accept []
      change set_attribute(:failed_at, &DateTime.utc_now/0)
    end

    update :consume do
      accept []
      change set_attribute(:consumed_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :purpose, :atom do
      allow_nil? false
      public? true
      constraints one_of: @purposes
    end

    attribute :subject_id, :uuid, allow_nil?: false, public?: true
    attribute :payload_hash, :string, allow_nil?: false, public?: true

    attribute :challenge, :binary do
      allow_nil? false
      sensitive? true
    end

    attribute :allowed_credential_ids, {:array, :binary} do
      allow_nil? false
      default []
    end

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :verified_at, :utc_datetime_usec, public?: true
    attribute :consumed_at, :utc_datetime_usec, public?: true
    attribute :failed_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Cloud.Accounts.User, allow_nil?: false, public?: true
    belongs_to :tenant, Cloud.Accounts.Tenant, public?: true
    belongs_to :passkey, Cloud.Accounts.Passkey, public?: true
  end
end
