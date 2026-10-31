defmodule Cloud.Audit.Head do
  @moduledoc """
  The head of a tenant's cloud audit chain: the `seq` and `hash` of its newest
  `Cloud.Audit.Entry`, or nil for both while the chain is empty.

  Appending locks this row (`:lock` upserts it, which takes a row lock until
  the transaction ends), so appends for one tenant serialise and get
  consecutive seqs, while different tenants never wait for each other.

  Trusted only: there are no actor policies, everything runs with
  `authorize?: false` through `Cloud.Audit`.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "audit_heads"
    repo Cloud.Repo

    references do
      reference :tenant, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :lock do
      description "Trusted: creates the head if needed and row-locks it until the transaction ends."
      accept [:tenant_id]
      upsert? true
      upsert_fields [:updated_at]
    end

    update :advance do
      description "Trusted: moves the head to the entry just appended."
      accept [:seq, :hash]
    end
  end

  attributes do
    attribute :seq, :integer, public?: true
    attribute :hash, :string, public?: true
    timestamps()
  end

  relationships do
    belongs_to :tenant, Cloud.Accounts.Tenant do
      primary_key? true
      allow_nil? false
      public? true
    end
  end
end
