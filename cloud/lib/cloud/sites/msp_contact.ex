defmodule Cloud.Sites.MspContact do
  @moduledoc """
  A person at the tenant's MSP who may request maintenance windows. MSP
  contacts have no account; in a later phase they get a magic link that can
  only request a window, never approve one (threat model T6).

  Members of the tenant can read contacts, admins manage them.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Checks.TenantMember

  postgres do
    table "msp_contacts"
    repo Cloud.Repo

    references do
      reference :tenant, on_delete: :delete
    end

    custom_indexes do
      # target of the windows (requested_by_id, tenant_id) foreign key
      index [:id, :tenant_id], unique: true, all_tenants?: true
    end
  end

  actions do
    defaults [:read, :destroy, create: [:name, :email, :phone], update: [:name, :email, :phone]]
  end

  policies do
    policy action_type(:read) do
      authorize_if TenantMember
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {TenantMember, role: :admin}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :email, :ci_string do
      allow_nil? false
      public? true
      constraints match: ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
    end

    attribute :phone, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
  end

  identities do
    identity :unique_email, [:email]
  end
end
