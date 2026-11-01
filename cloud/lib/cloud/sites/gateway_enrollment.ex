defmodule Cloud.Sites.GatewayEnrollment do
  @moduledoc """
  A one-time code that lets one gateway box enrol for one site.

  An admin issues it from the site page after a passkey step-up with purpose
  `:enroll_gateway`, subject the site and params `site_id`. The code is 160
  random bits, shown once as grouped base32 (`Cloud.Sites.GatewayEnrollments`);
  only its sha256 is stored (`code_hash`). It is valid for 30 minutes and can
  be used once. Issuing a code cancels the site's other pending codes, and an
  admin can cancel one by hand.

  The gateway presents the code to `CloudWeb.GatewayEnroll` on the gateway
  endpoint, over a TLS session in which it presented its own self-signed
  certificate. That certificate's fingerprint is pinned on the site and kept
  here (`gateway_cert_fingerprint`), with the fingerprint it replaced
  (`replaced_fingerprint`) and the client ip. Issue, use and cancel are each
  recorded in the tenant's audit chain; a use is recorded with no actor (the
  system).

  The resource is `global?` multitenant so the enrolment endpoint can find a
  code by its hash without knowing the tenant; actors always need the tenant.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Sites,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Cloud.Accounts.Changes.RequireStepUp
  alias Cloud.Audit.Changes.Record
  alias Cloud.Checks.TenantMember

  postgres do
    table "gateway_enrollments"
    repo Cloud.Repo

    references do
      reference :site, on_delete: :delete, match_tenant?: true
      reference :created_by, on_delete: :nilify
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    read :lock_by_code_hash do
      description "Trusted: finds a code by its sha256 with a row lock, see `Cloud.Sites.GatewayEnrollments.enroll/3`."
      get_by [:code_hash]
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    read :pending do
      description "The site's codes that can still be used at `now`."
      argument :site_id, :uuid, allow_nil?: false
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               site_id == ^arg(:site_id) and is_nil(used_at) and is_nil(cancelled_at) and
                 expires_at > ^arg(:now)
             )

      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    create :issue do
      primary? true
      transaction? true
      accept [:site_id]
      argument :step_up_id, :uuid

      change {RequireStepUp, purpose: :enroll_gateway, subject: :site_id, params: [:site_id]}
      change Cloud.Sites.Changes.EnrollmentCode
      change relate_actor(:created_by)

      change {Record,
              action: "gateway_enrollment.issued",
              fields: [:site_id, :expires_at, :replaced_fingerprint]}
    end

    update :cancel do
      require_atomic? false
      transaction? true
      accept []
      validate attribute_equals(:used_at, nil), message: "is already used"
      validate attribute_equals(:cancelled_at, nil), message: "is already cancelled"
      change set_attribute(:cancelled_at, &DateTime.utc_now/0)
      change {Record, action: "gateway_enrollment.cancelled", fields: [:site_id]}
    end

    update :use do
      description "Trusted: records the gateway certificate that used the code."
      require_atomic? false
      transaction? true
      accept [:gateway_cert_fingerprint, :replaced_fingerprint, :remote_ip]
      validate match(:gateway_cert_fingerprint, ~r/^[0-9a-f]{64}$/)
      change set_attribute(:used_at, &DateTime.utc_now/0)

      change {Record,
              action: "gateway_enrollment.used",
              fields: [:site_id, :gateway_cert_fingerprint, :replaced_fingerprint, :remote_ip]}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {TenantMember, role: :admin}
    end

    policy action([:issue, :cancel]) do
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

    attribute :code_hash, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :used_at, :utc_datetime_usec, public?: true
    attribute :cancelled_at, :utc_datetime_usec, public?: true
    attribute :gateway_cert_fingerprint, :string, public?: true
    attribute :replaced_fingerprint, :string, public?: true
    attribute :remote_ip, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false, public?: true
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
    belongs_to :created_by, Cloud.Accounts.User, public?: true
  end

  identities do
    identity :unique_code_hash, [:code_hash], all_tenants?: true
  end
end
