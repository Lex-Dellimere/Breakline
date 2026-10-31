defmodule CloudWeb.AuthLive.SignIn do
  @moduledoc """
  Sign in, mounted through `sign_in_route live_view: ...`.

  Password: follows ash_authentication_phoenix's password sign in form. The
  strategy's sign in action runs through an ash_phoenix form, and on success
  a short lived sign in token is posted to the strategy's
  `sign_in_with_token` route through a hidden form (`phx-trigger-action`),
  so the controller can set the session.

  TOTP: when the user has TOTP on, the password step does not release a
  token. The page asks for a code instead (`Cloud.Accounts.Totp.check_code/2`,
  rate limited) and only then mints a fresh sign in token and posts it. The
  code step must be finished within five minutes of the password step.
  `CloudWeb.AuthController` refuses the strategy's plain password route, so
  this page is the only way in with a password.

  Passkey: "Sign in with a passkey" asks the `CloudWeb.PasskeyCeremony` hook
  for a discoverable credential, verifies it with the webauthn strategy
  (challenge kept in this process) and posts the resulting token to the
  webauthn strategy's `sign_in_with_token` route. A passkey needs no TOTP
  code.
  """
  use CloudWeb, :live_view

  alias AshAuthentication.{Info, Jwt}
  alias AshAuthentication.Strategy.WebAuthn
  alias AshPhoenix.Form
  alias Cloud.Accounts.{Totp, User}
  alias CloudWeb.AuthLive.Helpers

  @totp_step_seconds 300
  @passkey_ref "sign-in"

  @impl true
  def mount(_params, _session, socket) do
    strategy = Helpers.password_strategy()

    {:ok,
     socket
     |> assign(
       page_title: "Sign in",
       strategy: strategy,
       webauthn: Info.strategy!(User, :webauthn),
       trigger_action: false,
       sign_in_token: nil,
       token_path: nil,
       remember_me: nil,
       error: nil,
       totp: nil,
       passkey_challenge: nil
     )
     |> assign(form: blank_form(strategy), totp_form: to_form(%{"code" => ""}, as: :totp))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      current_user={@current_user}
      title="Sign in"
      subtitle={
        if @totp,
          do: "Enter the code from your authenticator app.",
          else: "Sign in to the Breakline control plane."
      }
    >
      <.alert :if={@error} kind={:danger} variant="bordered" class="mb-4" icon={nil}>
        {@error}
      </.alert>

      <%= if @totp do %>
        <.form_wrapper for={@totp_form} id="totp-sign-in-form" phx-submit="totp" space="medium">
          <.text_field
            field={@totp_form[:code]}
            label="Code"
            inputmode="numeric"
            autocomplete="one-time-code"
            required
          />
          <:actions>
            <.button
              type="submit"
              variant="default"
              color="primary"
              full_width
              phx-disable-with="Checking..."
            >
              Continue
            </.button>
          </:actions>
        </.form_wrapper>
      <% else %>
        <.form_wrapper
          for={@form}
          id={@form.id}
          phx-change="validate"
          phx-submit="submit"
          phx-trigger-action={@trigger_action}
          action={Helpers.auth_path(@strategy, :sign_in)}
          method="post"
          space="medium"
        >
          <.email_field
            field={@form[@strategy.identity_field]}
            label="Email"
            autocomplete="username webauthn"
            required
            phx-debounce="blur"
          />
          <.password_field
            field={@form[@strategy.password_field]}
            label="Password"
            autocomplete="current-password"
            required
          />
          <.checkbox_field field={@form[:remember_me]} label="Remember me" />
          <:actions>
            <.button
              type="submit"
              variant="default"
              color="primary"
              full_width
              phx-disable-with="Signing in..."
            >
              Sign in
            </.button>
          </:actions>
        </.form_wrapper>

        <div class="mt-4">
          <.button
            id="passkey-sign-in"
            type="button"
            phx-click="passkey_sign_in"
            disabled={@passkey_challenge != nil}
            variant="bordered"
            color="natural"
            full_width
            icon="hero-finger-print"
          >
            Sign in with a passkey
          </.button>
        </div>
        <CloudWeb.PasskeyCeremony.hook id="passkey-ceremony" />
      <% end %>

      <.form
        :if={@strategy.sign_in_tokens_enabled?}
        for={%{}}
        id={@form.id <> "-with-token"}
        action={@token_path || Helpers.auth_path(@strategy, :sign_in_with_token)}
        method="post"
        phx-trigger-action={@sign_in_token != nil}
        class="hidden"
      >
        <input type="hidden" name="token" value={@sign_in_token} />
        <input :if={@remember_me} type="hidden" name="remember_me" value={@remember_me} />
      </.form>

      <:footer>
        <p>
          <.link navigate={~p"/reset"} class="text-blue-600 hover:underline dark:text-blue-400">
            Forgot your password?
          </.link>
        </p>
        <p class="text-zinc-600 dark:text-zinc-400">
          No account yet?
          <.link navigate={~p"/register"} class="text-blue-600 hover:underline dark:text-blue-400">
            Register
          </.link>
        </p>
      </:footer>
    </Layouts.auth>
    """
  end

  @impl true
  def handle_event("validate", params, socket) do
    form = Form.validate(socket.assigns.form, Helpers.subject_params(params), errors: false)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", params, socket) do
    %{strategy: strategy, form: form} = socket.assigns
    params = Helpers.subject_params(params)

    if strategy.sign_in_tokens_enabled? do
      case Form.submit(form, params: params, read_one?: true) do
        {:ok, user} ->
          if Totp.enabled?(user) do
            # the password was right, but no token leaves this process before the code
            deadline = DateTime.add(DateTime.utc_now(), @totp_step_seconds, :second)

            {:noreply,
             assign(socket,
               totp: %{user: user, deadline: deadline},
               remember_me: params["remember_me"],
               error: nil
             )}
          else
            {:noreply,
             assign(socket,
               sign_in_token: user.__metadata__.token,
               remember_me: params["remember_me"]
             )}
          end

        {:error, form} ->
          # clearing the password also hides its field error, so show it as an alert
          {:noreply,
           assign(socket,
             form: Form.clear_value(form, strategy.password_field),
             error: "Email or password was incorrect"
           )}
      end
    else
      form = Form.validate(form, params)
      {:noreply, assign(socket, form: form, trigger_action: form.source.valid?)}
    end
  end

  def handle_event("totp", %{"totp" => %{"code" => code}}, socket) do
    %{user: user, deadline: deadline} = socket.assigns.totp

    cond do
      DateTime.compare(DateTime.utc_now(), deadline) != :lt ->
        {:noreply, restart(socket, "That took too long, sign in again")}

      true ->
        case Totp.check_code(user, code) do
          :ok ->
            {:ok, token, _claims} =
              Jwt.token_for_user(user, %{"purpose" => "sign_in"},
                purpose: :sign_in,
                token_lifetime: {60, :seconds}
              )

            {:noreply, assign(socket, sign_in_token: token, error: nil)}

          {:error, :too_many_attempts} ->
            {:noreply, restart(socket, "Too many wrong codes, wait a few minutes")}

          {:error, :invalid_code} ->
            {:noreply,
             assign(socket,
               error: "That code was not right",
               totp_form: to_form(%{"code" => ""}, as: :totp)
             )}
        end
    end
  end

  def handle_event("passkey_sign_in", _params, socket) do
    strategy = socket.assigns.webauthn
    {:ok, challenge} = WebAuthn.Actions.authentication_challenge(strategy, [], nil)

    options = %{
      ref: @passkey_ref,
      challenge: Cloud.WebAuthn.encode64(challenge.bytes),
      rp_id: challenge.rp_id,
      timeout: strategy.timeout,
      user_verification: Cloud.WebAuthn.user_verification(),
      allow_credentials: []
    }

    {:noreply,
     socket
     |> assign(passkey_challenge: challenge, error: nil)
     |> push_event("passkey:get", options)}
  end

  def handle_event("passkey_assertion", %{"ref" => @passkey_ref} = params, socket) do
    case socket.assigns.passkey_challenge do
      nil ->
        {:noreply, socket}

      challenge ->
        socket = assign(socket, :passkey_challenge, nil)
        strategy = socket.assigns.webauthn

        case WebAuthn.Actions.sign_in(strategy, Map.take(params, assertion_keys()),
               challenge: challenge
             ) do
          {:ok, user} ->
            {:noreply,
             assign(socket,
               sign_in_token: user.__metadata__.token,
               token_path: Helpers.auth_path(strategy, :sign_in_with_token)
             )}

          {:error, _error} ->
            {:noreply, assign(socket, error: "That passkey could not sign you in")}
        end
    end
  end

  def handle_event("passkey_assertion", _params, socket), do: {:noreply, socket}

  def handle_event("passkey_error", params, socket) do
    {:noreply,
     assign(socket,
       passkey_challenge: nil,
       error: CloudWeb.PasskeyCeremony.error_message(params)
     )}
  end

  defp assertion_keys, do: ~w(raw_id authenticator_data signature client_data_json)

  defp restart(socket, error) do
    assign(socket,
      totp: nil,
      remember_me: nil,
      error: error,
      form: blank_form(socket.assigns.strategy)
    )
  end

  defp blank_form(strategy) do
    context =
      if strategy.sign_in_tokens_enabled? do
        %{token_type: :sign_in, private: %{skip_remember_me_token_generation: true}}
      else
        %{}
      end

    Helpers.form(strategy, strategy.sign_in_action_name, context)
  end
end
