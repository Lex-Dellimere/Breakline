defmodule Cloud.Sites.PolicyVersion do
  @moduledoc """
  One published version of a site's policy. Append-only: there are create and
  read actions only, and creating is reserved for `Cloud.Policies`.

  `policy` is exactly `Breakline.Policy.to_map/1` of the published policy.
  `published_by` is the user whose action caused the publish, or nil for the
  system (for example a threat-feed lock). `reason` says what changed.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Checks.TenantMember

  @type t :: %__MODULE__{}

  postgres do
    table "policy_versions"
    repo Cloud.Repo

    references do
      reference :site, on_delete: :delete, match_tenant?: true
      reference :published_by, on_delete: :nilify
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :latest do
      argument :site_id, :uuid, allow_nil?: false
      get? true
      filter expr(site_id == ^arg(:site_id))
      prepare build(sort: [version: :desc], limit: 1)
    end

    create :create do
      description "Trusted: used only by `Cloud.Policies`."
      primary? true
      accept [:site_id, :version, :policy, :published_by_id, :reason]
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

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :policy, :map do
      allow_nil? false
      public? true
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
    belongs_to :published_by, Cloud.Accounts.User, public?: true
  end

  identities do
    identity :unique_site_version, [:site_id, :version]
  end
end
