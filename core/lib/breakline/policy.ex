defmodule Breakline.Policy do
  @moduledoc """
  A site's access policy: which RMM tools it covers, when their channel may be
  open, and the overrides (advisory locks and break-glass) on top of that.

  Windows are stored in the site's IANA time zone. `Breakline.Schedule`
  turns a policy into an open or locked state at a given UTC instant.

  `version` is monotonic. The cloud bumps it on every change and the gateway
  rejects any policy whose version is not greater than the one it applied.
  `mode` does not affect the schedule: in `:monitor` mode the gateway logs
  what it would have blocked instead of blocking it.

  `new/1` validates trusted, atom keyed attrs. `from_map/1` decodes the
  untrusted string keyed form produced by `to_map/1` and never creates atoms.
  Both reject unknown keys, so a field this version does not understand can
  never be silently dropped.

  Validation errors are a list of `{path, message}` tuples, where `path`
  points at the offending field, for example
  `{[:recurring_windows, 0, :days], :invalid}`.
  """

  alias Breakline.Policy.{AdvisoryLock, BreakGlass, Fields, OneOffWindow, RecurringWindow}

  @enforce_keys [:site_id, :version, :mode, :time_zone]
  defstruct [
    :site_id,
    :version,
    :mode,
    :time_zone,
    tool_ids: [],
    site_hosts: [],
    recurring_windows: [],
    one_off_windows: [],
    advisory_locks: [],
    break_glass: nil
  ]

  @type mode :: :enforce | :monitor

  @type t :: %__MODULE__{
          site_id: String.t(),
          version: non_neg_integer(),
          mode: mode(),
          time_zone: String.t(),
          tool_ids: [String.t()],
          site_hosts: [String.t()],
          recurring_windows: [RecurringWindow.t()],
          one_off_windows: [OneOffWindow.t()],
          advisory_locks: [AdvisoryLock.t()],
          break_glass: BreakGlass.t() | nil
        }

  @typedoc "A validation error: the path to the field and what is wrong with it."
  @type reason :: {[atom() | non_neg_integer() | String.t()], atom()}

  @doc """
  Builds a validated policy from a keyword list or an atom keyed map.

  `site_id`, `version`, `mode` and `time_zone` are required. The lists default
  to empty and `break_glass` to nil. Nested windows, locks and break-glass may
  be given as structs or as attrs.

  Window ids must be unique across recurring and one-off windows, lock ids
  must be unique, and `tool_ids` must not repeat.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [reason()]}
  def new(attrs) do
    specs = [
      {:site_id, :required, &Fields.string/1},
      {:version, :required, &Fields.non_neg_integer/1},
      {:mode, :required, &mode/1},
      {:time_zone, :required, &time_zone/1},
      {:tool_ids, {:default, []}, unique(Fields.list_of(&Fields.string/1))},
      {:site_hosts, {:default, []}, Fields.list_of(&Fields.string/1)},
      {:recurring_windows, {:default, []}, Fields.list_of(&RecurringWindow.new/1)},
      {:one_off_windows, {:default, []}, Fields.list_of(&OneOffWindow.new/1)},
      {:advisory_locks, {:default, []}, Fields.list_of(&AdvisoryLock.new/1)},
      {:break_glass, {:default, nil}, Fields.nilable(&BreakGlass.new/1)}
    ]

    with {:ok, values} <- Fields.validate(attrs, specs),
         :ok <- check_unique_ids(values) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  @doc """
  Encodes the policy as a json-compatible map with string keys. Datetimes
  become ISO 8601 strings and `mode` becomes `"enforce"` or `"monitor"`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = policy) do
    %{
      "site_id" => policy.site_id,
      "version" => policy.version,
      "mode" => Atom.to_string(policy.mode),
      "time_zone" => policy.time_zone,
      "tool_ids" => policy.tool_ids,
      "site_hosts" => policy.site_hosts,
      "recurring_windows" => Enum.map(policy.recurring_windows, &RecurringWindow.to_map/1),
      "one_off_windows" => Enum.map(policy.one_off_windows, &OneOffWindow.to_map/1),
      "advisory_locks" => Enum.map(policy.advisory_locks, &AdvisoryLock.to_map/1),
      "break_glass" => policy.break_glass && BreakGlass.to_map(policy.break_glass)
    }
  end

  @doc """
  Decodes and validates an untrusted string keyed map, as produced by
  `to_map/1`. Datetimes must be in the exact canonical form `to_map/1` emits.
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, [reason()]}
  def from_map(map) do
    table = [
      {"site_id", :site_id, &Fields.as_is/1},
      {"version", :version, &Fields.as_is/1},
      {"mode", :mode, &decode_mode/1},
      {"time_zone", :time_zone, &Fields.as_is/1},
      {"tool_ids", :tool_ids, &Fields.as_is/1},
      {"site_hosts", :site_hosts, &Fields.as_is/1},
      {"recurring_windows", :recurring_windows, Fields.list_of(&RecurringWindow.from_map/1)},
      {"one_off_windows", :one_off_windows, Fields.list_of(&OneOffWindow.from_map/1)},
      {"advisory_locks", :advisory_locks, Fields.list_of(&AdvisoryLock.from_map/1)},
      {"break_glass", :break_glass, Fields.nilable(&BreakGlass.from_map/1)}
    ]

    with {:ok, attrs} <- Fields.decode_keys(map, table), do: new(attrs)
  end

  defp mode(mode) when mode in [:enforce, :monitor], do: {:ok, mode}
  defp mode(_), do: Fields.invalid()

  defp decode_mode("enforce"), do: {:ok, :enforce}
  defp decode_mode("monitor"), do: {:ok, :monitor}
  defp decode_mode(_), do: :error

  defp time_zone(tz) when is_binary(tz) do
    # any fixed wall time works: an unknown zone fails before periods are looked up
    case DateTime.from_naive(~N[2000-01-01 12:00:00], tz, Breakline.time_zone_database()) do
      {:error, _} -> {:error, [{[], :unknown_time_zone}]}
      _ -> {:ok, tz}
    end
  end

  defp time_zone(_), do: Fields.invalid()

  defp unique(validator) do
    fn value ->
      with {:ok, list} <- validator.(value) do
        if Enum.uniq(list) == list, do: {:ok, list}, else: {:error, [{[], :duplicate}]}
      end
    end
  end

  defp check_unique_ids(values) do
    window_ids = Enum.map(values.recurring_windows ++ values.one_off_windows, & &1.id)
    lock_ids = Enum.map(values.advisory_locks, & &1.id)

    errors =
      Enum.map(duplicates(window_ids), &{[:windows, &1], :duplicate_id}) ++
        Enum.map(duplicates(lock_ids), &{[:advisory_locks, &1], :duplicate_id})

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp duplicates(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.filter(fn {_, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
