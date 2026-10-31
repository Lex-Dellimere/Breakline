defmodule Breakline.AuditLog do
  @moduledoc """
  Tamper-evident audit log as a SHA-256 hash chain (threat model T9).

  Each record is a json-compatible map:

      %{"seq" => 0, "prev_hash" => "00…00", "hash" => "9f…", "entry" => %{...}}

  and

      hash = SHA-256(prev_hash_bytes <> CanonicalJSON.encode!(Map.put(entry, "seq", seq)))

  `prev_hash` and `hash` are lowercase hex in the record; the raw 32 bytes are what get
  hashed. The first record (seq 0) has 32 zero bytes as its `prev_hash`. Merging `seq`
  into the hashed entry binds each record to its position, so deleting, inserting or
  reordering records breaks the chain. `"seq"` is therefore a reserved entry key.

  `verify_chain/2` detects any edit, insertion, deletion or reordering inside the
  records it is given. A hash chain has no secret, though: someone who can rewrite the
  storage can also recompute every hash from some point on, and cutting off the tail
  leaves a valid shorter chain. Both are only detectable against an independently kept
  head, passed as `expected_head:`; the gateway and the cloud each keep their own.

  The chain struct is a convenience for building logs in memory. Storage-backed callers
  (database rows, files on disk) keep only the head and use `append_record/2`.
  """

  alias Breakline.CanonicalJSON

  defstruct head: nil, next_seq: 0, records_rev: []

  @typedoc "a chain held in memory; records are kept newest first internally"
  @type t :: %__MODULE__{
          head: head(),
          next_seq: non_neg_integer(),
          records_rev: [record()]
        }

  @type hash_hex :: String.t()
  @type head :: {non_neg_integer(), hash_hex()} | nil
  @type record :: %{required(String.t()) => term()}
  @type break_reason ::
          :malformed | :seq_gap | :prev_mismatch | :hash_mismatch | :truncated | :head_mismatch

  @zero_hash <<0::256>>

  @doc """
  Returns an empty chain.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Appends `entry` (a json-compatible map without a `"seq"` key) to the chain.
  Raises `ArgumentError` if the entry is not json-compatible or uses `"seq"`.
  """
  @spec append(t(), map()) :: t()
  def append(%__MODULE__{} = chain, entry) do
    record = append_record(chain.head, entry)

    %__MODULE__{
      head: {record["seq"], record["hash"]},
      next_seq: record["seq"] + 1,
      records_rev: [record | chain.records_rev]
    }
  end

  @doc """
  Returns the chain's records, oldest first.
  """
  @spec records(t()) :: [record()]
  def records(%__MODULE__{records_rev: rev}), do: Enum.reverse(rev)

  @doc """
  Returns `{seq, hash_hex}` of the newest record, or `nil` for an empty chain.
  """
  @spec head(t()) :: head()
  def head(%__MODULE__{head: head}), do: head

  @doc """
  Builds the record that follows `head` (`nil` for the first record), without needing
  the rest of the chain. The new head is `{record["seq"], record["hash"]}`.

  Atom keys in `entry` are normalised to strings so the record is json-compatible.
  Raises `ArgumentError` if the entry is not a json-compatible map or uses `"seq"`.
  """
  @spec append_record(head(), map()) :: record()
  def append_record(head, entry) when is_map(entry) and not is_struct(entry) do
    entry = normalize!(entry)

    {seq, prev} =
      case head do
        nil -> {0, @zero_hash}
        {seq, hash_hex} when is_integer(seq) and seq >= 0 -> {seq + 1, decode_hash!(hash_hex)}
      end

    %{
      "seq" => seq,
      "prev_hash" => hex(prev),
      "hash" => hex(hash(prev, entry, seq)),
      "entry" => entry
    }
  end

  def append_record(_head, entry),
    do: raise(ArgumentError, "entry must be a map, got: #{inspect(entry)}")

  @doc """
  Verifies a list of records, oldest first, starting at seq 0.

  Returns `:ok` or `{:error, {:broken_at, index, reason}}`, where `index` is the
  position in the list (which equals the expected seq) and `reason` is one of:

    * `:malformed`: not a record map, bad field types, or an entry using `"seq"`
    * `:seq_gap`: the record's seq is not its position
    * `:prev_mismatch`: `prev_hash` is not the previous record's hash
    * `:hash_mismatch`: `hash` does not match the record's contents

  With `expected_head: {seq, hash_hex}` the last record must also be that head:
  `:truncated` (at the first missing seq) if the chain stops short of it, and
  `:head_mismatch` if the record at that seq has another hash or the chain runs past it.
  `expected_head: nil` (the head of an empty chain) requires `records` to be empty.
  """
  @spec verify_chain([record()], keyword()) ::
          :ok | {:error, {:broken_at, non_neg_integer(), break_reason()}}
  def verify_chain(records, opts \\ []) when is_list(records) do
    with {:ok, last} <- walk(records, 0, @zero_hash) do
      check_head(last, Keyword.get(opts, :expected_head, :none))
    end
  end

  # walking the chain

  defp walk([], _index, _prev), do: {:ok, nil}

  defp walk([record | rest], index, prev) do
    case check_record(record, index, prev) do
      {:ok, this_hash} ->
        case rest do
          [] -> {:ok, {index, hex(this_hash)}}
          _ -> walk(rest, index + 1, this_hash)
        end

      {:error, reason} ->
        {:error, {:broken_at, index, reason}}
    end
  end

  defp check_record(
         %{"seq" => seq, "prev_hash" => prev_hex, "hash" => hash_hex, "entry" => entry} = record,
         index,
         prev
       )
       when map_size(record) == 4 and is_map(entry) and is_binary(prev_hex) and
              is_binary(hash_hex) do
    cond do
      Map.has_key?(entry, "seq") -> {:error, :malformed}
      seq != index -> {:error, :seq_gap}
      prev_hex != hex(prev) -> {:error, :prev_mismatch}
      true -> check_hash(prev, entry, seq, hash_hex)
    end
  end

  defp check_record(_record, _index, _prev), do: {:error, :malformed}

  defp check_hash(prev, entry, seq, hash_hex) do
    case CanonicalJSON.encode(Map.put(entry, "seq", seq)) do
      {:ok, json} ->
        computed = :crypto.hash(:sha256, prev <> json)
        if hex(computed) == hash_hex, do: {:ok, computed}, else: {:error, :hash_mismatch}

      {:error, _} ->
        {:error, :malformed}
    end
  end

  defp check_head(_last, :none), do: :ok
  defp check_head(nil, nil), do: :ok
  # an expected empty chain that has records
  defp check_head(_last, nil), do: {:error, {:broken_at, 0, :head_mismatch}}

  defp check_head(nil, {_seq, _hash}), do: {:error, {:broken_at, 0, :truncated}}

  defp check_head({last_seq, last_hash}, {seq, hash_hex}) do
    cond do
      last_seq < seq -> {:error, {:broken_at, last_seq + 1, :truncated}}
      last_seq > seq -> {:error, {:broken_at, seq + 1, :head_mismatch}}
      last_hash != hash_hex -> {:error, {:broken_at, seq, :head_mismatch}}
      true -> :ok
    end
  end

  # hashing

  defp hash(prev, entry, seq) do
    :crypto.hash(:sha256, prev <> CanonicalJSON.encode!(Map.put(entry, "seq", seq)))
  end

  defp normalize!(entry) do
    {:ok, normalized} = entry |> CanonicalJSON.encode!() |> CanonicalJSON.decode()

    if Map.has_key?(normalized, "seq"),
      do: raise(ArgumentError, ~s("seq" is a reserved audit entry key))

    normalized
  end

  defp decode_hash!(hash_hex) do
    case is_binary(hash_hex) and Base.decode16(hash_hex, case: :lower) do
      {:ok, <<_::binary-size(32)>> = bytes} -> bytes
      _ -> raise ArgumentError, "invalid head hash: #{inspect(hash_hex)}"
    end
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
