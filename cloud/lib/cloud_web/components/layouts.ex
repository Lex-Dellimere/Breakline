defmodule CloudWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.

  Everything here is built from mishka chelekom components
  (imported through `CloudWeb.Components.MishkaComponents`) and plain tailwind.
  """
  use CloudWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: header with navigation, main content and the flash group.

  ## Examples

      <Layouts.app flash={@flash} current_user={@current_user}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_user, :map, default: nil, doc: "the signed in user, if any"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-zinc-200 dark:border-zinc-800">
      <div class="mx-auto flex max-w-5xl items-center justify-between gap-4 px-4 py-3 sm:px-6 lg:px-8">
        <.link href={~p"/"} class="flex items-center gap-2 text-base font-semibold">
          <.icon name="hero-shield-check" class="size-6 text-blue-600 dark:text-blue-400" />
          <span>Breakline</span>
        </.link>

        <nav class="flex items-center gap-2">
          <%= if @current_user do %>
            <.button_link
              id="nav-sites"
              navigate={~p"/sites"}
              variant="transparent"
              color="natural"
              size="small"
            >
              Sites
            </.button_link>
            <.button_link
              id="nav-requests"
              navigate={~p"/requests"}
              variant="transparent"
              color="natural"
              size="small"
            >
              Requests
            </.button_link>
            <.button_link
              id="nav-advisories"
              navigate={~p"/advisories"}
              variant="transparent"
              color="natural"
              size="small"
            >
              Advisories
            </.button_link>
            <.button_link
              id="nav-notifications"
              navigate={~p"/settings/notifications"}
              variant="transparent"
              color="natural"
              size="small"
            >
              Notifications
            </.button_link>
            <.button_link
              id="nav-security"
              navigate={~p"/account/security"}
              variant="transparent"
              color="natural"
              size="small"
            >
              Security
            </.button_link>
            <span class="hidden text-sm text-zinc-600 sm:inline dark:text-zinc-400">
              {@current_user.email}
            </span>
            <.button_link href={~p"/sign-out"} variant="bordered" color="natural" size="small">
              Sign out
            </.button_link>
          <% else %>
            <.button_link href={~p"/sign-in"} variant="transparent" color="natural" size="small">
              Sign in
            </.button_link>
            <.button_link href={~p"/register"} variant="default" color="primary" size="small">
              Register
            </.button_link>
          <% end %>
          <.theme_toggle />
        </nav>
      </div>
    </header>

    <main class="px-4 py-12 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-5xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group (info, error and connection-lost flashes) using mishka's alert flashes.

  ## Examples

      <Layouts.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <CloudWeb.Components.Alert.flash_group id={@id} flash={@flash} />
    """
  end

  @doc """
  Renders a narrow, centered layout for the auth pages.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the signed in user, if any"
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true
  slot :footer

  def auth(assigns) do
    ~H"""
    <.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto w-full max-w-md">
        <.card variant="bordered" color="natural" rounded="large" padding="large" space="medium">
          <.card_title title={@title} size="large" font_weight="font-semibold" />
          <.card_content>
            <p :if={@subtitle} class="mb-4 text-sm text-zinc-600 dark:text-zinc-400">
              {@subtitle}
            </p>
            {render_slot(@inner_block)}
          </.card_content>
        </.card>
        <div :if={@footer != []} class="mt-4 space-y-1 text-center text-sm">
          {render_slot(@footer)}
        </div>
      </div>
    </.app>
    """
  end

  @doc """
  Provides a system / light / dark theme toggle.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-zinc-200 bg-zinc-100 dark:border-zinc-700 dark:bg-zinc-800">
      <div class="absolute left-0 h-full w-1/3 rounded-full border border-zinc-300 bg-white transition-[left] dark:border-zinc-600 dark:bg-zinc-600 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />

      <button
        :for={
          {theme, icon} <- [
            {"system", "hero-computer-desktop-micro"},
            {"light", "hero-sun-micro"},
            {"dark", "hero-moon-micro"}
          ]
        }
        type="button"
        class="relative flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={"#{theme} theme"}
      >
        <.icon name={icon} class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
