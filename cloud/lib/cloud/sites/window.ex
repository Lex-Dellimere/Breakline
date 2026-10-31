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

  Lifecycle: a window is `:requested` (by an admin, or by an MSP contact
  through their `Cloud.Sites.RequestLink`, see
  `Cloud.Sites.Changes.FromRequestLink`), then
  `:approved` or `:rejected` by an approver or admin, and may be `:cancelled`.
  Only approved windows are published. Approving, booking an approved window
  directly, opening now and cancelling each publish a new policy version.

  Everything that opens access needs a passkey step-up bound to it
  (`Cloud.Accounts.Changes.RequireStepUp`, threat model T5):

  - `:approve`: purpose `:approve_window`, subject the window, params its
    `id` and `site_id`
  - `:create_approved`: purpose `:open_window`, subject the site, params the
    window's shape fields
  - `:open_now`: purpose `:open_window`, subject the site, params `site_id`
    and `minutes`

  A request made through a link carries the link (`request_link_id`) and a
  `reason` (reason or ticket reference). Rejecting takes an optional `note`.
  Requesting, approving and rejecting notify the tenant's channels after
  commit (`Cloud.Sites.Notifications`).

  Every action is recorded in the tenant's audit chain (`Cloud.Audit`).
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Accounts.Changes.RequireStepUp
  alias Cloud.Audit.Changes.Record
  alias Cloud.Checks.{RequestLinkActor, RequestLinkWindows, TenantMember}
  alias Cloud.Sites.Changes.{FromRequestLink, Notify, Publish}
  alias Cloud.Sites.Validations.WindowShape

  @shape_fields [:site_id, :kind, :days, :starts, :ends, :starts_at, :ends_at]

  postgres do
    table "windows"
    repo Cloud.Repo

    references do
      reference :site, on_delete: :delete, match_tenant?: true
      reference :requested_by, on_delete: {:nilify, [:requested_by_id]}, match_tenant?: true
      reference :approved_by, on_delete: :nilify
      reference :rejected_by, on_delete: :nilify
      reference :request_link, on_delete: {:nilify, [:request_link_id]}, match_tenant?: true
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
      transaction? true
      accept @shape_fields ++ [:requested_by_id, :reason]
      # a request link actor gets its site, contact and kind forced and its caps checked
      change FromRequestLink
      validate {WindowShape, []}

      change {Record,
              action: "window.requested",
              fields: @shape_fields ++ [:requested_by_id, :request_link_id, :reason]}

      change {Notify, type: :window_requested}
    end

    create :create_approved do
      description "Books a window that is approved straight away."
      accept @shape_fields
      transaction? true
      argument :step_up_id, :uuid
      validate {WindowShape, []}
      change {RequireStepUp, purpose: :open_window, subject: :site_id, params: @shape_fields}
      change set_attribute(:status, :approved)
      change relate_actor(:approved_by, allow_nil?: true)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
      change {Record, action: "window.approved", fields: @shape_fields, extra: %{booked: true}}
      change {Publish, reason: "window booked"}
    end

    create :open_now do
      description """
      Opens the site now with an approved one-off window from the current minute
      to the first whole minute at or after now plus `minutes`, in the site's time.
      """

      accept [:site_id]
      transaction? true

      argument :minutes, :integer do
        allow_nil? false
        constraints min: 1, max: 24 * 60
      end

      argument :step_up_id, :uuid

      change {RequireStepUp,
              purpose: :open_window, subject: :site_id, params: [:site_id, :minutes]}

      change Cloud.Sites.Changes.OpenNowSpan
      change set_attribute(:kind, :one_off)
      validate {WindowShape, []}
      change set_attribute(:status, :approved)
      change relate_actor(:approved_by, allow_nil?: true)
      change set_attribute(:approved_at, &DateTime.utc_now/0)

      change {Record,
              action: "access.open_now",
              fields: [:site_id, :starts_at, :ends_at],
              arguments: [:minutes]}

      change {Publish, reason: "opened now"}
    end

    update :approve do
      require_atomic? false
      transaction? true
      accept []
      argument :step_up_id, :uuid

      validate attribute_equals(:status, :requested),
        message: "only a requested window can be approved"

      change {RequireStepUp, purpose: :approve_window, subject: :id, params: [:id, :site_id]}
      change set_attribute(:status, :approved)
      change relate_actor(:approved_by, allow_nil?: true)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
      change {Record, action: "window.approved", fields: [:site_id, :kind]}
      change {Publish, reason: "window approved"}
      change {Notify, type: :window_approved}
    end

    update :reject do
      require_atomic? false
      transaction? true
      accept []

      argument :note, :string do
        constraints max_length: 500
      end

      validate attribute_equals(:status, :requested),
        message: "only a requested window can be rejected"

      change set_attribute(:status, :rejected)
      change set_attribute(:rejection_note, arg(:note))
      change set_attribute(:rejected_at, &DateTime.utc_now/0)
      change relate_actor(:rejected_by, allow_nil?: true)
      change {Record, action: "window.rejected", fields: [:site_id, :rejection_note]}
      change {Notify, type: :window_rejected}
    end

    update :cancel do
      require_atomic? false
      transaction? true
      accept []

      validate attribute_in(:status, [:requested, :approved]),
        message: "only a requested or approved window can be cancelled"

      change set_attribute(:status, :cancelled)
      change {Record, action: "window.cancelled", fields: [:site_id]}
      change {Publish, reason: "window cancelled"}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if TenantMember
      authorize_if RequestLinkWindows
    end

    policy action(:request) do
      authorize_if {TenantMember, role: :admin}
      authorize_if RequestLinkActor
    end

    policy action([:create_approved, :open_now, :approve, :reject, :cancel]) do
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

    attribute :reason, :string do
      public? true
      constraints max_length: 500
    end

    attribute :rejected_at, :utc_datetime_usec, public?: true

    attribute :rejection_note, :string do
      public? true
      constraints max_length: 500
    end

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
    belongs_to :requested_by, Cloud.Sites.MspContact, public?: true
    belongs_to :approved_by, Cloud.Accounts.User, public?: true
    belongs_to :rejected_by, Cloud.Accounts.User, public?: true
    belongs_to :request_link, Cloud.Sites.RequestLink, public?: true
  end
end
