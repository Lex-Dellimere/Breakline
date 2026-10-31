defmodule CloudWeb.SitesLive.PresenterTest do
  use ExUnit.Case, async: true

  alias CloudWeb.SitesLive.Presenter

  @tz "Australia/Sydney"

  defp reason(r, windows \\ []),
    do: Presenter.reason(%{"state" => "x", "reason" => r}, windows, @tz)

  test "reasons read as a sentence" do
    assert Presenter.reason(nil, [], @tz) == "No heartbeat yet"
    assert reason(%{"rule" => "default"}) == "Locked: no window"
    assert reason(%{"rule" => "clock_unsynced"}) == "Locked: gateway clock not synced"
    assert reason(%{"rule" => "no_policy"}) == "Locked: no policy received yet"

    assert reason(%{
             "rule" => "advisory_lock",
             "source" => "kev:CVE-2026-1",
             "reason" => "kev:CVE-2026-1"
           }) ==
             "Locked: advisory lock kev:CVE-2026-1"

    assert reason(%{"rule" => "advisory_lock", "source" => "manual", "reason" => "audit"}) ==
             "Locked: manual lock (audit)"

    assert reason(%{
             "rule" => "break_glass",
             "until" => "2026-11-02T01:30:00Z",
             "approved_by" => "a@b"
           }) ==
             "Open: break-glass until 12:30 (approved by a@b)"
  end

  test "windows are described by their days" do
    w = fn days, starts, ends ->
      %{id: "w", kind: :recurring, days: days, starts: starts, ends: ends}
    end

    r = %{"rule" => "window", "id" => "w", "ends_at" => "2026-11-02T15:00:00Z"}

    assert reason(r, [w.([1, 2, 3, 4, 5], ~T[22:00:00], ~T[02:00:00])]) ==
             "Open: window weeknights until 02:00"

    assert reason(r, [w.([1, 2, 3, 4, 5], ~T[09:00:00], ~T[17:00:00])]) ==
             "Open: window weekdays until 02:00"

    assert reason(r, [w.([6, 7], ~T[09:00:00], ~T[17:00:00])]) ==
             "Open: window weekends until 02:00"

    assert reason(r, [w.([1, 3], ~T[09:00:00], ~T[17:00:00])]) ==
             "Open: window Mon, Wed until 02:00"

    assert reason(r, [%{id: "w", kind: :one_off}]) == "Open: window one-off until 02:00"
    assert reason(r) == "Open: window until 02:00"
  end

  test "event summaries" do
    assert Presenter.event_summary(%{
             type: "blocked",
             data: %{
               "qname" => "x.anydesk.com",
               "match" => %{"kind" => "tool", "tag" => "anydesk"}
             }
           }) == "x.anydesk.com (anydesk)"

    assert Presenter.event_summary(%{
             type: "policy_result",
             data: %{"policy_version" => 3, "result" => "rejected", "reason" => "stale_version"}
           }) == "v3 rejected (stale_version)"

    assert Presenter.event_summary(%{type: "other", data: %{}}) == ""
  end
end
