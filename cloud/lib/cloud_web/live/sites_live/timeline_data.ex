defmodule CloudWeb.SitesLive.TimelineData do
  @moduledoc """
  One site's history as a single stream, newest first, merged from four
  sources, all read as the signed-in user with the site's tenant:

    * `:gateway`: the events the gateway reported (`Cloud.Gateways.Event`)
    * `:audit`: the tenant's cloud audit entries about this site (entries
      whose data has the site's `site_id`), except `"policy.published"`,
      which the policy versions already show with more detail
    * `:policy`: the published policy versions, with their reason and who
      published them
    * `:notification`: the notifications sent about the site (only admins
      can read deliveries, so approvers see none)

  Pages are cut with a cursor, the `{time, kind, id}` key of the last item
  shown: items are ordered by that key, descending, and each source is asked
  only for items strictly after it, so a page boundary never skips or
  repeats an item, even when items share a timestamp.
  """

  alias Cloud.{Gateways, Notifications, Sites}
  alias Cloud.Accounts.User
  alias Cloud.Audit.Entry
  alias Cloud.Notifications.Event
  alias CloudWeb.SitesLive.Presenter

  require Ash.Query

  @kinds [:gateway, :audit, :policy, :notification]
  # the kind's place in the sort key, for items with the same time
  @rank %{gateway: 0, audit: 1, policy: 2, notification: 3}

  @type kind :: :gateway | :audit | :policy | :notification
  @type cursor :: {DateTime.t(), non_neg_integer(), String.t()} | nil
  @type item :: %{
          id: String.t(),
          kind: kind(),
          at: DateTime.t(),
          label: String.t(),
          summary: String.t(),
          actor: String.t() | nil,
          cursor: cursor()
        }

  @doc "Every kind, in display order."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A kind's name for the filter and badge."
  @spec kind_label(kind()) :: String.t()
  def kind_label(:gateway), do: "Gateway"
  def kind_label(:audit), do: "Cloud audit"
  def kind_label(:policy), do: "Policy"
  def kind_label(:notification), do: "Notification"

  @doc """
  One page of the site's timeline: up to `limit` items of the given `kinds`
  older than `cursor` (nil for the newest). Returns `{items, more?}`.
  """
  @spec page(User.t(), Sites.Site.t(), [kind()], cursor(), pos_integer(), keyword()) ::
          {[item()], boolean()}
  def page(%User{} = user, site, kinds, cursor, limit, opts \\ []) do
    ctx = %{user: user, site: site, cursor: cursor, limit: limit + 1, role: opts[:role]}

    items =
      kinds
      |> Enum.flat_map(&source(&1, ctx))
      |> Enum.sort_by(& &1.cursor, &(compare_keys(&1, &2) != :lt))
      |> Enum.take(limit + 1)

    {Enum.take(items, limit), length(items) > limit}
  end

  @doc "The timeline item for a gateway event, for live updates."
  @spec gateway_item(Gateways.Event.t()) :: item()
  def gateway_item(event) do
    %{
      id: "gateway-" <> event.id,
      kind: :gateway,
      at: event.at,
      label: event.type,
      summary: Presenter.event_summary(event),
      actor: "gateway",
      cursor: {event.at, @rank.gateway, event.id}
    }
  end

  defp compare_keys({a_at, a_rank, a_id}, {b_at, b_rank, b_id}) do
    case DateTime.compare(a_at, b_at) do
      :eq -> compare_terms({a_rank, a_id}, {b_rank, b_id})
      other -> other
    end
  end

  defp compare_terms(a, b) when a < b, do: :lt
  defp compare_terms(a, b) when a > b, do: :gt
  defp compare_terms(_a, _b), do: :eq

  # sources

  defp source(:gateway, ctx) do
    Gateways.list_events!(
      opts(ctx,
        filter: [site_id: ctx.site.id] ++ after_cursor(:at, :gateway, ctx.cursor),
        sort: [at: :desc, id: :desc],
        limit: ctx.limit
      )
    )
    |> Enum.map(&gateway_item/1)
  end

  defp source(:audit, ctx) do
    site_id = ctx.site.id

    query =
      Entry
      |> Ash.Query.filter(
        fragment("(? ->> 'site_id') = ?", entry, ^site_id) and
          fragment("(? ->> 'action') IS DISTINCT FROM 'policy.published'", entry)
      )
      |> Ash.Query.do_filter(after_cursor(:inserted_at, :audit, ctx.cursor))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(ctx.limit)

    entries =
      Ash.read!(query, actor: ctx.user, tenant: ctx.site.tenant_id)

    emails = Cloud.Accounts.emails_by_id(Enum.map(entries, & &1.actor_id))

    Enum.map(entries, fn entry ->
      %{
        id: "audit-" <> entry.id,
        kind: :audit,
        at: entry.inserted_at,
        label: to_string(entry.entry["action"]),
        summary: audit_summary(entry.entry, ctx.site.time_zone),
        actor: actor_name(entry.actor_id, emails),
        cursor: {entry.inserted_at, @rank.audit, entry.id}
      }
    end)
  end

  defp source(:policy, ctx) do
    versions =
      Sites.list_policy_versions!(
        opts(ctx,
          filter: [site_id: ctx.site.id] ++ after_cursor(:inserted_at, :policy, ctx.cursor),
          sort: [inserted_at: :desc, id: :desc],
          limit: ctx.limit
        )
      )

    emails = Cloud.Accounts.emails_by_id(Enum.map(versions, & &1.published_by_id))

    Enum.map(versions, fn version ->
      %{
        id: "policy-" <> version.id,
        kind: :policy,
        at: version.inserted_at,
        label: "v#{version.version}",
        summary: "published v#{version.version}: #{version.reason}",
        actor: actor_name(version.published_by_id, emails),
        cursor: {version.inserted_at, @rank.policy, version.id}
      }
    end)
  end

  defp source(:notification, %{role: :admin} = ctx) do
    Notifications.list_deliveries!(
      opts(ctx,
        filter: [site_id: ctx.site.id] ++ after_cursor(:inserted_at, :notification, ctx.cursor),
        sort: [inserted_at: :desc, id: :desc],
        limit: ctx.limit
      )
    )
    |> Enum.map(fn delivery ->
      %{
        id: "notification-" <> delivery.id,
        kind: :notification,
        at: delivery.inserted_at,
        label: Atom.to_string(delivery.status),
        summary:
          "#{Event.label(delivery.event_type)} to #{delivery.channel_name}" <>
            target(delivery.target_hint) <> error(delivery.last_error),
        actor: nil,
        cursor: {delivery.inserted_at, @rank.notification, delivery.id}
      }
    end)
  end

  # deliveries are for admins only
  defp source(:notification, _ctx), do: []

  defp opts(ctx, query), do: [actor: ctx.user, tenant: ctx.site.tenant_id, query: query]

  # the keyword filter for items of `kind` strictly after `cursor` in the descending
  # {time, kind, id} order
  defp after_cursor(_field, _kind, nil), do: []

  defp after_cursor(field, kind, {at, rank, id}) do
    own = @rank[kind]

    cond do
      own < rank -> [{field, [less_than_or_equal: at]}]
      own > rank -> [{field, [less_than: at]}]
      true -> [or: [[{field, [less_than: at]}], [{field, at}, {:id, [less_than: id]}]]]
    end
  end

  defp actor_name(nil, _emails), do: "system"
  defp actor_name(id, emails), do: Map.get(emails, id, "a removed user")

  defp audit_summary(entry, time_zone) do
    details =
      [
        entry["kind"],
        entry["reason"],
        entry["source"],
        entry["minutes"] && "#{entry["minutes"]} min",
        entry["until"] && "until #{Presenter.local_time(entry["until"], time_zone)}",
        entry["rejection_note"] && "note: #{entry["rejection_note"]}"
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    case details do
      [] -> humanise(entry["action"])
      details -> humanise(entry["action"]) <> " (" <> Enum.join(details, ", ") <> ")"
    end
  end

  defp humanise(action) when is_binary(action),
    do: action |> String.replace([".", "_"], " ")

  defp humanise(_action), do: "entry"

  defp target(hint) when is_binary(hint) and hint != "", do: " (#{hint})"
  defp target(_hint), do: ""

  defp error(error) when is_binary(error) and error != "", do: ": #{error}"
  defp error(_error), do: ""
end
