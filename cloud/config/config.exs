# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config
config :phoenix, filter_parameters: ["password", "token"]

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  default_string_length_count: :codepoints,
  infer_generic_action_reactors?: false,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:admin, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :cloud,
  ecto_repos: [Cloud.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    Cloud.Accounts,
    Cloud.Sites,
    Cloud.Gateways,
    Cloud.Advisories,
    Cloud.Audit,
    Cloud.Notifications
  ]

# background jobs (oban, without oban pro). ash_oban adds the cron entries of the
# resources' scheduled actions to the crontab at startup, see Cloud.Advisories.Feed.
# the advisories queue runs one job at a time so two polls of a feed never race
config :ash_oban, pro?: false

config :cloud, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10, advisories: 1, notifications: 5],
  lifeline: [rescue_after: {2, :hours}],
  pruner: [max_age: {7, :day}],
  repo: Cloud.Repo,
  cron: [crontab: []]

# signs gateway commands. the file signer is for dev and pilots; production replaces it
# with a kms or hsm backed Cloud.Signer implementation
config :cloud, :signer, Cloud.Signer.File

config :cloud, Cloud.Signer.File, path: Path.expand("../priv/keys/signer_ed25519.json", __DIR__)

# passkeys (webauthn). rp_id is the bare host the credentials are bound to; the origin
# defaults to the endpoint url (http://localhost:4010 in dev, a secure context for
# webauthn because the host is localhost). runtime.exs reads both from the environment
# in prod
config :cloud, :webauthn, rp_id: "localhost", rp_name: "Breakline"

# notifications (Cloud.Notifications). sms goes to the dev adapter until a provider is
# chosen; the dispatcher subscribes to every tenant's notifications topic
config :cloud, Cloud.Notifications.SMS, adapter: Cloud.Notifications.SMS.Dev
config :cloud, Cloud.Notifications.Dispatcher, start?: true
config :cloud, :notifications_from, {"Breakline", "noreply@example.com"}

# Configure the endpoint
config :cloud, CloudWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CloudWeb.ErrorHTML, json: CloudWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cloud.PubSub,
  live_view: [signing_salt: "WMcoXO7w"]

# the endpoint gateways dial: https with mutual tls only, see CloudWeb.GatewayEndpoint.
# the listener (port, certificates) is set per environment in runtime.exs. gateways are
# not browsers and authenticate with their client certificate, so origins are not checked
config :cloud, CloudWeb.GatewayEndpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Cloud.PubSub,
  check_origin: false,
  render_errors: [formats: [json: CloudWeb.ErrorJSON], layout: false]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :cloud, Cloud.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cloud: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  cloud: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# tz ships with core (:breakline); use it for all timezone-aware datetime work
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
