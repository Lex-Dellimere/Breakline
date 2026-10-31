defmodule Breakline.AuditExport do
  @moduledoc """
  Offline verification of a Breakline audit export (`"format":
  "breakline-audit-export/1"`), the json file the cloud's audit export
  produces. Pure: it takes the decoded json map and returns a result, so an
  auditor can re-check an export without the cloud or its database
  (`mix breakline.audit.verify`).

  An export holds one segment per hash chain: the tenant's cloud chain under
  `"cloud_audit"` and each site gateway's current chain under
  `"gateway_audit"`. A segment is the chain's records in the export period,
  plus:

    * `"previous_record"`: the record just before the period, or null when
      the period starts at the chain's genesis (seq 0);
    * `"head"`: the chain's head (`{"seq", "hash"}`) when the export was
      made, or null for an empty chain;
    * `"from_genesis"`: true when the segment starts at seq 0;
    * `"to_head"`: true when the segment runs up to the head.

  Each segment is verified with `Breakline.AuditLog.verify_segment/2`, the
  previous record first. A segment starting at seq 0 is anchored at the
  genesis hash; a segment starting mid-chain is anchored at the previous
  record's own `prev_hash`, so the previous record's hash and every link
  after it are checked. When the segment claims to reach the head, its last
  record must be exactly the head (`:truncated` or `:head_mismatch`
  otherwise); when it stops earlier, the head cannot be checked from the
  file and the result says so.

  What this proves: the records in the file are a consistent, gap-free piece
  of a hash chain that ends at the stated head. It does not prove the head
  itself is genuine: compare it with a head recorded independently (an
  earlier export, the gateway's own `audit.jsonl`) for that (threat model
  T9).
  """

  alias Breakline.AuditLog

  @format "breakline-audit-export/1"

  @typedoc "The result for one chain segment."
  @type chain_result :: %{
          name: String.t(),
          records: non_neg_integer(),
          result: :ok | {:broken_at, non_neg_integer(), atom()},
          head_checked?: boolean()
        }

  @doc "The format string this module verifies."
  @spec format() :: String.t()
  def format, do: @format

  @doc """
  Verifies every chain segment of a decoded export.

  Returns `{:ok, results}` when every segment is intact, `{:error, results}`
  when at least one is broken (each result says which), or
  `{:error, :not_an_export}` when the map is not an export of this format.
  """
  @spec verify(term()) :: {:ok, [chain_result()]} | {:error, [chain_result()] | :not_an_export}
  def verify(%{"format" => @format} = export) do
    with {:ok, cloud} <- fetch_map(export, "cloud_audit"),
         {:ok, gateways} <- fetch_list(export, "gateway_audit") do
      results =
        [verify_segment("cloud audit chain", cloud, &cloud_record/1)] ++
          Enum.map(gateways, fn segment ->
            verify_segment(gateway_name(segment), segment, &gateway_record/1)
          end)

      if Enum.all?(results, &(&1.result == :ok)),
        do: {:ok, results},
        else: {:error, results}
    end
  end

  def verify(_export), do: {:error, :not_an_export}

  @doc "A one-line, human-readable description of a chain result."
  @spec describe(chain_result()) :: String.t()
  def describe(%{name: name, records: n, result: :ok, head_checked?: true}),
    do: "#{name}: intact, #{n} records checked, ends at the head"

  def describe(%{name: name, records: n, result: :ok}),
    do: "#{name}: intact, #{n} records checked (the period ends before the head)"

  def describe(%{name: name, result: {:broken_at, seq, reason}}),
    do: "#{name}: broken at seq #{seq}: #{reason}"

  # one segment

  defp verify_segment(name, segment, to_record) when is_map(segment) do
    previous = segment["previous_record"]
    records = List.wrap(segment["records"])
    listed = if is_nil(previous), do: records, else: [previous | records]

    result =
      with {:ok, chain} <- convert(listed, to_record),
           :ok <- check_genesis(chain, segment["from_genesis"]),
           {:ok, last} <- walk(chain),
           :ok <- check_head(last, segment["head"], segment["to_head"] == true) do
        :ok
      end

    %{
      name: name,
      records: length(listed),
      result: result,
      head_checked?: result == :ok and segment["to_head"] == true
    }
  end

  defp verify_segment(name, _segment, _to_record),
    do: %{name: name, records: 0, result: {:broken_at, 0, :malformed}, head_checked?: false}

  defp convert(listed, to_record) do
    listed
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case to_record.(item) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        :error -> {:halt, {:broken_at, seq_of(item, index), :malformed}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      broken -> broken
    end
  end

  defp seq_of(%{"seq" => seq}, _index) when is_integer(seq) and seq >= 0, do: seq
  defp seq_of(_item, index), do: index

  # a segment that says it starts at genesis must start at seq 0
  defp check_genesis([%{"seq" => seq} | _], true) when seq != 0, do: {:broken_at, 0, :truncated}
  defp check_genesis(_chain, _from_genesis), do: :ok

  defp walk([]), do: {:ok, nil}

  defp walk([%{"seq" => seq, "prev_hash" => prev} | _] = chain)
       when is_integer(seq) and seq >= 0 and is_binary(prev) do
    after_head = if seq == 0, do: nil, else: {seq - 1, prev}

    case safe_verify(chain, after_head) do
      {:ok, head} -> {:ok, head}
      {:error, {:broken_at, at, reason}} -> {:broken_at, at, reason}
    end
  end

  defp walk(_chain), do: {:broken_at, 0, :malformed}

  defp safe_verify(chain, after_head) do
    AuditLog.verify_segment(chain, after: after_head)
  rescue
    # a prev_hash that is not 32 bytes of lowercase hex
    ArgumentError ->
      [%{"seq" => seq} | _] = chain
      {:error, {:broken_at, seq, :malformed}}
  end

  defp check_head(nil, nil, _to_head?), do: :ok
  # no records but the export claims to reach a non-empty head
  defp check_head(nil, %{"seq" => seq}, true) when is_integer(seq),
    do: {:broken_at, 0, :truncated}

  defp check_head(nil, _head, _to_head?), do: :ok

  defp check_head({_seq, _hash}, nil, true), do: {:broken_at, 0, :head_mismatch}

  defp check_head({last_seq, last_hash}, %{"seq" => seq, "hash" => hash}, to_head?)
       when is_integer(seq) do
    cond do
      last_seq > seq -> {:broken_at, seq + 1, :head_mismatch}
      last_seq == seq and last_hash != hash -> {:broken_at, seq, :head_mismatch}
      last_seq < seq and to_head? -> {:broken_at, last_seq + 1, :truncated}
      true -> :ok
    end
  end

  defp check_head(_last, nil, false), do: :ok
  defp check_head(_last, _head, _to_head?), do: {:broken_at, 0, :malformed}

  # record shapes

  # a cloud entry as exported: the chain fields plus readable extras, which are not hashed
  defp cloud_record(%{"seq" => seq, "prev_hash" => prev, "hash" => hash, "entry" => entry}),
    do: {:ok, %{"seq" => seq, "prev_hash" => prev, "hash" => hash, "entry" => entry}}

  defp cloud_record(_item), do: :error

  # a gateway record as exported: the record as the gateway sent it, plus copies of its
  # seq and hashes, which must agree with it
  defp gateway_record(
         %{"seq" => seq, "prev_hash" => prev, "hash" => hash, "record" => record} = item
       )
       when is_map(record) do
    if map_size(item) == 4 and record["seq"] == seq and record["prev_hash"] == prev and
         record["hash"] == hash,
       do: {:ok, record},
       else: :error
  end

  defp gateway_record(_item), do: :error

  defp gateway_name(%{"site_name" => name}) when is_binary(name),
    do: "gateway audit chain of #{name}"

  defp gateway_name(%{"site_id" => id}) when is_binary(id), do: "gateway audit chain of #{id}"
  defp gateway_name(_segment), do: "gateway audit chain"

  defp fetch_map(export, key) do
    case export[key] do
      %{} = value -> {:ok, value}
      _ -> {:error, :not_an_export}
    end
  end

  defp fetch_list(export, key) do
    case export[key] do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, :not_an_export}
    end
  end
end
