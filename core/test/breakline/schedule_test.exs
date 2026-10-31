defmodule Breakline.ScheduleTest do
  use ExUnit.Case, async: true

  alias Breakline.{Policy, Schedule}

  defp policy(tz, overrides \\ []) do
    {:ok, policy} =
      [site_id: "site-1", version: 1, mode: :enforce, time_zone: tz]
      |> Keyword.merge(overrides)
      |> Policy.new()

    policy
  end

  defp weekly(id, days, starts, ends), do: %{id: id, days: days, starts: starts, ends: ends}

  defp one_off(id, starts_at, ends_at), do: %{id: id, starts_at: starts_at, ends_at: ends_at}

  defp lock(id, expires_at \\ nil),
    do: %{id: id, reason: "exploited", source: "kev:CVE-2026-18577", expires_at: expires_at}

  # a window open all week in sydney time, so precedence tests have an open baseline
  defp always_open, do: weekly("always", [1, 2, 3, 4, 5, 6, 7], ~T[00:00:00], ~T[23:59:00])

  defp occurrences(p, from, to),
    do: Enum.map(Schedule.windows_between(p, from, to), fn {s, e, id} -> {id, s, e} end)

  describe "precedence" do
    test "default is locked" do
      p = policy("Australia/Sydney")
      assert Schedule.explain(p, ~U[2026-10-31 00:00:00Z]) == {:locked, :default}
      assert Schedule.state_at(p, ~U[2026-10-31 00:00:00Z]) == :locked
    end

    test "an active window opens" do
      p = policy("Australia/Sydney", recurring_windows: [always_open()])
      at = ~U[2026-10-31 00:00:00Z]

      assert {:open, {:window, "always", {s, e}}} = Schedule.explain(p, at)
      assert DateTime.compare(s, at) != :gt and DateTime.compare(at, e) == :lt
    end

    test "break-glass opens over the default" do
      p =
        policy("Australia/Sydney",
          break_glass: %{until: ~U[2026-11-01 00:00:00Z], approved_by: "a"}
        )

      assert {:open, {:break_glass, %{approved_by: "a"}}} =
               Schedule.explain(p, ~U[2026-10-31 00:00:00Z])
    end

    test "break-glass wins over a window" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [always_open()],
          break_glass: %{until: ~U[2026-11-01 00:00:00Z], approved_by: "a"}
        )

      assert {:open, {:break_glass, _}} = Schedule.explain(p, ~U[2026-10-31 00:00:00Z])
    end

    test "an advisory lock wins over break-glass and windows" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [always_open()],
          break_glass: %{until: ~U[2026-11-01 00:00:00Z], approved_by: "a"},
          advisory_locks: [lock("expired", ~U[2026-10-01 00:00:00Z]), lock("kev")]
        )

      assert {:locked, {:advisory_lock, %{id: "kev"}}} =
               Schedule.explain(p, ~U[2026-10-31 00:00:00Z])

      assert Schedule.state_at(p, ~U[2026-10-31 00:00:00Z]) == :locked
    end

    test "mode does not change the schedule" do
      for mode <- [:enforce, :monitor] do
        p = policy("Australia/Sydney", mode: mode, recurring_windows: [always_open()])
        assert Schedule.state_at(p, ~U[2026-10-31 00:00:00Z]) == :open
      end
    end
  end

  describe "expiry boundaries" do
    test "an advisory lock is active strictly before expires_at" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [always_open()],
          advisory_locks: [lock("kev", ~U[2026-10-31 12:00:00Z])]
        )

      assert Schedule.state_at(p, ~U[2026-10-31 11:59:59Z]) == :locked
      assert Schedule.state_at(p, ~U[2026-10-31 12:00:00Z]) == :open
      assert Schedule.next_change(p, ~U[2026-10-31 11:00:00Z]) == ~U[2026-10-31 12:00:00Z]
    end

    test "a lock without expiry never ends" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [always_open()],
          advisory_locks: [lock("kev")]
        )

      assert Schedule.state_at(p, ~U[2099-01-01 00:00:00Z]) == :locked
    end

    test "break-glass is active strictly before until" do
      p =
        policy("Australia/Sydney",
          break_glass: %{until: ~U[2026-10-31 12:00:00Z], approved_by: "a"}
        )

      assert Schedule.state_at(p, ~U[2026-10-31 11:59:59Z]) == :open
      assert Schedule.state_at(p, ~U[2026-10-31 12:00:00Z]) == :locked
      assert Schedule.next_change(p, ~U[2026-10-31 11:00:00Z]) == ~U[2026-10-31 12:00:00Z]
      assert Schedule.next_change(p, ~U[2026-10-31 12:00:00Z]) == nil
    end

    test "window occurrences are half-open" do
      # brisbane is utc+10 all year, monday 09:00-17:00 local is sunday 23:00z to monday 07:00z
      p =
        policy("Australia/Brisbane",
          recurring_windows: [weekly("bus", [1], ~T[09:00:00], ~T[17:00:00])]
        )

      assert Schedule.state_at(p, ~U[2026-11-01 22:59:59Z]) == :locked
      assert Schedule.state_at(p, ~U[2026-11-01 23:00:00Z]) == :open
      assert Schedule.state_at(p, ~U[2026-11-02 06:59:59Z]) == :open
      assert Schedule.state_at(p, ~U[2026-11-02 07:00:00Z]) == :locked
      assert Schedule.state_at(p, ~U[2026-11-02 07:00:00.000001Z]) == :locked
    end
  end

  describe "recurring windows" do
    test "a window crossing midnight ends on the next local day" do
      # friday 22:00 to saturday 02:00 sydney (aedt, utc+11)
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("night", [5], ~T[22:00:00], ~T[02:00:00])]
        )

      assert occurrences(p, ~U[2026-11-01 00:00:00Z], ~U[2026-11-08 00:00:00Z]) == [
               {"night", ~U[2026-11-06 11:00:00Z], ~U[2026-11-06 15:00:00Z]}
             ]

      assert Schedule.state_at(p, ~U[2026-11-06 14:00:00Z]) == :open
      assert Schedule.state_at(p, ~U[2026-11-06 15:00:00Z]) == :locked
      # saturday is not in days, so nothing starts on saturday night
      assert Schedule.state_at(p, ~U[2026-11-07 12:00:00Z]) == :locked
    end

    test "a window ending before it starts covers almost a full day" do
      p =
        policy("Australia/Brisbane",
          recurring_windows: [weekly("long", [3], ~T[06:00:00], ~T[05:00:00])]
        )

      assert occurrences(p, ~U[2026-11-01 00:00:00Z], ~U[2026-11-08 00:00:00Z]) == [
               {"long", ~U[2026-11-03 20:00:00Z], ~U[2026-11-04 19:00:00Z]}
             ]
    end

    test "an occurrence from the previous local day is still checked" do
      # the occurrence starting on sunday is still open early monday local time
      p =
        policy("Australia/Brisbane",
          recurring_windows: [weekly("sun", [7], ~T[20:00:00], ~T[03:00:00])]
        )

      assert {:open, {:window, "sun", {~U[2026-11-01 10:00:00Z], ~U[2026-11-01 17:00:00Z]}}} =
               Schedule.explain(p, ~U[2026-11-01 16:00:00Z])
    end

    test "explain picks the overlapping occurrence that ends last" do
      p =
        policy("Australia/Brisbane",
          recurring_windows: [
            weekly("short", [1], ~T[09:00:00], ~T[10:00:00]),
            weekly("long", [1], ~T[08:00:00], ~T[12:00:00])
          ]
        )

      assert {:open, {:window, "long", _}} = Schedule.explain(p, ~U[2026-11-01 23:30:00Z])
    end
  end

  describe "one-off windows" do
    test "open between starts_at and ends_at local time" do
      p =
        policy("Australia/Sydney",
          one_off_windows: [one_off("patch", ~N[2026-11-02 09:00:00], ~N[2026-11-02 11:30:00])]
        )

      assert Schedule.state_at(p, ~U[2026-11-01 21:59:59Z]) == :locked

      assert Schedule.explain(p, ~U[2026-11-01 22:00:00Z]) ==
               {:open, {:window, "patch", {~U[2026-11-01 22:00:00Z], ~U[2026-11-02 00:30:00Z]}}}

      assert Schedule.state_at(p, ~U[2026-11-02 00:30:00Z]) == :locked
    end

    test "a multi-day one-off window is open throughout" do
      p =
        policy("Australia/Sydney",
          one_off_windows: [
            one_off("migration", ~N[2026-11-01 00:00:00], ~N[2026-11-20 00:00:00])
          ]
        )

      assert Schedule.state_at(p, ~U[2026-11-10 12:00:00Z]) == :open
      assert Schedule.next_change(p, ~U[2026-11-10 12:00:00Z]) == ~U[2026-11-19 13:00:00Z]
      assert Schedule.next_change(p, ~U[2026-11-01 00:00:00Z]) == nil
    end

    test "windows_between merges and sorts recurring and one-off occurrences" do
      p =
        policy("Australia/Brisbane",
          recurring_windows: [weekly("daily", [1, 2, 3, 4, 5, 6, 7], ~T[12:00:00], ~T[13:00:00])],
          one_off_windows: [one_off("extra", ~N[2026-11-02 11:30:00], ~N[2026-11-02 12:30:00])]
        )

      assert occurrences(p, ~U[2026-11-01 00:00:00Z], ~U[2026-11-03 00:00:00Z]) == [
               {"daily", ~U[2026-11-01 02:00:00Z], ~U[2026-11-01 03:00:00Z]},
               {"extra", ~U[2026-11-02 01:30:00Z], ~U[2026-11-02 02:30:00Z]},
               {"daily", ~U[2026-11-02 02:00:00Z], ~U[2026-11-02 03:00:00Z]}
             ]

      # occurrences overlapping the range edges are included unclipped, empty ranges give nothing
      assert [{"daily", ~U[2026-11-01 02:00:00Z], _}] =
               occurrences(p, ~U[2026-11-01 02:59:59Z], ~U[2026-11-01 03:00:00Z])

      assert occurrences(p, ~U[2026-11-01 03:00:00Z], ~U[2026-11-02 01:30:00Z]) == []
      assert occurrences(p, ~U[2026-11-02 00:00:00Z], ~U[2026-11-01 00:00:00Z]) == []
    end
  end

  describe "next_change/2" do
    test "returns the next window edge strictly after the instant" do
      p =
        policy("Australia/Brisbane",
          recurring_windows: [weekly("bus", [1], ~T[09:00:00], ~T[17:00:00])]
        )

      assert Schedule.next_change(p, ~U[2026-10-31 00:00:00Z]) == ~U[2026-11-01 23:00:00Z]
      assert Schedule.next_change(p, ~U[2026-11-01 23:00:00Z]) == ~U[2026-11-02 07:00:00Z]
      assert Schedule.next_change(p, ~U[2026-11-02 07:00:00Z]) == ~U[2026-11-08 23:00:00Z]
    end

    test "is nil with nothing within 14 days" do
      assert Schedule.next_change(policy("Australia/Sydney"), ~U[2026-10-31 00:00:00Z]) == nil

      p =
        policy("Australia/Sydney",
          advisory_locks: [lock("kev", ~U[2026-11-20 00:00:00Z])],
          one_off_windows: [one_off("later", ~N[2026-12-01 09:00:00], ~N[2026-12-01 10:00:00])]
        )

      assert Schedule.next_change(p, ~U[2026-10-31 00:00:00Z]) == nil
    end

    test "includes an edge exactly at the horizon" do
      p = policy("Australia/Sydney", advisory_locks: [lock("kev", ~U[2026-11-14 00:00:00Z])])
      assert Schedule.next_change(p, ~U[2026-10-31 00:00:00Z]) == ~U[2026-11-14 00:00:00Z]
    end
  end

  describe "dst in australia/sydney" do
    # fall back: sunday 2026-04-05 03:00 aedt (utc+11) becomes 02:00 aest (utc+10) at 16:00z,
    # so local 02:00-03:00 happens twice: 15:00-16:00z then 16:00-17:00z
    test "a window fully inside the repeated hour is skipped" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("rep", [7], ~T[02:15:00], ~T[02:45:00])]
        )

      assert occurrences(p, ~U[2026-04-04 00:00:00Z], ~U[2026-04-06 00:00:00Z]) == []

      for at <- [~U[2026-04-04 15:20:00Z], ~U[2026-04-04 15:50:00Z], ~U[2026-04-04 16:20:00Z]] do
        assert Schedule.state_at(p, at) == :locked
      end

      # the week before has no transition and opens normally (aedt)
      assert occurrences(p, ~U[2026-03-28 00:00:00Z], ~U[2026-03-30 00:00:00Z]) == [
               {"rep", ~U[2026-03-28 15:15:00Z], ~U[2026-03-28 15:45:00Z]}
             ]
    end

    test "a window ending in the repeated hour ends at its first occurrence" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("in", [7], ~T[01:30:00], ~T[02:30:00])]
        )

      assert occurrences(p, ~U[2026-04-04 00:00:00Z], ~U[2026-04-06 00:00:00Z]) == [
               {"in", ~U[2026-04-04 14:30:00Z], ~U[2026-04-04 15:30:00Z]}
             ]

      # second pass of 02:00-02:30 local is locked
      assert Schedule.state_at(p, ~U[2026-04-04 16:10:00Z]) == :locked
    end

    test "a window starting in the repeated hour starts at its second occurrence" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("out", [7], ~T[02:30:00], ~T[03:30:00])]
        )

      assert occurrences(p, ~U[2026-04-04 00:00:00Z], ~U[2026-04-06 00:00:00Z]) == [
               {"out", ~U[2026-04-04 16:30:00Z], ~U[2026-04-04 17:30:00Z]}
             ]

      # first pass of 02:30-03:00 local is locked
      assert Schedule.state_at(p, ~U[2026-04-04 15:40:00Z]) == :locked
    end

    test "a window straddling the whole repeated hour keeps its real length" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("all", [7], ~T[01:00:00], ~T[04:00:00])]
        )

      assert occurrences(p, ~U[2026-04-04 00:00:00Z], ~U[2026-04-06 00:00:00Z]) == [
               {"all", ~U[2026-04-04 14:00:00Z], ~U[2026-04-04 18:00:00Z]}
             ]
    end

    # spring forward: sunday 2026-10-04 02:00 aest (utc+10) becomes 03:00 aedt (utc+11) at
    # 2026-10-03 16:00z, local 02:00-03:00 does not exist
    test "a window starting in the gap opens at the transition" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("gap", [7], ~T[02:30:00], ~T[04:00:00])]
        )

      assert occurrences(p, ~U[2026-10-03 00:00:00Z], ~U[2026-10-05 00:00:00Z]) == [
               {"gap", ~U[2026-10-03 16:00:00Z], ~U[2026-10-03 17:00:00Z]}
             ]

      assert Schedule.state_at(p, ~U[2026-10-03 15:59:59Z]) == :locked
      assert Schedule.state_at(p, ~U[2026-10-03 16:00:00Z]) == :open
    end

    test "a window ending in the gap closes at the transition" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("pre", [7], ~T[01:00:00], ~T[02:30:00])]
        )

      assert occurrences(p, ~U[2026-10-03 00:00:00Z], ~U[2026-10-05 00:00:00Z]) == [
               {"pre", ~U[2026-10-03 15:00:00Z], ~U[2026-10-03 16:00:00Z]}
             ]
    end

    test "a window fully inside the gap is skipped" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("none", [7], ~T[02:15:00], ~T[02:45:00])]
        )

      assert occurrences(p, ~U[2026-10-03 00:00:00Z], ~U[2026-10-05 00:00:00Z]) == []
    end

    test "a window crossing midnight into the gap" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("sat", [6], ~T[22:00:00], ~T[02:30:00])]
        )

      assert occurrences(p, ~U[2026-10-03 00:00:00Z], ~U[2026-10-05 00:00:00Z]) == [
               {"sat", ~U[2026-10-03 12:00:00Z], ~U[2026-10-03 16:00:00Z]}
             ]
    end

    test "one-off windows use the same rules" do
      p =
        policy("Australia/Sydney",
          one_off_windows: [
            one_off("gap", ~N[2026-10-04 02:30:00], ~N[2026-10-04 03:30:00]),
            one_off("rep", ~N[2026-04-05 02:10:00], ~N[2026-04-05 02:50:00]),
            one_off("straddle", ~N[2026-04-05 02:30:00], ~N[2026-04-05 03:30:00])
          ]
        )

      assert occurrences(p, ~U[2026-01-01 00:00:00Z], ~U[2027-01-01 00:00:00Z]) == [
               {"straddle", ~U[2026-04-04 16:30:00Z], ~U[2026-04-04 17:30:00Z]},
               {"gap", ~U[2026-10-03 16:00:00Z], ~U[2026-10-03 16:30:00Z]}
             ]
    end

    test "next_change crosses the transition" do
      p =
        policy("Australia/Sydney",
          recurring_windows: [weekly("gap", [7], ~T[02:30:00], ~T[04:00:00])]
        )

      assert Schedule.next_change(p, ~U[2026-10-03 00:00:00Z]) == ~U[2026-10-03 16:00:00Z]
      assert Schedule.next_change(p, ~U[2026-10-03 16:00:00Z]) == ~U[2026-10-03 17:00:00Z]
      # the following sunday is plain aedt
      assert Schedule.next_change(p, ~U[2026-10-03 17:00:00Z]) == ~U[2026-10-10 15:30:00Z]
    end
  end

  describe "dst in australia/adelaide (half-hour offsets)" do
    # fall back: 2026-04-05 03:00 acdt (utc+10:30) becomes 02:00 acst (utc+9:30) at 16:30z,
    # spring forward: 2026-10-04 02:00 acst becomes 03:00 acdt at 2026-10-03 16:30z
    test "a window fully inside the repeated hour is skipped" do
      p =
        policy("Australia/Adelaide",
          recurring_windows: [weekly("rep", [7], ~T[02:15:00], ~T[02:45:00])]
        )

      assert occurrences(p, ~U[2026-04-04 00:00:00Z], ~U[2026-04-06 00:00:00Z]) == []
    end

    test "a window straddling the repeated hour" do
      p =
        policy("Australia/Adelaide",
          recurring_windows: [
            weekly("in", [7], ~T[01:30:00], ~T[02:30:00]),
            weekly("out", [7], ~T[02:30:00], ~T[03:30:00])
          ]
        )

      assert occurrences(p, ~U[2026-04-04 00:00:00Z], ~U[2026-04-06 00:00:00Z]) == [
               {"in", ~U[2026-04-04 15:00:00Z], ~U[2026-04-04 16:00:00Z]},
               {"out", ~U[2026-04-04 17:00:00Z], ~U[2026-04-04 18:00:00Z]}
             ]
    end

    test "a window starting in the gap opens at the transition" do
      p =
        policy("Australia/Adelaide",
          recurring_windows: [weekly("gap", [7], ~T[02:30:00], ~T[04:00:00])]
        )

      assert occurrences(p, ~U[2026-10-03 00:00:00Z], ~U[2026-10-05 00:00:00Z]) == [
               {"gap", ~U[2026-10-03 16:30:00Z], ~U[2026-10-03 17:30:00Z]}
             ]
    end
  end

  describe "australia/brisbane (no dst)" do
    test "local is always utc+10, including on the sydney transition dates" do
      p =
        policy("Australia/Brisbane",
          recurring_windows: [weekly("w", [7], ~T[02:30:00], ~T[03:30:00])]
        )

      assert occurrences(p, ~U[2026-04-04 00:00:00Z], ~U[2026-04-06 00:00:00Z]) == [
               {"w", ~U[2026-04-04 16:30:00Z], ~U[2026-04-04 17:30:00Z]}
             ]

      assert occurrences(p, ~U[2026-10-03 00:00:00Z], ~U[2026-10-05 00:00:00Z]) == [
               {"w", ~U[2026-10-03 16:30:00Z], ~U[2026-10-03 17:30:00Z]}
             ]

      assert occurrences(p, ~U[2026-07-04 00:00:00Z], ~U[2026-07-06 00:00:00Z]) == [
               {"w", ~U[2026-07-04 16:30:00Z], ~U[2026-07-04 17:30:00Z]}
             ]
    end
  end
end
