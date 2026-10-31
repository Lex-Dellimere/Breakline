defmodule CloudWeb.DashboardLive.Index do
  @moduledoc """
  The signed-in home: one tenant at a glance. Counters for sites open,
  locked and offline, pending window requests, pending advisories and active
  break-glass, then a card per site with its live state and why, whether
  the gateway is connected and when it was last seen, mode, published vs
  applied policy version, the next change, an active break-glass and the
  windows of the next #{CloudWeb.DashboardLive.Data.upcoming_days()} days
  from the latest published policy, in the site's time zone.

  A member of several tenants picks one with `?tenant=<id>`; the first by
  name is the default. Reads run as the user with the tenant
  (`CloudWeb.DashboardLive.Data`). The page updates live from each site's
  gateway topic, gateway presence and policy topic, and from the tenant's
  notifications topic.
  """

  use CloudWeb, :live_view

  import CloudWeb.SitesLive.Components

  alias Cloud.Gateways
  alias CloudWeb.DashboardLive.Data
  alias CloudWeb.GatewayPresence
  alias CloudWeb.SitesLive.Data, as: SitesData
  alias CloudWeb.SitesLive.Presenter

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @upcoming_shown 6

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:tenants, SitesData.tenants(socket.assigns.current_user))
     |> assign(:tenant, nil)
     |> assign(:cards, [])
     |> assign(:connected, %{})
     |> assign(:pending_requests, 0)
     |> assign(:pending_advisories, 0)
     |> assign(:upcoming_shown, @upcoming_shown)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.tenants do
      [] ->
        {:noreply, socket}

      [first | _] = tenants ->
        tenant = Enum.find(tenants, first, &(&1.id == params["tenant"]))

        if socket.assigns.tenant && socket.assigns.tenant.id == tenant.id do
          {:noreply, socket}
        else
          {:noreply, socket |> unsubscribe() |> assign(:tenant, tenant) |> load() |> subscribe()}
        end
    end
  end

  defp load(socket) do
    overview =
      Data.overview(socket.assigns.current_user, socket.assigns.tenant.id, DateTime.utc_now())

    socket
    |> assign(:cards, overview.sites)
    |> assign(:pending_requests, overview.pending_requests)
    |> assign(:pending_advisories, overview.pending_advisories)
    |> assign(
      :connected,
      Map.new(overview.sites, &{&1.site.id, GatewayPresence.connected?(&1.site.id)})
    )
  end

  # reloads and follows the reloaded sites' topics (a site may have been added)
  defp reload(socket), do: socket |> unsubscribe() |> load() |> subscribe()

  defp topics(socket) do
    site_topics =
      Enum.flat_map(socket.assigns.cards, fn %{site: site} ->
        [
          Gateways.ui_topic(site.id),
          GatewayPresence.topic(site.id),
          Cloud.Policies.topic(site.id)
        ]
      end)

    case socket.assigns.tenant do
      nil -> site_topics
      tenant -> [Cloud.Advisories.notifications_topic(tenant.id) | site_topics]
    end
  end

  defp subscribe(socket) do
    if connected?(socket) do
      Enum.each(topics(socket), &Phoenix.PubSub.subscribe(Cloud.PubSub, &1))
    end

    socket
  end

  defp unsubscribe(socket) do
    if connected?(socket) do
      Enum.each(topics(socket), &Phoenix.PubSub.unsubscribe(Cloud.PubSub, &1))
    end

    socket
  end

  # live updates

  @impl true
  def handle_info({:gateway_heartbeat, site_id, status, seen_at}, socket) do
    {:noreply,
     update_site(socket, site_id, &%{&1 | gateway_status: status, gateway_last_seen_at: seen_at})}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    "gateway_presence:" <> site_id = topic

    {:noreply,
     update(socket, :connected, &Map.put(&1, site_id, GatewayPresence.connected?(site_id)))}
  end

  # a new policy (windows, locks, break-glass) or a request or advisory changed
  def handle_info({:policy_published, _site_id, _version}, socket), do: {:noreply, reload(socket)}
  def handle_info({:advisory, _payload}, socket), do: {:noreply, reload(socket)}
  def handle_info({:notification, _payload}, socket), do: {:noreply, reload(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp update_site(socket, site_id, fun) do
    update(socket, :cards, fn cards ->
      Enum.map(cards, fn
        %{site: %{id: ^site_id} = site} = card -> %{card | site: fun.(site)}
        card -> card
      end)
    end)
  end

  defp counts(cards, connected) do
    states = Enum.map(cards, &Presenter.state(&1.site.gateway_status))

    %{
      open: Enum.count(states, &(&1 == "open")),
      locked: Enum.count(states, &(&1 == "locked")),
      offline: Enum.count(cards, &(not Map.get(connected, &1.site.id, false))),
      break_glass: Enum.count(cards, & &1.break_glass)
    }
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :counts, counts(assigns.cards, assigns.connected))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Dashboard</h1>
          <p :if={@tenant} id="dashboard-tenant" class="text-sm text-zinc-600 dark:text-zinc-400">
            {@tenant.name}: whether each site's MSP channel is open, why, and what changes next.
          </p>
        </div>
        <div :if={length(@tenants) > 1} id="tenant-picker" class="flex flex-wrap gap-2">
          <.button_link
            :for={tenant <- @tenants}
            id={"tenant-#{tenant.id}"}
            patch={~p"/dashboard?tenant=#{tenant.id}"}
            variant={if(tenant.id == @tenant.id, do: "default", else: "bordered")}
            color={if(tenant.id == @tenant.id, do: "primary", else: "natural")}
            size="small"
          >
            {tenant.name}
          </.button_link>
        </div>
      </div>

      <.card
        :if={@tenants == []}
        id="no-tenants"
        variant="bordered"
        color="natural"
        rounded="large"
        padding="large"
      >
        <.card_content>
          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            You are not a member of any tenant yet.
          </p>
        </.card_content>
      </.card>

      <div :if={@tenant} id="counters" class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <.counter id="count-open" title="Open" value={@counts.open} icon="hero-lock-open" />
        <.counter id="count-locked" title="Locked" value={@counts.locked} icon="hero-lock-closed" />
        <.counter id="count-offline" title="Offline" value={@counts.offline} icon="hero-signal-slash" />
        <.counter
          id="count-requests"
          title="Pending requests"
          value={@pending_requests}
          icon="hero-inbox-arrow-down"
          navigate={~p"/requests"}
        />
        <.counter
          id="count-advisories"
          title="Pending advisories"
          value={@pending_advisories}
          icon="hero-shield-exclamation"
          navigate={~p"/advisories"}
        />
        <.counter
          id="count-break-glass"
          title="Break-glass"
          value={@counts.break_glass}
          icon="hero-bolt"
        />
      </div>

      <.card
        :if={@tenant && @cards == []}
        id="no-sites"
        variant="bordered"
        color="natural"
        rounded="large"
        padding="large"
      >
        <.card_content>
          <p class="text-sm text-zinc-600 dark:text-zinc-400">{@tenant.name} has no sites yet.</p>
        </.card_content>
      </.card>

      <div id="dashboard-sites" class="grid gap-3 lg:grid-cols-2">
        <.site_card
          :for={card <- @cards}
          card={card}
          connected={Map.get(@connected, card.site.id, false)}
          upcoming_shown={@upcoming_shown}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :navigate, :string, default: nil

  defp counter(assigns) do
    ~H"""
    <.link :if={@navigate} navigate={@navigate} class="group block">
      <.stat
        id={@id}
        title={@title}
        value={Integer.to_string(@value)}
        variant="bordered"
        color="natural"
        rounded="large"
        class="h-full transition group-hover:border-blue-400"
      >
        <:figure><.icon name={@icon} class="size-5" /></:figure>
      </.stat>
    </.link>
    <.stat
      :if={!@navigate}
      id={@id}
      title={@title}
      value={Integer.to_string(@value)}
      variant="bordered"
      color="natural"
      rounded="large"
      class="h-full"
    >
      <:figure><.icon name={@icon} class="size-5" /></:figure>
    </.stat>
    """
  end

  attr :card, :map, required: true
  attr :connected, :boolean, required: true
  attr :upcoming_shown, :integer, required: true

  defp site_card(assigns) do
    site = assigns.card.site

    assigns =
      assign(assigns,
        site: site,
        status: site.gateway_status,
        tz: site.time_zone,
        shown: Enum.take(assigns.card.upcoming, assigns.upcoming_shown),
        more: max(length(assigns.card.upcoming) - assigns.upcoming_shown, 0)
      )

    ~H"""
    <.card
      id={"dash-site-#{@site.id}"}
      variant="bordered"
      color="natural"
      rounded="large"
      padding="medium"
    >
      <.card_content>
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div class="min-w-0">
            <.link
              navigate={~p"/sites/#{@site.id}"}
              class="truncate font-medium hover:text-blue-600 dark:hover:text-blue-400"
            >
              {@site.name}
            </.link>
            <p class="text-xs text-zinc-500">{@site.time_zone}</p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.state_badge id={"dash-state-#{@site.id}"} status={@status} />
            <.connected_badge id={"dash-connected-#{@site.id}"} connected={@connected} />
          </div>
        </div>

        <p
          id={"dash-reason-#{@site.id}"}
          class={[
            "mt-3 font-medium",
            Presenter.state(@status) == "open" && "text-emerald-700 dark:text-emerald-400",
            Presenter.state(@status) == "locked" && "text-red-700 dark:text-red-400"
          ]}
        >
          {Presenter.reason(@status, @card.windows, @tz)}
        </p>

        <p
          :if={@card.break_glass}
          id={"dash-break-glass-#{@site.id}"}
          class="mt-2 text-sm font-medium text-red-700 dark:text-red-400"
        >
          <.icon name="hero-bolt" class="size-4 align-text-bottom" />
          Break-glass open until {Presenter.local_time(@card.break_glass.until, @tz)}
        </p>

        <dl class="mt-3 grid grid-cols-1 gap-x-4 gap-y-2 text-sm sm:grid-cols-2">
          <div>
            <dt class="text-xs text-zinc-500">Gateway</dt>
            <dd id={"dash-gateway-#{@site.id}"}>
              {if @connected, do: "connected", else: "offline"}
              <%= if @site.gateway_last_seen_at do %>
                · last seen {Presenter.local_time(@site.gateway_last_seen_at, @tz)}
              <% else %>
                · never seen
              <% end %>
            </dd>
          </div>
          <div>
            <dt class="text-xs text-zinc-500">Mode</dt>
            <dd id={"dash-mode-#{@site.id}"}>{Presenter.mode(@status) || @site.mode}</dd>
          </div>
          <div>
            <dt class="text-xs text-zinc-500">Policy</dt>
            <dd id={"dash-versions-#{@site.id}"}>
              <.versions
                published={@site.policy_version}
                applied={Presenter.applied_version(@status)}
              />
            </dd>
          </div>
          <div>
            <dt class="text-xs text-zinc-500">Next change</dt>
            <dd id={"dash-next-change-#{@site.id}"}>
              {Presenter.local_time(@status && @status["next_change"], @tz) || "none scheduled"}
            </dd>
          </div>
        </dl>

        <div class="mt-3 border-t border-zinc-100 pt-3 dark:border-zinc-800">
          <p class="text-xs font-medium uppercase tracking-wide text-zinc-500">
            Windows, next {CloudWeb.DashboardLive.Data.upcoming_days()} days
          </p>
          <p
            :if={@card.locked_by_advisory? and @card.upcoming != []}
            id={"dash-advisory-note-#{@site.id}"}
            class="mt-1 text-xs text-amber-700 dark:text-amber-400"
          >
            An advisory lock keeps the site locked through these windows.
          </p>
          <p
            :if={@card.upcoming == []}
            id={"dash-no-windows-#{@site.id}"}
            class="mt-1 text-sm text-zinc-500"
          >
            None scheduled.
          </p>
          <ul
            :if={@card.upcoming != []}
            id={"dash-windows-#{@site.id}"}
            class="mt-1 space-y-1 text-sm"
          >
            <li
              :for={w <- @shown}
              id={"dash-window-#{@site.id}-#{w.id}-#{DateTime.to_unix(w.starts_at)}"}
              class="flex flex-wrap items-center gap-2"
            >
              <span class="tabular-nums">{Presenter.local_range(w.starts_at, w.ends_at, @tz)}</span>
              <.badge size="extra_small" color="natural" variant="bordered">
                {if w.kind == :one_off, do: "one-off", else: "recurring"}
              </.badge>
              <.badge :if={w.active?} size="extra_small" color="success" variant="bordered">
                now
              </.badge>
            </li>
          </ul>
          <p :if={@more > 0} class="mt-1 text-xs text-zinc-500">and {@more} more</p>
        </div>

        <div class="mt-3 flex flex-wrap gap-2">
          <.button_link
            id={"dash-open-site-#{@site.id}"}
            navigate={~p"/sites/#{@site.id}"}
            variant="bordered"
            color="natural"
            size="extra_small"
          >
            Site
          </.button_link>
          <.button_link
            id={"dash-timeline-#{@site.id}"}
            navigate={~p"/sites/#{@site.id}/timeline"}
            variant="bordered"
            color="natural"
            size="extra_small"
          >
            Timeline
          </.button_link>
        </div>
      </.card_content>
    </.card>
    """
  end
end
