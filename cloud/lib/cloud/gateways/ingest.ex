defmodule Cloud.Gateways.Ingest do
  @moduledoc """
  The server side of the gateway uplink protocol (`Gateway.Uplink` in the
  gateway app): what the cloud does with a gateway's hello, heartbeats, events,
  audit records and policy results. `CloudWeb.GatewayChannel` only decodes the
  messages and calls these functions.

  These are trusted server paths: every read and write runs with
  `authorize?: false`, and is scoped to the site and tenant the gateway's
  client certificate was pinned to (`CloudWeb.GatewaySocket`). Callers must
  never pass ids that came from the gateway's payload.

  Live changes are broadcast on `Cloud.Gateways.ui_topic/1` after they are
  written.
  """

  require Logger

  alias Breakline.AuditLog
  alias Cloud.Gateways
  alias Cloud.Gateways.{AuditRecord, Event}
  alias Cloud.Sites
  alias Cloud.Sites.Site

  @max_events 500
  @max_audit 200
  @heartbeat_ms 30_000

  @typedoc "The site and tenant a gateway connection is bound to."
  @type scope :: %{site_id: String.t(), tenant_id: String.t()}

  @doc "The most events accepted in one push."
  def max_events, do: @max_events

  @doc "The most audit records accepted in one push."
  def max_audit, do: @max_audit

  @doc """
  Builds the join reply for a gateway's hello:

    * `"server_time"`: now, iso8601
    * `"heartbeat_ms"`: #{@heartbeat_ms}
    * `"audit_ack"`: the anchored head of the gateway's audit chain,
      `%{"seq", "hash"}`, when the hello's `chain_id` is the anchored chain, and
      nil otherwise. A chain id the cloud has not anchored yet is recorded as
      an `"audit_chain_reset"` event and anchored with no head, so the gateway
      sends that chain from seq 0.
    * `"policy"`: a freshly signed command for the site's latest policy when
      its version is greater than the hello's `last_version`, else nil.
  """
  @spec join_reply(scope(), map()) :: {:ok, map()} | {:error, term()}
  def join_reply(scope, hello) when is_map(hello) do
    with {:ok, site} <- fetch_site(scope) do
      last_version = int(get_in(hello, ["last_version"])) || 0
      chain_id = get_in(hello, ["audit", "chain_id"])

      with {:ok, audit_ack} <- audit_ack(site, chain_id) do
        {:ok,
         %{
           "server_time" => DateTime.to_iso8601(DateTime.utc_now()),
           "heartbeat_ms" => @heartbeat_ms,
           "audit_ack" => audit_ack,
           "policy" => policy_for(site, last_version)
         }}
      end
    end
  end

  defp audit_ack(_site, chain_id) when not is_binary(chain_id), do: {:ok, nil}

  defp audit_ack(%Site{gateway_audit_chain_id: chain_id} = site, chain_id),
    do: {:ok, head_map(site.gateway_audit_head)}

  defp audit_ack(site, chain_id) do
    previous = site.gateway_audit_chain_id

    with {:ok, _site} <- Sites.anchor_audit(site, chain_id, nil, authorize?: false),
         {:ok, event} <-
           create_event(site, %{
             type: "audit_chain_reset",
             at: DateTime.utc_now(),
             data: %{"chain_id" => chain_id, "previous_chain_id" => previous}
           }) do
      Gateways.broadcast_ui(site.id, {:gateway_events, site.id, [event]})
      {:ok, nil}
    end
  end

  defp policy_for(site, last_version) do
    if site.policy_version > last_version do
      case Cloud.Policies.command_for(site.id) do
        {:ok, wire} ->
          wire

        {:error, reason} ->
          Logger.warning("gateway #{site.id}: no policy to send: #{inspect(reason)}")
          nil
      end
    end
  end

  @doc """
  A freshly signed command for the site's latest policy, as pushed in a
  `"policy"` message. Returns `{:error, :not_published}` before the first
  publish.
  """
  @spec policy_command(scope()) :: {:ok, map()} | {:error, term()}
  def policy_command(scope) do
    with {:ok, site} <- fetch_site(scope), do: Cloud.Policies.command_for(site.id)
  end

  @doc """
  Records a heartbeat: the gateway's enforcer status (a map, or nil when the
  gateway could not read it) becomes the site's `gateway_status`, and the site
  is marked as seen now.
  """
  @spec heartbeat(scope(), map()) :: {:ok, Site.t()} | {:error, term()}
  def heartbeat(scope, payload) when is_map(payload) do
    status = if is_map(payload["status"]), do: payload["status"]

    with {:ok, site} <- fetch_site(scope),
         {:ok, site} <- Sites.record_heartbeat(site, status, authorize?: false) do
      Gateways.broadcast_ui(
        site.id,
        {:gateway_heartbeat, site.id, site.gateway_status, site.gateway_last_seen_at}
      )

      {:ok, site}
    end
  end

  @doc """
  Stores a batch of gateway events, at most #{@max_events}. An event the site
  already has (same `"id"`) is skipped, so a batch sent again is harmless.
  Entries that are not maps are skipped too. Returns `{:ok, accepted}`, the
  number of new events stored.
  """
  @spec events(scope(), list()) :: {:ok, non_neg_integer()} | {:error, term()}
  def events(_scope, events) when is_list(events) and length(events) > @max_events,
    do: {:error, :too_many}

  def events(scope, events) when is_list(events) do
    with {:ok, site} <- fetch_site(scope) do
      now = DateTime.utc_now()

      inputs =
        events
        |> Enum.filter(&is_map/1)
        |> Enum.map(&event_input(&1, now))
        |> Enum.uniq_by(fn i -> i.event_id || make_ref() end)

      inputs = drop_known(site, inputs)
      insert_events(site, inputs)
    end
  end

  defp event_input(event, now) do
    id = event["id"]

    %{
      event_id: if(is_binary(id) and byte_size(id) in 1..64, do: id),
      type: event_type(event["type"]),
      at: parse_time(event["at"]) || now,
      data: Map.delete(event, "id")
    }
  end

  defp event_type(type) when is_binary(type) and type != "", do: String.slice(type, 0, 100)
  defp event_type(_), do: "unknown"

  defp drop_known(site, inputs) do
    ids = for %{event_id: id} when is_binary(id) <- inputs, do: id

    known =
      case ids do
        [] ->
          MapSet.new()

        ids ->
          Gateways.list_events!(
            tenant: site.tenant_id,
            authorize?: false,
            query: [filter: [site_id: site.id, event_id: [in: ids]], select: [:event_id]]
          )
          |> MapSet.new(& &1.event_id)
      end

    Enum.reject(inputs, &(&1.event_id && MapSet.member?(known, &1.event_id)))
  end

  defp insert_events(_site, []), do: {:ok, 0}

  defp insert_events(site, inputs) do
    result =
      inputs
      |> Enum.map(&Map.put(&1, :site_id, site.id))
      |> Ash.bulk_create(Event, :create,
        tenant: site.tenant_id,
        authorize?: false,
        return_records?: true,
        return_errors?: true,
        stop_on_error?: true,
        transaction: :all
      )

    case result do
      %Ash.BulkResult{status: :success, records: records} ->
        newest_first = Enum.sort_by(records, & &1.at, {:desc, DateTime})
        Gateways.broadcast_ui(site.id, {:gateway_events, site.id, newest_first})
        {:ok, length(records)}

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  @doc """
  Accepts audit records that continue the site's anchored audit chain, at
  most #{@max_audit}. The records are verified with
  `Breakline.AuditLog.verify_segment/2` after the anchored head (from seq 0
  for a chain the cloud has not anchored, whose record 0 must hash to its
  chain id), stored, and the new head anchored on the site.

  Returns `{:ok, %{"seq", "hash"}}`, the new head, or
  `{:error, {:chain_mismatch, expected_seq}}` when the records do not
  continue the anchored head: a gap, an overlap or a record that does not
  verify. `expected_seq` is the seq the cloud needs next.
  """
  @spec audit(scope(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  def audit(_scope, _chain_id, records) when is_list(records) and length(records) > @max_audit,
    do: {:error, :too_many}

  def audit(scope, chain_id, records)
      when is_binary(chain_id) and chain_id != "" and is_list(records) do
    with {:ok, site} <- fetch_site(scope) do
      after_head =
        if site.gateway_audit_chain_id == chain_id,
          do: head_tuple(site.gateway_audit_head),
          else: nil

      expected = if after_head, do: elem(after_head, 0) + 1, else: 0

      with {:ok, {seq, hash}} <- verify(records, after_head, chain_id, expected),
           :ok <- store_audit(site, chain_id, records, {seq, hash}) do
        {:ok, %{"seq" => seq, "hash" => hash}}
      end
    end
  end

  def audit(_scope, _chain_id, _records), do: {:error, :malformed}

  defp verify([], _after_head, _chain_id, expected), do: {:error, {:chain_mismatch, expected}}

  defp verify([first | _] = records, after_head, chain_id, expected) do
    genesis_ok? = after_head != nil or (is_map(first) and first["hash"] == chain_id)

    case genesis_ok? && AuditLog.verify_segment(records, after: after_head) do
      {:ok, head} ->
        {:ok, head}

      {:error, {:broken_at, at, reason}} ->
        Logger.warning("gateway audit batch refused at seq #{at}: #{reason}")
        {:error, {:chain_mismatch, expected}}

      false ->
        Logger.warning("gateway audit chain #{chain_id} does not start with its own record 0")
        {:error, {:chain_mismatch, expected}}
    end
  end

  defp store_audit(site, chain_id, records, {seq, hash}) do
    Cloud.Repo.transaction(fn ->
      result =
        records
        |> Enum.map(
          &%{
            site_id: site.id,
            chain_id: chain_id,
            seq: &1["seq"],
            hash: &1["hash"],
            record: &1
          }
        )
        |> Ash.bulk_create(AuditRecord, :create,
          tenant: site.tenant_id,
          authorize?: false,
          return_errors?: true,
          stop_on_error?: true
        )

      # sites have no notifiers; notifications are taken and dropped so ash does not
      # warn about notifications missed inside the transaction
      with %Ash.BulkResult{status: :success} <- result,
           {:ok, _site, _notifications} <-
             Sites.anchor_audit(site, chain_id, %{"seq" => seq, "hash" => hash},
               authorize?: false,
               return_notifications?: true
             ) do
        :ok
      else
        %Ash.BulkResult{errors: errors} -> Cloud.Repo.rollback(errors)
        {:error, error} -> Cloud.Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Stores a gateway's `"policy_result"` (`{"policy_version", "result",
  "reason"}`) as a `"policy_result"` event.
  """
  @spec policy_result(scope(), map()) :: {:ok, Event.t()} | {:error, term()}
  def policy_result(scope, payload) when is_map(payload) do
    data = Map.take(payload, ["policy_version", "result", "reason"])

    with {:ok, site} <- fetch_site(scope),
         {:ok, event} <-
           create_event(site, %{type: "policy_result", at: DateTime.utc_now(), data: data}) do
      Gateways.broadcast_ui(site.id, {:gateway_events, site.id, [event]})
      {:ok, event}
    end
  end

  # helpers

  defp create_event(site, attrs) do
    Gateways.create_event(Map.put(attrs, :site_id, site.id),
      tenant: site.tenant_id,
      authorize?: false
    )
  end

  defp fetch_site(%{site_id: site_id, tenant_id: tenant_id}) do
    case Sites.get_site(site_id, tenant: tenant_id, authorize?: false, not_found_error?: false) do
      {:ok, %Site{} = site} -> {:ok, site}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp head_map(%{"seq" => seq, "hash" => hash}) when is_integer(seq) and is_binary(hash),
    do: %{"seq" => seq, "hash" => hash}

  defp head_map(_), do: nil

  defp head_tuple(%{"seq" => seq, "hash" => hash}) when is_integer(seq) and is_binary(hash),
    do: {seq, hash}

  defp head_tuple(_), do: nil

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_), do: nil

  defp parse_time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
