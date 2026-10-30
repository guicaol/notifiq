import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :notifiq, Notifiq.Repo,
  username: "postgres",
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: "localhost",
  database: "notifiq_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Cheap password hashing so the suite stays fast (Spec 010); real rounds in every other env.
config :pbkdf2_elixir, :rounds, 1

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :notifiq, NotifiqWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "osFOb7YtaxvMq/EfLPC7YIn4sCPUCQ6Fq/ZUIautm2BQL8IMd0PAl4Qw3qK7IEvx",
  server: false

# Jobs are inserted but never executed automatically; tests assert on them
# with Oban.Testing.
config :notifiq, Oban, testing: :manual, queues: false, plugins: false

# Fake adapters from test/support, reachable through /api/webhooks/:source_key.
config :notifiq, :integration_sources, %{
  "bling" => Notifiq.Integrations.Bling,
  "fake" => Notifiq.Test.FakeSource,
  "other_fake" => Notifiq.Test.OtherFakeSource
}

config :notifiq, :integration_credentials, %{
  "bling" => %{client_secret: "test-bling-secret"}
}

config :notifiq, :integration_callback_timeout, 500

config :notifiq, :channel_providers, %{
  "twilio" => Notifiq.Channels.Twilio,
  "fake_sms" => Notifiq.Test.FakeProvider,
  "fake_multi" => Notifiq.Test.OtherFakeProvider
}

config :notifiq, :channel_credentials, %{
  "fake_sms" => %{api_key: "test-api-key"},
  "twilio" => %{
    account_sid: "AC00000000000000000000000000000000",
    auth_token: "test-twilio-token",
    sms_from: "+15005550006"
  }
}

# Twilio talks to Req.Test stubs, never to the network (Spec 005, AC-12).
config :notifiq, Notifiq.Channels.Twilio, req_options: [plug: {Req.Test, Notifiq.Channels.Twilio}]
config :notifiq, :channel_callback_timeout, 300

# In test we don't send emails
config :notifiq, Notifiq.Mailer, adapter: Swoosh.Adapters.Test

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
