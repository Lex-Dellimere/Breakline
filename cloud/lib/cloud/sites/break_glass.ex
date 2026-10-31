defmodule Cloud.Sites.BreakGlass do
  @moduledoc """
  An approver's "open now" override for a site, active until `until` unless
  revoked. Advisory locks still win over it (`Breakline.Schedule`).

  `until` is at most 4 hours from now (`max_minutes/0`). Creating one
  needs a passkey step-up with purpose `:break_glass`, subject the site and
  params `site_id` and `until` exactly as given (threat model T5); revoking
  closes access and needs none.

  Only the most recent unrevoked, unexpired break-glass of a site is
  published. Creating and revoking each publish a new policy version, are
  recorded in the tenant's audit chain and notify the tenant's channels after
  commit (`Cloud.Sites.Notifications`). Approvers and admins may do both.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Accounts.Changes.RequireStepUp
  alias Cloud.Audit.Changes.Record
  alias Cloud.Checks.TenantMember
  alias Cloud.Sites.Changes.{Notify, Publish}

  @max_minutes 4 * 60

  @doc "The longest a break-glass may last, in minutes from now."
  def max_minutes, do: @max_minutes

  @doc "The latest `until` a break-glass created now may have."
  def latest_until, do: DateTime.add(DateTime.utc_now(), @max_minutes * 60, :second)

  postgres do
    table "break_glasses"
    repo Cloud.Repo

    references do
      reference :site, on_delete: :delete, match_tenant?: true
      reference :approved_by, on_delete: :nilify
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :current do
      description "Trusted: the break-glass `Cloud.Policies` publishes for a site."
      argument :site_id, :uuid, allow_nil?: false
      argument :now, :utc_datetime_usec, allow_nil?: false
      get? true

      filter expr(site_id == ^arg(:site_id) and is_nil(revoked_at) and until > ^arg(:now))

      prepare build(sort: [inserted_at: :desc, id: :desc], limit: 1, load: [:approved_by])
    end

    create :create do
      primary? true
      transaction? true
      accept [:site_id, :until]
      argument :step_up_id, :uuid

      validate compare(:until, greater_than: &DateTime.utc_now/0),
        message: "must be in the future"

      validate compare(:until, less_than_or_equal_to: &__MODULE__.latest_until/0),
        message: "must be at most 4 hours from now"

      change {RequireStepUp, purpose: :break_glass, subject: :site_id, params: [:site_id, :until]}
      change relate_actor(:approved_by)
      change {Record, action: "break_glass.created", fields: [:site_id, :until]}
      change {Publish, reason: "break-glass opened"}
      change {Notify, type: :break_glass_opened}
    end

    update :revoke do
      require_atomic? false
      transaction? true
      accept []
      validate attribute_equals(:revoked_at, nil), message: "is already revoked"
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
      change {Record, action: "break_glass.revoked", fields: [:site_id]}
      change {Publish, reason: "break-glass revoked"}
      change {Notify, type: :break_glass_revoked}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if TenantMember
    end

    policy action([:create, :revoke]) do
      authorize_if {TenantMember, role: [:admin, :approver]}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id

    attribute :until, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
    belongs_to :approved_by, Cloud.Accounts.User, allow_nil?: false, public?: true
  end
end
