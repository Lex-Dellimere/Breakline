defmodule Breakline.SchedulePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Breakline.{Policy, Schedule}

  @db Tz.TimeZoneDatabase
  @zones ["Australia/Sydney", "Australia/Adelaide", "Australia/Brisbane"]
  @tool_ids ~w(n_central take_control screenconnect ninjaone datto_rmm anydesk teamviewer splashtop)

  # 2026 transitions: sydney at 16:00z, adelaide at 16:30z, on the day before the local date
  @transitions_utc [
    ~U[2026-04-04 16:00:00Z],
    ~U[2026-10-03 16:00:00Z],
    ~U[2026-04-04 16:30:00Z],
    ~U[2026-10-03 16:30:00Z]
  ]
  @transitions_local [~N[2026-04-05 02:30:00], ~N[2026-10-04 02:30:00]]

  @range_start DateTime.to_unix(~U[2025-01-01 00:00:00Z])
  @range_end DateTime.to_unix(~U[2028-01-01 00:00:00Z])
  @three_hours 3 * 60 * 60

  # generators

  defp instant do
    frequency([
      {1, map(integer(@range_start..@range_end), &DateTime.from_unix!/1)},
      {1,
       bind(member_of(@transitions_utc), fn t ->
         map(integer(-@three_hours..@three_hours), &DateTime.add(t, &1, :second))
       end)}
    ])
  end

  # minute of the day, biased towards 01:00-04:00 where the transitions happen
  defp local_time do
    frequency([{3, integer(0..1439)}, {2, integer(60..240)}])
    |> map(&Time.add(~T[00:00:00], &1 * 60))
  end

  defp recurring_window(id) do
    gen all(
          first <- integer(1..7),
          others <- subset_of(Enum.to_list(1..7)),
          starts <- local_time(),
          ends <- local_time(),
          starts != ends
        ) do
      %{id: id, days: Enum.uniq([first | others]), starts: starts, ends: ends}
    end
  end

  # a random subset in random order. uniq_list_of struggles with tiny domains at small sizes
  defp subset_of(items) do
    n = length(items)

    gen all(flags <- list_of(boolean(), length: n), keys <- list_of(integer(), length: n)) do
      [items, flags, keys]
      |> Enum.zip()
      |> Enum.filter(fn {_, keep, _} -> keep end)
      |> Enum.sort_by(fn {_, _, key} -> key end)
      |> Enum.map(fn {item, _, _} -> item end)
    end
  end

  defp local_naive do
    uniform =
      map(
        integer(div(@range_start, 60)..div(@range_end, 60)),
        &NaiveDateTime.add(~N[1970-01-01 00:00:00], &1 * 60)
      )

    near =
      bind(member_of(@transitions_local), fn n ->
        map(integer(-180..180), &NaiveDateTime.add(n, &1 * 60))
      end)

    frequency([{1, uniform}, {1, near}])
  end

  defp one_off_window(id) do
    gen all(
          starts_at <- local_naive(),
          minutes <- frequency([{3, integer(1..240)}, {1, integer(1..(3 * 1440))}])
        ) do
      %{id: id, starts_at: starts_at, ends_at: NaiveDateTime.add(starts_at, minutes * 60)}
    end
  end

  defp windows do
    gen all(
          recurring_count <- integer(0..3),
          one_off_count <- integer(0..2),
          recurring <- fixed_list(Enum.map(1..recurring_count//1, &recurring_window("r#{&1}"))),
          one_off <- fixed_list(Enum.map(1..one_off_count//1, &one_off_window("o#{&1}")))
        ) do
      {recurring, one_off}
    end
  end

  defp lock(id) do
    gen all(
          expires_at <- one_of([constant(nil), instant()]),
          reason <- string(:printable, min_length: 1, max_length: 20),
          source <- member_of(["kev:CVE-2026-18577", "acsc", "manual"])
        ) do
      %{id: id, reason: reason, source: source, expires_at: expires_at}
    end
  end

  defp break_glass do
    one_of([
      constant(nil),
      gen all(until <- instant(), approved_by <- string(:alphanumeric, min_length: 1)) do
        %{until: until, approved_by: approved_by}
      end
    ])
  end

  # a policy with windows only
  defp window_policy do
    gen all(tz <- member_of(@zones), {recurring, one_off} <- windows()) do
      build!(time_zone: tz, recurring_windows: recurring, one_off_windows: one_off)
    end
  end

  # a policy with everything, including locks and break-glass
  defp full_policy do
    gen all(
          tz <- member_of(@zones),
          {recurring, one_off} <- windows(),
          lock_count <- integer(0..2),
          locks <- fixed_list(Enum.map(1..lock_count//1, &lock("l#{&1}"))),
          break_glass <- break_glass(),
          site_id <- string(:alphanumeric, min_length: 1, max_length: 12),
          version <- non_negative_integer(),
          mode <- member_of([:enforce, :monitor]),
          tool_ids <- subset_of(@tool_ids),
          site_hosts <- list_of(string(:printable, min_length: 1, max_length: 20), max_length: 3)
        ) do
      build!(
        site_id: site_id,
        version: version,
        mode: mode,
        time_zone: tz,
        tool_ids: tool_ids,
        site_hosts: site_hosts,
        recurring_windows: recurring,
        one_off_windows: one_off,
        advisory_locks: locks,
        break_glass: break_glass
      )
    end
  end

  defp build!(attrs) do
    {:ok, policy} =
      [site_id: "site-1", version: 1, mode: :enforce]
      |> Keyword.merge(attrs)
      |> Policy.new()

    policy
  end

  # the oracle: read the instant as local wall-clock time and check it against the windows
  # as plain wall-clock times, ignoring dst entirely
  defp naive_open?(%Policy{} = policy, at) do
    local = at |> DateTime.shift_zone!(policy.time_zone, @db) |> DateTime.to_naive()
    date = NaiveDateTime.to_date(local)
    time = NaiveDateTime.to_time(local)
    today = Date.day_of_week(date)
    yesterday = Date.day_of_week(Date.add(date, -1))

    recurring_open =
      Enum.any?(policy.recurring_windows, fn w ->
        if Time.compare(w.starts, w.ends) == :lt do
          today in w.days and Time.compare(time, w.starts) != :lt and
            Time.compare(time, w.ends) == :lt
        else
          (today in w.days and Time.compare(time, w.starts) != :lt) or
            (yesterday in w.days and Time.compare(time, w.ends) == :lt)
        end
      end)

    one_off_open =
      Enum.any?(policy.one_off_windows, fn w ->
        NaiveDateTime.compare(local, w.starts_at) != :lt and
          NaiveDateTime.compare(local, w.ends_at) == :lt
      end)

    recurring_open or one_off_open
  end

  defp offset(at, tz) do
    local = DateTime.shift_zone!(at, tz, @db)
    local.utc_offset + local.std_offset
  end

  # no transition within three days either side covers every occurrence that can touch `at`
  defp stable_offset?(at, tz) do
    window = 3 * 24 * 60 * 60
    o = offset(at, tz)
    offset(DateTime.add(at, -window), tz) == o and offset(DateTime.add(at, window), tz) == o
  end

  defp windows_only(policy), do: %{policy | advisory_locks: [], break_glass: nil}

  # properties

  property "on days without a transition, window state matches the wall-clock oracle" do
    check all(policy <- window_policy(), at <- instant(), max_runs: 3000) do
      if stable_offset?(at, policy.time_zone) do
        assert Schedule.state_at(policy, at) ==
                 if(naive_open?(policy, at), do: :open, else: :locked)
      end
    end
  end

  property "everywhere, including transition days, window-open implies wall-clock open" do
    check all(policy <- window_policy(), at <- instant(), max_runs: 3000) do
      if Schedule.state_at(policy, at) == :open, do: assert(naive_open?(policy, at))

      # random instants rarely land on an edge, so also check the first and last second of
      # every nearby occurrence, which is where dst resolution matters
      day = 24 * 60 * 60

      for {s, e, _} <-
            Schedule.windows_between(policy, DateTime.add(at, -day), DateTime.add(at, day)),
          edge <- [s, DateTime.add(e, -1)] do
        assert Schedule.state_at(policy, edge) == :open
        assert naive_open?(policy, edge)
      end
    end
  end

  property "advisory lock beats break-glass beats windows" do
    check all(policy <- full_policy(), at <- instant(), max_runs: 500) do
      lock_active =
        Enum.any?(policy.advisory_locks, fn l ->
          l.expires_at == nil or DateTime.compare(at, l.expires_at) == :lt
        end)

      break_glass_active =
        policy.break_glass != nil and DateTime.compare(at, policy.break_glass.until) == :lt

      state = Schedule.state_at(policy, at)

      cond do
        lock_active -> assert state == :locked
        break_glass_active -> assert state == :open
        true -> assert state == Schedule.state_at(windows_only(policy), at)
      end
    end
  end

  property "explain agrees with state_at and its window really contains the instant" do
    check all(policy <- full_policy(), at <- instant(), max_runs: 500) do
      explanation = Schedule.explain(policy, at)
      assert Schedule.state_at(policy, at) == elem(explanation, 0)

      case explanation do
        {:open, {:window, id, {s, e}}} ->
          assert DateTime.compare(s, at) != :gt and DateTime.compare(at, e) == :lt
          assert {s, e, id} in Schedule.windows_between(policy, at, DateTime.add(at, 1))

        {:locked, {:advisory_lock, lock}} ->
          assert lock in policy.advisory_locks

        {:open, {:break_glass, bg}} ->
          assert bg == policy.break_glass

        {:locked, :default} ->
          :ok
      end
    end
  end

  property "policy map round trip is lossless" do
    check all(policy <- full_policy(), max_runs: 300) do
      assert Policy.from_map(Policy.to_map(policy)) == {:ok, policy}
    end
  end

  property "next_lock is locked, the state is open before it, and nil while locked" do
    check all(
            policy <- full_policy(),
            at <- instant(),
            fractions <- list_of(integer(1..999_999), length: 8),
            max_runs: 300
          ) do
      case {Schedule.state_at(policy, at), Schedule.next_lock(policy, at)} do
        {:locked, lock} ->
          assert lock == nil

        {:open, nil} ->
          :ok

        {:open, lock} ->
          assert DateTime.compare(lock, at) == :gt
          assert DateTime.diff(lock, at) <= 14 * 24 * 60 * 60
          assert Schedule.state_at(policy, lock) == :locked
          span = DateTime.diff(lock, at)

          for offset <- Enum.map(fractions, &div(&1 * span, 1_000_000)), offset > 0 do
            assert Schedule.state_at(policy, DateTime.add(at, offset)) == :open
          end
      end
    end
  end

  property "state is constant from an instant until next_change" do
    check all(
            policy <- full_policy(),
            at <- instant(),
            fractions <- list_of(integer(0..1_000_000), length: 12),
            max_runs: 300
          ) do
      next = Schedule.next_change(policy, at)
      horizon = DateTime.add(at, 14 * 24 * 60 * 60)
      stop = next || horizon

      if next do
        assert DateTime.compare(next, at) == :gt
        assert DateTime.compare(next, horizon) != :gt
      end

      span = DateTime.diff(stop, at)
      state = Schedule.state_at(policy, at)

      samples = [span - 1 | Enum.map(fractions, &div(&1 * span, 1_000_000))]

      for offset <- samples, offset >= 0, offset < span do
        assert Schedule.state_at(policy, DateTime.add(at, offset)) == state
      end
    end
  end
end
