# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cinder,
  ecto_repos: [Cinder.Repo],
  generators: [timestamp_type: :utc_datetime]

# External services resolve through behaviours; the concrete impl is config-selected.
# Tests override these with Mox mocks (see config/test.exs).
config :cinder, tmdb: Cinder.Catalog.TMDB.HTTP
config :cinder, indexer: Cinder.Acquisition.Indexer.Prowlarr
config :cinder, download_client: Cinder.Download.Client.QBittorrent
config :cinder, filesystem: Cinder.Library.Filesystem.Disk
config :cinder, Cinder.Download.Poller, interval: 5_000

# Configure the endpoint
config :cinder, CinderWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CinderWeb.ErrorHTML, json: CinderWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cinder.PubSub,
  live_view: [signing_salt: "w5SpjsQ6"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :cinder, Cinder.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cinder: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  cinder: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
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
