defmodule Cloud.Audit.Entry do
  @moduledoc """
  One record of a tenant's cloud audit chain (threat model T9), as built by
  `Breakline.AuditLog.append_record/2`: `seq`, `prev_hash`, `hash` and the
  `entry` map that was hashed. `actor_id` repeats the entry's actor for
  querying; only the `entry` map is covered by the hash.

  Entries are appended by `Cloud.Audit.append/4` inside the transaction of the
  action they record, so an action and its audit record commit or roll back
  together. Members of the tenant can read the chain; nobody can write it
  except trusted server code.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Checks.TenantMember

  postgres do
    table "audit_entries"
    repo Cloud.Repo

    references do
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :chain do
      description "The whole chain, oldest first."
      prepare build(sort: [seq: :asc])
    end

    create :append do
      description "Trusted: stores a record built by `Cloud.Audit.append/4`."
      accept [:seq, :prev_hash, :hash, :entry, :actor_id]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if TenantMember
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id

    attribute :seq, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :prev_hash, :string, allow_nil?: false, public?: true
    attribute :hash, :string, allow_nil?: false, public?: true
    attribute :entry, :map, allow_nil?: false, public?: true
    attribute :actor_id, :uuid, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
  end

  identities do
    identity :unique_seq, [:tenant_id, :seq]
  end
end
