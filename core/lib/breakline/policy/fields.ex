defmodule Breakline.Policy.Fields do
  @moduledoc false
  # shared helpers for validating policy attrs and decoding untrusted string keyed maps.
  # validators return {:ok, value} or {:error, [{relative_path, message}]}.

  alias Breakline.Policy

  @type validator :: (term() -> {:ok, term()} | {:error, [Policy.reason()]})
  @type spec :: {atom(), :required | {:default, term()}, validator()}

  @doc false
  # turns a keyword list, map or struct into a plain map with atom keys
  @spec to_attrs(term()) :: {:ok, map()} | {:error, [Policy.reason()]}
  def to_attrs(%_{} = struct), do: {:ok, Map.from_struct(struct)}
  def to_attrs(attrs) when is_map(attrs), do: {:ok, attrs}

  def to_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: {:ok, Map.new(attrs)}, else: {:error, [{[], :invalid}]}
  end

  def to_attrs(_), do: {:error, [{[], :invalid}]}

  @doc false
  # validates attrs against specs, rejecting unknown keys
  @spec validate(term(), [spec()]) :: {:ok, map()} | {:error, [Policy.reason()]}
  def validate(attrs, specs) do
    with {:ok, attrs} <- to_attrs(attrs) do
      known = MapSet.new(specs, &elem(&1, 0))

      unknown =
        attrs
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(known, &1))
        |> Enum.sort()
        |> Enum.map(&{[path_key(&1)], :unknown_key})

      {values, errors} =
        Enum.reduce(specs, {%{}, []}, fn {key, presence, validator}, {values, errors} ->
          case {Map.fetch(attrs, key), presence} do
            {:error, :required} ->
              {values, [{[key], :required} | errors]}

            {:error, {:default, default}} ->
              {Map.put(values, key, default), errors}

            {{:ok, value}, _} ->
              case validator.(value) do
                {:ok, value} -> {Map.put(values, key, value), errors}
                {:error, reasons} -> {values, Enum.reverse(prefix(reasons, key), errors)}
              end
          end
        end)

      case unknown ++ Enum.reverse(errors) do
        [] -> {:ok, values}
        reasons -> {:error, reasons}
      end
    end
  end

  @doc false
  # maps a string keyed map onto atom keys using a fixed table, never creating atoms
  @spec decode_keys(term(), [{String.t(), atom(), (term() -> {:ok, term()} | :error)}]) ::
          {:ok, map()} | {:error, [Policy.reason()]}
  def decode_keys(map, table) when is_map(map) and not is_struct(map) do
    known = MapSet.new(table, &elem(&1, 0))

    unknown =
      map
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&path_key/1)
      |> Enum.sort()
      |> Enum.map(&{[&1], :unknown_key})

    {attrs, errors} =
      Enum.reduce(table, {%{}, []}, fn {string_key, key, decoder}, {attrs, errors} ->
        case Map.fetch(map, string_key) do
          :error ->
            {attrs, errors}

          {:ok, value} ->
            case decoder.(value) do
              {:ok, decoded} -> {Map.put(attrs, key, decoded), errors}
              {:error, reasons} -> {attrs, Enum.reverse(prefix(reasons, key), errors)}
              :error -> {attrs, [{[key], :invalid} | errors]}
            end
        end
      end)

    case unknown ++ Enum.reverse(errors) do
      [] -> {:ok, attrs}
      reasons -> {:error, reasons}
    end
  end

  def decode_keys(_, _), do: {:error, [{[], :invalid}]}

  @doc false
  @spec prefix([Policy.reason()], atom() | non_neg_integer()) :: [Policy.reason()]
  def prefix(reasons, key), do: Enum.map(reasons, fn {path, msg} -> {[key | path], msg} end)

  # validators

  @doc false
  @spec string(term()) :: {:ok, String.t()} | {:error, [Policy.reason()]}
  def string(value) when is_binary(value) and value != "" do
    if String.valid?(value), do: {:ok, value}, else: invalid()
  end

  def string(_), do: invalid()

  @doc false
  @spec non_neg_integer(term()) :: {:ok, non_neg_integer()} | {:error, [Policy.reason()]}
  def non_neg_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def non_neg_integer(_), do: invalid()

  @doc false
  # whole minute local time, normalised to zero microsecond precision
  @spec minute_time(term()) :: {:ok, Time.t()} | {:error, [Policy.reason()]}
  def minute_time(%Time{calendar: Calendar.ISO, second: 0, microsecond: {0, _}} = time),
    do: {:ok, %{time | microsecond: {0, 0}}}

  def minute_time(_), do: invalid()

  @doc false
  @spec minute_naive(term()) :: {:ok, NaiveDateTime.t()} | {:error, [Policy.reason()]}
  def minute_naive(
        %NaiveDateTime{calendar: Calendar.ISO, second: 0, microsecond: {0, _}} = naive
      ),
      do: {:ok, %{naive | microsecond: {0, 0}}}

  def minute_naive(_), do: invalid()

  @doc false
  # utc datetime rounded to whole seconds, :floor or :ceil
  @spec utc_datetime(term(), :floor | :ceil) :: {:ok, DateTime.t()} | {:error, [Policy.reason()]}
  def utc_datetime(%DateTime{calendar: Calendar.ISO, time_zone: "Etc/UTC"} = dt, rounding) do
    truncated = DateTime.truncate(dt, :second)

    case {rounding, dt.microsecond} do
      {:ceil, {us, _}} when us > 0 -> {:ok, DateTime.add(truncated, 1, :second)}
      _ -> {:ok, truncated}
    end
  end

  def utc_datetime(_, _), do: invalid()

  @doc false
  @spec nilable(validator()) :: validator()
  def nilable(validator) do
    fn
      nil -> {:ok, nil}
      value -> validator.(value)
    end
  end

  @doc false
  # validates each element, prefixing errors with the element index
  @spec list_of(validator()) :: validator()
  def list_of(validator) do
    fn
      list when is_list(list) ->
        {values, errors} =
          list
          |> Enum.with_index()
          |> Enum.reduce({[], []}, fn {item, index}, {values, errors} ->
            case validator.(item) do
              {:ok, value} -> {[value | values], errors}
              {:error, reasons} -> {values, Enum.reverse(prefix(reasons, index), errors)}
            end
          end)

        case errors do
          [] -> {:ok, Enum.reverse(values)}
          _ -> {:error, Enum.reverse(errors)}
        end

      _ ->
        invalid()
    end
  end

  @doc false
  @spec invalid() :: {:error, [Policy.reason()]}
  def invalid, do: {:error, [{[], :invalid}]}

  # decoders for untrusted json-compatible values, strict canonical forms only:
  # no fractional seconds, no offsets other than z, re-encoding must give the input back

  @doc false
  @spec decode_time(term()) :: {:ok, Time.t()} | :error
  def decode_time(value) when is_binary(value) do
    with {:ok, %Time{microsecond: {0, 0}} = time} <- Time.from_iso8601(value),
         true <- Time.to_iso8601(time) == value do
      {:ok, time}
    else
      _ -> :error
    end
  end

  def decode_time(_), do: :error

  @doc false
  @spec decode_naive(term()) :: {:ok, NaiveDateTime.t()} | :error
  def decode_naive(value) when is_binary(value) do
    with {:ok, %NaiveDateTime{microsecond: {0, 0}} = naive} <- NaiveDateTime.from_iso8601(value),
         true <- NaiveDateTime.to_iso8601(naive) == value do
      {:ok, naive}
    else
      _ -> :error
    end
  end

  def decode_naive(_), do: :error

  @doc false
  @spec decode_utc(term()) :: {:ok, DateTime.t() | nil} | :error
  def decode_utc(nil), do: {:ok, nil}

  def decode_utc(value) when is_binary(value) do
    with {:ok, %DateTime{microsecond: {0, 0}} = dt, 0} <- DateTime.from_iso8601(value),
         true <- DateTime.to_iso8601(dt) == value do
      {:ok, dt}
    else
      _ -> :error
    end
  end

  def decode_utc(_), do: :error

  @doc false
  @spec encode_utc(DateTime.t() | nil) :: String.t() | nil
  def encode_utc(nil), do: nil
  def encode_utc(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @doc false
  # passes plain json values through, validation happens in new/1
  @spec as_is(term()) :: {:ok, term()}
  def as_is(value), do: {:ok, value}

  # keeps error paths printable without converting arbitrary terms into atoms
  defp path_key(key) when is_atom(key) or is_binary(key), do: key
  defp path_key(key), do: inspect(key)
end
