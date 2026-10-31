defmodule CloudWeb.AuthLive.Reset do
  @moduledoc """
  sets a new password from an emailed reset token, mounted through
  `reset_route live_view: ...`.

  validates in the liveview, then posts to the strategy's reset route
  (`phx-trigger-action`) so the controller can sign the user in.
  """
  use CloudWeb, :live_view

  alias AshPhoenix.Form
  alias CloudWeb.AuthLive.Helpers

  @impl true
  def mount(_params, _session, socket) do
    strategy = Helpers.password_strategy()

    {:ok,
     socket
     |> assign(page_title: "Choose a new password", strategy: strategy, trigger_action: false)
     |> assign(form: Helpers.form(strategy, strategy.resettable.password_reset_action_name))}
  end

  @impl true
  def handle_params(%{"token" => token}, _uri, socket) do
    {:noreply, assign(socket, token: token)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_user={@current_user} title="Choose a new password">
      <.form_wrapper
        for={@form}
        id={@form.id}
        phx-change="validate"
        phx-submit="submit"
        phx-trigger-action={@trigger_action}
        action={Helpers.auth_path(@strategy, :reset)}
        method="post"
        space="medium"
      >
        <input type="hidden" name={@form[:reset_token].name} value={@token} />
        <.password_field
          field={@form[@strategy.password_field]}
          label="New password"
          autocomplete="new-password"
          required
          phx-debounce="blur"
        />
        <.password_field
          :if={@strategy.confirmation_required?}
          field={@form[@strategy.password_confirmation_field]}
          label="Confirm new password"
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
            phx-disable-with="Saving..."
          >
            Reset password
          </.button>
        </:actions>
      </.form_wrapper>
    </Layouts.auth>
    """
  end

  @impl true
  def handle_event("validate", params, socket) do
    form = Form.validate(socket.assigns.form, Helpers.subject_params(params))
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", params, socket) do
    form = Form.validate(socket.assigns.form, Helpers.subject_params(params))
    {:noreply, assign(socket, form: form, trigger_action: form.source.valid?)}
  end
end
