defmodule CloudWeb.DevLive.Sms do
  @moduledoc """
  Dev only (`/dev/sms`, next to `/dev/mailbox`): the text messages the dev
  SMS adapter (`Cloud.Notifications.SMS.Dev`) would have sent, newest
  first. Mounted only when `dev_routes` is on.
  """

  use CloudWeb, :live_view

  alias Cloud.Notifications.SMS.Dev

  on_mount {CloudWeb.LiveUserAuth, :current_user}
  on_mount {CloudWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Dev SMS") |> load()}
  end

  defp load(socket) do
    messages = Dev.messages()

    socket
    |> assign(:count, length(messages))
    |> stream(:messages, Enum.with_index(messages, &Map.put(&1, :id, "sms-#{&2}")), reset: true)
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("clear", _params, socket) do
    Dev.clear()
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Dev SMS</h1>
          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            Messages the dev SMS adapter kept instead of sending ({@count}).
          </p>
        </div>
        <div class="flex gap-2">
          <.button
            id="sms-refresh"
            phx-click="refresh"
            color="natural"
            variant="bordered"
            size="small"
            icon="hero-arrow-path"
          >
            Refresh
          </.button>
          <.button id="sms-clear" phx-click="clear" color="danger" variant="bordered" size="small">
            Clear
          </.button>
        </div>
      </div>
      <p :if={@count == 0} id="no-sms" class="text-sm text-zinc-500">No messages.</p>
      <div id="sms-messages" phx-update="stream" class="grid gap-3">
        <.card
          :for={{dom_id, message} <- @streams.messages}
          id={dom_id}
          variant="bordered"
          color="natural"
          rounded="large"
          padding="medium"
        >
          <.card_content>
            <p class="text-xs text-zinc-500">
              <span class="font-mono">{message.to}</span>
              · {Calendar.strftime(message.at, "%d %b %H:%M:%S UTC")}
            </p>
            <p class="mt-1 text-sm break-words">{message.body}</p>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
