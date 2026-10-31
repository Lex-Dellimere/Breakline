defmodule Breakline.Policy.BreakGlass do
  @moduledoc """
  An approver's "open now" override, active until `until` (UTC).

  A sub-second `until` is truncated to the whole second so break-glass never
  lasts longer than approved.
  """

  alias Breakline.Policy
  alias Breakline.Policy.Fields

  @enforce_keys [:until, :approved_by]
  defstruct [:until, :approved_by]

  @type t :: %__MODULE__{until: DateTime.t(), approved_by: String.t()}

  @doc """
  Builds a validated break-glass from a keyword list, an atom keyed map or a
  struct.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [Policy.reason()]}
  def new(attrs) do
    specs = [
      {:until, :required, &Fields.utc_datetime(&1, :floor)},
      {:approved_by, :required, &Fields.string/1}
    ]

    with {:ok, values} <- Fields.validate(attrs, specs), do: {:ok, struct!(__MODULE__, values)}
  end

  @doc "Encodes the break-glass as a json-compatible map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = bg) do
    %{"until" => Fields.encode_utc(bg.until), "approved_by" => bg.approved_by}
  end

  @doc "Decodes and validates a string keyed map produced by `to_map/1`."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Policy.reason()]}
  def from_map(map) do
    table = [
      {"until", :until, &Fields.decode_utc/1},
      {"approved_by", :approved_by, &Fields.as_is/1}
    ]

    with {:ok, attrs} <- Fields.decode_keys(map, table), do: new(attrs)
  end
end
