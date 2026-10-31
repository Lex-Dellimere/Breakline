defmodule Cloud.Accounts.Tenant do
  @moduledoc """
  A client organisation. Every site, window, lock and policy version belongs to
  exactly one tenant, and users reach a tenant's data only through a
  `Cloud.Accounts.Membership`.

  `advisory_mode` says what happens when a threat feed matches one of the
  tenant's tools: `:auto_lock` raises an advisory lock straight away, `:ask`
  only notifies an approver.

  Tenants are created by trusted server code (seeds, provisioning) with
  `authorize?: false`. Members can read their tenant and admins can change its
  settings. A tenant struct can be passed as `tenant:` to any tenant-scoped
  action, see `Ash.ToTenant`.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "tenants"
    repo Cloud.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :slug, :advisory_mode]
    end

    update :update_settings do
      accept [:name, :advisory_mode]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(exists(memberships, user_id == ^actor(:id)))
    end

    policy action(:update_settings) do
      authorize_if expr(exists(memberships, user_id == ^actor(:id) and role == :admin))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[a-z0-9][a-z0-9-]{0,62}$/
    end

    attribute :advisory_mode, :atom do
      allow_nil? false
      public? true
      default :auto_lock
      constraints one_of: [:auto_lock, :ask]
    end

    timestamps()
  end

  relationships do
    has_many :memberships, Cloud.Accounts.Membership
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
