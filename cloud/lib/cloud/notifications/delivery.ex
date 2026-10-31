defmodule Cloud.Notifications.Delivery do
  @moduledoc """
  One notification sent, or being sent, to one channel or one fallback
  recipient: its event type, site, status (`:pending`, `:sent`, `:failed`),
  attempts, last error and when it was sent.

  A delivery for a channel keeps the channel's name and masked target, so the
  history still reads well after the channel is removed (`channel_id`
  becomes nil). A fallback email to an admin or approver has no channel and
  names the user instead (`recipient_user_id`). No target, message body or
  secret is stored here; errors are short descriptions such as
  `"http status 500"`, never a URL.

  Deliveries are created and updated only by trusted server code
  (`Cloud.Notifications`, `Cloud.Notifications.Worker`). Admins of the tenant
  can read them.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Checks.TenantMember

  postgres do
    table "notification_deliveries"
    repo Cloud.Repo

    references do
      reference :tenant, on_delete: :delete
      reference :channel, on_delete: {:nilify, [:channel_id]}, match_tenant?: true
      reference :recipient_user, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    read :recent do
      argument :limit, :integer, default: 25, constraints: [min: 1, max: 200]
      prepare build(sort: [inserted_at: :desc, id: :desc])
      prepare fn query, _context -> Ash.Query.limit(query, query.arguments.limit) end
    end

    create :enqueue do
      description "Trusted: a delivery about to be queued."

      accept [
        :channel_id,
        :recipient_user_id,
        :kind,
        :channel_name,
        :target_hint,
        :event_type,
        :site_id
      ]
    end

    update :record_result do
      description "Trusted: the worker records an attempt's outcome."
      accept [:status, :attempts, :last_error, :sent_at]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {TenantMember, role: :admin}
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
      constraints one_of: [:slack, :teams, :email, :sms]
    end

    attribute :channel_name, :string, public?: true
    attribute :target_hint, :string, public?: true

    attribute :event_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:test | Cloud.Notifications.Event.types()]
    end

    attribute :site_id, :uuid, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :sent, :failed]
    end

    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true
    attribute :last_error, :string, public?: true, constraints: [max_length: 500]
    attribute :sent_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :channel, Cloud.Notifications.Channel, public?: true
    belongs_to :recipient_user, Cloud.Accounts.User, public?: true
  end
end
