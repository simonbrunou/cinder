ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Cinder.Repo, :manual)

# Mox mocks for the external-service behaviours (real impls land per phase).
Mox.defmock(Cinder.Catalog.TMDBMock, for: Cinder.Catalog.TMDB)
Mox.defmock(Cinder.Acquisition.IndexerMock, for: Cinder.Acquisition.Indexer)
Mox.defmock(Cinder.Download.ClientMock, for: Cinder.Download.Client)
# Second client mock so routing tests can prove a usenet release reaches the
# usenet-mapped client (and a torrent release does not). Wired as the :usenet
# client in config/test.exs.
Mox.defmock(Cinder.Download.SabnzbdClientMock, for: Cinder.Download.Client)
Mox.defmock(Cinder.Library.MediaServerMock, for: Cinder.Library.MediaServer)
Mox.defmock(Cinder.Library.FilesystemMock, for: Cinder.Library.Filesystem)
