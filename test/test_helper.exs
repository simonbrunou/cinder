ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Cinder.Repo, :manual)

# Mox mocks for the external-service behaviours (real impls land per phase).
Mox.defmock(Cinder.Catalog.TMDBMock, for: Cinder.Catalog.TMDB)
Mox.defmock(Cinder.Acquisition.IndexerMock, for: Cinder.Acquisition.Indexer)
Mox.defmock(Cinder.Download.ClientMock, for: Cinder.Download.Client)
Mox.defmock(Cinder.Library.MediaServerMock, for: Cinder.Library.MediaServer)
