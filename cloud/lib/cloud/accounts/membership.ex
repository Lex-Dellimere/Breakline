defmodule Cloud.Accounts.Membership do
  @moduledoc """
  Links a user to a tenant with a role.

  - `:admin` manages the tenant's sites, MSP contacts, windows and locks, and
    can do everything an approver can.
  - `:approver` approves or rejects windows and opens break-glass access.

  A user has at most one membership per tenant. Memberships are created by
  trusted server code with `authorize?: false`; members of a tenant can read
  that tenant's memberships.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "memberships"
    repo Cloud.Repo

    references do
      reference :user, on_delete: :delete
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:user_id, :tenant_id, :role]
    end

    read :for_user_in_tenant do
      description "Trusted lookup used by `Cloud.Checks.TenantMember`, run with authorize?: false."
      argument :user_id, :uuid, allow_nil?: false
      argument :tenant_id, :uuid, allow_nil?: false
      get? true
      filter expr(user_id == ^arg(:user_id) and tenant_id == ^arg(:tenant_id))
    end
  end

  policies do
    policy action(:read) do
      authorize_if expr(exists(tenant.memberships, user_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:admin, :approver]
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Cloud.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :tenant, Cloud.Accounts.Tenant do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_user_tenant, [:user_id, :tenant_id]
  end
end
