# Phase 5 — Live smoke test

The mocked suite proves wiring and logic; only a live run proves your actual
Prowlarr/qBittorrent/Jellyfin return what Cinder expects. Run this when those
services are reachable.

## 1. Set credentials (read by `config/runtime.exs` in all envs)

    export TMDB_API_TOKEN=...            # TMDB v4 bearer token
    export QBITTORRENT_URL=http://localhost:8080
    export QBITTORRENT_USERNAME=...
    export QBITTORRENT_PASSWORD=...
    export JELLYFIN_URL=http://localhost:8096
    export JELLYFIN_API_KEY=...
    export LIBRARY_PATH=/path/to/jellyfin/movies   # MUST be the same filesystem as the qBittorrent download dir (hardlink)

Prowlarr is configured under `config :cinder, Cinder.Acquisition.Indexer.Prowlarr`
(`base_url`, `api_key`); add an env-var block to `config/runtime.exs` if you
haven't already (mirror the qBittorrent block).

## 2. Run

    mix phx.server

Open `/`, search a real movie, click Add. Open `/status` and watch it advance
`:requested → :searching → :downloading → :downloaded → :available`.

## 3. Known hazards / what each terminal state means

- **`:search_failed`** (red badge) — a release was found but couldn't be handed
  off, or transient search/handoff errors exhausted ~10 minutes of retries.
  Check the server log for the reason. Causes: a malformed/HTML "torrent"
  response, a BitTorrent v2-only (SHA-256) torrent (not handled — v1 only), or a
  persistent Prowlarr/qBittorrent outage. Distinct from `:no_match` on purpose.
- **`:no_match`** (yellow) — no acceptable release exists (scorer rejected all /
  zero results), or the movie has no IMDb id on TMDB. Passive; nothing to fix.
- **`:import_failed`** (red) — completed download had no usable video file, or
  import failed ~10 times. The hardlink requires `LIBRARY_PATH` to be on the same
  filesystem as the download dir; a cross-filesystem path fails every import.
- **Jellyfin scan is unvalidated against a real instance** — `MediaServer.Jellyfin.scan/0`
  (POST `/Library/Refresh`, `x-emby-token` header) is mock-tested only; the live
  run is its first real call. Adjust the endpoint/header if the scan doesn't fire.
- **Manually re-requesting a parked movie** keeps its `search_attempts`/`import_attempts`
  at the cap, so it re-parks on the first attempt — reset the counter in IEx
  (no retry UI yet).
