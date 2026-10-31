defmodule Cloud.Advisories do
  @moduledoc """
  Threat-feed advisories and what they did to each site.

  Breakline polls CISA's Known Exploited Vulnerabilities catalogue (KEV) and
  the ACSC alerts and advisories RSS feeds (`Cloud.Advisories.Feed`), keeps
  every entry it has seen (`Cloud.Advisories.Advisory`) and matches it to the
  `Breakline.Catalog` tools. A new entry that names a tool a site uses either
  locks the site straight away or asks the tenant's approvers to confirm
  (`Cloud.Advisories.SiteAdvisory`):

  - a KEV entry locks every matching site of a tenant whose `advisory_mode`
    is `:auto_lock` and asks in tenants set to `:ask`;
  - an ACSC-only match always asks, because ACSC entries are free text.

  The first successful fetch of a feed is its baseline: everything in it is
  recorded as seen and nothing is acted on, so years-old KEV entries do not
  lock every site on the first day.

  `Feed` and `Advisory` are global (feeds are public data); `SiteAdvisory` is
  tenant-scoped. Feeds can only add locks, never open access.

  Each site advisory status change is broadcast as
  `{:advisory, %{tenant_id: ..., site_id: ..., advisory_id: ..., status: ...}}`
  on `notifications_topic/1` of its tenant after it commits.
  """

  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Cloud.Advisories.Feed do
      define :list_feeds, action: :read
      define :ensure_feed, action: :ensure, args: [:name]
      define :record_fetch, action: :record_fetch
      define :poll_feed, action: :poll, args: [:feed]
    end

    resource Cloud.Advisories.Advisory do
      define :list_advisories, action: :read
      define :seen_external_ids, action: :seen_external_ids, args: [:source, :external_ids]
      define :kev_advisories_for_cves, action: :kev_for_cves, args: [:cves]
      define :unprocessed_advisories, action: :unprocessed
      define :mark_advisory_processed, action: :mark_processed
    end

    resource Cloud.Advisories.SiteAdvisory do
      define :list_site_advisories, action: :read
      define :get_site_advisory, action: :read, get_by: [:id]
      define :record_site_advisory, action: :record
      define :confirm_lock, action: :confirm_lock
      define :dismiss_site_advisory, action: :dismiss
    end
  end

  @feeds [:kev, :acsc_alerts, :acsc_advisories]

  @doc "The feeds Breakline polls, in the order `poll_all/1` polls them."
  @spec feeds() :: [atom()]
  def feeds, do: @feeds

  @doc "The PubSub topic for a tenant's notifications: `\"tenant:<tenant_id>:notifications\"`."
  @spec notifications_topic(String.t()) :: String.t()
  def notifications_topic(tenant_id), do: "tenant:" <> tenant_id <> ":notifications"

  @doc """
  Polls one feed now, in the calling process, and returns its summary (see
  `Cloud.Advisories.Poller.poll/2`). This is a trusted path.
  """
  @spec poll(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def poll(feed, opts \\ []) when feed in @feeds, do: Cloud.Advisories.Poller.poll(feed, opts)

  @doc """
  Polls every feed now, KEV first so ACSC entries can be matched by the CVEs
  KEV already knows. Returns `[{feed, result}]`.
  """
  @spec poll_all(keyword()) :: [{atom(), {:ok, map()} | {:error, term()}}]
  def poll_all(opts \\ []), do: Enum.map(@feeds, &{&1, poll(&1, opts)})

  @doc """
  Enqueues the scheduled poll job of every feed to run now, as the 30 minute
  cron would. Used by the dev-only "poll now" button.
  """
  @spec enqueue_polls() :: [Oban.Job.t()]
  def enqueue_polls do
    Enum.map(@feeds, &AshOban.schedule(Cloud.Advisories.Feed, :"poll_#{&1}"))
  end
end
