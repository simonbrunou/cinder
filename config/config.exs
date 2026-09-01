# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :cinder,
  ecto_repos: [Cinder.Repo],
  bootstrap_token: nil,
  secure_cookies: false,
  household_timezone: "Etc/UTC"

# SQLite correctness, pinned in ONE place so every environment gets it — including a non-prod
# release that never reaches runtime.exs's prod-only branch. Env files add only `database`/
# `pool_size` (+ the test Sandbox pool), merging over this base.
#   - journal_mode: :wal + a raised busy_timeout → a web write racing the poller waits rather
#     than erroring "database busy".
#   - default_transaction_mode: :immediate → every Repo.transaction takes the write lock at BEGIN,
#     so busy_timeout governs it. A deferred BEGIN (the exqlite default) can still raise
#     SQLITE_BUSY_SNAPSHOT on a read-then-write txn, which busy_timeout cannot retry.
#   - foreign_keys: :on → the admin-delete cascades stay enforced.
#   - journal_size_limit: 64 MB → caps the on-disk `-wal` high-water mark. The exqlite adapter
#     already sets `wal_autocheckpoint = 1000` (~4 MB) on every connection, so checkpoints DO run;
#     but a PASSIVE autocheckpoint blocked by a long-lived reader lets `-wal` grow past that, and
#     even a normal checkpoint only resets the write cursor — it never SHRINKS the file. SQLite's
#     default limit is -1 (never truncate), so without this a briefly-bloated `-wal` stays at its
#     peak size forever on the same volume as `cinder.db`. Pinning the limit truncates it back down
#     at the next checkpoint. Autocheckpoint being on is why no scheduled `wal_checkpoint(TRUNCATE)`
#     is needed.
# Pinned (not left to ecto_sqlite3 defaults) so a dep-default change can't silently alter the
# contract the locked "SQLite stays" decision rests on.
config :cinder, Cinder.Repo,
  journal_mode: :wal,
  busy_timeout: 5_000,
  foreign_keys: :on,
  default_transaction_mode: :immediate,
  journal_size_limit: 64 * 1024 * 1024

# External services resolve through behaviours; the concrete impl is config-selected.
# Tests override these with Mox mocks (see config/test.exs).
config :cinder, tmdb: Cinder.Catalog.TMDB.HTTP
config :cinder, indexer: Cinder.Acquisition.Indexer.Prowlarr
config :cinder, plex_auth: Cinder.Accounts.PlexAuth.HTTP
config :cinder, jellyfin_auth: Cinder.Accounts.JellyfinAuth.HTTP

config :cinder,
  migration_sources: %{
    radarr: Cinder.Library.MigrationSource.Radarr,
    sonarr: Cinder.Library.MigrationSource.Sonarr
  }

config :cinder,
  download_clients: %{
    torrent: Cinder.Download.Client.QBittorrent,
    usenet: Cinder.Download.Client.Sabnzbd
  }

config :cinder, filesystem: Cinder.Library.Filesystem.Disk
# Free-disk prober behind the pre-grab / pre-import space guards; the test config points this at a
# permissive stub so the suite never probes the real disks.
config :cinder, disk_prober: Cinder.Disk

# `Cinder.Disk` validates and probes one path at a time inside a supervised POSIX `df -kP`
# subprocess deadline. If SIGKILL cannot reap a stuck filesystem call, its owner keeps the port and
# rejects further probes instead of accumulating orphan processes. This avoids `:disksup`'s
# process-wide scan: one hung network mount used to wedge every later dashboard probe.
config :cinder, disk_probe_timeout: 2_000

# Import-time audio-language verification (needs `ffprobe`; the Docker image ships it). Enabled by
# default; degrades to a no-op if ffprobe is absent. Set `media_info: nil` to disable.
config :cinder, media_info: Cinder.Library.MediaInfo.Ffprobe
# `ffprobe` binary name/path; editable at /settings (Cinder.Settings overlays this key).
config :cinder, ffprobe_bin: "ffprobe"

# Local, CPU-only subtitle alignment. The release image pins ffsubsync 0.5.1 and coreutils timeout;
# direct installs may point `ffsubsync_python` at a Python interpreter containing ffsubsync 0.5.1.
config :cinder,
  subtitle_sync_engine: Cinder.Subtitles.Sync.Ffsubsync,
  ffsubsync_python: nil,
  timeout_bin: "timeout"

# Default; setting PLEX_URL (see runtime.exs) switches this to Plex.
config :cinder, media_server: Cinder.Library.MediaServer.Jellyfin

config :cinder, Cinder.Books.Metadata,
  providers: [Cinder.Books.Metadata.OpenLibrary, Cinder.Books.Metadata.Hardcover]

config :cinder, notifier: Cinder.Notifier.Dispatcher
config :cinder, subtitles_provider: Cinder.Subtitles.Provider.OpenSubtitles
config :cinder, subtitles_translator: Cinder.Subtitles.Translator.LibreTranslate

config :cinder, :anime_preferences,
  embedded_subtitle_mode: :prefer,
  preferred_groups: [],
  blocked_groups: [],
  group_fallback_delay: 24 * 60 * 60

# Shipped release size bands, in bytes (decimal GB in /settings; the TV band applies per wanted
# episode covered: k*min <= size <= k*max). A fresh install starts bounded so a single wanted
# episode can't legally match a multi-hundred-GB batch archive (issue #108). Tunable at
# /settings, where a stored 0 means unbounded and blank reverts to these defaults.
config :cinder,
  movies_min_size: 300_000_000,
  movies_max_size: 15_000_000_000,
  tv_min_size: 50_000_000,
  tv_max_size: 4_000_000_000

# Conservative quota for newly self-registered users; editable at /settings.
config :cinder, default_request_quota: 10
config :cinder, oidc_auth: Cinder.Accounts.OIDC.Assent

# First-run wizard gate: redirect to /setup until setup_complete. Off in test so the
# existing LiveView suite (which never marks setup complete) isn't redirected.
config :cinder, :enforce_setup, true

# Stalled-download reaper (issue #147): the pollers reap a torrent stuck with no forward progress
# (dead swarm / metaDL with 0 seeders) — remove it (with data), blocklist the release recoverably,
# and re-search a different one. Torrent-only (usenet reports no speed, so it is never reaped).
# Timeouts in ms. Set `enabled: false` to turn it off. The suite neutralizes this in config/test.exs.
config :cinder, Cinder.Download.StallReaper,
  enabled: true,
  stall_timeout: :timer.hours(2),
  no_seeders_timeout: :timer.minutes(30)

# Re-queues parked titles so a request with no release yet keeps getting hunted.
config :cinder, Cinder.Catalog.Rehunter, enabled: true, rehunt_after: :timer.hours(24)

# Books sibling: returns a transiently-held book target to :monitored so a manual retry isn't the
# only way back. Can never trigger a download by itself (no `best_book_release/2` exists).
config :cinder, Cinder.Books.Rehunter, enabled: true, rehunt_after: :timer.hours(24)

# Reaps Cinder-submitted downloads nothing owns any more. Completed torrents seed indefinitely
# unless an operator saves an opt-in ratio and/or seed-time limit in Settings.
config :cinder, Cinder.Download.Cleaner, enabled: true

# Rejects a download whose file list marks it as a fake (a .lnk/.exe payload, not a movie).
config :cinder, Cinder.Download.ContentPolicy, enabled: true

# Re-searches library items for a better release. OFF by default: it replaces library files, so
# it is opt-in rather than something an upgrade starts doing to an existing library. This is the
# boot default only: the operator switch is "Library upgrades" in /settings, which overlays
# :enabled here at runtime (and reverts to this value when cleared).
config :cinder, Cinder.Catalog.UpgradeHunter, enabled: false

# Configure the endpoint
config :cinder, CinderWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CinderWeb.ErrorHTML, json: CinderWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cinder.PubSub

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

config :phoenix, :filter_parameters, ["password", "email", "token"]

# i18n: English + French. The active locale is resolved per request/socket by
# CinderWeb.Locale (authenticated user → session → Accept-Language → default). `en` is the source
# language (msgids), so the default-locale test suite keeps asserting English
# with no translation needed; French lives in priv/gettext/fr.
config :gettext, :default_locale, "en"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
