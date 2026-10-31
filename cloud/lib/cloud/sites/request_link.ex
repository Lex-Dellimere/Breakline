defmodule Cloud.Sites.RequestLink do
  @moduledoc """
  A magic link that lets one MSP contact request maintenance windows for one
  site, without an account (threat model T6).

  The link's token is 32 random bytes, sent to the contact by email as part
  of the URL `/request/<token>`. Only the sha256 of the token is stored
  (`token_hash`), so the database alone can never be used to make a working
  link. A link expires 14 days after it was made and an admin can revoke it
  sooner. `last_used_at` is when it last requested a window.

  A link can only ever request: used as the actor of `Cloud.Sites.Window`'s
  `:request` action it creates a one-off window in status `:requested` for its
  own site and contact (`Cloud.Sites.Changes.FromRequestLink`). Nothing a link
  can do approves or opens anything; that needs an approver's passkey.

  Admins create and revoke links, and both are recorded in the tenant's audit
  chain. Creating one emails the link to the contact
  (`Cloud.Sites.RequestLinkEmail`); the raw token is handed back once, in the
  created record's `:token` metadata, and never again.

  The resource is `global?` multitenant so the public request page can find a
  link by its token hash without knowing the tenant
  (`Cloud.Sites.RequestLinks.lookup/1`, trusted); actors always need the
  tenant.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Audit.Changes.Record
  alias Cloud.Checks.TenantMember

  postgres do
    table "request_links"
    repo Cloud.Repo

    references do
      reference :site, on_delete: :delete, match_tenant?: true
      reference :msp_contact, on_delete: :delete, match_tenant?: true
      reference :created_by, on_delete: :nilify
      reference :tenant, on_delete: :delete
    end

    custom_indexes do
      # target of the windows (request_link_id, tenant_id) foreign key
      index [:id, :tenant_id], unique: true, all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    read :by_token_hash do
      description "Trusted: finds a link by the sha256 of its token, see `Cloud.Sites.RequestLinks.lookup/1`."
      get_by [:token_hash]
    end

    read :lock do
      description "Trusted: one link with a row lock, so its request caps hold under concurrency."
      get_by [:id]
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    create :create do
      primary? true
      transaction? true
      accept [:site_id, :msp_contact_id]
      change Cloud.Sites.Changes.RequestLinkToken
      change relate_actor(:created_by)

      change {Record,
              action: "request_link.created", fields: [:site_id, :msp_contact_id, :expires_at]}

      change Cloud.Sites.Changes.SendRequestLink
    end

    update :revoke do
      require_atomic? false
      transaction? true
      accept []
      validate attribute_equals(:revoked_at, nil), message: "is already revoked"
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
      change {Record, action: "request_link.revoked", fields: [:site_id, :msp_contact_id]}
    end

    update :touch do
      description "Trusted: records that the link just requested a window."
      accept []
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {TenantMember, role: :admin}
    end

    policy action([:create, :revoke]) do
      authorize_if {TenantMember, role: :admin}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :token_hash, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true
    attribute :last_used_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false, public?: true
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
    belongs_to :msp_contact, Cloud.Sites.MspContact, allow_nil?: false, public?: true
    belongs_to :created_by, Cloud.Accounts.User, public?: true
  end

  identities do
    identity :unique_token_hash, [:token_hash], all_tenants?: true
  end
end
