defmodule CloudWeb.SitesLive.Show do
  @moduledoc """
  One site: the gateway's live state and why, whether it is connected and
  when it was last seen, mode, next change, published vs applied policy
  version, the newest gateway events (live), and a demo panel that opens or
  locks the site through `Cloud.Access`.

  The site is only shown to members of its tenant; any other id redirects to
  `/sites` as not found.
  """

  use CloudWeb, :live_view

  import CloudWeb.SitesLive.Components

  alias Cloud.Gateways
  alias CloudWeb.GatewayPresence
  alias CloudWeb.SitesLive.{Data, Presenter}

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @events 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Data.get_site(user, id) do
      {:ok, site} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Cloud.PubSub, Gateways.ui_topic(site.id))
          Phoenix.PubSub.subscribe(Cloud.PubSub, GatewayPresence.topic(site.id))
          Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(site.id))
        end

        events = Data.recent_events(user, site, @events)

        {:ok,
         socket
         |> assign(:page_title, site.name)
         |> assign(:site, site)
         |> assign(:windows, Data.windows(user, site))
         |> assign(:connected, GatewayPresence.connected?(site.id))
         |> assign(:events_empty?, events == [])
         |> assign(:busy, nil)
         |> stream(:events, events, limit: @events)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Site not found")
         |> push_navigate(to: ~p"/sites")}
    end
  end

  # demo actions

  @impl true
  def handle_event("open", %{"minutes" => minutes}, socket) do
    case Integer.parse(minutes) do
      {m, ""} when m in [15, 30, 60] ->
        site = socket.assigns.site

        site.id
        |> Cloud.Access.open_now(m, socket.assigns.current_user)
        |> action_result(socket, "Opened for #{m} minutes")

      _ ->
        {:noreply, put_flash(socket, :error, "Unknown duration")}
    end
  end

  def handle_event("lock", _params, socket) do
    socket.assigns.site.id
    |> Cloud.Access.lock_now(socket.assigns.current_user, "locked from the demo panel")
    |> action_result(socket, "Locked")
  end

  def handle_event("unlock", _params, socket) do
    socket.assigns.site.id
    |> Cloud.Access.unlock(socket.assigns.current_user)
    |> action_result(socket, "Manual locks lifted")
  end

  defp action_result({:ok, %{policy_version: version}}, socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, "#{message}: published policy v#{version.version}")
     |> reload_site()}
  end

  defp action_result({:error, %Ash.Error.Forbidden{}}, socket, _message),
    do: {:noreply, put_flash(socket, :error, "Your role does not allow that")}

  defp action_result({:error, :no_manual_lock}, socket, _message),
    do: {:noreply, put_flash(socket, :error, "There is no manual lock to lift")}

  defp action_result({:error, _error}, socket, _message),
    do: {:noreply, put_flash(socket, :error, "That did not work, see the server log")}

  # live updates

  @impl true
  def handle_info({:gateway_heartbeat, _site_id, status, seen_at}, socket) do
    site = %{socket.assigns.site | gateway_status: status, gateway_last_seen_at: seen_at}
    {:noreply, assign(socket, :site, site)}
  end

  def handle_info({:gateway_events, _site_id, events}, socket) do
    socket =
      events
      |> Enum.reverse()
      |> Enum.reduce(socket, &stream_insert(&2, :events, &1, at: 0, limit: @events))

    {:noreply, assign(socket, :events_empty?, false)}
  end

  def handle_info({:policy_published, _site_id, _version}, socket) do
    {:noreply, reload_site(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :connected, GatewayPresence.connected?(socket.assigns.site.id))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload_site(socket) do
    user = socket.assigns.current_user

    case Data.get_site(user, socket.assigns.site.id) do
      {:ok, site} -> assign(socket, site: site, windows: Data.windows(user, site))
      {:error, _} -> socket
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        status: assigns.site.gateway_status,
        tz: assigns.site.time_zone
      )

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.link
        navigate={~p"/sites"}
        class="inline-flex items-center gap-1 text-sm text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
      >
        <.icon name="hero-arrow-left-micro" class="size-4" /> Sites
      </.link>

      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 id="site-name" class="text-2xl font-semibold tracking-tight">{@site.name}</h1>
          <p class="text-sm text-zinc-500">{@site.time_zone}</p>
        </div>
        <div class="flex items-center gap-2">
          <.state_badge id="site-state" status={@status} />
          <.connected_badge id="site-connected" connected={@connected} />
        </div>
      </div>

      <.card id="site-status" variant="bordered" color="natural" rounded="large" padding="large">
        <.card_content>
          <p
            id="site-reason"
            class={[
              "text-lg font-medium",
              Presenter.state(@status) == "open" && "text-emerald-700 dark:text-emerald-400",
              Presenter.state(@status) == "locked" && "text-red-700 dark:text-red-400"
            ]}
          >
            {Presenter.reason(@status, @windows, @tz)}
          </p>

          <dl class="mt-4 grid grid-cols-1 gap-x-6 gap-y-3 text-sm sm:grid-cols-2">
            <div>
              <dt class="text-zinc-500">Gateway</dt>
              <dd id="site-gateway">
                <%= if @connected do %>
                  connected
                <% else %>
                  not connected
                <% end %>
                <%= if @site.gateway_last_seen_at do %>
                  · last seen {Presenter.local_time(
                    @site.gateway_last_seen_at,
                    @tz,
                    "%a %d %b %H:%M:%S"
                  )}
                <% else %>
                  · never seen
                <% end %>
              </dd>
            </div>
            <div>
              <dt class="text-zinc-500">Mode</dt>
              <dd id="site-mode">
                {Presenter.mode(@status) || @site.mode}
                <%= if (Presenter.mode(@status) || to_string(@site.mode)) == "monitor" do %>
                  <span class="text-amber-600 dark:text-amber-400">
                    · would-blocks are logged, nothing is blocked
                  </span>
                <% end %>
              </dd>
            </div>
            <div>
              <dt class="text-zinc-500">Next change</dt>
              <dd id="site-next-change">
                {Presenter.local_time(@status && @status["next_change"], @tz) || "none scheduled"}
              </dd>
            </div>
            <div>
              <dt class="text-zinc-500">Policy</dt>
              <dd id="site-versions">
                <.versions
                  published={@site.policy_version}
                  applied={Presenter.applied_version(@status)}
                />
              </dd>
            </div>
          </dl>
        </.card_content>
      </.card>

      <.card id="demo-actions" variant="bordered" color="warning" rounded="large" padding="large">
        <.card_title
          title="Demo actions — passkey approval arrives in phase 4"
          size="small"
          font_weight="font-semibold"
        />
        <.card_content>
          <p class="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
            Each button publishes a new signed policy, which the gateway applies within seconds.
          </p>
          <div class="flex flex-wrap gap-2">
            <.button
              :for={m <- [15, 30, 60]}
              id={"open-#{m}"}
              phx-click="open"
              phx-value-minutes={m}
              phx-disable-with="Opening..."
              color="success"
              variant="default"
              size="small"
              icon="hero-lock-open"
            >
              Open {m} min
            </.button>
            <.button
              id="lock-now"
              phx-click="lock"
              phx-disable-with="Locking..."
              color="danger"
              variant="default"
              size="small"
              icon="hero-lock-closed"
            >
              Lock now
            </.button>
            <.button
              id="unlock"
              phx-click="unlock"
              phx-disable-with="Unlocking..."
              color="natural"
              variant="bordered"
              size="small"
              icon="hero-arrow-uturn-left"
            >
              Unlock
            </.button>
          </div>
        </.card_content>
      </.card>

      <.card id="site-events-card" variant="bordered" color="natural" rounded="large" padding="large">
        <.card_title title="Gateway events" size="small" font_weight="font-semibold" />
        <.card_content>
          <p :if={@events_empty?} id="no-events" class="text-sm text-zinc-500">
            No events yet.
          </p>
          <ul
            id="site-events"
            phx-update="stream"
            class="divide-y divide-zinc-100 text-sm dark:divide-zinc-800"
          >
            <li
              :for={{dom_id, event} <- @streams.events}
              id={dom_id}
              class="flex flex-wrap items-baseline gap-x-3 py-2"
            >
              <span class="w-36 shrink-0 tabular-nums text-zinc-500">
                {Presenter.local_time(event.at, @tz, "%d %b %H:%M:%S")}
              </span>
              <.badge size="small" color={event_color(event.type)} variant="bordered">
                {event.type}
              </.badge>
              <span class="min-w-0 break-all text-zinc-700 dark:text-zinc-300">
                {Presenter.event_summary(event)}
              </span>
            </li>
          </ul>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end

  defp event_color("blocked"), do: "danger"
  defp event_color("would_block"), do: "warning"
  defp event_color("state_changed"), do: "info"
  defp event_color("policy_applied"), do: "success"
  defp event_color("policy_result"), do: "success"
  defp event_color("command_rejected"), do: "danger"
  defp event_color(_), do: "natural"
end
