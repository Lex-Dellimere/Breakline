defmodule CloudWeb.AdvisoriesLive.Index do
  @moduledoc """
  Threat-feed advisories for the signed-in user's tenants: the pending ones,
  which an approver or admin confirms (locks the site and publishes) or
  dismisses (leaves access as it is), and the recently locked or dismissed
  ones. Each links to its source; ACSC entries carry the CC BY 4.0
  attribution.

  Every read and decision runs as the user with the tenant, so the resource
  policies decide what is visible and allowed. The page updates live from
  the tenants' notification topics. In dev it also offers "poll feeds now".
  """

  use CloudWeb, :live_view

  alias Cloud.Advisories
  alias CloudWeb.SitesLive.Data

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @recent 50
  @dev_tools? Application.compile_env(:cloud, :advisories_poll_button?, false)

  @impl true
  def mount(_params, _session, socket) do
    tenant_ids = Data.tenant_ids(socket.assigns.current_user)

    if connected?(socket) do
      for tenant_id <- tenant_ids do
        Phoenix.PubSub.subscribe(Cloud.PubSub, Advisories.notifications_topic(tenant_id))
      end
    end

    {:ok,
     socket
     |> assign(:page_title, "Advisories")
     |> assign(:tenant_ids, tenant_ids)
     |> assign(:dev_tools?, @dev_tools?)
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_user

    all =
      Enum.flat_map(socket.assigns.tenant_ids, fn tenant_id ->
        Advisories.list_site_advisories!(
          actor: user,
          tenant: tenant_id,
          query: [sort: [updated_at: :desc, id: :desc], load: [:advisory, :site]]
        )
      end)

    {pending, decided} = Enum.split_with(all, &(&1.status == :pending))
    pending = Enum.sort_by(pending, & &1.inserted_at, {:desc, DateTime})

    decided =
      decided |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> Enum.take(@recent)

    socket
    |> assign(:pending_count, length(pending))
    |> assign(:decided_count, length(decided))
    |> stream(:pending, pending, reset: true)
    |> stream(:decided, decided, reset: true)
  end

  @impl true
  def handle_event("confirm", %{"id" => id}, socket) do
    decide(socket, id, &Advisories.confirm_lock/2, "Site locked")
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    decide(socket, id, &Advisories.dismiss_site_advisory/2, "Advisory dismissed")
  end

  def handle_event("poll_now", _params, socket) when @dev_tools? do
    Advisories.enqueue_polls()
    {:noreply, put_flash(socket, :info, "Feed polls queued")}
  end

  defp decide(socket, id, action, message) do
    user = socket.assigns.current_user

    with {:ok, site_advisory} <- find(socket, id),
         {:ok, _} <- action.(site_advisory, actor: user, tenant: site_advisory.tenant_id) do
      {:noreply, socket |> put_flash(:info, message) |> load()}
    else
      {:error, :not_found} ->
        {:noreply, socket |> put_flash(:error, "Advisory not found") |> load()}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "Your role does not allow that")}

      {:error, _error} ->
        {:noreply, socket |> put_flash(:error, "That advisory was already decided") |> load()}
    end
  end

  # an id is looked up only in the user's own tenants, as the user
  defp find(socket, id) do
    with {:ok, _} <- Ecto.UUID.cast(id) do
      Enum.find_value(socket.assigns.tenant_ids, {:error, :not_found}, fn tenant_id ->
        case Advisories.get_site_advisory(id,
               actor: socket.assigns.current_user,
               tenant: tenant_id,
               not_found_error?: false
             ) do
          {:ok, %{} = site_advisory} -> {:ok, site_advisory}
          _ -> nil
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def handle_info({:advisory, _change}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Advisories</h1>
          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            When CISA KEV or the ACSC report a tool your MSP uses as exploited, its sites are locked or you are asked to lock them.
          </p>
        </div>
        <.button
          :if={@dev_tools?}
          id="poll-now"
          phx-click="poll_now"
          phx-disable-with="Queuing..."
          color="natural"
          variant="bordered"
          size="small"
          icon="hero-arrow-path"
        >
          Poll feeds now (dev)
        </.button>
      </div>

      <section class="space-y-3">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">
          Waiting for a decision <span class="tabular-nums">({@pending_count})</span>
        </h2>
        <p :if={@pending_count == 0} id="no-pending" class="text-sm text-zinc-500">
          Nothing to decide.
        </p>
        <div id="pending" phx-update="stream" class="grid gap-3">
          <.card
            :for={{dom_id, sa} <- @streams.pending}
            id={dom_id}
            variant="bordered"
            color="warning"
            rounded="large"
            padding="medium"
          >
            <.card_content>
              <.advisory_summary site_advisory={sa} />
              <div class="mt-3 flex flex-wrap gap-2">
                <.button
                  id={"confirm-#{sa.id}"}
                  phx-click="confirm"
                  phx-value-id={sa.id}
                  phx-disable-with="Locking..."
                  color="danger"
                  variant="default"
                  size="small"
                  icon="hero-lock-closed"
                >
                  Confirm lock
                </.button>
                <.button
                  id={"dismiss-#{sa.id}"}
                  phx-click="dismiss"
                  phx-value-id={sa.id}
                  phx-disable-with="Dismissing..."
                  color="natural"
                  variant="bordered"
                  size="small"
                >
                  Dismiss
                </.button>
              </div>
            </.card_content>
          </.card>
        </div>
      </section>

      <section class="space-y-3 pt-4">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">Recent decisions</h2>
        <p :if={@decided_count == 0} id="no-decided" class="text-sm text-zinc-500">
          No advisory has locked or been dismissed yet.
        </p>
        <div id="decided" phx-update="stream" class="grid gap-3">
          <.card
            :for={{dom_id, sa} <- @streams.decided}
            id={dom_id}
            variant="bordered"
            color="natural"
            rounded="large"
            padding="medium"
          >
            <.card_content>
              <.advisory_summary site_advisory={sa} />
              <p class="mt-2 text-xs text-zinc-500">
                {decision_text(sa, @current_user)}
              </p>
            </.card_content>
          </.card>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :site_advisory, :map, required: true

  defp advisory_summary(assigns) do
    assigns = assign(assigns, :advisory, assigns.site_advisory.advisory)

    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0 space-y-1">
        <div class="flex flex-wrap items-center gap-2">
          <.link
            navigate={~p"/sites/#{@site_advisory.site_id}"}
            class="font-medium hover:underline"
          >
            {@site_advisory.site.name}
          </.link>
          <.status_badge id={"status-#{@site_advisory.id}"} status={@site_advisory.status} />
          <.badge color="natural" variant="default" size="small">
            {source_label(@advisory.source)}
          </.badge>
          <.badge
            :if={@advisory.exploitation == :not_known}
            color="info"
            variant="default"
            size="small"
          >
            Source says no known active exploitation
          </.badge>
        </div>
        <p class="text-sm">{@advisory.title}</p>
        <p class="text-xs text-zinc-500">
          <span :if={@advisory.cves != []} class="font-mono">
            {Enum.join(@advisory.cves, ", ")} ·
          </span>
          {tool_names(@advisory.tool_ids)}
        </p>
      </div>
      <div :if={@advisory.link} class="shrink-0 text-right text-xs">
        <.link
          href={@advisory.link}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center gap-1 text-blue-600 hover:underline dark:text-blue-400"
        >
          View source <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
        </.link>
        <p class="text-zinc-500">{attribution(@advisory.source)}</p>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true
  attr :id, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <%= case @status do %>
      <% :locked -> %>
        <.badge id={@id} color="danger" variant="bordered" size="small" icon="hero-lock-closed">
          Locked
        </.badge>
      <% :pending -> %>
        <.badge id={@id} color="warning" variant="bordered" size="small" icon="hero-clock">
          Pending
        </.badge>
      <% :dismissed -> %>
        <.badge id={@id} color="natural" variant="bordered" size="small">Dismissed</.badge>
    <% end %>
    """
  end

  defp source_label(:kev), do: "CISA KEV"
  defp source_label(:acsc), do: "ACSC"

  defp attribution(:kev), do: "Source: CISA KEV"
  defp attribution(:acsc), do: "Source: ACSC, CC BY 4.0"

  defp tool_names(tool_ids) do
    Enum.map_join(tool_ids, ", ", fn id ->
      case Breakline.Catalog.get(id) do
        {:ok, tool} -> tool.name
        :error -> id
      end
    end)
  end

  defp decision_text(%{status: :locked, decided_by_id: nil}, _user),
    do: "Locked automatically (tenant set to auto-lock). An admin can lift the lock on the site."

  defp decision_text(%{status: :locked, decided_by_id: id}, %{id: id}),
    do: "You confirmed the lock."

  defp decision_text(%{status: :locked}, _user), do: "An approver confirmed the lock."
  defp decision_text(%{status: :dismissed, decided_by_id: id}, %{id: id}), do: "You dismissed it."
  defp decision_text(%{status: :dismissed}, _user), do: "An approver dismissed it."
end
