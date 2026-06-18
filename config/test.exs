import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cinder, Cinder.Repo,
  database: Path.expand("../cinder_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cinder, CinderWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Gp5+FdjhnJocqtKsh/zVtI5jn/hrQe1+jt+t9dSNNBgM99QPkfZOu7jz6ttEit3l",
  server: false

# In test we don't send emails
config :cinder, Cinder.Mailer, adapter: Swoosh.Adapters.Test

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

# External services are mocked in tests (Mox defs live in test/test_helper.exs).
config :cinder,
  tmdb: Cinder.Catalog.TMDBMock,
  indexer: Cinder.Acquisition.IndexerMock,
  download_client: Cinder.Download.ClientMock,
  media_server: Cinder.Library.MediaServerMock

# The real TMDB client's own test routes Req through a Req.Test stub (no network).
config :cinder, Cinder.Catalog.TMDB.HTTP, req_options: [plug: {Req.Test, Cinder.TMDBStub}]

config :cinder, Cinder.Acquisition.Indexer.Prowlarr,
  req_options: [plug: {Req.Test, Cinder.ProwlarrStub}, retry: false],
  api_key: "test-key"

# The app-level poller must not run during the suite (it would race Mox/Sandbox).
# Poller tests start their own supervised instance.
config :cinder, start_poller: false
