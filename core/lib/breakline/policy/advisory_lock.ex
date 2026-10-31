defmodule Breakline.Policy.AdvisoryLock do
  @moduledoc """
  A lock on the whole site, usually raised because a tool is under active
  exploitation. `source` says where it came from (for example
  `"kev:CVE-2026-18577"`, `"acsc"` or `"manual"`). `expires_at` is a UTC
  datetime, or nil for a lock that holds until it is lifted.

  A sub-second `expires_at` is rounded up to the next whole second so the
  lock never ends earlier than asked.
  """

  alias Breakline.Policy
  alias Breakline.Policy.Fields

  @enforce_keys [:id, :reason, :source]
  defstruct [:id, :reason, :source, expires_at: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          reason: String.t(),
          source: String.t(),
          expires_at: DateTime.t() | nil
        }

  @doc """
  Builds a validated lock from a keyword list, an atom keyed map or a struct.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [Policy.reason()]}
  def new(attrs) do
    specs = [
      {:id, :required, &Fields.string/1},
      {:reason, :required, &Fields.string/1},
      {:source, :required, &Fields.string/1},
      {:expires_at, {:default, nil}, Fields.nilable(&Fields.utc_datetime(&1, :ceil))}
    ]

    with {:ok, values} <- Fields.validate(attrs, specs), do: {:ok, struct!(__MODULE__, values)}
  end

  @doc "Encodes the lock as a json-compatible map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = lock) do
    %{
      "id" => lock.id,
      "reason" => lock.reason,
      "source" => lock.source,
      "expires_at" => Fields.encode_utc(lock.expires_at)
    }
  end

  @doc "Decodes and validates a string keyed map produced by `to_map/1`."
  @spec from_map(term()) :: {:ok, t()} | {:error, [Policy.reason()]}
  def from_map(map) do
    table = [
      {"id", :id, &Fields.as_is/1},
      {"reason", :reason, &Fields.as_is/1},
      {"source", :source, &Fields.as_is/1},
      {"expires_at", :expires_at, &Fields.decode_utc/1}
    ]

    with {:ok, attrs} <- Fields.decode_keys(map, table), do: new(attrs)
  end
end
