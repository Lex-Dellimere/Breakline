defmodule CloudWeb.SettingsLive.Notifications do
  @moduledoc """
  A tenant's notification channels, for its admins: the channels with their
  masked targets, adding one (kind, name, target, event types), enabling and
  disabling, sending a test message, removing, and the recent deliveries
  with their status.

  Only admins reach the page; anyone else is sent back to the sites list.
  A user who administers several tenants picks one with `?tenant=<id>`.
  Every read and change runs as the user with the tenant, so the resource
  policies decide (`Cloud.Notifications.Channel`). Delivery statuses update
  live.
  """

  use CloudWeb, :live_view

  alias Cloud.Notifications
  alias Cloud.Notifications.{Channel, Event}

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @recent 25

  @kinds [
    {:slack, "Slack"},
    {:teams, "Microsoft Teams"},
    {:email, "Email"},
    {:sms, "SMS"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    case admin_tenants(socket.assigns.current_user) do
      [] ->
        {:ok,
         socket
         |> put_flash(:error, "Only a tenant admin can manage notifications")
         |> push_navigate(to: ~p"/sites")}

      tenants ->
        {:ok,
         socket
         |> assign(:page_title, "Notifications")
         |> assign(:tenants, tenants)
         |> assign(:tenant, nil)
         |> assign(:kinds, @kinds)
         |> assign(:event_types, Event.types())}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tenants = socket.assigns.tenants
    tenant = Enum.find(tenants, hd(tenants), &(&1.id == params["tenant"]))

    if connected?(socket) and socket.assigns.tenant != tenant do
      if old = socket.assigns.tenant do
        Phoenix.PubSub.unsubscribe(Cloud.PubSub, Notifications.deliveries_topic(old.id))
      end

      Phoenix.PubSub.subscribe(Cloud.PubSub, Notifications.deliveries_topic(tenant.id))
    end

    {:noreply,
     socket
     |> assign(:tenant, tenant)
     |> assign_form()
     |> load()}
  end

  defp admin_tenants(user) do
    Cloud.Accounts.list_memberships!(
      actor: user,
      query: [filter: [user_id: user.id, role: :admin], load: [:tenant]]
    )
    |> Enum.map(& &1.tenant)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp assign_form(socket, params \\ %{"kind" => "slack"}) do
    form =
      Channel
      |> AshPhoenix.Form.for_create(:create,
        actor: socket.assigns.current_user,
        tenant: socket.assigns.tenant.id,
        as: "channel"
      )
      |> AshPhoenix.Form.validate(params, errors: false)

    socket
    |> assign(:form, to_form(form))
    |> assign(:selected_types, selected_types(params))
  end

  defp load(socket) do
    opts = [actor: socket.assigns.current_user, tenant: socket.assigns.tenant.id]

    channels =
      Notifications.list_channels!(Keyword.put(opts, :query, sort: [inserted_at: :asc, id: :asc]))

    deliveries = Notifications.recent_deliveries!(%{limit: @recent}, opts)

    socket
    |> assign(:channel_count, length(channels))
    |> assign(:has_email_channel?, Enum.any?(channels, &(&1.kind == :email)))
    |> assign(:delivery_count, length(deliveries))
    |> stream(:channels, channels, reset: true)
    |> stream(:deliveries, deliveries, reset: true)
  end

  @impl true
  def handle_event("validate", %{"channel" => params}, socket) do
    params = clean(params)
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    {:noreply,
     socket |> assign(:form, to_form(form)) |> assign(:selected_types, selected_types(params))}
  end

  def handle_event("add", %{"channel" => params}, socket) do
    params = clean(params)

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> put_flash(:info, "Channel \"#{channel.name}\" added")
         |> assign_form()
         |> load()}

      {:error, form} ->
        {:noreply,
         socket |> assign(:form, to_form(form)) |> assign(:selected_types, selected_types(params))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with_channel(socket, id, fn channel, opts ->
      case Notifications.set_channel_enabled(channel, not channel.enabled, opts) do
        {:ok, %{enabled: true}} -> {:info, "Channel enabled"}
        {:ok, %{enabled: false}} -> {:info, "Channel disabled"}
        {:error, _} -> {:error, "The channel could not be changed"}
      end
    end)
  end

  def handle_event("test", %{"id" => id}, socket) do
    with_channel(socket, id, fn channel, opts ->
      case Notifications.send_test(socket.assigns.tenant.id, channel.id, opts) do
        {:ok, _delivery} -> {:info, "Test message queued for \"#{channel.name}\""}
        {:error, _} -> {:error, "The test message could not be queued"}
      end
    end)
  end

  def handle_event("remove", %{"id" => id}, socket) do
    with_channel(socket, id, fn channel, opts ->
      case Notifications.destroy_channel(channel, opts) do
        :ok -> {:info, "Channel \"#{channel.name}\" removed"}
        {:error, _} -> {:error, "The channel could not be removed"}
      end
    end)
  end

  # a channel id is looked up only in the selected tenant, as the user
  defp with_channel(socket, id, fun) do
    opts = [actor: socket.assigns.current_user, tenant: socket.assigns.tenant.id]

    result =
      with {:ok, _} <- Ecto.UUID.cast(id),
           {:ok, %Channel{} = channel} <-
             Notifications.get_channel(id, Keyword.put(opts, :not_found_error?, false)) do
        fun.(channel, opts)
      else
        _ -> {:error, "Channel not found"}
      end

    {kind, message} = result
    {:noreply, socket |> put_flash(kind, message) |> load()}
  end

  @impl true
  def handle_info({:delivery, _change}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  # the checkboxes send "" from their hidden inputs; only real choices count
  defp clean(params) do
    Map.update(params, "event_types", [], fn types ->
      Enum.reject(List.wrap(types), &(&1 == ""))
    end)
  end

  defp selected_types(%{"event_types" => types}) when is_list(types), do: types
  defp selected_types(_params), do: Enum.map(Event.types(), &Atom.to_string/1)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Notifications</h1>
          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            Where {@tenant.name} hears about locks, window requests and break-glass. Every message is one line and a link to Breakline, never an approve button: approving always needs a passkey in the app.
          </p>
        </div>
        <div :if={length(@tenants) > 1} id="tenant-picker" class="flex flex-wrap gap-2">
          <.button_link
            :for={tenant <- @tenants}
            id={"tenant-#{tenant.id}"}
            patch={~p"/settings/notifications?tenant=#{tenant.id}"}
            variant={if(tenant.id == @tenant.id, do: "default", else: "bordered")}
            color={if(tenant.id == @tenant.id, do: "primary", else: "natural")}
            size="small"
          >
            {tenant.name}
          </.button_link>
        </div>
      </div>

      <.alert
        :if={not @has_email_channel?}
        id="fallback-note"
        kind={:info}
        variant="bordered"
        size="small"
      >
        No email channel yet, so every admin and approver of {@tenant.name} is emailed instead. Add an email channel to choose who gets them.
      </.alert>

      <section class="space-y-3">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">
          Channels <span class="tabular-nums">({@channel_count})</span>
        </h2>
        <p :if={@channel_count == 0} id="no-channels" class="text-sm text-zinc-500">
          No channels yet.
        </p>
        <div id="channels" phx-update="stream" class="grid gap-3">
          <.card
            :for={{dom_id, channel} <- @streams.channels}
            id={dom_id}
            variant="bordered"
            color="natural"
            rounded="large"
            padding="medium"
          >
            <.card_content>
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 space-y-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="font-medium">{channel.name}</span>
                    <.badge color="natural" variant="default" size="small">
                      {kind_label(channel.kind)}
                    </.badge>
                    <.badge
                      id={"state-#{channel.id}"}
                      color={if(channel.enabled, do: "success", else: "natural")}
                      variant="bordered"
                      size="small"
                    >
                      {if(channel.enabled, do: "Enabled", else: "Disabled")}
                    </.badge>
                  </div>
                  <p id={"target-#{channel.id}"} class="font-mono text-xs text-zinc-500">
                    {channel.target_hint}
                  </p>
                  <p class="text-xs text-zinc-500">
                    {types_text(channel.event_types)}
                  </p>
                </div>
                <div class="flex flex-wrap gap-2">
                  <.button
                    id={"test-#{channel.id}"}
                    phx-click="test"
                    phx-value-id={channel.id}
                    phx-disable-with="Queuing..."
                    color="natural"
                    variant="bordered"
                    size="small"
                    icon="hero-paper-airplane"
                  >
                    Send test
                  </.button>
                  <.button
                    id={"toggle-#{channel.id}"}
                    phx-click="toggle"
                    phx-value-id={channel.id}
                    color="natural"
                    variant="bordered"
                    size="small"
                  >
                    {if(channel.enabled, do: "Disable", else: "Enable")}
                  </.button>
                  <.button
                    id={"remove-#{channel.id}"}
                    phx-click="remove"
                    phx-value-id={channel.id}
                    data-confirm={"Remove the channel \"#{channel.name}\"?"}
                    color="danger"
                    variant="bordered"
                    size="small"
                    icon="hero-trash"
                  >
                    Remove
                  </.button>
                </div>
              </div>
            </.card_content>
          </.card>
        </div>
      </section>

      <.card id="add-channel" variant="bordered" color="natural" rounded="large" padding="large">
        <.card_title title="Add a channel" size="small" font_weight="font-semibold" />
        <.card_content>
          <.form_wrapper
            for={@form}
            id="channel-form"
            phx-change="validate"
            phx-submit="add"
            space="small"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <.native_select field={@form[:kind]} label="Kind" size="small">
                <:option
                  :for={{kind, label} <- @kinds}
                  value={Atom.to_string(kind)}
                  selected={to_string(@form[:kind].value) == Atom.to_string(kind)}
                >
                  {label}
                </:option>
              </.native_select>
              <.text_field
                field={@form[:name]}
                label="Name"
                placeholder="e.g. IT team channel"
                autocomplete="off"
                size="small"
              />
            </div>
            <.text_field
              field={@form[:target]}
              label={target_label(@form[:kind].value)}
              description={target_help(@form[:kind].value)}
              placeholder={target_placeholder(@form[:kind].value)}
              autocomplete="off"
              size="small"
            />
            <fieldset id="event-types" class="space-y-2">
              <legend class="text-sm font-medium">Sends</legend>
              <div class="grid gap-1 sm:grid-cols-2">
                <.checkbox_field
                  :for={type <- @event_types}
                  id={"event-type-#{type}"}
                  name="channel[event_types][]"
                  value={Atom.to_string(type)}
                  checked={Atom.to_string(type) in @selected_types}
                  label={Event.label(type)}
                  size="small"
                />
              </div>
              <p
                :for={{message, _} <- @form[:event_types].errors}
                :if={Phoenix.Component.used_input?(@form[:event_types])}
                class="text-xs text-rose-600"
              >
                Pick at least one ({message})
              </p>
            </fieldset>
            <:actions>
              <.button
                id="add-channel-button"
                type="submit"
                phx-disable-with="Adding..."
                color="primary"
                variant="default"
                size="small"
                icon="hero-plus"
              >
                Add channel
              </.button>
            </:actions>
          </.form_wrapper>
        </.card_content>
      </.card>

      <section class="space-y-3 pt-4">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">Recent deliveries</h2>
        <p :if={@delivery_count == 0} id="no-deliveries" class="text-sm text-zinc-500">
          Nothing sent yet.
        </p>
        <div :if={@delivery_count > 0}>
          <.table
            id="deliveries"
            rows={@streams.deliveries}
            row_item={fn {_id, delivery} -> delivery end}
            variant="separated"
            color="natural"
            text_size="small"
          >
            <:col :let={d} label="When">
              <span class="whitespace-nowrap tabular-nums">{when_text(d.inserted_at)}</span>
            </:col>
            <:col :let={d} label="To">
              {d.channel_name || "Removed channel"}
              <span class="block font-mono text-xs text-zinc-500">{d.target_hint}</span>
            </:col>
            <:col :let={d} label="Event">{Event.label(d.event_type)}</:col>
            <:col :let={d} label="Status">
              <.delivery_status id={"delivery-#{d.id}"} delivery={d} />
            </:col>
          </.table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :delivery, :map, required: true

  defp delivery_status(assigns) do
    ~H"""
    <div id={@id}>
      <%= case @delivery.status do %>
        <% :sent -> %>
          <.badge color="success" variant="bordered" size="small">Sent</.badge>
        <% :pending -> %>
          <.badge color="warning" variant="bordered" size="small">
            {if(@delivery.attempts > 0, do: "Retrying", else: "Queued")}
          </.badge>
        <% :failed -> %>
          <.badge color="danger" variant="bordered" size="small">Failed</.badge>
      <% end %>
      <span :if={@delivery.attempts > 1} class="ml-1 text-xs text-zinc-500">
        {@delivery.attempts} attempts
      </span>
      <span :if={@delivery.last_error} class="block text-xs text-zinc-500">
        {@delivery.last_error}
      </span>
    </div>
    """
  end

  defp kind_label(kind), do: @kinds |> List.keyfind(kind, 0) |> elem(1)

  defp types_text(types) do
    if Enum.sort(types) == Enum.sort(Event.types()),
      do: "All events",
      else: Enum.map_join(types, ", ", &Event.label/1)
  end

  defp when_text(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %H:%M UTC")

  defp kind(value) when value in [:teams, "teams"], do: :teams
  defp kind(value) when value in [:email, "email"], do: :email
  defp kind(value) when value in [:sms, "sms"], do: :sms
  defp kind(_value), do: :slack

  defp target_label(value) do
    case kind(value) do
      :slack -> "Slack webhook URL"
      :teams -> "Teams Workflows webhook URL"
      :email -> "Email address"
      :sms -> "Mobile number"
    end
  end

  defp target_help(value) do
    case kind(value) do
      :slack ->
        "From a Slack app's Incoming Webhooks page. Stored encrypted and shown masked."

      :teams ->
        "In Teams: the channel's Workflows, \"Send webhook alerts to a channel\", copy the URL. Stored encrypted and shown masked."

      :email ->
        "A person or a shared mailbox."

      :sms ->
        "In international format."
    end
  end

  defp target_placeholder(value) do
    case kind(value) do
      :slack ->
        "https://hooks.slack.com/services/..."

      :teams ->
        "https://....environment.api.powerplatform.com/powerautomate/automations/direct/..."

      :email ->
        "it@example.com.au"

      :sms ->
        "+61412345678"
    end
  end
end
