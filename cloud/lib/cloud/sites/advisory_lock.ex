defmodule Cloud.Sites.AdvisoryLock do
  @moduledoc """
  Locks a whole site's RMM channel, whatever the windows say.

  `source` says where the lock came from: `"kev:CVE-..."` or `"acsc"` for a
  threat-feed match, `"manual"` for an admin's lock. A lock is active while
  it is not lifted and `expires_at` is nil or still in the future. Creating
  and lifting a lock each publish a new policy version.

  Feed-driven locks are created by trusted server code with
  `authorize?: false`; admins create manual locks and lift locks.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Checks.TenantMember
  alias Cloud.Sites.Changes.Publish

  postgres do
    table "advisory_locks"
    repo Cloud.Repo

    references do
      reference :site, on_delete: :delete, match_tenant?: true
      reference :lifted_by, on_delete: :nilify
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :active do
      description "Trusted: the locks `Cloud.Policies` publishes for a site."
      argument :site_id, :uuid, allow_nil?: false
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               site_id == ^arg(:site_id) and is_nil(lifted_at) and
                 (is_nil(expires_at) or expires_at > ^arg(:now))
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :create do
      primary? true
      transaction? true
      accept [:site_id, :reason, :source, :expires_at]
      change {Publish, reason: "advisory lock"}
    end

    update :lift do
      require_atomic? false
      transaction? true
      accept []
      validate attribute_equals(:lifted_at, nil), message: "is already lifted"
      change set_attribute(:lifted_at, &DateTime.utc_now/0)
      change relate_actor(:lifted_by, allow_nil?: true)
      change {Publish, reason: "advisory lock lifted"}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if TenantMember
    end

    policy action([:create, :lift]) do
      authorize_if {TenantMember, role: :admin}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :lifted_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
    belongs_to :lifted_by, Cloud.Accounts.User, public?: true
  end
end
