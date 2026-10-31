defmodule Cloud.Notifications.Dispatcher do
  @moduledoc """
  Subscribes to every tenant's notifications topic
  (`Cloud.Advisories.notifications_topic/1`) and turns each event broadcast
  there into queued deliveries (`Cloud.Notifications.dispatch/1`).

  It subscribes at start and rescans the tenants every 60 seconds (option
  `:rescan_ms`), so new tenants are picked up. Messages that are not a
  notification event are ignored (`Cloud.Notifications.Event`), and a
  failing dispatch is logged without taking the dispatcher down.

  One dispatcher runs per node. With several cloud nodes every node would
  queue the same deliveries; v1 runs a single node (see docs/DECISIONS.md).
  """

  use GenServer

  alias Cloud.Notifications
  alias Cloud.Notifications.Event

  require Logger

  @rescan_ms 60_000

  @doc "Starts the dispatcher. Options: `:name`, `:rescan_ms`."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Rescans the tenants now and returns the subscribed tenant ids."
  @spec rescan(GenServer.server()) :: MapSet.t()
  def rescan(server \\ __MODULE__), do: GenServer.call(server, :rescan)

  @impl true
  def init(opts) do
    state = %{tenants: MapSet.new(), rescan_ms: Keyword.get(opts, :rescan_ms, @rescan_ms)}
    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    state = subscribe_new(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:rescan, _from, state) do
    state = subscribe_new(state)
    {:reply, state.tenants, state}
  end

  @impl true
  def handle_info(:rescan, state) do
    state = subscribe_new(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(message, state) do
    case Event.from_message(message) do
      {:ok, event} -> dispatch(event)
      :ignore -> :ok
    end

    {:noreply, state}
  end

  defp dispatch(event) do
    case Notifications.dispatch(event) do
      {:ok, _deliveries} ->
        :ok

      {:error, error} ->
        Logger.error(
          "notification #{event.type} for tenant #{event.tenant_id} not queued: " <>
            Exception.message(Ash.Error.to_error_class(error))
        )
    end
  rescue
    exception ->
      Logger.error(
        "notification #{event.type} for tenant #{event.tenant_id} not queued: " <>
          Exception.message(exception)
      )
  end

  defp subscribe_new(state) do
    ids =
      Cloud.Accounts.list_tenants!(authorize?: false)
      |> MapSet.new(& &1.id)

    ids
    |> MapSet.difference(state.tenants)
    |> Enum.each(
      &Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Advisories.notifications_topic(&1))
    )

    %{state | tenants: MapSet.union(state.tenants, ids)}
  rescue
    exception ->
      Logger.error(
        "notification dispatcher could not list tenants: " <> Exception.message(exception)
      )

      state
  end

  defp schedule(%{rescan_ms: ms}), do: Process.send_after(self(), :rescan, ms)
end
