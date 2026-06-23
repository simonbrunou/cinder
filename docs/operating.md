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
media server, `library_path`, `tv_library_path`, the TV size band — is edited at `/settings` and
stored in the database. **DB values override the env bootstrap; clearing a setting reverts to the
env value/default.** Secret fields are encrypted at rest with a key derived from `SECRET_KEY_BASE`.

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

The media-server library scan after an import is **best-effort**: if the scan call fails (e.g. an
endpoint/header mismatch on your Jellyfin/Plex version) the item still reaches `:available`, and
your server picks the file up on its next periodic scan.

## Troubleshooting parked states

| State | Meaning | What to do |
|---|---|---|
| `:no_match` | No acceptable release found (the scorer rejected all results, or the title has no IMDb id on TMDB). | Passive; nothing to fix. Relax scoring if it's too strict. |
| `:search_failed` | A release was found but couldn't be handed off, or transient errors exhausted ~10 min of retries. | Check the server log. Often a malformed/HTML "torrent", a BitTorrent **v2-only** torrent (see limits), or a Prowlarr/qBittorrent outage. **Retry** once fixed. |
| `:import_failed` | The completed download had no usable video file, or import failed repeatedly — commonly a **cross-filesystem** library/download path or a permission mismatch. | Verify the hardlink requirement above; the log shows the cross-device/permission error. **Retry** after fixing. |

## TV: monitoring, season packs, and the calendar

Add a series from the TV search, then choose what to monitor — whole seasons or individual
episodes, with a per-series strategy (`all` past + future, `future` only, or `none`). The TV
poller searches each still-wanted monitored episode (monitored, aired, no file yet), preferring a
season pack when one covers them and falling back to per-episode grabs; on import it maps each
file in a pack to its episode by parsing `SxxEyy`. A file it can't match to a wanted episode is
**logged and skipped** (the grab parks and its episodes re-search) rather than mis-filed.

A periodic TMDB refresh reconciles season/episode data, so a newly-announced or late-dated episode
becomes search-eligible on its own once its air date passes — no manual re-add. The **`/calendar`**
view (admin) lists upcoming monitored episodes.

**Tuning TV grabs.** The `TV releases` group in `/settings` sets a per-episode size band (decimal
GB) and a preferred-resolution list. The band is **per episode**: a season pack of N episodes is
allowed up to N× the max, so don't set the max to a whole-pack figure. Both bounds are optional —
blank means no limit. A too-low max (or any min above what your indexer carries) silently rejects
every release, so the episode stays wanted and nothing grabs; start with the band blank and tighten
only if you're pulling oversized packs.

## Library roots: movies vs TV

Movies import under `library_path` and TV under a **separate** `tv_library_path` — point your media
server's Movies and Shows libraries at the two roots. **The TV root is required and has no fallback:**
with it unset, TV grabs park (logged) rather than importing episodes into the movie library, and the
first-run wizard won't finish until both roots validate writable.

> **Upgrading from a single-root instance (≤ 0.7.0):** set `TV_LIBRARY_PATH` (or the TV library path
> in `/settings`) before your next TV import — an already-set-up instance is **not** sent back through
> the wizard, so an unset TV root will park TV grabs until you configure it. Both roots must still be
> on the same filesystem as the download client's completed dir (hardlinks).

## Known limitations

- **BitTorrent v1 only.** Releases with a v2-only (SHA-256) infohash aren't handled; most public
  trackers are still v1.
- **SABnzbd "Pause on Duplicates" must be OFF.** That mode re-keys the download id after an add, so
  Cinder loses track of the job and it parks.
- **Specials (season 0) aren't grabbed** by the TV sweep yet.
