defmodule Cloud.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        CloudWeb.Telemetry,
        Cloud.Repo,
        {DNSCluster, query: Application.get_env(:cloud, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Cloud.PubSub},
        CloudWeb.GatewayPresence,
        # counters for public pages, such as token lookups on the msp request page
        CloudWeb.RateLimit,
        # background jobs, including the advisory feed polls scheduled by ash_oban
        {Oban,
         AshOban.config(
           Application.fetch_env!(:cloud, :ash_domains),
           Application.fetch_env!(:cloud, Oban)
         )}
      ] ++
        notification_children() ++
        [
          # Start to serve requests, typically the last entry
          CloudWeb.Endpoint,
          # the mutual tls endpoint gateways dial, separate from the browser endpoint
          CloudWeb.GatewayEndpoint,
          {AshAuthentication.Supervisor, [otp_app: :cloud]}
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cloud.Supervisor]
    warn_without_gateway_listener()
    Supervisor.start_link(children, opts)
  end

  # the dev sms adapter keeps its messages for /dev/sms; the dispatcher turns tenant
  # notification events into delivery jobs (tests start their own)
  defp notification_children do
    sms =
      if Cloud.Notifications.SMS.adapter() == Cloud.Notifications.SMS.Dev,
        do: [Cloud.Notifications.SMS.Dev],
        else: []

    dispatcher =
      if Application.get_env(:cloud, Cloud.Notifications.Dispatcher, [])[:start?],
        do: [Cloud.Notifications.Dispatcher],
        else: []

    sms ++ dispatcher
  end

  defp warn_without_gateway_listener do
    config = Application.get_env(:cloud, CloudWeb.GatewayEndpoint, [])

    # `mix phx.server` serves endpoints, but dev without certificates has no listener
    if Application.get_env(:phoenix, :serve_endpoints, false) and config[:https] == nil do
      Logger.warning("gateway endpoint not listening: no certificates, run `mix cloud.dev.pki`")
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CloudWeb.Endpoint.config_change(changed, removed)
    CloudWeb.GatewayEndpoint.config_change(changed, removed)
    :ok
  end
end
