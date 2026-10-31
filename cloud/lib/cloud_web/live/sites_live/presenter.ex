defmodule CloudWeb.SitesLive.Presenter do
  @moduledoc """
  Turns a site's gateway status (the enforcer status of its last heartbeat, as
  `Gateway.Uplink.Encode.status/1` sends it) and events into the short,
  human-readable text the sites pages show. Pure functions, no data access.

  Times are shown in the site's own time zone.
  """

  @day_names ~w(Mon Tue Wed Thu Fri Sat Sun)

  @doc "`\"open\"`, `\"locked\"` or nil when the gateway never reported."
  @spec state(map() | nil) :: String.t() | nil
  def state(%{"state" => state}) when state in ["open", "locked"], do: state
  def state(_status), do: nil

  @doc "The gateway's mode, `\"enforce\"` or `\"monitor\"`, or nil."
  @spec mode(map() | nil) :: String.t() | nil
  def mode(%{"mode" => mode}) when is_binary(mode), do: mode
  def mode(_status), do: nil

  @doc "The policy version the gateway has applied, or nil."
  @spec applied_version(map() | nil) :: non_neg_integer() | nil
  def applied_version(%{"policy_version" => v}) when is_integer(v), do: v
  def applied_version(_status), do: nil

  @doc """
  Why the gateway is open or locked, for example `"Locked: no window"`,
  `"Open: window weeknights until 02:00"`, `"Locked: advisory lock
  kev:CVE-2026-1"` or `"Locked: gateway clock not synced"`. `windows` are the
  site's windows, used to describe the one the gateway reports.
  """
  @spec reason(map() | nil, [map()], String.t()) :: String.t()
  def reason(status, windows \\ [], time_zone \\ "Etc/UTC")

  def reason(%{"state" => _} = status, windows, time_zone) do
    case status["reason"] do
      %{"rule" => "window"} = r ->
        window = Enum.find(windows, &(&1.id == r["id"]))
        "Open: window" <> window_phrase(window) <> until(r["ends_at"], time_zone)

      %{"rule" => "break_glass"} = r ->
        by = if is_binary(r["approved_by"]), do: " (approved by #{r["approved_by"]})", else: ""
        "Open: break-glass" <> until(r["until"], time_zone) <> by

      %{"rule" => "advisory_lock", "source" => "manual"} = r ->
        "Locked: manual lock" <> detail(r["reason"])

      %{"rule" => "advisory_lock"} = r ->
        "Locked: advisory lock #{r["source"]}" <> detail(r["reason"], r["source"])

      %{"rule" => "default"} ->
        "Locked: no window"

      %{"rule" => "no_policy"} ->
        "Locked: no policy received yet"

      %{"rule" => "clock_unsynced"} ->
        "Locked: gateway clock not synced"

      _ ->
        String.capitalize(to_string(status["state"]))
    end
  end

  def reason(_status, _windows, _time_zone), do: "No heartbeat yet"

  defp detail(reason, same \\ nil)

  defp detail(reason, same) when is_binary(reason) and reason != "" and reason != same,
    do: " (#{reason})"

  defp detail(_reason, _same), do: ""

  defp until(iso, time_zone) do
    case local(iso, time_zone) do
      nil -> ""
      dt -> " until " <> Calendar.strftime(dt, "%H:%M")
    end
  end

  defp window_phrase(%{kind: :recurring, days: days, starts: starts, ends: ends}) do
    night? = Time.compare(ends, starts) != :gt or starts.hour >= 18

    phrase =
      case Enum.sort(days) do
        [1, 2, 3, 4, 5] -> if night?, do: "weeknights", else: "weekdays"
        [6, 7] -> "weekends"
        [1, 2, 3, 4, 5, 6, 7] -> if night?, do: "nightly", else: "daily"
        days -> Enum.map_join(days, ", ", &Enum.at(@day_names, &1 - 1))
      end

    " " <> phrase
  end

  defp window_phrase(%{kind: :one_off}), do: " one-off"
  defp window_phrase(_window), do: ""

  @doc """
  An iso8601 time (or a `DateTime`) as the site's local time, formatted with
  `format`, or nil.
  """
  @spec local_time(String.t() | DateTime.t() | nil, String.t(), String.t()) :: String.t() | nil
  def local_time(time, time_zone, format \\ "%a %d %b %H:%M") do
    case local(time, time_zone) do
      nil -> nil
      dt -> Calendar.strftime(dt, format)
    end
  end

  @doc """
  A start and end as one local range in the site's time zone, for example
  `"Mon 03 Nov 22:00–23:30"` on one day or `"Mon 03 Nov 22:00 – Tue 04 Nov
  02:00"` across midnight.
  """
  @spec local_range(DateTime.t(), DateTime.t(), String.t()) :: String.t()
  def local_range(starts_at, ends_at, time_zone) do
    with %DateTime{} = s <- local(starts_at, time_zone),
         %DateTime{} = e <- local(ends_at, time_zone) do
      if DateTime.to_date(s) == DateTime.to_date(e),
        do: Calendar.strftime(s, "%a %d %b %H:%M") <> "–" <> Calendar.strftime(e, "%H:%M"),
        else:
          Calendar.strftime(s, "%a %d %b %H:%M") <>
            " – " <> Calendar.strftime(e, "%a %d %b %H:%M")
    else
      _ -> ""
    end
  end

  defp local(%DateTime{} = dt, time_zone) do
    case DateTime.shift_zone(dt, time_zone, Tz.TimeZoneDatabase) do
      {:ok, local} -> local
      _ -> nil
    end
  end

  defp local(iso, time_zone) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> local(dt, time_zone)
      _ -> nil
    end
  end

  defp local(_time, _time_zone), do: nil

  @doc "A one-line summary of a gateway event's data."
  @spec event_summary(map()) :: String.t()
  def event_summary(%{type: type, data: data}) do
    case {type, data} do
      {t, %{"qname" => q} = d} when t in ["blocked", "would_block"] ->
        "#{q}" <> match_tag(d["match"])

      {"state_changed", d} ->
        state = if d["locked"], do: "locked", else: "open"
        "#{state}, #{d["mode"]}" <> rule(d["reason"])

      {"policy_applied", d} ->
        "policy v#{d["policy_version"]}"

      {"command_rejected", %{"reason" => %{"reason" => r}}} ->
        "rejected: #{r}"

      {"policy_result", d} ->
        "v#{d["policy_version"]} #{d["result"]}" <> detail(d["reason"])

      {"audit_chain_reset", d} ->
        "new audit chain " <> String.slice(to_string(d["chain_id"]), 0, 12)

      _ ->
        ""
    end
  end

  defp match_tag(%{"tag" => tag}) when is_binary(tag), do: " (#{tag})"
  defp match_tag(%{"kind" => kind}) when is_binary(kind), do: " (#{kind})"
  defp match_tag(_), do: ""

  defp rule(%{"rule" => rule}), do: " (#{rule})"
  defp rule(_), do: ""
end
