defmodule Cloud.Gateways.Event do
  @moduledoc """
  An event a site's gateway reported, for example a blocked lookup or a
  state change. `at` is when it happened on the gateway, `data` is the event
  body as sent.

  Created by the gateway channel (trusted, `authorize?: false`); members of
  the tenant can read them.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Gateways,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Checks.TenantMember

  postgres do
    table "gateway_events"
    repo Cloud.Repo

    references do
      reference :site, on_delete: :delete, match_tenant?: true
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:site_id, :type, :at, :data]
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

    attribute :type, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :data, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
  end
end
