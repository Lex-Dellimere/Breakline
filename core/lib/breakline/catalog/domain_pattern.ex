defmodule Breakline.Catalog.DomainPattern do
  @moduledoc """
  Compiles and matches the domain patterns used by the tool catalog.

  Three forms are supported:

    * An exact name such as `boot.net.anydesk.com` matches only that name.
    * A leading `*.` such as `*.teamviewer.com` matches one or more whole
      labels in front of the suffix (`a.teamviewer.com`,
      `a.b.teamviewer.com`) but never the bare suffix `teamviewer.com`.
    * A `*` inside a label such as `relay-*.net.anydesk.com` matches zero or
      more characters within that one label and never crosses a dot. It can be
      combined with a leading `*.`.

  Matching ignores case and a single trailing dot on the query name, so
  `Boot.Net.AnyDesk.com.` matches `boot.net.anydesk.com`.

  Patterns are rejected when they are empty, contain an empty label, use a
  bare `*`, put a `*` in the top-level label, use characters other than
  letters, digits, `-`, `_` and `*`, or apply a leading `*.` to a single-label
  suffix such as `*.com`. A compiled pattern is plain data, so it can be built
  at compile time and stored in a module attribute.
  """

  @enforce_keys [:source, :kind, :labels]
  defstruct [:source, :kind, :labels]

  @typedoc "A single label, either a literal or the literal pieces between `*` wildcards."
  @type label :: {:literal, String.t()} | {:glob, [String.t(), ...]}

  @typedoc """
  A compiled pattern. `labels` are stored right to left (top-level label
  first). `kind` is `:exact` for a name of fixed length and `:subdomains` for
  a leading `*.`, where `labels` hold the suffix only.
  """
  @type t :: %__MODULE__{
          source: String.t(),
          kind: :exact | :subdomains,
          labels: [label(), ...]
        }

  @type error ::
          :empty
          | :empty_label
          | :bare_wildcard
          | :wildcard_tld
          | :suffix_too_short
          | :invalid_character
          | :label_too_long

  @max_label 63

  @doc """
  Compiles a pattern string. Returns `{:error, reason}` for invalid patterns.

      iex> {:ok, p} = Breakline.Catalog.DomainPattern.compile("*.teamviewer.com")
      iex> p.kind
      :subdomains

      iex> Breakline.Catalog.DomainPattern.compile("*.com")
      {:error, :suffix_too_short}
  """
  @spec compile(String.t()) :: {:ok, t()} | {:error, error()}
  def compile(pattern) when is_binary(pattern) do
    lower = String.downcase(pattern)

    case String.split(lower, ".") do
      [""] -> {:error, :empty}
      ["*"] -> {:error, :bare_wildcard}
      ["*" | suffix] -> build(pattern, :subdomains, suffix)
      labels -> build(pattern, :exact, labels)
    end
  end

  @doc """
  Compiles a pattern string, raising `ArgumentError` when it is invalid.
  """
  @spec compile!(String.t()) :: t()
  def compile!(pattern) do
    case compile(pattern) do
      {:ok, compiled} ->
        compiled

      {:error, reason} ->
        raise ArgumentError, "invalid domain pattern #{inspect(pattern)}: #{reason}"
    end
  end

  @doc """
  Returns true when the query name matches the compiled pattern.

      iex> p = Breakline.Catalog.DomainPattern.compile!("relay-*.net.anydesk.com")
      iex> Breakline.Catalog.DomainPattern.match?(p, "RELAY-0a1b.net.anydesk.com.")
      true
      iex> Breakline.Catalog.DomainPattern.match?(p, "relay-a.b.net.anydesk.com")
      false
  """
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{kind: kind, labels: pattern_labels}, qname) when is_binary(qname) do
    case query_labels(qname) do
      {:ok, query} -> labels_match?(kind, pattern_labels, query)
      :error -> false
    end
  end

  defp build(source, kind, labels) do
    with :ok <- check_suffix(kind, labels),
         {:ok, compiled} <- compile_labels(labels) do
      {:ok, %__MODULE__{source: source, kind: kind, labels: Enum.reverse(compiled)}}
    end
  end

  defp check_suffix(:subdomains, [_single]), do: {:error, :suffix_too_short}
  defp check_suffix(_kind, _labels), do: :ok

  defp compile_labels(labels) do
    last = length(labels) - 1

    labels
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {label, index}, {:ok, acc} ->
      case compile_label(label, index == last) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp compile_label("", _tld?), do: {:error, :empty_label}

  defp compile_label(label, tld?) do
    cond do
      byte_size(label) > @max_label -> {:error, :label_too_long}
      not valid_chars?(label) -> {:error, :invalid_character}
      not String.contains?(label, "*") -> {:ok, {:literal, label}}
      tld? -> {:error, :wildcard_tld}
      true -> {:ok, {:glob, String.split(label, "*")}}
    end
  end

  defp valid_chars?(label) do
    label
    |> String.to_charlist()
    |> Enum.all?(&(&1 in ?a..?z or &1 in ?0..?9 or &1 in [?-, ?_, ?*]))
  end

  # query names are split right to left so suffix checks are list prefixes
  defp query_labels(qname) do
    name = qname |> String.downcase() |> strip_trailing_dot()
    labels = String.split(name, ".")

    if Enum.any?(labels, &(&1 == "")), do: :error, else: {:ok, Enum.reverse(labels)}
  end

  defp strip_trailing_dot(name) do
    if String.ends_with?(name, "."), do: binary_part(name, 0, byte_size(name) - 1), else: name
  end

  defp labels_match?(:exact, pattern, query) do
    length(pattern) == length(query) and all_labels_match?(pattern, query)
  end

  defp labels_match?(:subdomains, pattern, query) do
    length(query) > length(pattern) and
      all_labels_match?(pattern, Enum.take(query, length(pattern)))
  end

  defp all_labels_match?(pattern, query) do
    pattern |> Enum.zip(query) |> Enum.all?(fn {p, q} -> label_match?(p, q) end)
  end

  defp label_match?({:literal, literal}, label), do: literal == label

  defp label_match?({:glob, [first | rest]}, label) do
    String.starts_with?(label, first) and
      glob_rest(rest, binary_part(label, byte_size(first), byte_size(label) - byte_size(first)))
  end

  # rest holds the pieces after each wildcard; the last piece must end the label
  defp glob_rest([last], remaining), do: String.ends_with?(remaining, last)

  # adjacent wildcards leave an empty piece, which matches anywhere
  defp glob_rest(["" | rest], remaining), do: glob_rest(rest, remaining)

  defp glob_rest([piece | rest], remaining) do
    case :binary.match(remaining, piece) do
      {pos, len} ->
        after_piece = pos + len
        glob_rest(rest, binary_part(remaining, after_piece, byte_size(remaining) - after_piece))

      :nomatch ->
        false
    end
  end
end
