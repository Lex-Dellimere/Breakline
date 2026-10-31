defmodule CloudWeb.AccountLive.Security do
  @moduledoc """
  The signed-in user's second factors: passkeys and TOTP.

  - Passkeys: the list (name, created, last used), adding one (our own
    registration ceremony, `Cloud.Accounts.Passkeys`) and removing one. Adding
    a second or later passkey, and removing any, first needs a step-up from
    an existing passkey (`CloudWeb.StepUp`). An admin or approver cannot
    remove their last passkey.
  - TOTP: set up with an authenticator app (the `otpauth://` uri is shown as
    text to paste or type: there is no QR code library in the project) and
    confirmed with a code, or turned off with a current code. TOTP is a
    second sign-in factor only, it never approves.
  """

  use CloudWeb, :live_view

  alias Cloud.Accounts.{Passkeys, Totp}
  alias CloudWeb.StepUp

  on_mount {CloudWeb.LiveUserAuth, :live_user_required}

  @register_ref "register"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Security")
     |> assign(:approver?, approver?(user))
     |> assign(:step_up, nil)
     |> assign(:registration, nil)
     |> assign(:totp_setup, nil)
     |> assign(:passkey_form, to_form(%{"label" => ""}, as: :passkey))
     |> assign(:totp_form, to_form(%{"code" => ""}, as: :totp))
     |> load()}
  end

  # passkeys

  @impl true
  def handle_event("add_passkey", %{"passkey" => %{"label" => label}}, socket) do
    user = socket.assigns.current_user

    if socket.assigns.passkey_count > 0 do
      {:noreply,
       StepUp.start(
         socket,
         :register_passkey,
         user.id,
         %{user_id: user.id},
         [],
         {:register, label}
       )}
    else
      {:noreply, begin_registration(socket, label, nil)}
    end
  end

  def handle_event("remove_passkey", %{"id" => id}, socket) do
    cond do
      socket.assigns.passkey_count <= 1 and socket.assigns.approver? ->
        {:noreply,
         put_flash(socket, :error, "As an admin or approver you must keep at least one passkey")}

      true ->
        {:noreply,
         StepUp.start(
           socket,
           :remove_passkey,
           id,
           %{id: id},
           [exclude_passkey_ids: [id]],
           {:remove, id}
         )}
    end
  end

  # the passkey ceremony hook

  def handle_event("passkey_attestation", %{"ref" => @register_ref} = params, socket) do
    case socket.assigns.registration do
      %{challenge: challenge, label: label, step_up_id: step_up_id} ->
        socket = assign(socket, :registration, nil)

        case Passkeys.register(socket.assigns.current_user, challenge, params,
               label: label,
               step_up_id: step_up_id
             ) do
          {:ok, passkey} ->
            {:noreply,
             socket
             |> put_flash(:info, "Passkey \"#{passkey.label}\" added")
             |> assign(:passkey_form, to_form(%{"label" => ""}, as: :passkey))
             |> load()}

          {:error, {:step_up, reason}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Passkey not added: " <> Cloud.Accounts.StepUps.message(reason)
             )}

          {:error, _error} ->
            {:noreply, put_flash(socket, :error, "The passkey could not be verified, try again")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "There is no passkey registration waiting")}
    end
  end

  def handle_event("passkey_assertion", params, socket) do
    case StepUp.verify(socket, params) do
      {:ok, {:register, label}, step_up_id, socket} ->
        {:noreply, begin_registration(socket, label, step_up_id)}

      {:ok, {:remove, id}, step_up_id, socket} ->
        remove(socket, id, step_up_id)

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("passkey_error", %{"ref" => @register_ref} = params, socket) do
    {:noreply,
     socket
     |> assign(:registration, nil)
     |> put_flash(:error, CloudWeb.PasskeyCeremony.error_message(params))}
  end

  def handle_event("passkey_error", params, socket) do
    {:noreply, StepUp.cancel(socket, params)}
  end

  # totp

  def handle_event("totp_begin", _params, socket) do
    case Totp.begin_setup(socket.assigns.current_user) do
      {:ok, setup} ->
        {:noreply,
         assign(socket, totp_setup: setup, totp_form: to_form(%{"code" => ""}, as: :totp))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "TOTP setup could not start")}
    end
  end

  def handle_event("totp_cancel", _params, socket) do
    {:noreply, assign(socket, :totp_setup, nil)}
  end

  def handle_event("totp_confirm", %{"totp" => %{"code" => code}}, socket) do
    %{setup_token: token} = socket.assigns.totp_setup

    case Totp.confirm_setup(socket.assigns.current_user, token, code) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(:totp_setup, nil)
         |> put_flash(:info, "TOTP is on: sign in will ask for a code")
         |> load()}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "That code did not match, try the current one")}
    end
  end

  def handle_event("totp_disable", %{"totp" => %{"code" => code}}, socket) do
    case Totp.disable(socket.assigns.current_user, code) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(:totp_form, to_form(%{"code" => ""}, as: :totp))
         |> put_flash(:info, "TOTP is off")
         |> load()}

      {:error, :too_many_attempts} ->
        {:noreply, put_flash(socket, :error, "Too many wrong codes, wait a few minutes")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "That code did not match")}
    end
  end

  defp begin_registration(socket, label, step_up_id) do
    {challenge, options} = Passkeys.registration_options(socket.assigns.current_user)

    socket
    |> assign(:registration, %{challenge: challenge, label: label, step_up_id: step_up_id})
    |> push_event("passkey:create", Map.put(options, :ref, @register_ref))
  end

  defp remove(socket, id, step_up_id) do
    case Passkeys.remove(socket.assigns.current_user, id, step_up_id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Passkey removed") |> load()}

      {:error, error} ->
        message = StepUp.action_error(error) || removal_error(error)
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp removal_error(error) do
    if Exception.message(error) =~ "at least one passkey",
      do: "As an admin or approver you must keep at least one passkey",
      else: "The passkey could not be removed"
  end

  defp load(socket) do
    user = socket.assigns.current_user
    passkeys = Passkeys.list(user)

    socket
    |> assign(:passkey_count, length(passkeys))
    |> assign(:totp_enabled?, Totp.enabled?(user))
    |> stream(:passkeys, passkeys, reset: true)
  end

  defp approver?(user) do
    Cloud.Accounts.list_memberships!(authorize?: false, query: [filter: [user_id: user.id]])
    |> Enum.any?(&(&1.role in [:admin, :approver]))
  end

  defp when_utc(nil), do: "never"
  defp when_utc(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div>
        <h1 class="text-2xl font-semibold tracking-tight">Security</h1>
        <p class="text-sm text-zinc-500">
          Passkeys sign you in and approve access. TOTP adds a code to password sign in.
        </p>
      </div>

      <.card id="passkeys-card" variant="bordered" color="natural" rounded="large" padding="large">
        <.card_title title="Passkeys" size="small" font_weight="font-semibold" />
        <.card_content>
          <p class="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
            Opening a site, approving a window and lifting a lock each ask for one of these.
            <%= if @approver? do %>
              As an admin or approver you need at least one.
            <% end %>
          </p>

          <p :if={@passkey_count == 0} id="no-passkeys" class="text-sm text-zinc-500">
            No passkeys yet.
          </p>

          <ul id="passkeys" phx-update="stream" class="divide-y divide-zinc-100 dark:divide-zinc-800">
            <li
              :for={{dom_id, passkey} <- @streams.passkeys}
              id={dom_id}
              class="flex flex-wrap items-center justify-between gap-3 py-3"
            >
              <div class="min-w-0">
                <p class="flex items-center gap-2 font-medium">
                  <.icon name="hero-key" class="size-4 text-zinc-500" />
                  {passkey.label}
                </p>
                <p class="text-xs text-zinc-500">
                  Added {when_utc(passkey.inserted_at)} · last used {when_utc(passkey.last_used_at)}
                </p>
              </div>
              <.button
                id={"remove-#{passkey.id}"}
                phx-click="remove_passkey"
                phx-value-id={passkey.id}
                disabled={@step_up != nil}
                color="danger"
                variant="bordered"
                size="small"
                icon="hero-trash"
              >
                Remove
              </.button>
            </li>
          </ul>

          <.form_wrapper
            for={@passkey_form}
            id="add-passkey-form"
            phx-submit="add_passkey"
            space="small"
            class="mt-4"
          >
            <.text_field
              field={@passkey_form[:label]}
              label="Name for the new passkey"
              placeholder="e.g. work laptop"
              autocomplete="off"
            />
            <:actions>
              <.button
                id="add-passkey"
                type="submit"
                disabled={@step_up != nil or @registration != nil}
                color="primary"
                variant="default"
                size="small"
                icon="hero-plus"
              >
                Add passkey
              </.button>
            </:actions>
          </.form_wrapper>

          <p
            :if={@step_up != nil or @registration != nil}
            id="passkey-waiting"
            class="mt-3 text-sm text-zinc-600 dark:text-zinc-400"
          >
            <.icon name="hero-finger-print" class="size-4 align-text-bottom" />
            Follow your browser's passkey prompt.
          </p>
          <CloudWeb.PasskeyCeremony.hook id="passkey-ceremony" />
        </.card_content>
      </.card>

      <.card id="totp-card" variant="bordered" color="natural" rounded="large" padding="large">
        <.card_title title="Authenticator app (TOTP)" size="small" font_weight="font-semibold" />
        <.card_content>
          <%= cond do %>
            <% @totp_enabled? -> %>
              <p id="totp-on" class="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
                <.badge color="success" variant="bordered" size="small">On</.badge>
                Password sign in asks for a code from your app.
              </p>
              <.form_wrapper
                for={@totp_form}
                id="totp-disable-form"
                phx-submit="totp_disable"
                space="small"
              >
                <.text_field
                  field={@totp_form[:code]}
                  label="Current code, to turn TOTP off"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                />
                <:actions>
                  <.button type="submit" color="danger" variant="bordered" size="small">
                    Turn off
                  </.button>
                </:actions>
              </.form_wrapper>
            <% @totp_setup -> %>
              <div id="totp-setup" class="space-y-3 text-sm">
                <p class="text-zinc-600 dark:text-zinc-400">
                  Add this account to your authenticator app, then enter the code it shows.
                  Paste the link into an app that accepts one, or type the key by hand.
                </p>
                <div>
                  <p class="text-xs text-zinc-500">Setup link</p>
                  <code
                    id="totp-uri"
                    class="block break-all rounded bg-zinc-100 p-2 text-xs dark:bg-zinc-900"
                  >
                    {@totp_setup.uri}
                  </code>
                </div>
                <div>
                  <p class="text-xs text-zinc-500">Key</p>
                  <code
                    id="totp-secret"
                    class="block break-all rounded bg-zinc-100 p-2 font-mono text-sm tracking-wider dark:bg-zinc-900"
                  >
                    {@totp_setup.secret}
                  </code>
                </div>
                <.form_wrapper
                  for={@totp_form}
                  id="totp-confirm-form"
                  phx-submit="totp_confirm"
                  space="small"
                >
                  <.text_field
                    field={@totp_form[:code]}
                    label="Code from the app"
                    inputmode="numeric"
                    autocomplete="one-time-code"
                    required
                  />
                  <:actions>
                    <div class="flex gap-2">
                      <.button type="submit" color="primary" variant="default" size="small">
                        Turn on
                      </.button>
                      <.button
                        type="button"
                        phx-click="totp_cancel"
                        color="natural"
                        variant="bordered"
                        size="small"
                      >
                        Cancel
                      </.button>
                    </div>
                  </:actions>
                </.form_wrapper>
              </div>
            <% true -> %>
              <p id="totp-off" class="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
                Off. Turn it on to need a code from your app after your password.
              </p>
              <.button
                id="totp-begin"
                phx-click="totp_begin"
                color="primary"
                variant="bordered"
                size="small"
                icon="hero-device-phone-mobile"
              >
                Set up TOTP
              </.button>
          <% end %>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end
end
