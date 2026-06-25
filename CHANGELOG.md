# Changelog

All notable changes to Cinder are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Cinder aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Delete media files from disk when removing a movie, TV show, season, or episode (opt-in
  checkbox on the delete dialogs; mirrors Sonarr/Radarr). Deleting a season/episode file leaves
  the item monitored so the poller re-grabs it, unless you also tick "stop monitoring". Empty
  library folders are pruned. Because library files are hardlinks, disk space is reclaimed only
  once the download client also drops its copy.
- **Multi-user TV requests (parity with movies)** — any authenticated user can search for a TV
  show on `/series` and request a season from the show's discovery page (`/series/tmdb/:tmdb_id`).
  A non-admin's request is `:pending` until an admin approves/denies it; an admin's own request
  auto-approves. Quota enforcement, the **My requests** view, and per-season state badges
  (Pending / Approved / Denied) all apply. On approval, the series is created and only the
  requested season is monitored; the admin can adjust episode-level monitoring from
  `/series/:id` (admin-only). The `/series` discovery page and show discovery are now
  **authenticated** (no longer admin-only); monitor management stays admin-only.
- **Per-kind library config (Movies, TV)** — every library kind has its own import root, Plex
  scan section, and editable release size band, all derived from one `Cinder.Library.kinds/0`
  list, so movies and TV behave identically and a new media type (books, audio) is a one-line
  addition. Movies now get an editable size band in `/settings`, like TV (per-episode for TV).
  Both library roots remain required and separate (the TV root does not fall back to the movie root).
- **Per-library Plex scan** — `MediaServer.scan(kind)` refreshes the right Plex section, so a TV
  import refreshes the Shows library. Previously a single movie-only section was refreshed and TV
  imports never refreshed Plex (Jellyfin's full refresh was unaffected). `/status` now shows a
  per-kind library health row, and a missing root holds the import (visible red) instead of failing.

### Changed
- **BREAKING (config):** library config keys are regularized per kind — the movie env vars gain the
  `MOVIES_` prefix the TV ones already had:
  - `LIBRARY_PATH` → `MOVIES_LIBRARY_PATH`
  - `PLEX_SECTION` → `MOVIES_PLEX_SECTION` (plus a new `TV_PLEX_SECTION` for the Shows library)

  Stored `/settings` rows are renamed automatically by a migration on upgrade — **but environment
  variables are not.** If you bootstrap via `docker-compose.yml` / `.env`, rename these there
  before redeploying, or the movie library path/section reverts to unset (movie imports then hold,
  shown red on `/status`, until you set it).

### Fixed
- **qBittorrent v5.x compatibility** — qBittorrent ≥ 5.x answers `POST /api/v2/auth/login` with
  `204 No Content` (not `200`) and names the session cookie `QBT_SID_<port>` (not `SID`). The client
  accepted only `200` and resent a literal `SID=` cookie, so every qBittorrent call (add / status /
  health) failed login with `{:qbittorrent_status, 204}` on modern servers. It now accepts any `2xx`
  login and threads the real session cookie back verbatim.
- **Pre-v1.0 release-audit fixes:**
  - **Docker:** the image now creates and owns `/data`, so a fresh `docker compose up` can write its
    SQLite database instead of crash-looping (the `nobody` user couldn't write the root-owned
    fresh-volume mountpoint).
  - **Scorer:** a release whose indexer omits the size no longer slips past a configured max-size
    band (it's accepted only when no band is set) — affected both movies and TV packs.
  - **Library import:** a title that sanitizes to only dots (e.g. `..`) now falls back to a tmdb-id
    folder instead of escaping the library root; an existing destination is treated as an idempotent
    success only when it's already a hardlink of the source (a *different* file colliding on the same
    `Title (Year)` name now fails loudly rather than mis-linking); and a TV pack with two files
    naming the same episode keeps the largest and logs the rest instead of colliding.
  - **`/activity`:** the Retry button no longer crashes the LiveView on a forged (non-numeric) id.
  - **SABnzbd:** the side-effecting `addurl` is no longer auto-retried by `Req`, preventing duplicate
    downloads on a transient failure.
  - **Admin audit:** changing a user's request quota now writes an `admin_audit` row, like every
    other destructive admin action.
  - **TV refresh:** the periodic TMDB reconcile no longer renumbers an episode with an in-flight
    grab (which could mislabel that grab's imported files).

### Internal
- SQLite correctness settings (`journal_mode: :wal`, `busy_timeout`, `foreign_keys: :on`, and now
  `default_transaction_mode: :immediate`) are pinned once in `config/config.exs` so every
  environment — including a non-prod release — applies them. `:immediate` makes `busy_timeout`
  govern the app's read-then-write transactions (a deferred `BEGIN` could still raise
  `SQLITE_BUSY_SNAPSHOT`, which `busy_timeout` can't retry).

## [0.7.0] - 2026-06-23

First packaged, publicly installable release — the movies + TV + multi-user product behind a
Docker image and a first-run wizard. Pre-1.0: dogfooding ahead of the v1.0 public launch.

### Added
- **Movies pipeline** — request → Prowlarr search → qBittorrent/SABnzbd download → hardlink +
  import into Jellyfin/Plex, advanced by background pollers with live LiveView status and
  crash-recovery.
- **TV pipeline** — series/season/episode monitoring, season-pack and multi-episode parsing +
  scoring, multi-file import, a periodic TMDB refresh sweep, and an upcoming-episodes calendar.
- **Multi-user** — local accounts with `admin`/`user` roles; non-admins request, an admin
  approves/denies (the approval gate lives in the data model), per-user quotas, and a notifier
  seam.
- **In-app configuration** — a settings store overlaying env bootstrap (secrets encrypted at
  rest via Cloak), a first-run setup wizard that validates every service before completion, and
  per-service health checks on `/status`.
- **Packaging** — Docker image, `docker-compose.yml` + `.env.example`, a tag-triggered GitHub
  Actions workflow publishing `ghcr.io/simonbrunou/cinder`, and operator + contributor docs.

[Unreleased]: https://github.com/simonbrunou/cinder/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/simonbrunou/cinder/releases/tag/v0.7.0
