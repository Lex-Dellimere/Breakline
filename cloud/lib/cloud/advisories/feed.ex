defmodule Cloud.Advisories.Feed do
  @moduledoc """
  The fetch state of one threat feed: `:kev` (CISA KEV json), `:acsc_alerts`
  and `:acsc_advisories` (ACSC RSS).

  - `etag` and `last_modified` are the validators of the last successful
    response, sent back as a conditional GET so an unchanged feed costs a 304.
  - `last_fetched_at` and `last_status` describe the last attempt
    (`"ok"`, `"not_modified"` or `"error: ..."`).
  - `baseline_at` is when the first successful fetch recorded the feed's
    entries as already seen. Until it is set, nothing from the feed is acted
    on.

  The `:poll` action fetches and processes a feed (`Cloud.Advisories.Poller`).
  ash_oban schedules it every 30 minutes for each feed on the `:advisories`
  queue, KEV first so the ACSC polls a few minutes later can match CVEs KEV
  already knows. Feeds are global: signed-in users may read them; only
  trusted code and the scheduled jobs write.
  """

  use Ash.Resource,
    otp_app: :cloud,
    domain: Cloud.Advisories,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  @names [:kev, :acsc_alerts, :acsc_advisories]

  postgres do
    table "advisory_feeds"
    repo Cloud.Repo
  end

  oban do
    scheduled_actions do
      schedule :poll_kev, "*/30 * * * *" do
        action :poll
        action_input %{feed: :kev}
        queue :advisories
        max_attempts 3
        worker_module_name Cloud.Advisories.Feed.AshOban.ActionWorker.PollKev
      end

      schedule :poll_acsc_alerts, "5,35 * * * *" do
        action :poll
        action_input %{feed: :acsc_alerts}
        queue :advisories
        max_attempts 3
        worker_module_name Cloud.Advisories.Feed.AshOban.ActionWorker.PollAcscAlerts
      end

      schedule :poll_acsc_advisories, "10,40 * * * *" do
        action :poll
        action_input %{feed: :acsc_advisories}
        queue :advisories
        max_attempts 3
        worker_module_name Cloud.Advisories.Feed.AshOban.ActionWorker.PollAcscAdvisories
      end
    end
  end

  actions do
    defaults [:read]

    create :ensure do
      description "Trusted: finds or creates the state row of a feed."
      accept [:name]
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:name]
    end

    update :record_fetch do
      description "Trusted: records the outcome of a fetch."
      accept [:etag, :last_modified, :last_fetched_at, :last_status, :baseline_at]
    end

    action :poll, :map do
      description "Fetches a feed, records new advisories and acts on them."

      argument :feed, :atom do
        allow_nil? false
        constraints one_of: @names
      end

      run fn input, _context ->
        feed = input.arguments.feed

        case Cloud.Advisories.Poller.poll(feed) do
          {:ok, summary} -> {:ok, summary}
          {:error, reason} -> {:error, "poll of #{feed} failed: #{inspect(reason)}"}
        end
      end
    end
  end

  policies do
    # the scheduled poll jobs
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :atom do
      allow_nil? false
      public? true
      constraints one_of: @names
    end

    attribute :etag, :string, public?: true
    attribute :last_modified, :string, public?: true
    attribute :last_fetched_at, :utc_datetime_usec, public?: true
    attribute :last_status, :string, public?: true
    attribute :baseline_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_name, [:name]
  end
end
