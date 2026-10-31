defmodule Breakline.CanonicalJSON do
  @moduledoc """
  Deterministic JSON encoding for signing and hashing.

  The same json-compatible term always encodes to the same bytes, whatever order its
  maps were built in. Signed commands and the audit chain hash these bytes, so the cloud
  and the gateway must agree on them exactly.

  A json-compatible term is `nil`, `true`, `false`, an integer, a utf-8 binary, a list
  of json-compatible terms, or a map whose keys are strings (atom keys are accepted and
  converted to strings) and whose values are json-compatible.

  Encoding rules:

    * object keys are sorted by their utf-8 bytes
    * no insignificant whitespace
    * strings escape only `"`, `\\` and control characters below 0x20, using `\\b`,
      `\\f`, `\\n`, `\\r`, `\\t` where they exist and `\\u00xx` (lowercase hex)
      otherwise; every other character is written as literal utf-8
    * integers are written in plain decimal

  This is close to, but not exactly, RFC 8785 (JCS). Floats are rejected rather than
  serialised with the ECMAScript number algorithm, and keys are sorted by utf-8 bytes
  rather than utf-16 code units. The two orders only differ for keys containing
  characters outside the basic multilingual plane, which Breakline never produces.

  Rejected with `{:error, reason}`: floats, atoms other than `nil`, `true` and `false`
  used as values, tuples, structs, pids, references, functions, binaries that are not
  valid utf-8, non-string non-atom map keys, and maps where an atom key and a string key
  collide after conversion.
  """

  @type json ::
          nil | boolean() | integer() | String.t() | [json()] | %{optional(String.t()) => json()}

  @type reason ::
          {:unsupported, term()}
          | {:invalid_utf8, binary()}
          | {:invalid_key, term()}
          | {:duplicate_key, String.t()}

  @doc """
  Encodes a json-compatible term to canonical JSON bytes.
  """
  @spec encode(term()) :: {:ok, binary()} | {:error, reason()}
  def encode(term) do
    {:ok, term |> enc() |> IO.iodata_to_binary()}
  catch
    {:canonical_json_error, reason} -> {:error, reason}
  end

  @doc """
  Like `encode/1` but raises `ArgumentError` on unsupported input.
  """
  @spec encode!(term()) :: binary()
  def encode!(term) do
    case encode(term) do
      {:ok, bin} -> bin
      {:error, reason} -> raise ArgumentError, "cannot canonically encode: #{inspect(reason)}"
    end
  end

  @doc """
  Decodes JSON bytes. Delegates to Elixir's built-in `JSON.decode/1`, so the result may
  contain floats; callers that need a json-compatible term should re-encode it.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary), do: JSON.decode(binary)

  # encoding

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(int) when is_integer(int), do: Integer.to_string(int)
  defp enc(bin) when is_binary(bin), do: enc_string(bin)
  defp enc(list) when is_list(list), do: enc_list(list)

  defp enc(%_{} = struct), do: fail({:unsupported, struct})

  defp enc(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {key(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))

    check_unique(pairs)

    body =
      pairs
      |> Enum.map(fn {k, v} -> [enc_string(k), ?:, enc(v)] end)
      |> Enum.intersperse(?,)

    [?{, body, ?}]
  end

  defp enc(other), do: fail({:unsupported, other})

  defp enc_list(list) do
    if not proper_list?(list), do: fail({:unsupported, list})
    [?[, list |> Enum.map(&enc/1) |> Enum.intersperse(?,), ?]]
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: fail({:invalid_key, k})

  # keys are sorted, so a collision shows up as two equal neighbours
  defp check_unique([{a, _}, {a, _} | _]), do: fail({:duplicate_key, a})
  defp check_unique([_ | rest]), do: check_unique(rest)
  defp check_unique([]), do: :ok

  defp enc_string(bin) do
    if not String.valid?(bin), do: fail({:invalid_utf8, bin})
    [?", escape(bin, bin, 0, 0, []), ?"]
  end

  # walks the binary, copying runs of unescaped bytes as sub-binaries
  defp escape(<<>>, orig, start, len, acc), do: [acc | binary_part(orig, start, len)]

  defp escape(<<c, rest::binary>>, orig, start, len, acc) when c < 0x20 or c in [?", ?\\] do
    acc = [acc, binary_part(orig, start, len), escape_char(c)]
    escape(rest, orig, start + len + 1, 0, acc)
  end

  defp escape(<<_, rest::binary>>, orig, start, len, acc),
    do: escape(rest, orig, start, len + 1, acc)

  defp escape_char(?"), do: "\\\""
  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?\b), do: "\\b"
  defp escape_char(?\f), do: "\\f"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\t), do: "\\t"

  defp escape_char(c) do
    hex = c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    ["\\u00", hex]
  end

  defp fail(reason), do: throw({:canonical_json_error, reason})
end
