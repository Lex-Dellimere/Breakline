defmodule CloudWeb.SitesLive.Components do
  @moduledoc """
  Small function components shared by the sites pages, built from mishka
  badges.
  """

  use CloudWeb, :html

  alias CloudWeb.SitesLive.Presenter

  @doc "Open, locked or unknown, from the last heartbeat's status."
  attr :status, :map, default: nil
  attr :id, :string, default: nil

  def state_badge(assigns) do
    assigns = assign(assigns, :state, Presenter.state(assigns.status))

    ~H"""
    <%= case @state do %>
      <% "open" -> %>
        <.badge id={@id} color="success" variant="bordered" size="small" icon="hero-lock-open">
          Open
        </.badge>
      <% "locked" -> %>
        <.badge id={@id} color="danger" variant="bordered" size="small" icon="hero-lock-closed">
          Locked
        </.badge>
      <% _ -> %>
        <.badge
          id={@id}
          color="natural"
          variant="bordered"
          size="small"
          icon="hero-question-mark-circle"
        >
          Unknown
        </.badge>
    <% end %>
    """
  end

  @doc "Whether the gateway is joined right now."
  attr :connected, :boolean, required: true
  attr :id, :string, default: nil

  def connected_badge(assigns) do
    ~H"""
    <%= if @connected do %>
      <.badge id={@id} color="success" variant="default" size="small" indicator pinging>
        Connected
      </.badge>
    <% else %>
      <.badge id={@id} color="natural" variant="default" size="small" indicator>
        Offline
      </.badge>
    <% end %>
    """
  end

  @doc "Published vs applied policy version."
  attr :published, :integer, required: true
  attr :applied, :integer, default: nil

  def versions(assigns) do
    ~H"""
    <span class="tabular-nums">
      v{@published}
      <%= cond do %>
        <% @applied == @published -> %>
          <span class="text-emerald-600 dark:text-emerald-400">applied</span>
        <% is_nil(@applied) -> %>
          <span class="text-zinc-500">· not applied yet</span>
        <% true -> %>
          <span class="text-amber-600 dark:text-amber-400">· gateway on v{@applied}</span>
      <% end %>
    </span>
    """
  end
end
