defmodule Breakline.Policy.RecurringWindow do
  @moduledoc """
  A weekly maintenance window in the site's local time.

  `days` are ISO weekdays (Monday is 1, Sunday is 7). `starts` and `ends` are
  local wall-clock times in whole minutes. When `ends` is not after `starts`
  the window crosses midnight and ends on the following local day. A window
  where `ends` equals `starts` is invalid.
  """

  alias Breakline.Policy
  alias Breakline.Policy.Fields

  @enforce_keys [:id, :days, :starts, :ends]
  defstruct [:id, :days, :starts, :ends]

  @type t :: %__MODULE__{
          id: String.t(),
          days: [1..7, ...],
          starts: Time.t(),
          ends: Time.t()
        }

  @doc """
  Builds a validated window from a keyword list, an atom keyed map or a struct.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [Policy.reason()]}
  def new(attrs) do
    specs = [
      {:id, :required, &Fields.string/1},
      {:days, :required, &days/1},
      {:starts, :required, &Fields.minute_time/1},
      {:ends, :required, &Fields.minute_time/1}
    ]

    with {:ok, values} <- Fields.validate(attrs, specs) do
      if Time.compare(values.starts, values.ends) == :eq do
        {:error, [{[:ends], :equals_starts}]}
      else
        {:ok, struct!(__MODULE__, values)}
      end
    end
  end

  @doc "Encodes the window as a json-compatible map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = window) do
    %{
      "id" => window.id,
      "days" => window.days,
      "starts" => Time.to_iso8601(window.starts),
      "ends" => Time.to_iso8601(window.ends)
    }
  end

  @doc "Decodes and validates a string keyed map produced by `to_map/1`."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Policy.reason()]}
  def from_map(map) do
    table = [
      {"id", :id, &Fields.as_is/1},
      {"days", :days, &Fields.as_is/1},
      {"starts", :starts, &Fields.decode_time/1},
      {"ends", :ends, &Fields.decode_time/1}
    ]

    with {:ok, attrs} <- Fields.decode_keys(map, table), do: new(attrs)
  end

  defp days([_ | _] = days) do
    if Enum.all?(days, &(is_integer(&1) and &1 in 1..7)) and Enum.uniq(days) == days do
      {:ok, days}
    else
      Fields.invalid()
    end
  end

  defp days(_), do: Fields.invalid()
end
