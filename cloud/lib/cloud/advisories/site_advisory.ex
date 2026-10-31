defmodule Cloud.Advisories.SiteAdvisory do
  @moduledoc """
  What an advisory did to one site.

  - `:locked`: an advisory lock (`advisory_lock_id`) closed the site's RMM
    channel and was published. It stays until an admin lifts the lock.
  - `:pending`: an approver or admin has to confirm the lock or dismiss it.
  - `:dismissed`: an approver or admin decided not to lock; access is left
    as it was.

  `decided_by` and `decided_at` record who decided and when; an automatic
  lock has `decided_at` but no `decided_by`. There is at most one site
  advisory per site and advisory, which is what makes acting on an advisory
  idempotent.

  `:record` is the trusted path the poller uses (`authorize?: false`).
  `:confirm_lock` and `:dismiss` need an admin or approver of the tenant.
  Closing access needs no step-up: a lock can only take access away.
  Every status change is broadcast on `Cloud.Advisories.notifications_topic/1`
  after it commits.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Advisories,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Advisories.Changes.{LockSite, Notify}
  alias Cloud.Checks.TenantMember

  postgres do
    table "site_advisories"
    repo Cloud.Repo

    references do
      reference :tenant, on_delete: :delete
      reference :site, on_delete: :delete, match_tenant?: true
      reference :advisory, on_delete: :delete
      # the lock is always created in the same tenant by Cloud.Advisories.Changes.LockSite
      reference :advisory_lock, on_delete: :nilify
      reference :decided_by, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "Trusted: the poller records what an advisory does to a site."
      transaction? true
      accept [:site_id, :advisory_id, :status]
      validate attribute_in(:status, [:locked, :pending])
      change {LockSite, when_status: :locked}
      change Notify
    end

    update :confirm_lock do
      description "Locks the site for a pending advisory and publishes."
      require_atomic? false
      transaction? true
      accept []
      validate attribute_equals(:status, :pending), message: "is not pending"
      change set_attribute(:status, :locked)
      change set_attribute(:decided_at, &DateTime.utc_now/0)
      change relate_actor(:decided_by)
      change {LockSite, when_status: :locked}
      change Notify
    end

    update :dismiss do
      description "Decides not to lock the site for a pending advisory."
      require_atomic? false
      accept []
      validate attribute_equals(:status, :pending), message: "is not pending"
      change set_attribute(:status, :dismissed)
      change set_attribute(:decided_at, &DateTime.utc_now/0)
      change relate_actor(:decided_by)
      change Notify
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if TenantMember
    end

    policy action([:confirm_lock, :dismiss]) do
      authorize_if {TenantMember, role: [:admin, :approver]}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:locked, :pending, :dismissed]
    end

    attribute :decided_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
    belongs_to :advisory, Cloud.Advisories.Advisory, allow_nil?: false, public?: true
    belongs_to :advisory_lock, Cloud.Sites.AdvisoryLock, public?: true
    belongs_to :decided_by, Cloud.Accounts.User, public?: true
  end

  identities do
    identity :unique_site_advisory, [:site_id, :advisory_id]
  end
end
