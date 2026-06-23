# Changelog

All notable changes to Cinder are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Cinder aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Separate TV library root** — TV episodes now import under their own `tv_library_path`
  (env bootstrap `TV_LIBRARY_PATH`, editable in `/settings`), so Jellyfin/Plex can point
  distinct Movies and Shows libraries at each. Movies keep `library_path`.
- **TV release size band in `/settings`** — per-episode min/max size (decimal GB) and a
  preferred-resolution list for TV grabs, applied per episode (a season pack of N episodes is
  allowed up to N× the max). Blank means no limit. The movie scorer is unchanged.

### Changed
- **BREAKING (config):** the TV library root is now required and separate from the movie root —
  it does **not** fall back to `library_path`. Set `TV_LIBRARY_PATH` (or the TV library path in
  `/settings`) before TV imports run. An unset TV root parks TV grabs (logged) rather than
  importing episodes into the movie library. The first-run wizard now requires both roots.

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
