defmodule Cloud.Sites.Changes.OpenNowSpan do
  @moduledoc """
  Sets `starts_at` and `ends_at` of an "open now" window from the `minutes`
  argument, in the site's local time and rounded outward to whole minutes
  (`local_span/3`).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    with site_id when is_binary(site_id) <- Ash.Changeset.get_attribute(changeset, :site_id),
         minutes when is_integer(minutes) <- Ash.Changeset.get_argument(changeset, :minutes),
         {:ok, %{time_zone: time_zone}} <-
           Cloud.Sites.get_site(site_id, authorize?: false, not_found_error?: false) do
      {starts_at, ends_at} = local_span(DateTime.utc_now(), minutes, time_zone)
      Ash.Changeset.force_change_attributes(changeset, starts_at: starts_at, ends_at: ends_at)
    else
      _ -> Ash.Changeset.add_error(changeset, field: :site_id, message: "is not a known site")
    end
  end

  @doc """
  The local naive span `[now floored to the minute, now + minutes ceiled to
  the minute)` in `time_zone`.
  """
  @spec local_span(DateTime.t(), pos_integer(), String.t()) ::
          {NaiveDateTime.t(), NaiveDateTime.t()}
  def local_span(now, minutes, time_zone) do
    to_local = fn utc ->
      utc |> DateTime.shift_zone!(time_zone, Tz.TimeZoneDatabase) |> DateTime.to_naive()
    end

    starts_at = now |> to_local.() |> floor_minute()
    ends_local = now |> DateTime.add(minutes * 60, :second) |> to_local.()
    floored = floor_minute(ends_local)

    ends_at =
      if NaiveDateTime.compare(floored, ends_local) == :eq,
        do: floored,
        else: NaiveDateTime.add(floored, 60, :second)

    {starts_at, ends_at}
  end

  defp floor_minute(naive), do: %{naive | second: 0, microsecond: {0, 0}}
end
