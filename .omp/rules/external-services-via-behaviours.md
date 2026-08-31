---
description: External services (TMDB, Prowlarr, torrent/Usenet clients, Jellyfin/Plex) are reachable only through behaviours resolved at runtime; tests never touch the network.
globs:
  - lib/cinder/catalog/**
  - lib/cinder/acquisition/**
  - lib/cinder/download/**
  - lib/cinder/library/**
  - test/**
---

Every external service sits behind a behaviour. Never call TMDB / Prowlarr / qBittorrent /
SABnzbd / Jellyfin / Plex directly from a context.

- `Cinder.Catalog.TMDB`
- `Cinder.Acquisition.Indexer`
- `Cinder.Download.Client`
- `Cinder.Library.MediaServer`

`{:req, "~> 0.5"}` is the HTTP client, and it belongs **inside an adapter** that implements
one of those behaviours — not in a context module.

**Resolve the implementation with `Application.fetch_env!/2`, never `compile_env!/2`.** The
Mox mock is defined at runtime, so compile-time resolution breaks
`mix compile --warnings-as-errors`, which is the first step of `mix test`. This is a real
failure, not a style preference.

`config/test.exs` points each behaviour at its Mox mock. **Tests never hit the network or a
real service.** If a test needs service behaviour, set an expectation on the mock.

Related: prefer searching indexers by IMDb id over free-text title — `Catalog.get_movie/1`
carries `imdb_id` through for exactly this.
