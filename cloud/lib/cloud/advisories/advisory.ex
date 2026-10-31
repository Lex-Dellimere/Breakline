defmodule Cloud.Advisories.Advisory do
  @moduledoc """
  One entry seen in a threat feed.

  - `source` is `:kev` or `:acsc` (both ACSC feeds share it, so the same
    alert in both is one advisory).
  - `external_id` is the KEV `cveID`, or for ACSC the slug of the normalised
    title, which is how ACSC duplicates under different links collapse.
  - `cves` are the CVE ids it names, `vendor` and `product` the KEV fields.
  - `tool_ids` are the `Breakline.Catalog` tools it matched, possibly none.
  - `exploitation` is `:active` for KEV and for ACSC text that says so,
    `:not_known` when the ACSC text says there is no known active
    exploitation, otherwise `:unknown`. It is informational only.
  - `raw` keeps the feed entry as received, plus for ACSC which rule matched
    (`"match"`).
  - `baseline?` marks entries recorded by a feed's first fetch; they are
    never acted on. `processed_at` is set once a non-baseline advisory has
    been acted on, so a poll that crashed half way picks it up next time.

  Advisories are global: any signed-in user may read them, only trusted code
  writes them.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Advisories,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "advisories"
    repo Cloud.Repo
  end

  actions do
    defaults [:read]

    read :seen_external_ids do
      description "Trusted: the advisories of a source among the given external ids."
      argument :source, :atom, allow_nil?: false
      argument :external_ids, {:array, :string}, allow_nil?: false
      filter expr(source == ^arg(:source) and external_id in ^arg(:external_ids))
    end

    read :kev_for_cves do
      description "Trusted: KEV advisories with tools for any of the given CVEs."
      argument :cves, {:array, :string}, allow_nil?: false

      filter expr(
               source == :kev and external_id in ^arg(:cves) and
                 fragment("cardinality(?) > 0", tool_ids)
             )
    end

    read :unprocessed do
      description "Trusted: advisories that still have to be acted on, oldest first."
      filter expr(baseline? == false and is_nil(processed_at))
      prepare build(sort: [first_seen_at: :asc, id: :asc])
    end

    create :record do
      description "Trusted: records a feed entry the first time it is seen."

      accept [
        :source,
        :external_id,
        :title,
        :cves,
        :vendor,
        :product,
        :tool_ids,
        :exploitation,
        :published_at,
        :link,
        :raw,
        :baseline?
      ]

      change set_attribute(:first_seen_at, &DateTime.utc_now/0)
    end

    update :mark_processed do
      description "Trusted: the advisory has been acted on."
      accept []
      change set_attribute(:processed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:kev, :acsc]
    end

    attribute :external_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 1000
    end

    attribute :cves, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :vendor, :string, public?: true
    attribute :product, :string, public?: true
    attribute :tool_ids, {:array, :string}, allow_nil?: false, default: [], public?: true

    attribute :exploitation, :atom do
      allow_nil? false
      public? true
      default :unknown
      constraints one_of: [:active, :not_known, :unknown]
    end

    attribute :published_at, :utc_datetime_usec, public?: true
    attribute :link, :string, public?: true
    attribute :raw, :map, allow_nil?: false, default: %{}

    attribute :baseline?, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :first_seen_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :processed_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_source_external_id, [:source, :external_id]
  end
end
