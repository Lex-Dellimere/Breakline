defmodule CloudWeb.AuditParams do
  @moduledoc """
  Reads the period and sites of an audit export from request params, for the
  `/audit` page and the json download (`CloudWeb.AuditExportController`).

  `from` and `to` are either UTC datetimes in iso8601 or dates. A date `from`
  starts at 00:00 UTC that day and a date `to` includes the whole day (the
  period ends at 00:00 UTC the next day). `site_ids` is a list or a comma
  separated string of site ids; absent or empty means every site.
  """

  @doc """
  Parses `from` and `to`. Missing values default to the last `default_days`
  up to `now`. Returns `{:ok, from, to}` or `:error` for a value that is not
  a date or datetime, or a period that does not end after it starts.
  """
  @spec period(map(), DateTime.t(), pos_integer()) :: {:ok, DateTime.t(), DateTime.t()} | :error
  def period(params, now, default_days \\ 30) do
    with {:ok, to} <- bound(params["to"], :to, now),
         {:ok, from} <-
           bound(params["from"], :from, DateTime.add(to, -default_days * 86_400, :second)),
         :lt <- DateTime.compare(from, to) do
      {:ok, from, to}
    else
      _ -> :error
    end
  end

  defp bound(value, _side, default) when value in [nil, ""], do: {:ok, default}

  defp bound(value, side, _default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        {:ok, at}

      {:error, _} ->
        case Date.from_iso8601(value) do
          {:ok, date} when side == :from -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          {:ok, date} -> {:ok, DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp bound(_value, _side, _default), do: :error

  @doc "The site ids asked for, or nil for every site."
  @spec site_ids(map()) :: [String.t()] | nil
  def site_ids(params) do
    ids =
      case params["site_ids"] do
        ids when is_list(ids) -> ids
        ids when is_binary(ids) -> String.split(ids, ",")
        _ -> []
      end
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))

    if ids == [], do: nil, else: Enum.uniq(ids)
  end
end
