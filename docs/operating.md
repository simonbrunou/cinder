# Operating Cinder

Operator guide for a self-hosted Cinder instance. For the architecture/build plan see
[`ROADMAP.md`](../ROADMAP.md); for local development see [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Deploy

The [`docker-compose.yml`](../docker-compose.yml) at the repo root is the supported deployment.
Copy `.env.example` to `.env`, set `SECRET_KEY_BASE` (`openssl rand -base64 48`), then
`docker compose up -d`. The container migrates the database on boot and serves on port 4000.

## First run & security

The first account created becomes the **admin**; the first-run wizard (`/setup`) then collects your
service config and validates it. Registration stays **open** afterward — that's how other household
members sign up to request media.

Because the first registrant is the admin and Cinder serves plain HTTP on `0.0.0.0:4000` (TLS is
expected to terminate at a reverse proxy):

- **Create your admin immediately** after first boot.
- **Do not expose port 4000 to an untrusted network.** Run Cinder behind a reverse proxy (with TLS)
  or a VPN. An exposed, not-yet-claimed instance lets a stranger register as admin first.

## Configuration: environment vs in-app

Boot-only keys (`SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_*`, `PORT`, `POOL_SIZE`,
`DNS_CLUSTER_QUERY`) stay in the environment. Everything else — TMDB, indexer, download clients,
media server, `library_path` — is edited at `/settings` and stored in the database. **DB values
override the env bootstrap; clearing a setting reverts to the env value/default.** Secret fields are
encrypted at rest with a key derived from `SECRET_KEY_BASE`.

## The hardlink requirement

On a completed download Cinder **hardlinks** the file into the library (instant, no copy, no extra
disk). A hardlink can't cross filesystems, so:

- The **library root** and the **download client's completed-downloads directory must be on the
  same filesystem.** The compose file keeps both under one `/media` mount (`/media/movies`,
  `/media/tv`, `/media/downloads`).
- Cinder's container runs as `nobody` (uid/gid **65534**). Give your download client a matching
  `PUID`/`PGID` (the linuxserver.io images take these env vars), or a shared group with group write
  — otherwise the hardlink fails with a permission error and the item parks as `:import_failed`.

## Backups

Back up the SQLite database — the `/data` volume (`cinder.db` plus its `-wal`/`-shm` sidecars).
That's the entire app state. **Keep `SECRET_KEY_BASE` with the backup:** it's the encryption key for
stored secrets, so losing it means re-entering every service credential in `/settings` after a
restore.

## Health & retry

`/status` (admin) shows every item's live pipeline state plus a **Service health** panel that pings
each configured service (with a **Recheck** button). A parked item (`:search_failed` / `:no_match` /
`:import_failed`) shows a **Retry** button that resets it to `:requested` with attempt counters
zeroed; the poller re-queues it on the next tick.

## Troubleshooting parked states

| State | Meaning | What to do |
|---|---|---|
| `:no_match` | No acceptable release found (the scorer rejected all results, or the title has no IMDb id on TMDB). | Passive; nothing to fix. Relax scoring if it's too strict. |
| `:search_failed` | A release was found but couldn't be handed off, or transient errors exhausted ~10 min of retries. | Check the server log. Often a malformed/HTML "torrent", a BitTorrent **v2-only** torrent (see limits), or a Prowlarr/qBittorrent outage. **Retry** once fixed. |
| `:import_failed` | The completed download had no usable video file, or import failed repeatedly — commonly a **cross-filesystem** library/download path or a permission mismatch. | Verify the hardlink requirement above; the log shows the cross-device/permission error. **Retry** after fixing. |

## Known limitations

- **Movies and TV share one library root.** Both import under `library_path` today
  (`Title (Year)/…` and `Show (Year)/Season NN/…` side by side). Point a single mixed Jellyfin/Plex
  library at it, or wait for the separate TV root (v1.0 / M8).
- **BitTorrent v1 only.** Releases with a v2-only (SHA-256) infohash aren't handled; most public
  trackers are still v1.
- **SABnzbd "Pause on Duplicates" must be OFF.** That mode re-keys the download id after an add, so
  Cinder loses track of the job and it parks.
- **Specials (season 0) aren't grabbed** by the TV sweep yet.
