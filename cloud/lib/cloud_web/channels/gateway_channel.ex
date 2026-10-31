defmodule CloudWeb.GatewayChannel do
  @moduledoc """
  The cloud side of the gateway uplink (`Gateway.Uplink` in the gateway app),
  on topic `"gateway:<site_id>"`.

  A gateway may only join its own site's topic: the site id in the topic must
  be the one `CloudWeb.GatewaySocket` found for its certificate, otherwise the
  join fails with `%{reason: "site_mismatch"}`. The join reply is
  `Cloud.Gateways.Ingest.join_reply/2`. A joined channel tracks itself in
  `CloudWeb.GatewayPresence` and subscribes to the site's policy topic
  (`Cloud.Policies.topic/1`): each `{:policy_published, ...}` is pushed as
  `"policy"` with a freshly signed command, `%{"command" => wire}`.

  Messages from the gateway:

    * `"heartbeat"` `{"status", "sent_at"}`: stored on the site, replied `:ok`
    * `"events"` `{"events": [...]}`: at most 500, deduplicated by their
      `"id"`, replied `{"accepted": n}`
    * `"audit"` `{"chain_id", "records"}`: at most 200, verified against the
      anchored head and anchored, replied `{"head": {"seq", "hash"}}`, or an
      error `{"reason": "chain_mismatch", "expected_seq": n}`
    * `"policy_result"` `{"policy_version", "result", "reason"}`: stored as an
      event, replied `:ok`

  Everything is written through `Cloud.Gateways.Ingest` with the socket's
  site and tenant only.
  """

  use CloudWeb, :channel

  require Logger

  alias Cloud.Gateways.Ingest
  alias CloudWeb.GatewayPresence

  @impl true
  def join("gateway:" <> site_id, params, socket) do
    if site_id == socket.assigns.site_id do
      hello = if is_map(params["hello"]), do: params["hello"], else: %{}

      case Ingest.join_reply(scope(socket), hello) do
        {:ok, reply} ->
          :ok = Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(site_id))
          send(self(), :after_join)
          {:ok, reply, assign(socket, :hello, hello)}

        {:error, reason} ->
          Logger.error("gateway #{site_id}: join failed: #{inspect(reason)}")
          {:error, %{reason: "unavailable"}}
      end
    else
      Logger.warning(
        "gateway #{socket.assigns.site_id} tried to join the topic of site #{site_id}"
      )

      {:error, %{reason: "site_mismatch"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_info(:after_join, socket) do
    hello = socket.assigns.hello

    {:ok, _} =
      GatewayPresence.track(
        self(),
        GatewayPresence.topic(socket.assigns.site_id),
        socket.assigns.site_id,
        %{
          joined_at: DateTime.to_iso8601(DateTime.utc_now()),
          gateway_version: hello["gateway_version"]
        }
      )

    {:noreply, socket}
  end

  def handle_info({:policy_published, site_id, version}, socket) do
    if site_id == socket.assigns.site_id do
      case Ingest.policy_command(scope(socket)) do
        {:ok, wire} ->
          push(socket, "policy", %{"command" => wire})

        {:error, reason} ->
          Logger.error("gateway #{site_id}: cannot sign policy #{version}: #{inspect(reason)}")
      end
    end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("heartbeat", payload, socket) when is_map(payload) do
    case Ingest.heartbeat(scope(socket), payload) do
      {:ok, _site} -> {:reply, :ok, socket}
      {:error, reason} -> error(socket, "heartbeat", reason)
    end
  end

  def handle_in("events", %{"events" => events}, socket) when is_list(events) do
    case Ingest.events(scope(socket), events) do
      {:ok, n} ->
        {:reply, {:ok, %{"accepted" => n}}, socket}

      {:error, :too_many} ->
        {:reply, {:error, %{"reason" => "too_many", "max" => Ingest.max_events()}}, socket}

      {:error, reason} ->
        error(socket, "events", reason)
    end
  end

  def handle_in("audit", %{"chain_id" => chain_id, "records" => records}, socket)
      when is_binary(chain_id) and is_list(records) do
    case Ingest.audit(scope(socket), chain_id, records) do
      {:ok, head} ->
        {:reply, {:ok, %{"head" => head}}, socket}

      {:error, {:chain_mismatch, expected}} ->
        {:reply, {:error, %{"reason" => "chain_mismatch", "expected_seq" => expected}}, socket}

      {:error, :too_many} ->
        {:reply, {:error, %{"reason" => "too_many", "max" => Ingest.max_audit()}}, socket}

      {:error, reason} ->
        error(socket, "audit", reason)
    end
  end

  def handle_in("policy_result", payload, socket) when is_map(payload) do
    case Ingest.policy_result(scope(socket), payload) do
      {:ok, _event} -> {:reply, :ok, socket}
      {:error, reason} -> error(socket, "policy_result", reason)
    end
  end

  def handle_in(event, _payload, socket) do
    Logger.warning("gateway #{socket.assigns.site_id}: malformed or unknown #{inspect(event)}")
    {:reply, {:error, %{"reason" => "malformed"}}, socket}
  end

  defp error(socket, what, reason) do
    Logger.error("gateway #{socket.assigns.site_id}: #{what} failed: #{inspect(reason)}")
    {:reply, {:error, %{"reason" => "internal_error"}}, socket}
  end

  defp scope(socket), do: %{site_id: socket.assigns.site_id, tenant_id: socket.assigns.tenant_id}
end
