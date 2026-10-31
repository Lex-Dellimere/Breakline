import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cloud start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :cloud, CloudWeb.Endpoint, server: true
end

# dev listens on 4010 by default (4000 is taken on this machine), test keeps its own port
case {config_env(), System.get_env("PORT")} do
  {:test, _} -> :ok
  {:dev, nil} -> config :cloud, CloudWeb.Endpoint, http: [port: 4010]
  {_, nil} -> config :cloud, CloudWeb.Endpoint, http: [port: 4000]
  {_, port} -> config :cloud, CloudWeb.Endpoint, http: [port: String.to_integer(port)]
end

# the gateway endpoint's mutual tls listener. both sides must present a certificate: the
# server's own, and a gateway client certificate signed by the client ca
gateway_tls = fn port, certfile, keyfile, cacertfile, ip ->
  [
    ip: ip,
    port: port,
    certfile: certfile,
    keyfile: keyfile,
    thousand_island_options: [
      transport_options: [
        cacertfile: cacertfile,
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        versions: [:"tlsv1.3", :"tlsv1.2"],
        depth: 4
      ]
    ]
  ]
end

if config_env() == :dev do
  # certificates from `mix cloud.dev.pki`; without them the gateway endpoint does not listen
  keys = Path.expand("../priv/keys", __DIR__)

  pki =
    Enum.map(
      ~w(gateway_endpoint_cert.pem gateway_endpoint_key.pem dev_ca_cert.pem),
      &Path.join(keys, &1)
    )

  if Enum.all?(pki, &File.exists?/1) do
    [cert, key, ca] = pki
    port = String.to_integer(System.get_env("GATEWAY_PORT") || "4011")

    config :cloud, CloudWeb.GatewayEndpoint,
      https: gateway_tls.(port, cert, key, ca, {127, 0, 0, 1})
  else
    config :cloud, CloudWeb.GatewayEndpoint, server: false
  end

  # Reload browser tabs when matching files change.
  config :cloud, CloudWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/cloud_web/router\.ex$",
        ~r"lib/cloud_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # the pinned typst cli that renders audit pdfs (D38). without TYPST_PATH the
  # release's own priv/bin/typst is used, installed by mix cloud.typst.install
  # before the release is built
  if typst_path = System.get_env("TYPST_PATH") do
    config :cloud, :typst_path, typst_path
  end

  # passkeys are bound to the rp id for good: changing it later invalidates every
  # registered credential. the origin is the full scheme://host[:port] browsers report
  config :cloud, :webauthn,
    rp_id:
      System.get_env("WEBAUTHN_RP_ID") || raise("environment variable WEBAUTHN_RP_ID is missing"),
    rp_name: System.get_env("WEBAUTHN_RP_NAME", "Breakline"),
    origin:
      System.get_env("WEBAUTHN_ORIGIN") ||
        raise("environment variable WEBAUTHN_ORIGIN is missing")

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :cloud, Cloud.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # the root secret notification targets (webhook urls) are encrypted with, see
  # Cloud.Notifications.Vault. without it they are encrypted with SECRET_KEY_BASE
  if key = System.get_env("NOTIFICATIONS_KEY") do
    config :cloud, :notifications_key, key
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :cloud, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # the gateway endpoint: GATEWAY_TLS_CERT and GATEWAY_TLS_KEY are its server certificate,
  # GATEWAY_CLIENT_CA the ca that signs gateway client certificates
  fetch_env! = fn name ->
    System.get_env(name) || raise "environment variable #{name} is missing"
  end

  config :cloud, CloudWeb.GatewayEndpoint,
    server: System.get_env("PHX_SERVER") != nil,
    https:
      gateway_tls.(
        String.to_integer(System.get_env("GATEWAY_PORT") || "4011"),
        fetch_env!.("GATEWAY_TLS_CERT"),
        fetch_env!.("GATEWAY_TLS_KEY"),
        fetch_env!.("GATEWAY_CLIENT_CA"),
        {0, 0, 0, 0, 0, 0, 0, 0}
      )

  config :cloud, CloudWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :ash,
    keyset_signing_secret:
      :crypto.mac(
        :hmac,
        :sha256,
        System.get_env("SECRET_KEY_BASE") ||
          raise("environment variable SECRET_KEY_BASE is missing"),
        "ash keyset signing"
      )

  config :cloud,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :cloud, CloudWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :cloud, CloudWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :cloud, Cloud.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
