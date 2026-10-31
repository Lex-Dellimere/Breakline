defmodule CloudWeb.SitesLive.Index do
  @moduledoc """
  The signed-in user's sites across their tenants: live open/locked state from
  the last heartbeat, whether the gateway is connected, and the published vs
  applied policy version.
  """

  use CloudWeb, :live_view

  import CloudWeb.SitesLive.Components

  alias Cloud.Gateways
  alias CloudWeb.GatewayPresence
  alias CloudWeb.SitesLive.{Data, Presenter}

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    sites = Data.list_sites(socket.assigns.current_user)

    if connected?(socket) do
      for site <- sites do
        Phoenix.PubSub.subscribe(Cloud.PubSub, Gateways.ui_topic(site.id))
        Phoenix.PubSub.subscribe(Cloud.PubSub, GatewayPresence.topic(site.id))
        Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(site.id))
      end
    end

    {:ok,
     socket
     |> assign(:page_title, "Sites")
     |> assign(:sites, sites)
     |> assign(:connected, Map.new(sites, &{&1.id, GatewayPresence.connected?(&1.id)}))}
  end

  @impl true
  def handle_info({:gateway_heartbeat, site_id, status, seen_at}, socket) do
    {:noreply,
     update_site(socket, site_id, &%{&1 | gateway_status: status, gateway_last_seen_at: seen_at})}
  end

  def handle_info({:policy_published, site_id, version}, socket) do
    {:noreply, update_site(socket, site_id, &%{&1 | policy_version: version})}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    "gateway_presence:" <> site_id = topic

    {:noreply,
     update(socket, :connected, &Map.put(&1, site_id, GatewayPresence.connected?(site_id)))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp update_site(socket, site_id, fun) do
    update(socket, :sites, fn sites ->
      Enum.map(sites, &if(&1.id == site_id, do: fun.(&1), else: &1))
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Sites</h1>
          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            Each site's gateway keeps the MSP's remote access closed unless its policy says open.
          </p>
        </div>
      </div>

      <%= if @sites == [] do %>
        <.card id="no-sites" variant="bordered" color="natural" rounded="large" padding="large">
          <.card_content>
            <p class="text-sm text-zinc-600 dark:text-zinc-400">
              You are not a member of any tenant with sites yet.
            </p>
          </.card_content>
        </.card>
      <% else %>
        <div id="sites" class="grid gap-3">
          <.link
            :for={site <- @sites}
            navigate={~p"/sites/#{site.id}"}
            id={"site-#{site.id}"}
            class="group block"
          >
            <.card
              variant="bordered"
              color="natural"
              rounded="large"
              padding="medium"
              class="transition group-hover:border-blue-400 group-hover:shadow-sm"
            >
              <.card_content>
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div class="min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="truncate font-medium">{site.name}</span>
                      <.icon
                        name="hero-chevron-right-micro"
                        class="size-4 text-zinc-400 transition group-hover:translate-x-0.5"
                      />
                    </div>
                    <p class="text-xs text-zinc-500">
                      {site.time_zone} · {site.mode}
                      <%= if site.gateway_last_seen_at do %>
                        · last seen {Presenter.local_time(site.gateway_last_seen_at, site.time_zone)}
                      <% end %>
                    </p>
                  </div>
                  <div class="flex flex-wrap items-center gap-3 text-sm">
                    <.state_badge id={"site-state-#{site.id}"} status={site.gateway_status} />
                    <.connected_badge
                      id={"site-connected-#{site.id}"}
                      connected={Map.get(@connected, site.id, false)}
                    />
                    <.versions
                      published={site.policy_version}
                      applied={Presenter.applied_version(site.gateway_status)}
                    />
                  </div>
                </div>
              </.card_content>
            </.card>
          </.link>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
