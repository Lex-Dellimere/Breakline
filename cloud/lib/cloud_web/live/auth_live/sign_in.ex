defmodule CloudWeb.AuthLive.SignIn do
  @moduledoc """
  password sign in, mounted through `sign_in_route live_view: ...`.

  follows ash_authentication_phoenix's password sign in form: the strategy's
  sign in action is run through an ash_phoenix form, and on success a short
  lived sign in token is posted to the strategy's `sign_in_with_token` route
  through a hidden form (`phx-trigger-action`), so the controller can set the
  session.
  """
  use CloudWeb, :live_view

  alias AshPhoenix.Form
  alias CloudWeb.AuthLive.Helpers

  @impl true
  def mount(_params, _session, socket) do
    strategy = Helpers.password_strategy()

    {:ok,
     socket
     |> assign(
       page_title: "Sign in",
       strategy: strategy,
       trigger_action: false,
       sign_in_token: nil,
       remember_me: nil,
       error: nil
     )
     |> assign(form: blank_form(strategy))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      current_user={@current_user}
      title="Sign in"
      subtitle="Sign in to the Breakline control plane."
    >
      <.alert :if={@error} kind={:danger} variant="bordered" class="mb-4" icon={nil}>
        {@error}
      </.alert>

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
          autocomplete="email"
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

      <.form
        :if={@strategy.sign_in_tokens_enabled?}
        for={%{}}
        id={@form.id <> "-with-token"}
        action={Helpers.auth_path(@strategy, :sign_in_with_token)}
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
          {:noreply,
           assign(socket,
             sign_in_token: user.__metadata__.token,
             remember_me: params["remember_me"]
           )}

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
