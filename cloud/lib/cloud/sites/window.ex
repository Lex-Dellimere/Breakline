defmodule Cloud.Sites.Window do
  @moduledoc """
  A maintenance window during which the site's RMM channel may be open.

  - `:recurring` windows repeat weekly: `days` are ISO weekdays (Monday is 1)
    and `starts`/`ends` are local whole-minute times. `ends <= starts`
    crosses midnight.
  - `:one_off` windows run from `starts_at` to `ends_at`, naive local
    datetimes in the site's time zone.

  The shape rules are those of `Breakline.Policy.RecurringWindow` and
  `Breakline.Policy.OneOffWindow` (`Cloud.Sites.Validations.WindowShape`).

  Lifecycle: a window is `:requested` (by an MSP contact or an admin), then
  `:approved` or `:rejected` by an approver or admin, and may be `:cancelled`.
  Only approved windows are published. Approving, booking an approved window
  directly and cancelling each publish a new policy version.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Checks.TenantMember
  alias Cloud.Sites.Changes.Publish
  alias Cloud.Sites.Validations.WindowShape

  @shape_fields [:site_id, :kind, :days, :starts, :ends, :starts_at, :ends_at]

  postgres do
    table "windows"
    repo Cloud.Repo

    references do
      reference :site, on_delete: :delete, match_tenant?: true
      reference :requested_by, on_delete: {:nilify, [:requested_by_id]}, match_tenant?: true
      reference :approved_by, on_delete: :nilify
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :in_policy do
      description "Trusted: the windows `Cloud.Policies` publishes for a site."
      argument :site_id, :uuid, allow_nil?: false
      argument :cutoff, :naive_datetime, allow_nil?: false

      filter expr(
               site_id == ^arg(:site_id) and status == :approved and
                 (kind == :recurring or ends_at >= ^arg(:cutoff))
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :request do
      primary? true
      accept @shape_fields ++ [:requested_by_id]
      validate {WindowShape, []}
    end

    create :create_approved do
      description "Books a window that is approved straight away."
      accept @shape_fields
      transaction? true
      validate {WindowShape, []}
      change set_attribute(:status, :approved)
      change relate_actor(:approved_by, allow_nil?: true)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
      change {Publish, reason: "window booked"}
    end

    update :approve do
      require_atomic? false
      transaction? true
      accept []

      validate attribute_equals(:status, :requested),
        message: "only a requested window can be approved"

      change set_attribute(:status, :approved)
      change relate_actor(:approved_by, allow_nil?: true)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
      change {Publish, reason: "window approved"}
    end

    update :reject do
      require_atomic? false
      accept []

      validate attribute_equals(:status, :requested),
        message: "only a requested window can be rejected"

      change set_attribute(:status, :rejected)
    end

    update :cancel do
      require_atomic? false
      transaction? true
      accept []

      validate attribute_in(:status, [:requested, :approved]),
        message: "only a requested or approved window can be cancelled"

      change set_attribute(:status, :cancelled)
      change {Publish, reason: "window cancelled"}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if TenantMember
    end

    policy action(:request) do
      authorize_if {TenantMember, role: :admin}
    end

    policy action([:create_approved, :approve, :reject, :cancel]) do
      authorize_if {TenantMember, role: [:admin, :approver]}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:recurring, :one_off]
    end

    attribute :days, {:array, :integer}, public?: true
    attribute :starts, :time, public?: true
    attribute :ends, :time, public?: true
    attribute :starts_at, :naive_datetime, public?: true
    attribute :ends_at, :naive_datetime, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :requested
      constraints one_of: [:requested, :approved, :rejected, :cancelled]
    end

    attribute :approved_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
    belongs_to :requested_by, Cloud.Sites.MspContact, public?: true
    belongs_to :approved_by, Cloud.Accounts.User, public?: true
  end
end
