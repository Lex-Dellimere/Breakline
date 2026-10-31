defmodule CloudWeb.AuthLive.SignOut do
  @moduledoc """
  sign out confirmation page, mounted through `sign_out_route live_view: ...`.

  the button sends a `DELETE` to the auth controller, so a plain link from
  another site can't sign anyone out.
  """
  use CloudWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       page_title: "Sign out",
       sign_out_path: session["sign_out_path"] || ~p"/sign-out"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      current_user={@current_user}
      title="Sign out"
      subtitle="Are you sure you want to sign out?"
    >
      <.form_wrapper for={%{}} id="sign-out-form" action={@sign_out_path} method="delete">
        <:actions>
          <.button type="submit" variant="default" color="primary" full_width>
            Sign out
          </.button>
        </:actions>
      </.form_wrapper>
    </Layouts.auth>
    """
  end
end
