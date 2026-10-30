# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :notifiq,
  ecto_repos: [Notifiq.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :notifiq, NotifiqWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: NotifiqWeb.ErrorHTML, json: NotifiqWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Notifiq.PubSub,
  live_view: [signing_salt: "FqisH+2a"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Background jobs (Spec 002, Constitution principle 8). Webhook endpoints only
# validate and enqueue; everything heavier runs in Oban queues.
config :notifiq, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  repo: Notifiq.Repo,
  queues: [ingestion: 10]

# Source adapters reachable through POST /api/webhooks/:source_key (Spec 002, FR-11).
# Maps the URL `source_key` (string, case-sensitive) to a module implementing
# `Notifiq.Integrations.Source`. Register a new source by adding it here.
config :notifiq, :integration_sources, %{
  "bling" => Notifiq.Integrations.Bling
}

# Maximum time (ms) an adapter callback may take before the request is failed.
config :notifiq, :integration_callback_timeout, 5_000

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :notifiq, Notifiq.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  notifiq: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  notifiq: [
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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
