defmodule CloudWeb.AuthLive.Confirm do
  @moduledoc """
  confirms a new user's email address, mounted through
  `confirm_route live_view: ...`.

  the confirmation add-on requires interaction, so the emailed link lands here
  and the button posts the token to the strategy's confirm route.
  """
  use CloudWeb, :live_view

  alias CloudWeb.AuthLive.Helpers

  @impl true
  def mount(_params, _session, socket) do
    strategy = Helpers.confirm_strategy()

    {:ok,
     socket
     |> assign(page_title: "Confirm your email", strategy: strategy)
     |> assign(form: Helpers.form(strategy, strategy.confirm_action_name))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, token: params["token"] || params["confirm"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      current_user={@current_user}
      title="Confirm your email"
      subtitle="Confirm the email address for your Breakline account."
    >
      <.form_wrapper
        for={@form}
        id={@form.id}
        action={Helpers.auth_path(@strategy, :confirm)}
        method="post"
      >
        <input type="hidden" name={@form[:confirm].name} value={@token} />
        <:actions>
          <.button type="submit" variant="default" color="primary" full_width>
            Confirm email
          </.button>
        </:actions>
      </.form_wrapper>
    </Layouts.auth>
    """
  end
end
