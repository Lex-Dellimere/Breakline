import Config

config :cloud, token_signing_secret: "8/Zz/W2sOMu8cB4c4G07qwVoMYdge9bV"
config :bcrypt_elixir, log_rounds: 1

# an in-memory key generated per test run, see test/support/signer_static.ex
config :cloud, :signer, Cloud.Signer.Static

config :ash,
  policies: [show_policy_breakdowns?: true],
  keyset_signing_secret: "f4+3P/mDK/Idz3edJRM4skrPQ38jTOwUoZJ6JY9usts",
  disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cloud, Cloud.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "cloud_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cloud, CloudWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vsNcDxV/6H0I+rQppo69GvPk2JIUWW2ts+brvg3W6U02HAE0xS6GPRXEpb9eyLjs",
  server: false

config :cloud, CloudWeb.GatewayEndpoint, server: false

# In test we don't send emails
config :cloud, Cloud.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# jobs are only inserted, never run, unless a test drains or performs them (Oban.Testing)
config :cloud, Oban, testing: :manual

# advisory feed requests go to Req.Test stubs, see test/support/advisory_feeds.ex
config :cloud, Cloud.Advisories.HTTP,
  req_options: [plug: {Req.Test, Cloud.Advisories.HTTP}, retry: false]

# the dev-only "poll feeds now" button, so its test can click it
config :cloud, advisories_poll_button?: true

# notification webhooks go to Req.Test stubs, and tests start their own dispatcher
config :cloud, Cloud.Notifications.Webhook,
  req_options: [plug: {Req.Test, Cloud.Notifications.Webhook}]

config :cloud, Cloud.Notifications.Dispatcher, start?: false

# the pinned typst cli for audit pdfs, installed by mix cloud.typst.install (D38)
config :cloud, :typst_path, Path.expand("../priv/bin/typst", __DIR__)
