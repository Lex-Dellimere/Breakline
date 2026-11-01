defmodule Breakline.Schedule do
  @moduledoc """
  Pure evaluation of a `Breakline.Policy` at a UTC instant.

  Precedence, highest first:

    1. an active advisory lock locks the site (`expires_at` nil, or the
       instant is before `expires_at`)
    2. an active break-glass opens it (the instant is before `until`)
    3. any active window occurrence opens it
    4. otherwise it is locked

  Window occurrences are half-open, `[start, end)`. A recurring window occurs
  on every local date whose ISO weekday is in `days`, from `starts` on that
  date to `ends` on the same date, or on the next date when `ends` is not
  after `starts`.

  Daylight saving is resolved fail-closed, giving the shortest real-time
  opening. A local start that occurs twice (the repeated hour when clocks go
  back) takes the later instant and a repeated local end takes the earlier
  one. A local start or end that does not exist (the skipped hour when clocks
  go forward) resolves to the transition instant. An occurrence whose
  resolved end is not after its resolved start is skipped. One-off windows
  follow the same rules.

  `mode` is ignored here; the gateway decides whether to block or only log.
  """

  alias Breakline.Policy
  alias Breakline.Policy.{AdvisoryLock, BreakGlass, OneOffWindow, RecurringWindow}

  @horizon_seconds 14 * 24 * 60 * 60

  @type state :: :open | :locked

  @type occurrence :: {start_utc :: DateTime.t(), end_utc :: DateTime.t(), String.t()}

  @type explanation ::
          {:locked, {:advisory_lock, AdvisoryLock.t()}}
          | {:open, {:break_glass, BreakGlass.t()}}
          | {:open, {:window, String.t(), {DateTime.t(), DateTime.t()}}}
          | {:locked, :default}

  @doc """
  Returns whether the RMM channel is `:open` or `:locked` at `at`.

  Always equal to `elem(explain(policy, at), 0)`.
  """
  @spec state_at(Policy.t(), DateTime.t()) :: state()
  def state_at(%Policy{} = policy, %DateTime{} = at), do: policy |> explain(at) |> elem(0)

  @doc """
  Returns the state at `at` together with the rule that decided it.

  When several advisory locks are active the first in policy order is
  returned. When several window occurrences are active the one ending last is
  returned (ties broken by earliest start, then by id).
  """
  @spec explain(Policy.t(), DateTime.t()) :: explanation()
  def explain(%Policy{} = policy, %DateTime{} = at) do
    cond do
      lock = Enum.find(policy.advisory_locks, &lock_active?(&1, at)) ->
        {:locked, {:advisory_lock, lock}}

      break_glass_active?(policy.break_glass, at) ->
        {:open, {:break_glass, policy.break_glass}}

      occurrence = active_occurrence(policy, at) ->
        {start_utc, end_utc, id} = occurrence
        {:open, {:window, id, {start_utc, end_utc}}}

      true ->
        {:locked, :default}
    end
  end

  @doc """
  Lists the window occurrences (recurring and one-off) that intersect
  `[from, to)`, sorted by start, then end, then id. Occurrences are not
  clipped to the range. Returns `[]` when `to` is not after `from`.
  """
  @spec windows_between(Policy.t(), DateTime.t(), DateTime.t()) :: [occurrence()]
  def windows_between(%Policy{} = policy, %DateTime{} = from, %DateTime{} = to) do
    if DateTime.compare(from, to) == :lt do
      # an occurrence starting on local date d ends by d + 1, so d - 2 is a safe lower bound
      first = Date.add(local_date(from, policy.time_zone), -2)
      last = local_date(to, policy.time_zone)

      policy
      |> occurrences(Date.range(first, last))
      |> Enum.filter(fn {s, e, _} ->
        DateTime.compare(s, to) == :lt and DateTime.compare(e, from) == :gt
      end)
      |> Enum.sort_by(fn {s, e, id} -> {DateTime.to_unix(s), DateTime.to_unix(e), id} end)
    else
      []
    end
  end

  @doc """
  Returns the next instant strictly after `at` where the state could change
  (an advisory lock expiring, break-glass ending, or a window occurrence
  starting or ending), looking at most 14 days ahead. Returns nil when there
  is no such instant within the horizon.

  The state is constant on `[at, next_change(policy, at))`, though it may also
  be unchanged across the returned instant.
  """
  @spec next_change(Policy.t(), DateTime.t()) :: DateTime.t() | nil
  def next_change(%Policy{} = policy, %DateTime{} = at) do
    horizon = DateTime.add(at, @horizon_seconds, :second)

    lock_ends = for %AdvisoryLock{expires_at: %DateTime{} = e} <- policy.advisory_locks, do: e
    break_glass_ends = for %BreakGlass{until: until} <- [policy.break_glass], do: until

    window_edges =
      policy
      |> windows_between(at, horizon)
      |> Enum.flat_map(fn {s, e, _} -> [s, e] end)

    (lock_ends ++ break_glass_ends ++ window_edges)
    |> Enum.filter(fn t ->
      DateTime.compare(t, at) == :gt and DateTime.compare(t, horizon) != :gt
    end)
    |> Enum.min(DateTime, fn -> nil end)
  end

  @doc """
  For a policy open at `at`, returns the instant it locks again, following
  `next_change/2` past the changes that leave it open (break-glass ending inside
  a window, back-to-back windows). The state is open on all of
  `[at, next_lock(policy, at))`.

  Returns nil when the policy is locked at `at`, or stays open for more than the
  14 days it looks ahead.
  """
  @spec next_lock(Policy.t(), DateTime.t()) :: DateTime.t() | nil
  def next_lock(%Policy{} = policy, %DateTime{} = at) do
    if state_at(policy, at) == :open do
      horizon = DateTime.add(at, @horizon_seconds, :second)
      find_lock(policy, next_change(policy, at), horizon)
    end
  end

  defp find_lock(_policy, nil, _horizon), do: nil

  defp find_lock(policy, t, horizon) do
    cond do
      DateTime.compare(t, horizon) == :gt -> nil
      state_at(policy, t) == :locked -> t
      true -> find_lock(policy, next_change(policy, t), horizon)
    end
  end

  defp lock_active?(%AdvisoryLock{expires_at: nil}, _at), do: true
  defp lock_active?(%AdvisoryLock{expires_at: e}, at), do: DateTime.compare(at, e) == :lt

  defp break_glass_active?(nil, _at), do: false
  defp break_glass_active?(%BreakGlass{until: until}, at), do: DateTime.compare(at, until) == :lt

  defp active_occurrence(policy, at) do
    today = local_date(at, policy.time_zone)

    policy
    |> occurrences(Date.range(Date.add(today, -2), today))
    |> Enum.filter(fn {s, e, _} ->
      DateTime.compare(s, at) != :gt and DateTime.compare(at, e) == :lt
    end)
    |> Enum.min_by(
      fn {s, e, id} -> {-DateTime.to_unix(e), DateTime.to_unix(s), id} end,
      fn -> nil end
    )
  end

  # recurring occurrences starting on the given local dates, plus every one-off occurrence
  defp occurrences(%Policy{time_zone: tz} = policy, dates) do
    recurring =
      for date <- dates,
          window <- policy.recurring_windows,
          occurrence <- recurring_occurrence(window, date, tz),
          do: occurrence

    one_off = Enum.flat_map(policy.one_off_windows, &one_off_occurrence(&1, tz))

    recurring ++ one_off
  end

  defp recurring_occurrence(%RecurringWindow{} = window, date, tz) do
    if Date.day_of_week(date) in window.days do
      end_date =
        if Time.compare(window.ends, window.starts) == :gt, do: date, else: Date.add(date, 1)

      build_occurrence(
        window.id,
        NaiveDateTime.new!(date, window.starts),
        NaiveDateTime.new!(end_date, window.ends),
        tz
      )
    else
      []
    end
  end

  defp one_off_occurrence(%OneOffWindow{} = window, tz),
    do: build_occurrence(window.id, window.starts_at, window.ends_at, tz)

  defp build_occurrence(id, local_start, local_end, tz) do
    start_utc = to_utc(local_start, tz, :start)
    end_utc = to_utc(local_end, tz, :end)

    if DateTime.compare(end_utc, start_utc) == :gt, do: [{start_utc, end_utc, id}], else: []
  end

  # fail closed: a repeated start takes the later instant, a repeated end the earlier,
  # and a skipped local time resolves to the transition instant
  defp to_utc(naive, tz, bound) do
    db = Breakline.time_zone_database()

    resolved =
      case DateTime.from_naive(naive, tz, db) do
        {:ok, dt} -> dt
        {:ambiguous, earlier, later} -> if bound == :start, do: later, else: earlier
        {:gap, _just_before, just_after} -> just_after
      end

    resolved |> DateTime.shift_zone!("Etc/UTC", db) |> DateTime.truncate(:second)
  end

  defp local_date(at, tz) do
    at |> DateTime.shift_zone!(tz, Breakline.time_zone_database()) |> DateTime.to_date()
  end
end
