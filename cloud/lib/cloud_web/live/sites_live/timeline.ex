defmodule CloudWeb.SitesLive.Timeline do
  @moduledoc """
  A site's timeline: gateway events, the cloud audit entries about the
  site, policy versions and notification deliveries in one chronological
  stream, newest first (`CloudWeb.SitesLive.TimelineData`). Each item shows
  its local time in the site's time zone, a kind badge, a one-line summary
  and the actor where known.

  `?kind=gateway|audit|policy|notification` shows one kind. "Load older"
  appends the next page. New gateway events appear live, and a new policy
  version reloads the newest page.

  Only members of the site's tenant see it; any other id redirects to
  `/sites` as not found.
  """

  use CloudWeb, :live_view

  alias Cloud.Gateways
  alias CloudWeb.SitesLive.{Data, Presenter, TimelineData}

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @page 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Data.get_site(user, id) do
      {:ok, site} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Cloud.PubSub, Gateways.ui_topic(site.id))
          Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Policies.topic(site.id))
        end

        {:ok,
         socket
         |> assign(:page_title, "#{site.name} timeline")
         |> assign(:site, site)
         |> assign(:role, Data.role(user, site.tenant_id))
         |> assign(:kind, nil)
         |> assign(:kinds, TimelineData.kinds())
         |> assign(:cursor, nil)
         |> assign(:more?, false)
         |> assign(:empty?, true)
         |> stream(:items, [])}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Site not found")
         |> push_navigate(to: ~p"/sites")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = Enum.find(TimelineData.kinds(), &(Atom.to_string(&1) == params["kind"]))
    {:noreply, socket |> assign(:kind, kind) |> load_page(:reset)}
  end

  defp selected_kinds(%{kind: nil}), do: TimelineData.kinds()
  defp selected_kinds(%{kind: kind}), do: [kind]

  defp load_page(socket, mode) do
    cursor = if mode == :reset, do: nil, else: socket.assigns.cursor

    {items, more?} =
      TimelineData.page(
        socket.assigns.current_user,
        socket.assigns.site,
        selected_kinds(socket.assigns),
        cursor,
        @page,
        role: socket.assigns.role
      )

    socket =
      case mode do
        :reset -> stream(socket, :items, items, reset: true)
        :append -> stream(socket, :items, items, at: -1)
      end

    socket
    |> assign(:more?, more?)
    |> assign(:cursor, if(items == [], do: cursor, else: List.last(items).cursor))
    |> assign(:empty?, mode == :reset and items == [])
  end

  @impl true
  def handle_event("load_older", _params, socket) do
    {:noreply, load_page(socket, :append)}
  end

  @impl true
  def handle_info({:gateway_events, _site_id, events}, socket) do
    if :gateway in selected_kinds(socket.assigns) do
      socket =
        events
        |> Enum.reverse()
        |> Enum.reduce(socket, &stream_insert(&2, :items, TimelineData.gateway_item(&1), at: 0))

      {:noreply, assign(socket, :empty?, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:policy_published, _site_id, _version}, socket) do
    # the cursor stays where the user scrolled to; only the top is refreshed
    {:noreply, if(socket.assigns.cursor, do: socket, else: load_page(socket, :reset))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.link
        navigate={~p"/sites/#{@site.id}"}
        class="inline-flex items-center gap-1 text-sm text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
      >
        <.icon name="hero-arrow-left-micro" class="size-4" /> {@site.name}
      </.link>

      <div>
        <h1 id="timeline-title" class="text-2xl font-semibold tracking-tight">Timeline</h1>
        <p class="text-sm text-zinc-500">
          {@site.name}, newest first, in {@site.time_zone} time.
        </p>
      </div>

      <div id="timeline-filters" class="flex flex-wrap gap-2">
        <.button_link
          id="filter-all"
          patch={~p"/sites/#{@site.id}/timeline"}
          variant={if(is_nil(@kind), do: "default", else: "bordered")}
          color={if(is_nil(@kind), do: "primary", else: "natural")}
          size="small"
        >
          All
        </.button_link>
        <.button_link
          :for={kind <- @kinds}
          id={"filter-#{kind}"}
          patch={~p"/sites/#{@site.id}/timeline?kind=#{kind}"}
          variant={if(@kind == kind, do: "default", else: "bordered")}
          color={if(@kind == kind, do: "primary", else: "natural")}
          size="small"
        >
          {TimelineData.kind_label(kind)}
        </.button_link>
      </div>

      <.card id="timeline-card" variant="bordered" color="natural" rounded="large" padding="large">
        <.card_content>
          <p :if={@empty?} id="timeline-empty" class="text-sm text-zinc-500">Nothing yet.</p>
          <p
            :if={@kind == :notification and @role != :admin}
            id="timeline-admin-only"
            class="text-sm text-zinc-500"
          >
            Only admins can see notification deliveries.
          </p>
          <ol
            id="timeline"
            phx-update="stream"
            class="divide-y divide-zinc-100 text-sm dark:divide-zinc-800"
          >
            <li
              :for={{dom_id, item} <- @streams.items}
              id={dom_id}
              data-kind={item.kind}
              class="flex flex-wrap items-baseline gap-x-3 gap-y-1 py-2"
            >
              <span class="w-36 shrink-0 tabular-nums text-zinc-500">
                {Presenter.local_time(item.at, @site.time_zone, "%d %b %H:%M:%S")}
              </span>
              <.badge size="small" color={kind_color(item.kind)} variant="bordered">
                {TimelineData.kind_label(item.kind)}
              </.badge>
              <span class="min-w-0 flex-1 break-words text-zinc-700 dark:text-zinc-300">
                <span class="font-medium">{item.label}</span>
                <span :if={item.summary != ""}>· {item.summary}</span>
              </span>
              <span :if={item.actor} class="text-xs text-zinc-500">{item.actor}</span>
            </li>
          </ol>
          <div :if={@more?} class="mt-3">
            <.button
              id="load-older"
              phx-click="load_older"
              phx-disable-with="Loading..."
              color="natural"
              variant="bordered"
              size="small"
              icon="hero-arrow-down"
            >
              Load older
            </.button>
          </div>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end

  defp kind_color(:gateway), do: "info"
  defp kind_color(:audit), do: "warning"
  defp kind_color(:policy), do: "success"
  defp kind_color(:notification), do: "natural"
end
