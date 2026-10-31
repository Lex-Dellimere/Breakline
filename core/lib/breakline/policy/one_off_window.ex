defmodule Breakline.Policy.OneOffWindow do
  @moduledoc """
  A single booked window, with `starts_at` and `ends_at` as naive local
  datetimes in the site's time zone (whole minutes, `ends_at` after
  `starts_at`).
  """

  alias Breakline.Policy
  alias Breakline.Policy.Fields

  @enforce_keys [:id, :starts_at, :ends_at]
  defstruct [:id, :starts_at, :ends_at]

  @type t :: %__MODULE__{
          id: String.t(),
          starts_at: NaiveDateTime.t(),
          ends_at: NaiveDateTime.t()
        }

  @doc """
  Builds a validated window from a keyword list, an atom keyed map or a struct.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [Policy.reason()]}
  def new(attrs) do
    specs = [
      {:id, :required, &Fields.string/1},
      {:starts_at, :required, &Fields.minute_naive/1},
      {:ends_at, :required, &Fields.minute_naive/1}
    ]

    with {:ok, values} <- Fields.validate(attrs, specs) do
      if NaiveDateTime.compare(values.ends_at, values.starts_at) == :gt do
        {:ok, struct!(__MODULE__, values)}
      else
        {:error, [{[:ends_at], :not_after_starts_at}]}
      end
    end
  end

  @doc "Encodes the window as a json-compatible map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = window) do
    %{
      "id" => window.id,
      "starts_at" => NaiveDateTime.to_iso8601(window.starts_at),
      "ends_at" => NaiveDateTime.to_iso8601(window.ends_at)
    }
  end

  @doc "Decodes and validates a string keyed map produced by `to_map/1`."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Policy.reason()]}
  def from_map(map) do
    table = [
      {"id", :id, &Fields.as_is/1},
      {"starts_at", :starts_at, &Fields.decode_naive/1},
      {"ends_at", :ends_at, &Fields.decode_naive/1}
    ]

    with {:ok, attrs} <- Fields.decode_keys(map, table), do: new(attrs)
  end
end
