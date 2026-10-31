defmodule Cloud.Gateways.AuditRecord do
  @moduledoc """
  A copy of one entry of a gateway's audit chain (`Breakline.AuditLog`), kept
  in the cloud so the chain can be exported and verified, and its head
  anchored outside the gateway (threat model T9).

  `chain_id` names one chain: a gateway starts a new chain when it finds its
  old one broken. `seq` and `hash` are the entry's position and hash,
  `record` the entry as sent. Each `(site, chain_id, seq)` is stored once.

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
    table "gateway_audit_records"
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
      accept [:site_id, :chain_id, :seq, :hash, :record]
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

    attribute :chain_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :seq, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :hash, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[0-9a-f]{64}$/
    end

    attribute :record, :map do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant, allow_nil?: false
    belongs_to :site, Cloud.Sites.Site, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_site_chain_seq, [:site_id, :chain_id, :seq]
  end
end
