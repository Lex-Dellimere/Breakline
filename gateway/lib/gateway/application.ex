defmodule Gateway.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # one supervisor per concern lands here in phase 2 (firewall, dns, enforcer, uplink).
    # a dns crash must never take firewall state down with it.
    children = []

    Supervisor.start_link(children, strategy: :one_for_one, name: Gateway.Supervisor)
  end
end
