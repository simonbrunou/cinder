# A partition of a bare `mix test` halts once the run that started it exits or is killed (#1488).
Cinder.TestPartitions.halt_when_parent_exits()

# A run stopped by SIGTERM halts with status 143 instead of printing a Result line that counts
# only the tests that finished, and a run whose ExUnit lost a module's tests exits 1 (#1475).
{:ok, _} = Cinder.LostTests.halt_on_sigterm()
ExUnit.after_suite(&Cinder.LostTests.after_suite/1)

# A positive wait only costs time when the test is already failing, so the default is generous:
# on the 3-core Forgejo CI runner a message a test waits for can take over a second (#636).
# `Cinder.MutationFailures` writes each failure block to the file `scripts/mutation-check` names
# (#1532).
ExUnit.start(
  assert_receive_timeout: 5_000,
  formatters: [ExUnit.CLIFormatter, Cinder.LostTests, Cinder.MutationFailures]
)

Ecto.Adapters.SQL.Sandbox.mode(Cinder.Repo, :manual)

# Mox mocks for the external-service behaviours (real impls land per phase).
Mox.defmock(Cinder.Catalog.TMDBMock, for: Cinder.Catalog.TMDB)
Mox.defmock(Cinder.Acquisition.IndexerMock, for: Cinder.Acquisition.IndexerSource)
# The indexer `Cinder.IndexerStubs.anime_sweep_pick/4` stubs, so its answers never reach a test's
# own `IndexerMock` expectations.
Mox.defmock(Cinder.Acquisition.InHandIndexerMock, for: Cinder.Acquisition.IndexerSource)
# The source a test passes as a search's `indexer_source:` opt while the env names `IndexerMock`,
# so a search that reads the env instead of the opt reaches the other mock.
Mox.defmock(Cinder.Acquisition.PassedIndexerMock, for: Cinder.Acquisition.IndexerSource)
Mox.defmock(Cinder.Indexers.Definitions.SourceMock, for: Cinder.Indexers.Definitions.Source)
# The source `Cinder.Indexers.Definitions.SourceTest` points `:indexer_definitions_source` at, to
# show `Source.fetch/1` reads that key rather than naming `SourceMock`.
Mox.defmock(Cinder.Indexers.Definitions.OtherSourceMock, for: Cinder.Indexers.Definitions.Source)
Mox.defmock(Cinder.Download.ClientMock, for: Cinder.Download.Client)
# Second client mock so routing tests can prove a usenet release reaches the
# usenet-mapped client (and a torrent release does not). Wired as the :usenet
# client in config/test.exs.
Mox.defmock(Cinder.Download.SabnzbdClientMock, for: Cinder.Download.Client)
Mox.defmock(Cinder.Library.MediaServerMock, for: Cinder.Library.MediaServer)
Mox.defmock(Cinder.Library.AudiobookServerMock, for: Cinder.Library.AudiobookServer)
Mox.defmock(Cinder.Library.MigrationSourceMock, for: Cinder.Library.MigrationSource)
Mox.defmock(Cinder.Library.RadarrMigrationSourceMock, for: Cinder.Library.MigrationSource)
Mox.defmock(Cinder.Library.SonarrMigrationSourceMock, for: Cinder.Library.MigrationSource)
Mox.defmock(Cinder.Library.ReadarrMigrationSourceMock, for: Cinder.Library.MigrationSource)
Mox.defmock(Cinder.Accounts.PlexAuthMock, for: Cinder.Accounts.PlexAuth)
Mox.defmock(Cinder.Accounts.JellyfinAuthMock, for: Cinder.Accounts.JellyfinAuth)
Mox.defmock(Cinder.Accounts.OIDCMock, for: Cinder.Accounts.OIDC)
Mox.defmock(Cinder.Library.FilesystemMock, for: Cinder.Library.Filesystem)
# Import-time audio probe. Disabled in config/test.exs (`media_info: nil`, so the existing import
# suite never shells out); the media_info tests enable it per-test via Application.put_env.
Mox.defmock(Cinder.Library.MediaInfoMock, for: Cinder.Library.MediaInfo)
Mox.defmock(Cinder.Library.AudioProbeMock, for: Cinder.Library.AudioProbe)
Mox.defmock(Cinder.Books.PrimaryMetadataMock, for: Cinder.Books.Metadata)
Mox.defmock(Cinder.Books.SecondaryMetadataMock, for: Cinder.Books.Metadata)
Mox.defmock(Cinder.Subtitles.ProviderMock, for: Cinder.Subtitles.Provider)
Mox.defmock(Cinder.Subtitles.TranslatorMock, for: Cinder.Subtitles.Translator)
Mox.defmock(Cinder.Subtitles.Sync.EngineMock, for: Cinder.Subtitles.Sync.Engine)
