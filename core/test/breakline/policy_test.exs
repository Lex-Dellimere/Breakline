defmodule Breakline.PolicyTest do
  use ExUnit.Case, async: true

  alias Breakline.Policy
  alias Breakline.Policy.{AdvisoryLock, BreakGlass, OneOffWindow, RecurringWindow}

  defp attrs(overrides \\ []) do
    Keyword.merge(
      [
        site_id: "site-1",
        version: 3,
        mode: :enforce,
        time_zone: "Australia/Sydney",
        tool_ids: ["n_central", "screenconnect"],
        site_hosts: ["rmm.example.com.au", "10.0.0.5", "203.0.113.0/24"],
        recurring_windows: [
          %{id: "weeknights", days: [1, 2, 3, 4, 5], starts: ~T[18:00:00], ends: ~T[06:00:00]}
        ],
        one_off_windows: [
          [id: "patch", starts_at: ~N[2026-11-02 09:00:00], ends_at: ~N[2026-11-02 11:30:00]]
        ],
        advisory_locks: [
          %{
            id: "lock-1",
            reason: "n-central exploited",
            source: "kev:CVE-2026-18577",
            expires_at: nil
          },
          %{
            id: "lock-2",
            reason: "acsc alert",
            source: "acsc",
            expires_at: ~U[2026-11-05 00:00:00Z]
          }
        ],
        break_glass: %{until: ~U[2026-10-31 10:00:00Z], approved_by: "approver-7"}
      ],
      overrides
    )
  end

  describe "new/1" do
    test "builds a full policy with nested structs" do
      assert {:ok, %Policy{} = p} = Policy.new(attrs())
      assert p.mode == :enforce
      assert [%RecurringWindow{id: "weeknights", days: [1, 2, 3, 4, 5]}] = p.recurring_windows
      assert [%OneOffWindow{id: "patch"}] = p.one_off_windows
      assert [%AdvisoryLock{expires_at: nil}, %AdvisoryLock{}] = p.advisory_locks
      assert %BreakGlass{approved_by: "approver-7"} = p.break_glass
    end

    test "accepts a map and defaults the optional fields" do
      assert {:ok, p} =
               Policy.new(%{site_id: "s", version: 0, mode: :monitor, time_zone: "Etc/UTC"})

      assert p.tool_ids == [] and p.site_hosts == [] and p.recurring_windows == []
      assert p.one_off_windows == [] and p.advisory_locks == [] and p.break_glass == nil
    end

    test "accepts nested structs" do
      {:ok, p} = Policy.new(attrs())
      assert {:ok, ^p} = p |> Map.from_struct() |> Policy.new()
    end

    test "reports every missing required field" do
      assert {:error, reasons} = Policy.new([])

      assert Enum.sort(reasons) ==
               Enum.sort([
                 {[:site_id], :required},
                 {[:version], :required},
                 {[:mode], :required},
                 {[:time_zone], :required}
               ])
    end

    test "rejects bad scalar fields" do
      assert {:error, [{[:site_id], :invalid}]} = Policy.new(attrs(site_id: ""))
      assert {:error, [{[:version], :invalid}]} = Policy.new(attrs(version: -1))
      assert {:error, [{[:version], :invalid}]} = Policy.new(attrs(version: 1.0))
      assert {:error, [{[:mode], :invalid}]} = Policy.new(attrs(mode: "enforce"))

      assert {:error, [{[:time_zone], :unknown_time_zone}]} =
               Policy.new(attrs(time_zone: "Australia/Atlantis"))

      assert {:error, [{[:tool_ids, 1], :invalid}]} = Policy.new(attrs(tool_ids: ["a", 1]))
      assert {:error, [{[:tool_ids], :duplicate}]} = Policy.new(attrs(tool_ids: ["a", "a"]))
      assert {:error, [{[:site_hosts, 0], :invalid}]} = Policy.new(attrs(site_hosts: [""]))
    end

    test "rejects unknown keys" do
      assert {:error, [{[:colour], :unknown_key}]} = Policy.new(attrs(colour: "blue"))
    end

    test "validates recurring windows" do
      bad = fn window -> Policy.new(attrs(recurring_windows: [window])) end
      base = %{id: "w", days: [1], starts: ~T[09:00:00], ends: ~T[17:00:00]}

      assert {:error, [{[:recurring_windows, 0, :days], :invalid}]} = bad.(%{base | days: []})
      assert {:error, [{[:recurring_windows, 0, :days], :invalid}]} = bad.(%{base | days: [0]})
      assert {:error, [{[:recurring_windows, 0, :days], :invalid}]} = bad.(%{base | days: [8]})

      assert {:error, [{[:recurring_windows, 0, :days], :invalid}]} =
               bad.(%{base | days: [1, 1]})

      assert {:error, [{[:recurring_windows, 0, :starts], :invalid}]} =
               bad.(%{base | starts: ~T[09:00:30]})

      assert {:error, [{[:recurring_windows, 0, :ends], :invalid}]} =
               bad.(%{base | ends: ~T[17:00:00.5]})

      assert {:error, [{[:recurring_windows, 0, :ends], :equals_starts}]} =
               bad.(%{base | ends: ~T[09:00:00]})

      assert {:error, [{[:recurring_windows, 0, :id], :required}]} = bad.(Map.delete(base, :id))
    end

    test "normalises zero microseconds on whole minute times" do
      w = %{id: "w", days: [7], starts: ~T[09:00:00.000], ends: ~T[17:00:00.000000]}
      assert {:ok, p} = Policy.new(attrs(recurring_windows: [w]))
      assert [%RecurringWindow{starts: ~T[09:00:00], ends: ~T[17:00:00]}] = p.recurring_windows
    end

    test "validates one-off windows" do
      bad = fn window -> Policy.new(attrs(one_off_windows: [window])) end
      base = %{id: "o", starts_at: ~N[2026-11-02 09:00:00], ends_at: ~N[2026-11-02 10:00:00]}

      assert {:error, [{[:one_off_windows, 0, :ends_at], :not_after_starts_at}]} =
               bad.(%{base | ends_at: base.starts_at})

      assert {:error, [{[:one_off_windows, 0, :starts_at], :invalid}]} =
               bad.(%{base | starts_at: ~N[2026-11-02 08:59:59]})

      assert {:error, [{[:one_off_windows, 0, :starts_at], :invalid}]} =
               bad.(%{base | starts_at: ~U[2026-11-02 08:00:00Z]})
    end

    test "window ids are unique across recurring and one-off windows" do
      assert {:error, [{[:windows, "patch"], :duplicate_id}]} =
               Policy.new(
                 attrs(
                   recurring_windows: [
                     %{id: "patch", days: [1], starts: ~T[09:00:00], ends: ~T[10:00:00]}
                   ]
                 )
               )
    end

    test "validates advisory locks" do
      lock = %{id: "l", reason: "r", source: "manual", expires_at: nil}

      assert {:error, [{[:advisory_locks, 0, :expires_at], :invalid}]} =
               Policy.new(attrs(advisory_locks: [%{lock | expires_at: ~N[2026-11-01 00:00:00]}]))

      sydney =
        DateTime.new!(~D[2026-11-01], ~T[00:00:00], "Australia/Sydney", Tz.TimeZoneDatabase)

      assert {:error, [{[:advisory_locks, 0, :expires_at], :invalid}]} =
               Policy.new(attrs(advisory_locks: [%{lock | expires_at: sydney}]))

      assert {:error, [{[:advisory_locks, "l"], :duplicate_id}]} =
               Policy.new(attrs(advisory_locks: [lock, lock]))

      assert {:ok, %Policy{advisory_locks: [%AdvisoryLock{expires_at: nil}]}} =
               Policy.new(attrs(advisory_locks: [Map.delete(lock, :expires_at)]))
    end

    test "rounds lock expiry up and break-glass end down to whole seconds" do
      lock = %{id: "l", reason: "r", source: "manual", expires_at: ~U[2026-11-01 00:00:00.250Z]}
      bg = %{until: ~U[2026-11-01 00:00:00.750Z], approved_by: "a"}

      assert {:ok, p} = Policy.new(attrs(advisory_locks: [lock], break_glass: bg))
      assert [%AdvisoryLock{expires_at: ~U[2026-11-01 00:00:01Z]}] = p.advisory_locks
      assert %BreakGlass{until: ~U[2026-11-01 00:00:00Z]} = p.break_glass
    end

    test "validates break-glass" do
      assert {:error, [{[:break_glass, :approved_by], :required}]} =
               Policy.new(attrs(break_glass: %{until: ~U[2026-11-01 00:00:00Z]}))

      assert {:error, [{[:break_glass], :invalid}]} = Policy.new(attrs(break_glass: "yes"))
    end
  end

  describe "to_map/1 and from_map/1" do
    test "encode to a json-compatible map" do
      {:ok, p} = Policy.new(attrs())
      map = Policy.to_map(p)

      assert map["mode"] == "enforce"

      assert map["recurring_windows"] == [
               %{
                 "id" => "weeknights",
                 "days" => [1, 2, 3, 4, 5],
                 "starts" => "18:00:00",
                 "ends" => "06:00:00"
               }
             ]

      assert [%{"starts_at" => "2026-11-02T09:00:00", "ends_at" => "2026-11-02T11:30:00"}] =
               map["one_off_windows"]

      assert [%{"expires_at" => nil}, %{"expires_at" => "2026-11-05T00:00:00Z"}] =
               map["advisory_locks"]

      assert map["break_glass"] == %{
               "until" => "2026-10-31T10:00:00Z",
               "approved_by" => "approver-7"
             }

      assert json_compatible?(map)
    end

    test "round trip is lossless" do
      {:ok, p} = Policy.new(attrs())
      assert Policy.from_map(Policy.to_map(p)) == {:ok, p}

      {:ok, minimal} = Policy.new(site_id: "s", version: 0, mode: :monitor, time_zone: "Etc/UTC")
      assert Policy.from_map(Policy.to_map(minimal)) == {:ok, minimal}
    end

    test "rejects unknown keys and modes without creating atoms" do
      {:ok, p} = Policy.new(attrs())
      map = Policy.to_map(p)
      key = "surely_not_an_existing_atom_#{System.unique_integer([:positive])}"

      assert {:error, [{[^key], :unknown_key}]} = Policy.from_map(Map.put(map, key, 1))
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

      assert {:error, [{[:mode], :invalid}]} = Policy.from_map(%{map | "mode" => "open"})
      assert {:error, [{[:mode], :invalid}]} = Policy.from_map(%{map | "mode" => :enforce})
    end

    test "rejects atom keys and non-maps" do
      assert {:error, [{[], :invalid}]} = Policy.from_map("policy")
      assert {:error, [{[], :invalid}]} = Policy.from_map(nil)

      assert {:error, reasons} = Policy.from_map(%{site_id: "s"})
      assert {[:site_id], :unknown_key} in reasons
    end

    test "requires canonical datetime strings" do
      {:ok, p} = Policy.new(attrs())
      map = Policy.to_map(p)

      for until <- [
            "2026-10-31T10:00:00+00:00",
            "2026-10-31T10:00:00.000Z",
            "2026-10-31 10:00:00Z",
            1
          ] do
        assert {:error, [{[:break_glass, :until], :invalid}]} =
                 Policy.from_map(put_in(map, ["break_glass", "until"], until))
      end

      [w] = map["recurring_windows"]

      for starts <- ["18:00", "18:00:00.000", "6pm"] do
        assert {:error, [{[:recurring_windows, 0, :starts], :invalid}]} =
                 Policy.from_map(%{map | "recurring_windows" => [%{w | "starts" => starts}]})
      end

      [o] = map["one_off_windows"]

      assert {:error, [{[:one_off_windows, 0, :starts_at], :invalid}]} =
               Policy.from_map(%{
                 map
                 | "one_off_windows" => [%{o | "starts_at" => "2026-11-02T09:00:00Z"}]
               })
    end

    test "reports nested errors from decoded input" do
      {:ok, p} = Policy.new(attrs())
      map = Policy.to_map(p)
      [w] = map["recurring_windows"]

      assert {:error, [{[:recurring_windows, 0, :days], :invalid}]} =
               Policy.from_map(%{map | "recurring_windows" => [%{w | "days" => ["1"]}]})

      assert {:error, [{[:recurring_windows, 0, "colour"], :unknown_key}]} =
               Policy.from_map(%{map | "recurring_windows" => [Map.put(w, "colour", "red")]})
    end
  end

  defp json_compatible?(v) when is_nil(v) or is_boolean(v) or is_integer(v), do: true
  defp json_compatible?(v) when is_binary(v), do: String.valid?(v)
  defp json_compatible?(v) when is_list(v), do: Enum.all?(v, &json_compatible?/1)

  defp json_compatible?(v) when is_map(v) and not is_struct(v),
    do: Enum.all?(v, fn {k, val} -> is_binary(k) and json_compatible?(val) end)

  defp json_compatible?(_), do: false
end
