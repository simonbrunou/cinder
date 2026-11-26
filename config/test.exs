import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# The file name ends in MIX_TEST_PARTITION's value, so each partition of a bare `mix test`, which
# sets it, gets its own file: cinder_test1.db and so on, cinder_test.db when it is unset
# (Cinder.TestPartitions, #1473).
config :cinder, Cinder.Repo,
  database: Path.expand("../cinder_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  # pool_size: 1 serializes Sandbox checkouts onto one connection — SQLite is a single writer, and
  # busy_timeout can't rescue the deferred read-then-write snapshot conflicts the Sandbox wraps each
  # test in (see repo_concurrency_test.exs). NOTE: `default_transaction_mode: :immediate`
  # (config/config.exs) does NOT lift this — it governs explicit `Repo.transaction` calls, but the
  # Sandbox's own per-test outer transaction is deferred, so a bare read-then-write in a test still
  # snapshot-conflicts across connections. Measured: pool_size: 5 reintroduces ~26 "database busy"
  # failures/run. One connection makes the suite deterministic with no real speed cost (async tests
  # can't truly parallelize on one connection anyway).
  pool_size: 1,
  # With one connection, async tests queue for it, each holding it for its whole test.
  # DBConnection drops a checkout that has queued past 2 x queue_target, so 30_000 puts the drop
  # at 60 s, no sooner than ExUnit's default test timeout: a starved checkout fails as an ExUnit
  # timeout with its stacktrace in `setup_sandbox/1`, not on `queue_timeout`. At 5_000 a loaded CI
  # runner dropped checkouts after 10 to 15 s (#947: runs 2345, 2520, 2734). Pinned in
  # repo_concurrency_test.exs. An async test tagged a `timeout` above 2 x queue_target fails in
  # `Cinder.DataCase.setup_sandbox/1` before its checkout (#1021).
  queue_target: 30_000,
  queue_interval: 30_000,
  # A Repo call that passes no `timeout:` or `deadline:` of its own, made outside another call's
  # checkout, gets `timeout` from its checkout request to its checkin, a transaction included.
  # Once that time runs out, the sandbox's ownership proxy, which holds the test's connection,
  # disconnects it and stops, unless the call checks the connection in before the proxy handles
  # the expiry. Where the limit falls sets the symptom:
  # - Before a query of the held checkout, that query fails on the closed connection. At
  #   DBConnection's default 15_000, a test process stalled in the code server
  #   (`:code.ensure_loaded/1`) inside `Repo.insert` on a loaded host, and that insert raised
  #   `DBConnection.ConnectionError` "connection is closed because of an error, disconnect or
  #   timeout" (#1510).
  # - After the last query of a transaction body that returns without asking for a rollback (no
  #   `Repo.rollback/1`, no `{:error, _}` from a `Repo.transact` body), the transaction returns
  #   `{:error, :rollback}`.
  # - At a transaction's commit, or after a plain checkout's last query, the call can return
  #   normally. The test's next Repo call then fails with `DBConnection.OwnershipError`
  #   "cannot find ownership process" (#1518). While the proxy is still stopping, that call can
  #   exit instead, for example with a `DBConnection.ConnectionError` saying the client "queued
  #   and checked out the connection for longer than" the limit. In two #1518 sightings,
  #   `Catalog.create_profile/1` returned `{:ok, _}` and the next `Books.upsert_work/1` raised.
  # 60_000 is ExUnit's default test timeout: in a test with no `timeout` tag, run with no
  # `--timeout` and outside trace mode, which `--trace` turns on, and so does a `--slowest` or
  # `--slowest-modules` above 0, a longer stall fails as an ExUnit timeout with the stalled call's
  # stacktrace. Pinned in repo_concurrency_test.exs.
  timeout: 60_000,
  # Coverage overhead delays lock release past the default 5000ms timeout.
  busy_timeout: 10_000,
  # journal_mode/foreign_keys/default_transaction_mode are pinned in config/config.exs;
  # busy_timeout is overridden here for coverage.
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
  indexer_source: Cinder.Acquisition.IndexerMock,
  indexer_definitions_source: Cinder.Indexers.Definitions.SourceMock,
  plex_auth: Cinder.Accounts.PlexAuthMock,
  jellyfin_auth: Cinder.Accounts.JellyfinAuthMock,
  oidc_auth: Cinder.Accounts.OIDCMock,
  media_server: Cinder.Library.MediaServerMock,
  audiobook_server: Cinder.Library.AudiobookServerMock,
  filesystem: Cinder.Library.FilesystemMock,
  path_policy: Cinder.Test.PermissivePathPolicy,
  # Permissive free-disk prober: reports abundant space so the space guards never fire, keeping the
  # suite off the real filesystem. Disk-guard tests override :disk_stats_stub for their duration.
  disk_prober: Cinder.Test.StubDisk,
  # Disabled by default (overrides the prod Ffprobe impl) so the import suite never shells out;
  # the media_info tests opt in per-test via Application.put_env(MediaInfoMock).
  media_info: nil,
  # Same posture as :media_info, for the audiobook multi-track resolver's tag probe — disabled by
  # default; `Cinder.Library.AudiobookSourcesTest` opts in per test via AudioProbeMock.
  audio_probe: nil,
  notifier: Cinder.TestNotifier,
  subtitles_provider: Cinder.Subtitles.ProviderMock,
  subtitles_translator: Cinder.Subtitles.TranslatorMock,
  migration_sources: %{
    radarr: Cinder.Library.RadarrMigrationSourceMock,
    sonarr: Cinder.Library.SonarrMigrationSourceMock,
    readarr: Cinder.Library.ReadarrMigrationSourceMock
  },
  bootstrap_token: "test-bootstrap-token",
  secure_cookies: false,
  # Off by default: every ConnCase/LiveViewTest request shares one test-harness peer
  # address, so an always-on global IP bucket (Cinder.Accounts.IpRateLimiter) would let
  # unrelated tests exhaust each other's budget. Tests for the limiter itself flip this on
  # locally and restore it in on_exit. The {ip, email} :login_pair bucket ignores the flag
  # (its keys carry the email, so tests never collide).
  ip_rate_limiting: false,
  # Run notifier transports inline (not off-process) so capture_log / assert_email_sent
  # see the delivery synchronously. Prod/dev default to :async.
  notifier_dispatch: :sync

# Two client mocks so routing is testable by protocol: a torrent release must
# reach ClientMock and a usenet release must reach SabnzbdClientMock.
config :cinder,
  download_clients: %{
    torrent: Cinder.Download.ClientMock,
    usenet: Cinder.Download.SabnzbdClientMock
  }

# The real TMDB client's own test routes Req through a Req.Test stub (no network).
config :cinder, Cinder.Catalog.TMDB.HTTP, req_options: [plug: {Req.Test, Cinder.TMDBStub}]

# Books metadata is an ordered *pair* — the point of the pair is that the two disagree — so the
# test wiring needs two distinct mocks, not one.
config :cinder, Cinder.Books.Metadata,
  providers: [Cinder.Books.PrimaryMetadataMock, Cinder.Books.SecondaryMetadataMock]

config :cinder, Cinder.Books.Metadata.OpenLibrary,
  req_options: [plug: {Req.Test, Cinder.OpenLibraryStub}, retry: false]

config :cinder, Cinder.Books.Metadata.Hardcover,
  base_url: "http://bookinfo.test",
  req_options: [plug: {Req.Test, Cinder.HardcoverStub}, retry: false]

config :cinder, Cinder.Acquisition.IndexerSource.Prowlarr,
  base_url: "http://prowlarr:9696",
  req_options: [plug: {Req.Test, Cinder.ProwlarrStub}, retry: false],
  api_key: "test-key"

# The one retry after an HTTP 502, 503, 504 or 408 answer waits 10 ms here, not the 2 s the app
# runs with, which `Cinder.Acquisition.IndexerRetryTest` pins with this key unset.
config :cinder, Cinder.Acquisition.Indexer, retry_delay_ms: 10

# Native spaces the requests to one configured indexer 10 ms apart here, not the 2 s the app runs
# with, which `Cinder.Acquisition.IndexerSource.Native.LeaseTest` pins on an instance that reads
# no config.
config :cinder, Cinder.Acquisition.IndexerSource.Native.Lease, spacing_ms: 10

# The Newznab and Torznab adapters' requests (Torznab reads Newznab's key) go to a Req.Test stub.
config :cinder, Cinder.Acquisition.Indexer.Newznab,
  req_options: [plug: {Req.Test, Cinder.NewznabStub}]

# The Prowlarr/Indexers definitions adapter's own test routes Req through a Req.Test stub.
config :cinder, Cinder.Indexers.Definitions.Source.GitHub,
  req_options: [plug: {Req.Test, Cinder.DefinitionsSourceStub}, retry: false]

config :cinder, Cinder.Library.MigrationSource.Radarr,
  base_url: "http://radarr:7878",
  api_key: "test-key",
  req_options: [plug: {Req.Test, Cinder.RadarrStub}, retry: false]

config :cinder, Cinder.Library.MigrationSource.Sonarr,
  base_url: "http://sonarr:8989",
  api_key: "test-key",
  req_options: [plug: {Req.Test, Cinder.SonarrStub}, retry: false]

config :cinder, Cinder.Library.MigrationSource.Readarr,
  base_url: "http://bookshelf:8787",
  api_key: "test-key",
  req_options: [plug: {Req.Test, Cinder.ReadarrStub}, retry: false]

config :cinder, Cinder.Download.Client.QBittorrent,
  base_url: "http://localhost:8080",
  username: "test",
  password: "test",
  fetch_plug: {Req.Test, Cinder.QBittorrentStub},
  # RFC 2606 reserved TLD stands in for NXDOMAIN (dead-tracker tests); all else resolves public.
  url_resolver: fn host ->
    if String.ends_with?(host, ".invalid"),
      do: {:error, :nxdomain},
      else: {:ok, [{93, 184, 216, 34}]}
  end,
  req_options: [plug: {Req.Test, Cinder.QBittorrentStub}, retry: false]

config :cinder, Cinder.Download.Client.Sabnzbd,
  base_url: "http://localhost:8080",
  api_key: "test-key",
  fetch_plug: {Req.Test, Cinder.SabnzbdStub},
  url_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
  req_options: [plug: {Req.Test, Cinder.SabnzbdStub}, retry: false]

config :cinder, Cinder.Download.Client.Transmission,
  base_url: "http://localhost:9091/transmission/rpc",
  username: "test",
  password: "test",
  fetch_plug: {Req.Test, Cinder.TransmissionStub},
  url_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
  req_options: [plug: {Req.Test, Cinder.TransmissionStub}, retry: false]

config :cinder, Cinder.Download.Client.Nzbget,
  base_url: "http://localhost:6789/jsonrpc",
  username: "nzbget",
  password: "test",
  fetch_plug: {Req.Test, Cinder.NzbgetStub},
  url_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
  req_options: [plug: {Req.Test, Cinder.NzbgetStub}, retry: false]

# Discord notifier: a stub webhook so Cinder.Notifier.Discord can exercise the real HTTP
# path (POST embeds, GET health) in tests without hitting the network.
config :cinder, Cinder.Notifier.Discord,
  webhook_url: "https://discord.test/hook",
  req_options: [plug: {Req.Test, Cinder.DiscordStub}, retry: false]

# Generic webhook notifier: no URL, so the transport is a no-op for the rest of the suite (the
# dispatcher runs inline here). Its own tests set a URL per-test; the stub plug is configured up
# front so one that does can still never reach the network.
config :cinder, Cinder.Notifier.Webhook,
  req_options: [plug: {Req.Test, Cinder.WebhookStub}, retry: false]

# Blank by default (feature off): fetch_missing/2 makes zero provider/filesystem calls when
# wanted_languages/0 is [], so the existing async import suite's precise Mox expectations are
# unaffected. Tests exercising subtitles opt in per-test (subtitles_test.exs,
# library_subtitles_test.exs).
config :cinder, Cinder.Subtitles.Provider.OpenSubtitles,
  base_url: "https://api.opensubtitles.test/api/v1",
  api_key: "test-key",
  username: "user",
  password: "pass",
  languages: "",
  url_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
  req_options: [plug: {Req.Test, Cinder.OpenSubtitlesStub}, retry: false]

config :cinder, Cinder.Subtitles.Translator.LibreTranslate,
  base_url: "https://libretranslate.test",
  req_options: [plug: {Req.Test, Cinder.LibreTranslateStub}, retry: false]

config :cinder, Cinder.Library.MediaServer.Jellyfin,
  url: "http://localhost:8096",
  api_key: "test-key",
  req_options: [plug: {Req.Test, Cinder.JellyfinStub}, retry: false]

config :cinder, Cinder.Library.MediaServer.Plex,
  url: "http://localhost:32400",
  token: "test-key",
  movies_section: "1",
  tv_section: "2",
  req_options: [plug: {Req.Test, Cinder.PlexStub}, retry: false]

config :cinder, Cinder.Library.AudiobookServer.Audiobookshelf,
  url: "http://localhost:13378",
  api_key: "test-key",
  library_id: "lib_test",
  req_options: [plug: {Req.Test, Cinder.AudiobookshelfStub}, retry: false]

config :cinder, Cinder.Accounts.PlexAuth.HTTP,
  req_options: [plug: {Req.Test, Cinder.PlexTvStub}, retry: false]

config :cinder, Cinder.Accounts.JellyfinAuth.HTTP,
  req_options: [plug: {Req.Test, Cinder.JellyfinAuthStub}, retry: false]

# The app-level poller must not run during the suite (it would race Mox/Sandbox).
# Poller tests start their own supervised instance.
config :cinder, start_poller: false

# Skip the user count behind Cinder.Application's boot warning for an unprotected instance.
# `Cinder.Settings.start_link/1` reads the DB from inside Cinder.Supervisor, and the Sandbox boots
# in :auto mode, so that process owns the one connection until test_helper.exs switches to
# :manual. The count, run from the application master when no CINDER_BASIC_AUTH_* pair is set,
# queued until the pool dropped it at 2 x queue_target: a `mix test` boot waited 10 to 15 s for a
# warning it never printed, then 60 to 90 s once queue_target went to 30_000 (#1018).
config :cinder, warn_unprotected_at_boot: false

# Attach no `db watch:` handler and start no stall ticker (Cinder.RepoWatch): a transaction held
# over a second on a loaded runner would log a warning, and a non-async test fails on any warning
# its subtitle-fetcher drain sees (#1047). Watch tests attach their own handler.
config :cinder, start_repo_watch: false

# Neutralize the (now on-by-default) stall reaper for the suite: reap tests enable it explicitly
# with 0-window thresholds; every other poller test relies on it staying off.
config :cinder, Cinder.Download.StallReaper, enabled: false

# Enable /dev routes in tests so the authorization matrix can gate them.
config :cinder, dev_routes: true

# First-run redirect off by default in test; the routing test flips it on locally.
config :cinder, :enforce_setup, false

config :cinder, :movies_library_path, "/tmp/cinder-test-library"
config :cinder, :tv_library_path, "/tmp/cinder-test-tv-library"

# Widen Cinder.Library.Filesystem.Disk's production subprocess bound (`@subprocess_timeout_ms`) for
# the suite (#945): a loaded CI runner can take longer than that to start the rooted helper, which
# failed tests that never set out to test a timeout. A real hang still fails its call after 20 s,
# before ExUnit's 60 s per-test timeout. Tests of a Disk timeout (DiskBoundedTest) set their own
# bound and restore this one in on_exit.
config :cinder, :disk_subprocess_timeout_ms, 20_000

# Neutralize the shipped default size bands: suite fixtures use arbitrary/tiny/absent sizes,
# and the Settings band tests seed their own bootstrap snapshot explicitly.
config :cinder,
  movies_min_size: nil,
  movies_max_size: nil,
  tv_min_size: nil,
  tv_max_size: nil
