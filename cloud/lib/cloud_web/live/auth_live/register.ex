defmodule CloudWeb.AuthLive.Register do
  @moduledoc """
  password registration.

  follows ash_authentication_phoenix's password register form: the strategy's
  register action runs through an ash_phoenix form; with sign in tokens enabled
  the new user is signed in by redirecting to the strategy's
  `sign_in_with_token` route, otherwise the form posts to the register route.
  """
  use CloudWeb, :live_view

  alias AshPhoenix.Form
  alias CloudWeb.AuthLive.Helpers

  @impl true
  def mount(_params, _session, socket) do
    strategy = Helpers.password_strategy()

    {:ok,
     socket
     |> assign(page_title: "Register", strategy: strategy, trigger_action: false)
     |> assign(form: blank_form(strategy))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      current_user={@current_user}
      title="Create an account"
      subtitle="Register with your email address and a password."
    >
      <.form_wrapper
        for={@form}
        id={@form.id}
        phx-change="validate"
        phx-submit="submit"
        phx-trigger-action={@trigger_action}
        action={Helpers.auth_path(@strategy, :register)}
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
          autocomplete="new-password"
          required
          phx-debounce="blur"
        />
        <.password_field
          :if={@strategy.confirmation_required?}
          field={@form[@strategy.password_confirmation_field]}
          label="Confirm password"
          autocomplete="new-password"
          required
          phx-debounce="blur"
        />
        <:actions>
          <.button
            type="submit"
            variant="default"
            color="primary"
            full_width
            phx-disable-with="Creating account..."
          >
            Create account
          </.button>
        </:actions>
      </.form_wrapper>

      <:footer>
        <p class="text-zinc-600 dark:text-zinc-400">
          Already have an account?
          <.link navigate={~p"/sign-in"} class="text-blue-600 hover:underline dark:text-blue-400">
            Sign in
          </.link>
        </p>
      </:footer>
    </Layouts.auth>
    """
  end

  @impl true
  def handle_event("validate", params, socket) do
    form = Form.validate(socket.assigns.form, Helpers.subject_params(params))
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", params, socket) do
    %{strategy: strategy, form: form} = socket.assigns
    params = Helpers.subject_params(params)

    if strategy.sign_in_tokens_enabled? do
      case Form.submit(form, params: params, read_one?: true) do
        {:ok, user} ->
          path =
            Helpers.auth_path(strategy, :sign_in_with_token, token: user.__metadata__.token)

          {:noreply, redirect(socket, to: path)}

        # passwords are kept (not cleared like the built-in form does) so their
        # field errors stay visible
        {:error, form} ->
          {:noreply, assign(socket, form: form)}
      end
    else
      form = Form.validate(form, params)
      {:noreply, assign(socket, form: form, trigger_action: form.source.valid?)}
    end
  end

  defp blank_form(strategy) do
    context = if strategy.sign_in_tokens_enabled?, do: %{token_type: :sign_in}, else: %{}
    Helpers.form(strategy, strategy.register_action_name, context)
  end
end
