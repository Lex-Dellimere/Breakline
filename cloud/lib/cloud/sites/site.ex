defmodule Cloud.Sites.Site do
  @moduledoc """
  A client location with one Breakline gateway.

  - `time_zone` is the IANA zone all of the site's windows are written in.
  - `mode` is `:monitor` (log would-blocks only, for pilots) or `:enforce`.
  - `tool_ids` are the `Breakline.Catalog` tools the MSP uses at this site.
  - `site_hosts` are extra hostnames, ips or CIDRs to block while locked, for
    example a self-hosted RMM server.
  - `policy_version` is the last published version; only
    `Cloud.Policies.publish/2` changes it.
  - The `gateway_*` fields belong to the gateway connection: the sha256
    fingerprint of its client certificate (lowercase hex of the DER), when it
    was last seen, its last heartbeat status and the head of its audit chain
    as last anchored by the cloud (`%{"seq" => n, "hash" => hex}`).

  Members of the tenant can read sites, admins create and edit them. Editing
  a site publishes a new policy version. The site resource is
  `global?` multitenant so trusted server code (publishing, the gateway
  channel) can find a site by id or certificate without knowing its tenant;
  actors always need the tenant.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Checks.TenantMember
  alias Cloud.Sites.Validations

  postgres do
    table "sites"
    repo Cloud.Repo

    references do
      reference :tenant, on_delete: :delete
    end

    custom_indexes do
      # lets tenant-scoped children use a composite (site_id, tenant_id) foreign key,
      # so a record can never point at another tenant's site
      index [:id, :tenant_id], unique: true, all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    read :lock_for_publish do
      description "Trusted: reads one site with a row lock, used by `Cloud.Policies`."
      get_by [:id]
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    read :by_gateway_fingerprint do
      description "Trusted: finds the site of a gateway client certificate."
      get_by [:gateway_cert_fingerprint]
    end

    create :create do
      primary? true
      accept [:name, :time_zone, :mode, :tool_ids, :site_hosts]
      change {Cloud.Sites.Changes.NormaliseSiteHosts, []}
      validate {Validations.TimeZone, []}
      validate {Validations.ToolIds, []}
      validate {Validations.SiteHosts, []}
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept [:name, :time_zone, :mode, :tool_ids, :site_hosts]
      change {Cloud.Sites.Changes.NormaliseSiteHosts, []}
      validate {Validations.TimeZone, []}
      validate {Validations.ToolIds, []}
      validate {Validations.SiteHosts, []}
      change {Cloud.Sites.Changes.Publish, site_field: :id, reason: "site updated"}
    end

    update :assign_gateway do
      description "Pins the gateway client certificate allowed to connect for this site."
      accept [:gateway_cert_fingerprint]
      validate match(:gateway_cert_fingerprint, ~r/^[0-9a-f]{64}$/)
    end

    update :bump_policy_version do
      description "Trusted: used only by `Cloud.Policies.publish_in_transaction/2`."
      accept []
      change atomic_update(:policy_version, expr(policy_version + 1))
    end

    update :record_heartbeat do
      description "Trusted: the gateway channel records a heartbeat."
      accept [:gateway_status]
      change set_attribute(:gateway_last_seen_at, &DateTime.utc_now/0)
    end

    update :anchor_audit do
      description "Trusted: the gateway channel anchors the head of the gateway audit chain."
      accept [:gateway_audit_chain_id, :gateway_audit_head]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if TenantMember
    end

    policy action([:create, :update, :assign_gateway]) do
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

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :time_zone, :string do
      allow_nil? false
      public? true
    end

    attribute :mode, :atom do
      allow_nil? false
      public? true
      default :monitor
      constraints one_of: [:enforce, :monitor]
    end

    attribute :tool_ids, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :site_hosts, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :policy_version, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :gateway_cert_fingerprint, :string, public?: true
    attribute :gateway_last_seen_at, :utc_datetime_usec, public?: true
    attribute :gateway_status, :map, public?: true
    attribute :gateway_audit_chain_id, :string, public?: true
    attribute :gateway_audit_head, :map, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant do
      allow_nil? false
      public? true
    end

    has_many :windows, Cloud.Sites.Window
    has_many :advisory_locks, Cloud.Sites.AdvisoryLock
    has_many :break_glasses, Cloud.Sites.BreakGlass
    has_many :policy_versions, Cloud.Sites.PolicyVersion
  end

  identities do
    identity :unique_gateway_cert_fingerprint, [:gateway_cert_fingerprint], all_tenants?: true
  end
end
