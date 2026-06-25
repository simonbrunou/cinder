# Operating Cinder

Operator guide for a self-hosted Cinder instance. For the architecture/build plan see
[`ROADMAP.md`](../ROADMAP.md); for local development see [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Deploy

The [`docker-compose.yml`](../docker-compose.yml) at the repo root is the supported deployment.
Copy `.env.example` to `.env`, set `SECRET_KEY_BASE` (`openssl rand -base64 48`), then
`docker compose up -d`. The container migrates the database on boot and serves on port 4000.

> **Upgrading from an early image:** the container owns its `/data` volume so a *fresh* `docker
> compose up` can write the database. Docker only sets a named volume's ownership when it's first
> created, so a `cinder_data` volume left root-owned by a pre-fix image keeps crash-looping after an
> upgrade. If the container can't write the DB after pulling a newer image, recreate the empty
> volume (`docker compose down && docker volume rm <project>_cinder_data`) or
> `chown -R 65534 /var/lib/docker/volumes/<project>_cinder_data/_data`.

## First run & security

The first account created becomes the **admin**; the first-run wizard (`/setup`) then collects your
service config and validates it. Registration stays **open** afterward — that's how other household
members sign up to request media.

Because the first registrant is the admin and Cinder serves plain HTTP on `0.0.0.0:4000` (TLS is
expected to terminate at a reverse proxy):

- **Create your admin immediately** after first boot. The first account to register *wins admin* —
  an exposed, not-yet-claimed instance lets a stranger take it.
- **Do not expose port 4000 to an untrusted network.** Run Cinder behind a reverse proxy (with TLS)
  or a VPN — this is the real access control. Registration stays **open** after the admin exists
  (that's how household members sign up), and **self-registered accounts are auto-confirmed**: they
  can log in and submit requests immediately (no email confirmation step). There is **no
  rate-limiting** on register/login — an accepted single-household ceiling, but another reason the
  instance must not face an untrusted network.

## Configuration: environment vs in-app

Boot-only keys (`SECRET_KEY_BASE`, `DATABASE_PATH`, `PHX_*`, `PORT`, `POOL_SIZE`, `RELEASE_NAME`,
`DNS_CLUSTER_QUERY`) stay in the environment. Everything else — TMDB, indexer, download clients,
media server, the per-kind library roots (`movies_library_path`, `tv_library_path`), the per-kind
size bands — is edited at `/settings` and
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
That's the entire app state.

**Don't `cp` a live WAL database.** Cinder runs SQLite in WAL mode, so at any moment recent writes
live in the `-wal` sidecar, not yet in `cinder.db`. A plain `cp` of the files while the container is
running can capture a torn, inconsistent snapshot. Either:

- **stop the container first** (`docker compose stop cinder`), then copy `/data`; or
- take a consistent online copy with SQLite's own tooling, e.g.
  `sqlite3 /data/cinder.db ".backup /data/backup.db"` or `VACUUM INTO`.

**Keep `SECRET_KEY_BASE` with the backup.** It's the master key: the at-rest encryption key for
stored secrets is *derived from it*, so **a leaked `SECRET_KEY_BASE` compromises every stored
service credential**, and losing it (or rotating it) means re-entering every credential in
`/settings` after a restore.

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

**TV requests work like movie requests.** Any authenticated user can search for a TV show on
`/series` and request a season from the show's discovery page. A non-admin's request is
`:pending` until an admin approves or denies it from the approval queue; an admin's own request
auto-approves. Per-user quotas, the **My requests** view, and per-season state badges
(Pending / Approved / Denied) all apply, in parity with movies. A denied season can be
re-requested. On approval, the series is created (if not already present) and **only that season**
is monitored — the admin can adjust episode-level monitoring from the series detail page (`/series/:id`,
admin-only).

The TV poller then takes over: it searches each still-wanted monitored episode (monitored, aired,
no file yet), preferring a season pack when one covers them and falling back to per-episode grabs;
on import it maps each file in a pack to its episode by parsing `SxxEyy`. A file it can't match
to a wanted episode is **logged and skipped** (the grab parks and its episodes re-search) rather
than mis-filed.

A periodic TMDB refresh reconciles season/episode data, so a newly-announced or late-dated episode
becomes search-eligible on its own once its air date passes — no manual re-add. The **`/calendar`**
view (admin) lists upcoming monitored episodes.

**Tuning grabs.** The `Release size bands` group in `/settings` sets a min/max size (decimal GB)
and a preferred-resolution list **per library kind** (Movies and TV). For TV the band is **per
episode**: a season pack of N episodes is allowed up to N× the max, so don't set the max to a
whole-pack figure (the movie band is per movie). Both bounds are optional —
blank means no limit. A too-low max (or any min above what your indexer carries) silently rejects
every release, so the episode stays wanted and nothing grabs; start with the band blank and tighten
only if you're pulling oversized packs.

## Library roots: movies vs TV

Each library kind has its **own** import root — movies under `movies_library_path`, TV under
`tv_library_path` — and (for Plex) its own scan section. Point your media server's Movies and Shows
libraries at the two roots. **Each root is required and has no fallback:** with one unset, that
kind's grabs *hold* (downloaded, logged, shown red on `/status`) rather than importing into the
wrong library, and the first-run wizard won't finish until both roots validate writable.

> **Upgrading across the key regularization:** the movie config keys gained the `MOVIES_` prefix the
> TV keys already had — `LIBRARY_PATH` → `MOVIES_LIBRARY_PATH`, `PLEX_SECTION` → `MOVIES_PLEX_SECTION`
> (and a new `TV_PLEX_SECTION` for the Shows library). Stored `/settings` rows migrate automatically,
> **but environment variables do not** — if you bootstrap movie config via `docker-compose.yml` /
> `.env`, rename those vars before redeploying, or the movie root/section reverts to unset (movie
> imports hold, red on `/status`, until set). Both roots must still be on the same filesystem as the
> download client's completed dir (hardlinks).

## Deleting media

The delete dialogs for movies and TV shows (`/library`) and for individual seasons and episodes
(`/series/:id`) include an opt-in **"Delete file from disk"** checkbox (unchecked by default).
Ticking it removes the library file when you confirm the deletion; empty parent folders left behind
are pruned automatically.

- **Season/episode file deletion leaves the item monitored** — the TV poller will re-grab it on
  the next sweep. Tick "stop monitoring" as well if you want to drop it permanently.
- **Disk space is reclaimed only once the download client also drops its copy.** Library files are
  hardlinks; the space frees when the last link (either the library copy or the download client's
  completed-downloads copy) is deleted.

## Known limitations

- **BitTorrent v1 only.** Releases with a v2-only (SHA-256) infohash aren't handled; most public
  trackers are still v1.
- **SABnzbd "Pause on Duplicates" must be OFF.** That mode re-keys the download id after an add, so
  Cinder loses track of the job and it parks.
- **Specials (season 0) aren't grabbed** by the TV sweep yet.
- **Air-date eligibility is by UTC calendar day.** An episode becomes search-eligible when its TMDB
  air date is "today or earlier" in **UTC**, so far from UTC it can flip to wanted up to ~a day
  early or late. Harmless for a household (it just grabs a few hours off) — there's no per-timezone
  scheduling.
