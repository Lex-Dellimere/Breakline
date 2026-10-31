defmodule Cloud.Advisories.Poller do
  @moduledoc """
  Polls one feed: conditional GET, parse, record the entries not seen
  before, then act on every advisory that has not been acted on yet
  (`Cloud.Advisories.Responder`).

  - A 304 records `"not_modified"` and only acts on leftovers.
  - The first successful fetch of a feed is its baseline: its entries are
    recorded with `baseline?: true` and never acted on.
  - A fetch or parse error records `"error: ..."`, keeps the old validators
    (so the next poll fetches the whole feed again) and returns the error,
    which fails the job.
  - ACSC items get the tools of KEV advisories for the CVEs they name, in
    addition to their name matches.

  This is a trusted path: it reads and writes with `authorize?: false`.
  """

  require Logger

  alias Cloud.Advisories
  alias Cloud.Advisories.{ACSC, KEV, Responder}

  @trusted [authorize?: false]
  @chunk 500

  @doc """
  Polls `feed` (`:kev`, `:acsc_alerts` or `:acsc_advisories`). Options:
  `:req_options` (extra Req options) and `:now`.

  Returns `{:ok, %{feed:, status: :ok | :not_modified, entries:, new:,
  baseline?:, acted: [%{site_id:, advisory_id:, status:}]}}`.
  """
  @spec poll(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def poll(feed, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    record = Advisories.ensure_feed!(feed, @trusted)
    validators = %{etag: record.etag, last_modified: record.last_modified}

    case fetch(feed, validators, opts) do
      {:ok, :not_modified} ->
        record_fetch!(record, %{last_fetched_at: now, last_status: "not_modified"})
        {:ok, summary(feed, :not_modified, 0, [], record.baseline_at == nil, act())}

      {:ok, %{body: body} = response} ->
        with {:ok, entries} <- parse(feed, body),
             {:ok, new} <- record_new(entries, record.baseline_at == nil) do
          record_fetch!(record, %{
            etag: response.etag,
            last_modified: response.last_modified,
            last_fetched_at: now,
            last_status: "ok",
            baseline_at: record.baseline_at || now
          })

          {:ok, summary(feed, :ok, length(entries), new, record.baseline_at == nil, act())}
        else
          {:error, reason} -> failed(record, now, reason)
        end

      {:error, reason} ->
        failed(record, now, reason)
    end
  end

  defp fetch(:kev, validators, opts), do: KEV.fetch(validators, opts)
  defp fetch(feed, validators, opts), do: ACSC.fetch(feed, validators, opts)

  defp parse(:kev, body), do: KEV.parse(body)

  defp parse(feed, body) do
    with {:ok, entries} <- ACSC.parse(body, feed), do: {:ok, Enum.map(entries, &add_kev_tools/1)}
  end

  # an acsc item naming a cve that kev ties to a tool matches that tool too
  defp add_kev_tools(%{cves: []} = entry), do: entry

  defp add_kev_tools(entry) do
    kev = Advisories.kev_advisories_for_cves!(entry.cves, @trusted)
    kev_tools = kev |> Enum.flat_map(& &1.tool_ids) |> Enum.uniq()

    %{
      entry
      | tool_ids: Enum.sort(Enum.uniq(entry.tool_ids ++ kev_tools)),
        raw: put_in(entry.raw, ["match", "kev"], Enum.map(kev, & &1.external_id))
    }
  end

  defp record_new(entries, baseline?) do
    source = entries |> List.first() |> then(&(&1 && &1.source))
    seen = seen_ids(source, Enum.map(entries, & &1.external_id))
    new = Enum.reject(entries, &MapSet.member?(seen, &1.external_id))

    result =
      new
      |> Enum.map(&Map.put(&1, :baseline?, baseline?))
      |> Ash.bulk_create(Advisories.Advisory, :record,
        authorize?: false,
        return_errors?: true,
        stop_on_error?: true,
        transaction: :all,
        batch_size: @chunk
      )

    case result do
      %Ash.BulkResult{status: :success} -> {:ok, new}
      %Ash.BulkResult{errors: errors} -> {:error, {:record_failed, errors}}
    end
  end

  defp seen_ids(nil, _ids), do: MapSet.new()

  defp seen_ids(source, ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(&Advisories.seen_external_ids!(source, &1, @trusted))
    |> MapSet.new(& &1.external_id)
  end

  defp act do
    Advisories.unprocessed_advisories!(@trusted)
    |> Enum.flat_map(fn advisory ->
      case Responder.act(advisory) do
        {:ok, acted} ->
          acted

        {:error, error} ->
          Logger.error("acting on advisory #{advisory.id} failed: #{inspect(error)}")
          []
      end
    end)
  end

  defp record_fetch!(record, attrs), do: Advisories.record_fetch!(record, attrs, @trusted)

  defp failed(record, now, reason) do
    Logger.warning("advisory feed #{record.name} poll failed: #{inspect(reason)}")

    record_fetch!(record, %{
      last_fetched_at: now,
      last_status: String.slice("error: " <> inspect(reason), 0, 500)
    })

    {:error, reason}
  end

  defp summary(feed, status, entries, new, baseline?, acted) do
    %{
      feed: feed,
      status: status,
      entries: entries,
      new: length(new),
      baseline?: baseline? and status == :ok,
      acted: acted
    }
  end
end
