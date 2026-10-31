defmodule CloudWeb.AuthLive.ResetRequest do
  @moduledoc """
  asks for a password reset email.

  runs the strategy's request password reset action. the response is the same
  whether or not the email exists, so the page can't be used to probe accounts.
  """
  use CloudWeb, :live_view

  alias AshPhoenix.Form
  alias CloudWeb.AuthLive.Helpers

  @impl true
  def mount(_params, _session, socket) do
    strategy = Helpers.password_strategy()

    {:ok,
     socket
     |> assign(page_title: "Reset password", strategy: strategy)
     |> assign(form: blank_form(strategy))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      current_user={@current_user}
      title="Reset your password"
      subtitle="We'll email you a link to choose a new password."
    >
      <.form_wrapper
        for={@form}
        id={@form.id}
        phx-change="validate"
        phx-submit="submit"
        space="medium"
      >
        <.email_field
          field={@form[@strategy.identity_field]}
          label="Email"
          autocomplete="email"
          required
        />
        <:actions>
          <.button
            type="submit"
            variant="default"
            color="primary"
            full_width
            phx-disable-with="Sending..."
          >
            Send reset link
          </.button>
        </:actions>
      </.form_wrapper>

      <:footer>
        <p>
          <.link navigate={~p"/sign-in"} class="text-blue-600 hover:underline dark:text-blue-400">
            Back to sign in
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
    params = Helpers.subject_params(params)

    # errors are deliberately not surfaced, same as the built-in form
    _ =
      socket.assigns.form
      |> Form.validate(params)
      |> Form.submit(params: params)

    {:noreply,
     socket
     |> assign(form: blank_form(socket.assigns.strategy))
     |> put_flash(
       :info,
       "If an account exists for that email, you will receive password reset instructions shortly."
     )}
  end

  defp blank_form(strategy) do
    Helpers.form(strategy, strategy.resettable.request_password_reset_action_name)
  end
end
