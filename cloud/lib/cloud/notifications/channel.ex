defmodule Cloud.Notifications.Channel do
  @moduledoc """
  Where a tenant's notifications go: a Slack or Teams webhook, an email
  address or a phone number for SMS.

  The target is passed to `:create` as the `target` argument, checked by
  `Cloud.Notifications.Target` and stored only encrypted
  (`target_ciphertext`, see `Cloud.Notifications.Vault`) plus a masked form
  (`target_hint`) for the settings page. The plain target is never readable
  through an action; the delivery worker decrypts it with
  `Cloud.Notifications.target/1`. A channel's target cannot be changed: an
  admin removes the channel and adds a new one.

  `event_types` lists the events the channel receives (all by default) and
  a disabled channel receives none. Only admins of the tenant can see and
  manage channels. Adding and removing a channel is recorded in the
  tenant's audit chain, without its target.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Audit.Changes.Record
  alias Cloud.Checks.TenantMember
  alias Cloud.Notifications.Changes.EncryptTarget

  postgres do
    table "notification_channels"
    repo Cloud.Repo
    # the ash default (every event type) applies on create; the column has none
    migration_defaults event_types: "nil"

    references do
      reference :tenant, on_delete: :delete
      reference :created_by, on_delete: :nilify
    end

    custom_indexes do
      # target of the deliveries (channel_id, tenant_id) foreign key
      index [:id, :tenant_id], unique: true, all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      transaction? true
      accept [:kind, :name, :event_types, :enabled]
      argument :target, :string, allow_nil?: false, sensitive?: true
      change EncryptTarget
      change relate_actor(:created_by)
      change {Record, action: "notification_channel.added", fields: [:kind, :name, :event_types]}
    end

    update :set_enabled do
      accept [:enabled]
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      transaction? true
      change {Record, action: "notification_channel.removed", fields: [:kind, :name]}
    end
  end

  policies do
    policy always() do
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

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :target_ciphertext, :string do
      allow_nil? false
      sensitive? true
      description "The target encrypted with Cloud.Notifications.Vault."
    end

    attribute :target_hint, :string do
      allow_nil? false
      public? true
      description "A masked form of the target that is safe to show."
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :event_types, {:array, :atom} do
      allow_nil? false
      public? true
      default Cloud.Notifications.Event.types()
      constraints items: [one_of: Cloud.Notifications.Event.types()], min_length: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :created_by, Cloud.Accounts.User, public?: true
  end
end
