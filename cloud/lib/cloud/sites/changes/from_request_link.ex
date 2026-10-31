defmodule Cloud.Sites.Changes.FromRequestLink do
  @moduledoc """
  Turns a window request made through a `Cloud.Sites.RequestLink` (the
  link is the actor) into exactly what a link may ask for (threat model T6):

  - The site, the requesting contact and the link come from the link; the
    window is always `:one_off`, whatever the caller sent.
  - `reason` (a reason or ticket reference) is required.
  - The start may not be more than 5 minutes in the past and the window may
    be at most 12 hours long. Both are checked in UTC after resolving the
    local times in the site's zone the way `Breakline.Schedule` does (a
    repeated local start takes the later instant, a repeated end the earlier
    one, a skipped time the transition instant).
  - Caps per link: at most 3 requests still waiting for a decision, and at
    most 10 requests in any 24 hours. They are counted inside the action's
    transaction with the link's row locked, so concurrent requests cannot
    overshoot, and the link is re-checked there (a link revoked a moment ago
    stops working). A successful request sets the link's `last_used_at`.

  Requests from any other actor pass through unchanged.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Cloud.Sites
  alias Cloud.Sites.{RequestLink, RequestLinks, Window}

  @slack_seconds 5 * 60
  @max_seconds 12 * 3600
  @max_pending 3
  @max_per_day 10

  @doc "The caps a link's requests are held to."
  def limits,
    do: %{
      slack_seconds: @slack_seconds,
      max_seconds: @max_seconds,
      max_pending: @max_pending,
      max_per_day: @max_per_day
    }

  @impl true
  def change(changeset, _opts, %{actor: %RequestLink{} = link}) do
    changeset
    |> Ash.Changeset.force_change_attributes(
      site_id: link.site_id,
      requested_by_id: link.msp_contact_id,
      request_link_id: link.id,
      kind: :one_off,
      days: nil,
      starts: nil,
      ends: nil
    )
    |> require_reason()
    |> check_times(link)
    |> Ash.Changeset.before_action(&check_caps(&1, link.id))
  end

  def change(changeset, _opts, _context), do: changeset

  defp require_reason(changeset) do
    case Ash.Changeset.get_attribute(changeset, :reason) do
      reason when is_binary(reason) and reason != "" ->
        if String.trim(reason) == "", do: add(changeset, :reason, "is required"), else: changeset

      _ ->
        add(changeset, :reason, "is required")
    end
  end

  defp check_times(changeset, link) do
    starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)
    ends_at = Ash.Changeset.get_attribute(changeset, :ends_at)

    with %NaiveDateTime{} <- starts_at,
         %NaiveDateTime{} <- ends_at,
         {:ok, %{time_zone: time_zone}} <-
           Sites.get_site(link.site_id, authorize?: false, not_found_error?: false) do
      start_utc = to_utc(starts_at, time_zone, :start)
      end_utc = to_utc(ends_at, time_zone, :end)
      earliest = DateTime.add(DateTime.utc_now(), -@slack_seconds, :second)

      changeset
      |> then(fn cs ->
        if DateTime.compare(start_utc, earliest) == :lt,
          do: add(cs, :starts_at, "must not be in the past"),
          else: cs
      end)
      |> then(fn cs ->
        if DateTime.diff(end_utc, start_utc, :second) > @max_seconds,
          do: add(cs, :ends_at, "must be at most 12 hours after the start"),
          else: cs
      end)
    else
      # missing times are reported by the window shape validation
      _ -> changeset
    end
  end

  defp check_caps(changeset, link_id) do
    with {:ok, %RequestLink{} = link} <-
           Sites.lock_request_link(link_id, authorize?: false, not_found_error?: false),
         true <- RequestLinks.usable?(link) || :unusable,
         :ok <- under_caps(link),
         {:ok, _link, _notifications} <-
           Sites.touch_request_link(link, authorize?: false, return_notifications?: true) do
      changeset
    else
      {:cap, message} -> add(changeset, :starts_at, message)
      _ -> add(changeset, :request_link_id, "this link is not valid")
    end
  end

  defp under_caps(link) do
    since = DateTime.add(DateTime.utc_now(), -86_400, :second)

    pending =
      count(link, Ash.Query.filter(Window, request_link_id == ^link.id and status == :requested))

    today =
      count(link, Ash.Query.filter(Window, request_link_id == ^link.id and inserted_at > ^since))

    cond do
      pending >= @max_pending ->
        {:cap, "this link already has #{@max_pending} requests waiting for a decision"}

      today >= @max_per_day ->
        {:cap, "this link has made #{@max_per_day} requests in the last 24 hours, try later"}

      true ->
        :ok
    end
  end

  defp count(link, query), do: Ash.count!(query, tenant: link.tenant_id, authorize?: false)

  # the same resolution of local times as Breakline.Schedule
  defp to_utc(naive, time_zone, bound) do
    case DateTime.from_naive(naive, time_zone, Tz.TimeZoneDatabase) do
      {:ok, dt} -> dt
      {:ambiguous, earlier, later} -> if bound == :start, do: later, else: earlier
      {:gap, _just_before, just_after} -> just_after
    end
    |> DateTime.shift_zone!("Etc/UTC", Tz.TimeZoneDatabase)
  end

  defp add(changeset, field, message) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)
    )
  end
end
