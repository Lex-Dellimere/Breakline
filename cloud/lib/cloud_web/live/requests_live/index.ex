defmodule CloudWeb.RequestsLive.Index do
  @moduledoc """
  Window requests waiting for a decision in the signed-in user's tenants,
  with the site, the MSP contact, the local start and end and the reason,
  and below them the recently decided ones.

  Approve runs a passkey step-up bound to the window (purpose
  `:approve_window`, params its `id` and `site_id`, `CloudWeb.StepUp`), then
  `Cloud.Sites.Window`'s `:approve`, which consumes the step-up and
  publishes. Reject takes an optional note and needs no step-up: it opens
  nothing.

  Every read and decision runs as the user with the tenant, so the resource
  policies decide what is visible and allowed. The page updates live from
  the tenants' notification topics.
  """

  use CloudWeb, :live_view

  alias Cloud.Accounts.Passkeys
  alias Cloud.Sites
  alias CloudWeb.SitesLive.Data
  alias CloudWeb.StepUp

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @recent 20
  @window_types [:window_requested, :window_approved, :window_rejected]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    tenant_ids = Data.tenant_ids(user)

    if connected?(socket) do
      for tenant_id <- tenant_ids do
        Phoenix.PubSub.subscribe(Cloud.PubSub, Cloud.Advisories.notifications_topic(tenant_id))
      end
    end

    {:ok,
     socket
     |> assign(:page_title, "Requests")
     |> assign(:tenant_ids, tenant_ids)
     |> assign(:step_up, nil)
     |> assign(:has_passkey, Passkeys.any?(user))
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_user

    windows =
      Enum.flat_map(socket.assigns.tenant_ids, fn tenant_id ->
        Sites.list_windows!(
          actor: user,
          tenant: tenant_id,
          query: [
            filter: [requested_by_id: [is_nil: false]],
            sort: [updated_at: :desc, id: :desc],
            load: [:site, :requested_by]
          ]
        )
      end)

    {pending, decided} = Enum.split_with(windows, &(&1.status == :requested))
    pending = Enum.sort_by(pending, & &1.inserted_at, {:asc, DateTime})

    decided =
      decided |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> Enum.take(@recent)

    socket
    |> assign(:pending_count, length(pending))
    |> assign(:decided_count, length(decided))
    |> stream(:pending, pending, reset: true)
    |> stream(:decided, decided, reset: true)
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    case find(socket, id) do
      {:ok, window} ->
        {:noreply,
         StepUp.start(
           socket,
           :approve_window,
           window.id,
           %{id: window.id, site_id: window.site_id},
           [tenant: window.tenant_id],
           {:approve, window.id}
         )}

      {:error, :not_found} ->
        {:noreply, socket |> put_flash(:error, "Request not found") |> load()}
    end
  end

  def handle_event("reject", %{"window_id" => id} = params, socket) do
    note =
      case String.trim(params["note"] || "") do
        "" -> nil
        note -> note
      end

    with {:ok, window} <- find(socket, id),
         {:ok, _} <-
           Sites.reject_window(window, %{note: note},
             actor: socket.assigns.current_user,
             tenant: window.tenant_id
           ) do
      {:noreply, socket |> put_flash(:info, "Request rejected") |> load()}
    else
      error -> {:noreply, socket |> decision_error(error) |> load()}
    end
  end

  def handle_event("passkey_assertion", params, socket) do
    case StepUp.verify(socket, params) do
      {:ok, {:approve, id}, step_up_id, socket} -> approve(socket, id, step_up_id)
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("passkey_error", params, socket) do
    {:noreply, StepUp.cancel(socket, params)}
  end

  defp approve(socket, id, step_up_id) do
    with {:ok, window} <- find(socket, id),
         {:ok, approved} <-
           Sites.approve_window(window, %{step_up_id: step_up_id},
             actor: socket.assigns.current_user,
             tenant: window.tenant_id
           ) do
      version = approved.__metadata__[:policy_version]

      {:noreply,
       socket
       |> put_flash(:info, "Approved: published policy v#{version && version.version}")
       |> load()}
    else
      error -> {:noreply, socket |> decision_error(error) |> load()}
    end
  end

  defp decision_error(socket, {:error, :not_found}),
    do: put_flash(socket, :error, "Request not found")

  defp decision_error(socket, {:error, %Ash.Error.Forbidden{}}),
    do: put_flash(socket, :error, "Your role does not allow that")

  defp decision_error(socket, {:error, error}) do
    message = StepUp.action_error(error) || "That request was already decided"
    put_flash(socket, :error, message)
  end

  # an id is looked up only in the user's own tenants, as the user
  defp find(socket, id) do
    with {:ok, _} <- Ecto.UUID.cast(id) do
      Enum.find_value(socket.assigns.tenant_ids, {:error, :not_found}, fn tenant_id ->
        case Sites.get_window(id,
               actor: socket.assigns.current_user,
               tenant: tenant_id,
               not_found_error?: false
             ) do
          {:ok, %{} = window} -> {:ok, window}
          _ -> nil
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def handle_info({:notification, %{type: type, tenant_id: tenant_id}}, socket)
      when type in @window_types do
    if tenant_id in socket.assigns.tenant_ids,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div>
        <h1 class="text-2xl font-semibold tracking-tight">Requests</h1>
        <p class="text-sm text-zinc-600 dark:text-zinc-400">
          Maintenance windows your MSP asked for. Approving asks for your passkey and publishes the
          window to the site's gateway; rejecting opens nothing.
        </p>
      </div>

      <p :if={!@has_passkey} id="passkey-needed" class="text-sm text-zinc-600 dark:text-zinc-400">
        Approving needs a passkey.
        <.link
          navigate={~p"/account/security"}
          class="text-blue-600 hover:underline dark:text-blue-400"
        >
          Add one on the security page
        </.link>
      </p>
      <p :if={@step_up} id="step-up-waiting" class="text-sm text-zinc-600 dark:text-zinc-400">
        <.icon name="hero-finger-print" class="size-4 align-text-bottom" />
        Confirm with your passkey to approve.
      </p>
      <CloudWeb.PasskeyCeremony.hook id="passkey-ceremony" />

      <section class="space-y-3">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">
          Waiting for a decision <span class="tabular-nums">({@pending_count})</span>
        </h2>
        <p :if={@pending_count == 0} id="no-pending" class="text-sm text-zinc-500">
          Nothing to decide.
        </p>
        <div id="pending" phx-update="stream" class="grid gap-3">
          <.card
            :for={{dom_id, window} <- @streams.pending}
            id={dom_id}
            variant="bordered"
            color="warning"
            rounded="large"
            padding="medium"
          >
            <.card_content>
              <.request_summary window={window} />
              <div class="mt-3 flex flex-wrap items-end gap-2">
                <.button
                  :if={@has_passkey}
                  id={"approve-#{window.id}"}
                  phx-click="approve"
                  phx-value-id={window.id}
                  disabled={@step_up != nil}
                  color="success"
                  variant="default"
                  size="small"
                  icon="hero-check"
                >
                  Approve
                </.button>
                <.form_wrapper
                  for={%{}}
                  id={"reject-form-#{window.id}"}
                  phx-submit="reject"
                  class="flex flex-wrap items-end gap-2"
                  space="small"
                >
                  <input type="hidden" name="window_id" value={window.id} />
                  <.text_field
                    id={"reject-note-#{window.id}"}
                    name="note"
                    value=""
                    placeholder="Note for the MSP (optional)"
                    autocomplete="off"
                    size="small"
                  />
                  <.button
                    id={"reject-#{window.id}"}
                    type="submit"
                    color="danger"
                    variant="bordered"
                    size="small"
                    icon="hero-x-mark"
                  >
                    Reject
                  </.button>
                </.form_wrapper>
              </div>
            </.card_content>
          </.card>
        </div>
      </section>

      <section class="space-y-3 pt-4">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">Recently decided</h2>
        <p :if={@decided_count == 0} id="no-decided" class="text-sm text-zinc-500">
          No request has been decided yet.
        </p>
        <div id="decided" phx-update="stream" class="grid gap-3">
          <.card
            :for={{dom_id, window} <- @streams.decided}
            id={dom_id}
            variant="bordered"
            color="natural"
            rounded="large"
            padding="medium"
          >
            <.card_content>
              <.request_summary window={window} />
              <p :if={window.rejection_note} class="mt-2 text-xs text-zinc-500">
                Note: {window.rejection_note}
              </p>
            </.card_content>
          </.card>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :window, :map, required: true

  defp request_summary(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0 space-y-1">
        <div class="flex flex-wrap items-center gap-2">
          <.link navigate={~p"/sites/#{@window.site_id}"} class="font-medium hover:underline">
            {@window.site.name}
          </.link>
          <CloudWeb.RequestLive.Show.window_status
            id={"status-#{@window.id}"}
            status={@window.status}
          />
        </div>
        <p class="text-sm tabular-nums">
          {span(@window)}
          <span class="text-zinc-500">({@window.site.time_zone})</span>
        </p>
        <p :if={@window.reason} class="text-sm text-zinc-700 dark:text-zinc-300">
          {@window.reason}
        </p>
      </div>
      <p class="shrink-0 text-xs text-zinc-500">
        from {@window.requested_by && @window.requested_by.name}
      </p>
    </div>
    """
  end

  defp span(%{kind: :one_off, starts_at: s, ends_at: e}) do
    if NaiveDateTime.to_date(s) == NaiveDateTime.to_date(e),
      do: Calendar.strftime(s, "%a %d %b %H:%M") <> "–" <> Calendar.strftime(e, "%H:%M"),
      else:
        Calendar.strftime(s, "%a %d %b %H:%M") <> " – " <> Calendar.strftime(e, "%a %d %b %H:%M")
  end

  defp span(%{kind: :recurring, days: days, starts: s, ends: e}) do
    "weekly on days #{Enum.join(days, ", ")} " <>
      Calendar.strftime(s, "%H:%M") <> "–" <> Calendar.strftime(e, "%H:%M")
  end
end
