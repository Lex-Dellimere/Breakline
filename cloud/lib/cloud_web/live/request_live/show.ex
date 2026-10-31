defmodule CloudWeb.RequestLive.Show do
  @moduledoc """
  The MSP contact's request page at `/request/:token`, reached from the
  magic link in their email (`Cloud.Sites.RequestLink`). No account, no
  sign in.

  A valid link shows the site's name and time zone, the contact's own
  requests for that site and a form to request a one-off window: start and
  end as local date-times in the site's zone and a reason or ticket
  reference. The window is created through `Cloud.Sites.Window`'s `:request`
  action with the link as the actor, so the resource decides what a link may
  ask for (`Cloud.Sites.Changes.FromRequestLink`). Nothing on this page can
  approve or open anything (threat model T6).

  An unknown, malformed, expired or revoked token, and a client over the
  lookup rate limit, all get the same "this link is not valid" page, after
  the same single lookup, so the page never says why or whether a site
  exists. Every token lookup (each mount and each submission) counts
  against a per-ip limit, `CloudWeb.RateLimit`.

  The list updates live when an approver decides one of the requests, and a
  link revoked while the page is open stops working on its next action.
  """

  use CloudWeb, :live_view

  alias AshPhoenix.Form
  alias Cloud.Sites
  alias Cloud.Sites.{RequestLinks, Window}

  @lookups 30
  @window_ms :timer.minutes(10)
  @fields ["starts_at", "ends_at", "reason"]
  @window_types [:window_requested, :window_approved, :window_rejected]

  @doc "The per-ip lookup limit: `{lookups, window_ms}`."
  def rate_limit do
    config = Application.get_env(:cloud, __MODULE__, [])
    {Keyword.get(config, :lookups, @lookups), Keyword.get(config, :window_ms, @window_ms)}
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket = assign(socket, page_title: "Request a window", ip: client_ip(socket))

    case lookup(socket, token) do
      {:ok, link} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(
            Cloud.PubSub,
            Cloud.Advisories.notifications_topic(link.tenant_id)
          )
        end

        {:ok,
         socket
         |> assign(:link, link)
         |> assign(:site, link.site)
         |> assign(:contact, link.msp_contact)
         |> assign(:form, new_form(link))
         |> load_requests()}

      {:error, _} ->
        {:ok, invalid(socket)}
    end
  end

  # every token lookup counts towards the ip's limit, valid or not
  defp lookup(socket, token) do
    {limit, window_ms} = rate_limit()

    with :ok <- CloudWeb.RateLimit.hit({:request_lookup, socket.assigns.ip}, limit, window_ms) do
      RequestLinks.lookup(token)
    end
  end

  # a submission re-reads the link by id (trusted) after counting a lookup, so a
  # revoked or expired link stops at once; the action re-checks it under a lock
  defp still_valid(socket) do
    {limit, window_ms} = rate_limit()
    link = socket.assigns.link

    with :ok <- CloudWeb.RateLimit.hit({:request_lookup, socket.assigns.ip}, limit, window_ms),
         {:ok, %{} = fresh} <-
           Sites.get_request_link(link.id, authorize?: false, not_found_error?: false),
         true <- RequestLinks.usable?(fresh) do
      {:ok, %{fresh | site: link.site, msp_contact: link.msp_contact}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp invalid(socket) do
    socket
    |> assign(:invalid?, true)
    |> assign(:link, nil)
  end

  defp new_form(link, params \\ %{}) do
    Window
    |> Form.for_create(:request, actor: link, tenant: link.tenant_id, as: "request")
    |> then(fn form -> if params == %{}, do: form, else: Form.validate(form, params) end)
    |> to_form()
  end

  defp load_requests(socket) do
    link = socket.assigns.link

    requests =
      Sites.list_windows!(
        actor: link,
        tenant: link.tenant_id,
        query: [sort: [inserted_at: :desc], limit: 50]
      )

    socket
    |> assign(:invalid?, false)
    |> assign(:requests_empty?, requests == [])
    |> stream(:requests, requests, reset: true)
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{invalid?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("validate", %{"request" => params}, socket) do
    {:noreply, assign(socket, :form, new_form(socket.assigns.link, Map.take(params, @fields)))}
  end

  def handle_event("submit", %{"request" => params}, socket) do
    with {:ok, link} <- still_valid(socket) do
      form = new_form(link)

      case Form.submit(form.source, params: Map.take(params, @fields)) do
        {:ok, _window} ->
          {:noreply,
           socket
           |> assign(:link, link)
           |> assign(:form, new_form(link))
           |> put_flash(:info, "Request sent. Your client will approve or reject it.")
           |> load_requests()}

        {:error, form} ->
          if link_rejected?(form) do
            {:noreply, invalid(socket)}
          else
            {:noreply, assign(socket, :form, to_form(form))}
          end
      end
    else
      _ -> {:noreply, invalid(socket)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp link_rejected?(form) do
    form
    |> Form.raw_errors(for_path: :all)
    |> Map.values()
    |> List.flatten()
    |> Enum.any?(&match?(%{field: :request_link_id}, &1))
  end

  @impl true
  def handle_info({:notification, %{type: type, site_id: site_id}}, socket)
      when type in @window_types do
    with %{link: %{site_id: ^site_id}} <- socket.assigns,
         {:ok, link} <- refresh_link(socket.assigns.link) do
      {:noreply, socket |> assign(:link, link) |> load_requests()}
    else
      {:error, :invalid} -> {:noreply, invalid(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_link(link) do
    case Sites.get_request_link(link.id, authorize?: false, not_found_error?: false) do
      {:ok, %{} = fresh} ->
        if RequestLinks.usable?(fresh),
          do: {:ok, %{fresh | site: link.site, msp_contact: link.msp_contact}},
          else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  end

  defp client_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  @impl true
  def render(%{invalid?: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto w-full max-w-md">
        <.card id="link-invalid" variant="bordered" color="natural" rounded="large" padding="large">
          <.card_title title="This link is not valid" size="large" font_weight="font-semibold" />
          <.card_content>
            <p class="text-sm text-zinc-600 dark:text-zinc-400">
              Ask the person who sent it to you for a new one.
            </p>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto w-full max-w-2xl space-y-4">
        <div>
          <p class="text-sm text-zinc-500">Request a remote access window</p>
          <h1 id="request-site" class="text-2xl font-semibold tracking-tight">{@site.name}</h1>
          <p id="request-time-zone" class="text-sm text-zinc-500">
            Times are in {@site.time_zone} (now {now_local(@site.time_zone)}) · requesting as {@contact.name}
          </p>
        </div>

        <.alert id="request-only" kind={:info} variant="bordered" size="small">
          This page can only ask for a window. A client approver approves each request with their
          passkey before anything opens.
        </.alert>

        <.card id="request-card" variant="bordered" color="natural" rounded="large" padding="large">
          <.card_content>
            <.form_wrapper
              for={@form}
              id="request-form"
              phx-change="validate"
              phx-submit="submit"
              space="medium"
            >
              <div class="grid gap-4 sm:grid-cols-2">
                <.date_time_field
                  field={@form[:starts_at]}
                  value={input_value(@form[:starts_at].value)}
                  type="datetime-local"
                  label="Start (site time)"
                  required
                />
                <.date_time_field
                  field={@form[:ends_at]}
                  value={input_value(@form[:ends_at].value)}
                  type="datetime-local"
                  label="End (site time)"
                  required
                />
              </div>
              <.textarea_field
                field={@form[:reason]}
                label="Reason or ticket reference"
                placeholder="e.g. INC-4821 patch the reception PC"
                rows="2"
                required
              />
              <p class="text-xs text-zinc-500">
                At most 12 hours. You can have up to 3 requests waiting at once.
              </p>
              <:actions>
                <.button
                  id="request-submit"
                  type="submit"
                  color="primary"
                  variant="default"
                  icon="hero-paper-airplane"
                  phx-disable-with="Sending..."
                >
                  Send request
                </.button>
              </:actions>
            </.form_wrapper>
          </.card_content>
        </.card>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">Your requests</h2>
          <p :if={@requests_empty?} id="no-requests" class="text-sm text-zinc-500">
            No requests yet.
          </p>
          <ul
            id="requests"
            phx-update="stream"
            class="divide-y divide-zinc-100 text-sm dark:divide-zinc-800"
          >
            <li
              :for={{dom_id, window} <- @streams.requests}
              id={dom_id}
              class="flex flex-wrap items-baseline gap-x-3 gap-y-1 py-2"
            >
              <span class="tabular-nums">{span(window)}</span>
              <.window_status id={"#{dom_id}-status"} status={window.status} />
              <span :if={window.reason} class="min-w-0 break-words text-zinc-600 dark:text-zinc-400">
                {window.reason}
              </span>
              <span
                :if={window.rejection_note}
                class="w-full text-xs text-zinc-500"
              >
                Note: {window.rejection_note}
              </span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :status, :atom, required: true

  @doc false
  def window_status(assigns) do
    ~H"""
    <%= case @status do %>
      <% :requested -> %>
        <.badge id={@id} color="warning" variant="bordered" size="small">Waiting</.badge>
      <% :approved -> %>
        <.badge id={@id} color="success" variant="bordered" size="small">Approved</.badge>
      <% :rejected -> %>
        <.badge id={@id} color="danger" variant="bordered" size="small">Rejected</.badge>
      <% :cancelled -> %>
        <.badge id={@id} color="natural" variant="bordered" size="small">Cancelled</.badge>
    <% end %>
    """
  end

  defp span(%{starts_at: %NaiveDateTime{} = s, ends_at: %NaiveDateTime{} = e}) do
    if NaiveDateTime.to_date(s) == NaiveDateTime.to_date(e),
      do: Calendar.strftime(s, "%a %d %b %H:%M") <> "–" <> Calendar.strftime(e, "%H:%M"),
      else:
        Calendar.strftime(s, "%a %d %b %H:%M") <> " – " <> Calendar.strftime(e, "%a %d %b %H:%M")
  end

  defp span(_window), do: "recurring"

  defp now_local(time_zone) do
    DateTime.utc_now()
    |> DateTime.shift_zone!(time_zone, Tz.TimeZoneDatabase)
    |> Calendar.strftime("%a %d %b %H:%M")
  end

  # datetime-local inputs want yyyy-mm-ddThh:mm
  defp input_value(%NaiveDateTime{} = value),
    do: value |> NaiveDateTime.to_iso8601() |> binary_part(0, 16)

  defp input_value(value) when is_binary(value), do: value
  defp input_value(_value), do: nil
end
