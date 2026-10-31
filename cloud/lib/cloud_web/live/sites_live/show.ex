defmodule CloudWeb.SitesLive.Show do
  @moduledoc """
  One site: the gateway's live state and why, whether it is connected and
  when it was last seen, mode, next change, published vs applied policy
  version, the newest gateway events (live), and an access panel that opens,
  locks and unlocks the site through `Cloud.Access`.

  Opening and unlocking need a passkey step-up bound to that exact action
  (`CloudWeb.StepUp`): the button starts the step-up, the
  `CloudWeb.PasskeyCeremony` hook asks the authenticator, and once the
  assertion verifies the action runs and consumes the step-up. Locking needs
  nothing more. A user without a passkey is pointed at `/account/security`.

  Break-glass opens the site now for 15 minutes to 4 hours, overriding the
  schedule (but not advisory locks). It runs a `:break_glass` step-up whose
  params are the site id and the exact `until` the break-glass is then
  created with. An active break-glass is shown at the top with who opened it
  and when it ends, and can be revoked without a step-up (that closes
  access).

  Admins also manage the site's MSP request links here: pick a contact and
  send a link (emailed to the contact), and revoke links
  (`Cloud.Sites.RequestLink`).

  The site is only shown to members of its tenant; any other id redirects to
  `/sites` as not found.
  """

  use CloudWeb, :live_view

  import CloudWeb.SitesLive.Components

  alias Cloud.Accounts.Passkeys
  alias Cloud.{Gateways, Sites}
  alias CloudWeb.{GatewayPresence, StepUp}
  alias CloudWeb.SitesLive.{Data, Presenter}

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @events 50
  @break_glass_minutes [15, 30, 60, 120, 240]

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
         |> assign(:step_up, nil)
         |> assign(:has_passkey, Passkeys.any?(user))
         |> assign(:role, Data.role(user, site.tenant_id))
         |> assign(:break_glass_minutes, @break_glass_minutes)
         |> assign(:break_glass, Data.current_break_glass(user, site))
         |> assign_links()
         |> stream(:events, events, limit: @events)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Site not found")
         |> push_navigate(to: ~p"/sites")}
    end
  end

  # access actions

  @impl true
  def handle_event("open", %{"minutes" => minutes}, socket) do
    case Integer.parse(minutes) do
      {m, ""} when m in [15, 30, 60] ->
        {:noreply, start_step_up(socket, :open_window, {:open, m})}

      _ ->
        {:noreply, put_flash(socket, :error, "Unknown duration")}
    end
  end

  def handle_event("lock", _params, socket) do
    socket.assigns.site.id
    |> Cloud.Access.lock_now(socket.assigns.current_user, "locked from the site page")
    |> action_result(socket, "Locked")
  end

  def handle_event("unlock", _params, socket) do
    if Cloud.Access.manual_lock?(socket.assigns.site.id, socket.assigns.current_user) do
      {:noreply, start_step_up(socket, :lift_lock, :unlock)}
    else
      {:noreply, put_flash(socket, :error, "There is no manual lock to lift")}
    end
  end

  def handle_event("break_glass", %{"minutes" => minutes}, socket) do
    case Integer.parse(minutes) do
      {m, ""} when m in @break_glass_minutes ->
        site = socket.assigns.site
        until = DateTime.add(DateTime.utc_now(), m * 60, :second)

        {:noreply,
         StepUp.start(
           socket,
           :break_glass,
           site.id,
           %{site_id: site.id, until: until},
           [tenant: site.tenant_id],
           {:break_glass, m, until}
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Unknown duration")}
    end
  end

  def handle_event("revoke_break_glass", _params, socket) do
    case socket.assigns.break_glass do
      nil ->
        {:noreply, put_flash(socket, :error, "There is no break-glass to revoke")}

      break_glass ->
        break_glass
        |> Sites.revoke_break_glass(
          actor: socket.assigns.current_user,
          tenant: break_glass.tenant_id
        )
        |> record_result(socket, "Break-glass revoked")
    end
  end

  # msp request links (admins)

  def handle_event("send_link", %{"link" => %{"msp_contact_id" => contact_id}}, socket) do
    site = socket.assigns.site

    case Sites.create_request_link(%{site_id: site.id, msp_contact_id: contact_id},
           actor: socket.assigns.current_user,
           tenant: site.tenant_id
         ) do
      {:ok, link} ->
        message =
          if link.__metadata__[:email_sent?],
            do: "Request link emailed",
            else: "The link was made but the email failed; revoke it and try again"

        {:noreply, socket |> put_flash(:info, message) |> assign_links()}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "Your role does not allow that")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Pick a contact to send the link to")}
    end
  end

  def handle_event("revoke_link", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.request_links, &(&1.id == id)) do
      nil -> {:noreply, put_flash(socket, :error, "Link not found")}
      link -> revoke_link(link, socket)
    end
  end

  # the passkey ceremony hook

  def handle_event("passkey_assertion", params, socket) do
    case StepUp.verify(socket, params) do
      {:ok, action, step_up_id, socket} -> run(action, step_up_id, socket)
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("passkey_error", params, socket) do
    {:noreply, StepUp.cancel(socket, params)}
  end

  defp start_step_up(socket, purpose, action) do
    site = socket.assigns.site

    StepUp.start(
      socket,
      purpose,
      site.id,
      Cloud.Access.step_up_params(site.id, action),
      [tenant: site.tenant_id],
      action
    )
  end

  defp run({:open, minutes}, step_up_id, socket) do
    socket.assigns.site.id
    |> Cloud.Access.open_now(minutes, socket.assigns.current_user, step_up_id)
    |> action_result(socket, "Opened for #{minutes} minutes")
  end

  defp run({:break_glass, minutes, until}, step_up_id, socket) do
    site = socket.assigns.site

    %{site_id: site.id, until: until, step_up_id: step_up_id}
    |> Sites.create_break_glass(actor: socket.assigns.current_user, tenant: site.tenant_id)
    |> record_result(socket, "Break-glass open for #{duration(minutes)}")
  end

  defp run(:unlock, step_up_id, socket) do
    socket.assigns.site.id
    |> Cloud.Access.unlock(socket.assigns.current_user, step_up_id)
    |> action_result(socket, "Manual locks lifted")
  end

  defp revoke_link(link, socket) do
    case Sites.revoke_request_link(link,
           actor: socket.assigns.current_user,
           tenant: link.tenant_id
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Link revoked") |> assign_links()}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "Your role does not allow that")}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "That link is already revoked") |> assign_links()}
    end
  end

  # a resource action that publishes: the version is in the record's metadata
  defp record_result({:ok, record}, socket, message),
    do:
      action_result({:ok, %{policy_version: record.__metadata__.policy_version}}, socket, message)

  defp record_result(error, socket, message), do: action_result(error, socket, message)

  defp assign_links(socket) do
    user = socket.assigns.current_user
    site = socket.assigns.site

    if socket.assigns.role == :admin do
      socket
      |> assign(:request_links, Data.request_links(user, site))
      |> assign(:msp_contacts, Data.msp_contacts(user, site.tenant_id))
      |> assign(:link_form, to_form(%{"msp_contact_id" => ""}, as: :link))
    else
      assign(socket, request_links: [], msp_contacts: [], link_form: nil)
    end
  end

  defp duration(minutes) when minutes < 60, do: "#{minutes} minutes"
  defp duration(60), do: "1 hour"
  defp duration(minutes), do: "#{div(minutes, 60)} hours"

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

  defp action_result({:error, error}, socket, _message) do
    message = StepUp.action_error(error) || "That did not work, see the server log"
    {:noreply, put_flash(socket, :error, message)}
  end

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
      {:ok, site} ->
        assign(socket,
          site: site,
          windows: Data.windows(user, site),
          break_glass: Data.current_break_glass(user, site)
        )

      {:error, _} ->
        socket
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

      <.card
        :if={@break_glass}
        id="break-glass-active"
        variant="bordered"
        color="danger"
        rounded="large"
        padding="large"
      >
        <.card_content>
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p class="text-lg font-semibold text-red-700 dark:text-red-400">
                <.icon name="hero-bolt" class="size-5 align-text-bottom" />
                Break-glass open until {Presenter.local_time(@break_glass.until, @tz)}
              </p>
              <p id="break-glass-by" class="text-sm text-zinc-600 dark:text-zinc-400">
                Opened by {@break_glass.approved_by && @break_glass.approved_by.email} at {Presenter.local_time(
                  @break_glass.inserted_at,
                  @tz
                )}.
                Advisory locks still win over it.
              </p>
            </div>
            <.button
              :if={@role in [:admin, :approver]}
              id="revoke-break-glass"
              phx-click="revoke_break_glass"
              phx-disable-with="Revoking..."
              color="danger"
              variant="default"
              size="small"
              icon="hero-lock-closed"
            >
              Revoke
            </.button>
          </div>
        </.card_content>
      </.card>

      <.card id="access" variant="bordered" color="natural" rounded="large" padding="large">
        <.card_title title="Access" size="small" font_weight="font-semibold" />
        <.card_content>
          <p class="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
            Each action publishes a new signed policy, which the gateway applies within seconds.
            Opening and unlocking ask for your passkey and approve only that one action.
          </p>
          <div class="flex flex-wrap items-center gap-2">
            <%= if @has_passkey do %>
              <.button
                :for={m <- [15, 30, 60]}
                id={"open-#{m}"}
                phx-click="open"
                phx-value-minutes={m}
                disabled={@step_up != nil}
                color="success"
                variant="default"
                size="small"
                icon="hero-lock-open"
              >
                Open {m} min
              </.button>
            <% end %>
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
            <%= if @has_passkey do %>
              <.button
                id="unlock"
                phx-click="unlock"
                disabled={@step_up != nil}
                color="natural"
                variant="bordered"
                size="small"
                icon="hero-arrow-uturn-left"
              >
                Unlock
              </.button>
            <% end %>
          </div>
          <div
            :if={@has_passkey and @role in [:admin, :approver]}
            id="break-glass"
            class="mt-4 border-t border-zinc-100 pt-4 dark:border-zinc-800"
          >
            <p class="mb-2 text-sm text-zinc-600 dark:text-zinc-400">
              <span class="font-medium text-zinc-800 dark:text-zinc-200">
                Open now (break-glass)
              </span>
              overrides the schedule until it ends or is revoked. For emergencies.
            </p>
            <div class="flex flex-wrap gap-2">
              <.button
                :for={m <- @break_glass_minutes}
                id={"break-glass-#{m}"}
                phx-click="break_glass"
                phx-value-minutes={m}
                disabled={@step_up != nil}
                color="warning"
                variant="bordered"
                size="small"
                icon="hero-bolt"
              >
                {short_duration(m)}
              </.button>
            </div>
          </div>
          <p :if={@step_up} id="step-up-waiting" class="mt-3 text-sm text-zinc-600 dark:text-zinc-400">
            <.icon name="hero-finger-print" class="size-4 align-text-bottom" />
            Confirm with your passkey to continue.
          </p>
          <p
            :if={!@has_passkey}
            id="passkey-needed"
            class="mt-3 text-sm text-zinc-600 dark:text-zinc-400"
          >
            Opening and unlocking need a passkey.
            <.link
              navigate={~p"/account/security"}
              class="text-blue-600 hover:underline dark:text-blue-400"
            >
              Add one on the security page
            </.link>
          </p>
          <CloudWeb.PasskeyCeremony.hook id="passkey-ceremony" />
        </.card_content>
      </.card>

      <.card
        :if={@role == :admin}
        id="request-links"
        variant="bordered"
        color="natural"
        rounded="large"
        padding="large"
      >
        <.card_title title="MSP request links" size="small" font_weight="font-semibold" />
        <.card_content>
          <p class="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
            A link lets one MSP contact request windows for this site for 14 days. It can only ask;
            approvers decide on the Requests page.
          </p>
          <p :if={@msp_contacts == []} id="no-contacts" class="text-sm text-zinc-500">
            This organisation has no MSP contacts yet.
          </p>
          <.form_wrapper
            :if={@msp_contacts != []}
            for={@link_form}
            id="send-link-form"
            phx-submit="send_link"
            class="flex flex-wrap items-end gap-2"
            space="small"
          >
            <.native_select field={@link_form[:msp_contact_id]} label="Contact" size="small">
              <:option :for={c <- @msp_contacts} value={c.id}>{c.name} ({c.email})</:option>
            </.native_select>
            <.button
              id="send-link"
              type="submit"
              color="primary"
              variant="default"
              size="small"
              icon="hero-envelope"
              phx-disable-with="Sending..."
            >
              Send link
            </.button>
          </.form_wrapper>
          <ul
            :if={@request_links != []}
            id="request-link-list"
            class="mt-3 divide-y divide-zinc-100 text-sm dark:divide-zinc-800"
          >
            <li
              :for={link <- @request_links}
              id={"request-link-#{link.id}"}
              class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2"
            >
              <span class="font-medium">{link.msp_contact.name}</span>
              <.link_status
                id={"request-link-status-#{link.id}"}
                status={Cloud.Sites.RequestLinks.status(link)}
              />
              <span class="text-xs text-zinc-500">
                expires {Presenter.local_time(link.expires_at, @tz, "%d %b")} · last used {Presenter.local_time(
                  link.last_used_at,
                  @tz,
                  "%d %b %H:%M"
                ) || "never"}
              </span>
              <.button
                :if={Cloud.Sites.RequestLinks.status(link) == :active}
                id={"revoke-link-#{link.id}"}
                phx-click="revoke_link"
                phx-value-id={link.id}
                color="danger"
                variant="transparent"
                size="extra_small"
                class="ms-auto"
              >
                Revoke
              </.button>
            </li>
          </ul>
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

  attr :id, :string, required: true
  attr :status, :atom, required: true

  defp link_status(assigns) do
    ~H"""
    <%= case @status do %>
      <% :active -> %>
        <.badge id={@id} color="success" variant="bordered" size="extra_small">active</.badge>
      <% :expired -> %>
        <.badge id={@id} color="natural" variant="bordered" size="extra_small">expired</.badge>
      <% :revoked -> %>
        <.badge id={@id} color="danger" variant="bordered" size="extra_small">revoked</.badge>
    <% end %>
    """
  end

  defp short_duration(minutes) when minutes < 60, do: "#{minutes} min"
  defp short_duration(minutes), do: "#{div(minutes, 60)} h"

  defp event_color("blocked"), do: "danger"
  defp event_color("would_block"), do: "warning"
  defp event_color("state_changed"), do: "info"
  defp event_color("policy_applied"), do: "success"
  defp event_color("policy_result"), do: "success"
  defp event_color("command_rejected"), do: "danger"
  defp event_color(_), do: "natural"
end
