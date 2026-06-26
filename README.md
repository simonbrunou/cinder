# Cinder

[![CI](https://github.com/simonbrunou/cinder/actions/workflows/ci.yml/badge.svg)](https://github.com/simonbrunou/cinder/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Cinder is a single-household, self-hosted replacement for the **Sonarr + Radarr + Seerr** loop:
request a movie or TV show → find the best release → download it → import it into **Jellyfin or
Plex**. It's one Phoenix/LiveView app on SQLite — a single container, no external database. Every
external service (TMDB, Prowlarr, qBittorrent/SABnzbd, Jellyfin/Plex) sits behind a behaviour and
is configured in-app.

> **Status:** movies + TV + multi-user (request → admin approval) are built and working; currently
> pre-1.0 (**v0.7.0**), dogfooded privately ahead of the v1.0 public launch. Build plan in
> [`ROADMAP.md`](ROADMAP.md).

## Quickstart (Docker)

Requires Docker with the Compose plugin.

```sh
git clone https://github.com/simonbrunou/cinder.git
cd cinder
cp .env.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48)" >> .env   # or edit .env by hand
mkdir -p media/{movies,tv,downloads} && sudo chown -R 65534:65534 media
docker compose up --build      # builds the image locally on first run
```

Cinder runs as `nobody` (uid 65534), so the bind-mounted `media/` directory must be owned by it —
otherwise the first-run wizard can't create the library roots and won't let you finish. (The
database volume is set up by the image itself.)

Open <http://localhost:4000>. The **first-run wizard** creates your admin account and collects
your TMDB / indexer / download-client / media-server details, validating each before it lets you
finish. The first account you create is the admin.

> ⚠️ **Secure it before exposing it.** The first registered user becomes the admin, and
> registration stays open afterward (that's how household members sign up to request). Create your
> admin **immediately**, and don't expose port 4000 to an untrusted network — run Cinder behind a
> reverse proxy (with TLS) or a VPN. See [`docs/operating.md`](docs/operating.md).

> 🔗 **Hardlinks.** Cinder hardlinks finished downloads into your library, so the library and your
> download client's completed-downloads directory must be on the **same filesystem**. The compose
> file keeps both under one `/media` mount — details in the operating guide.

## Configuration

Two tiers. A handful of **boot-only** keys stay environment variables; **everything else** is
edited in-app at `/settings` (or the wizard) and stored in the database. DB values **override** the
env bootstrap, and clearing a setting reverts it to the env value/default. Secrets are encrypted at
rest with a key derived from `SECRET_KEY_BASE`.

### Boot-only environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `SECRET_KEY_BASE` | **yes** | — | Signs sessions/cookies; also derives the at-rest encryption key and signing salts. Generate with `openssl rand -base64 48`. |
| `DATABASE_PATH` | **yes** | — | Path to the SQLite database file (compose: `/data/cinder.db`). |
| `PHX_SERVER` | set `true` | — | Start the web server in the release. |
| `PHX_HOST` | no | `localhost` | Public hostname; used in generated URLs + HSTS. |
| `PORT` | no | `4000` | HTTP listen port. |
| `POOL_SIZE` | no | `5` | SQLite connection-pool size. |
| `RELEASE_NAME` | auto | — | Set by the release; its presence triggers DB migrations on boot. |
| `DNS_CLUSTER_QUERY` | no | — | DNS-based clustering (unused on a single node). |

### In-app service configuration (set in the wizard / `/settings`)

| Group | Settings |
|---|---|
| TMDB | API read token (v4 bearer) |
| Indexer | Prowlarr URL + API key |
| Download | qBittorrent URL / username / password, SABnzbd URL + API key, per-client enable toggles |
| Media server | Jellyfin URL + API key **or** Plex URL + token + a per-library section (Movies, TV); media-server type |
| Library paths | `movies_library_path` **and** `tv_library_path` — a separate import root per kind, both required |
| Release size bands | Per-kind min/max size (decimal GB) + preferred-resolution list + preferred-source list (`remux, bluray, webrip, webdl, hdtv, dvd, cam`); for TV the band is per episode (a season pack of N is allowed N× the max) |

Each can be **bootstrapped** from an environment variable (`TMDB_API_TOKEN`, `PROWLARR_URL`,
`MOVIES_LIBRARY_PATH`, `TV_LIBRARY_PATH`, `MOVIES_PLEX_SECTION`, `TV_PLEX_SECTION`, …) for an
unattended first boot, but the in-app value wins once set. The size bands have no env bootstrap —
set them in `/settings`.

## How it works

Four contexts mirror the pipeline: **Catalog** (TMDB discovery + watchlist/series), **Acquisition**
(Prowlarr search + release parsing/scoring), **Download** (qBittorrent/SABnzbd client + a polling
GenServer), **Library** (hardlink + rename into the Jellyfin/Plex layout, then scan). Background
pollers advance each request through its state machine and broadcast over PubSub so the LiveView
dashboard updates live. Every state change goes through a single context choke-point, which — on
SQLite WAL — keeps a web write racing the poller correct rather than flaky.

**TV** works the same way as movies for users: any authenticated user searches for a TV show and
**requests a season**; a non-admin's request is pending until an admin approves (or denies), and
an admin's own request auto-approves. The request→approval gate, per-user quotas, My-requests
view, and per-season state badges (Pending / Approved / Denied) all apply, in parity with movies.
Once approved, monitoring is set for that season only and the TV poller takes over: it searches
for the best release per still-wanted episode — preferring a season pack when one covers them,
falling back to per-episode grabs — then maps each file in a pack to its episode on import.
Admins can also manage monitoring directly from the series detail page. A periodic TMDB refresh
keeps season/episode data current (so a newly-aired or late-dated episode becomes search-eligible
on its own), and a `/calendar` view lists upcoming monitored episodes. Episodes land under the
separate TV root (`tv_library_path`) in the `Show (Year)/Season NN/Show (Year) - SxxEyy.ext`
layout Jellyfin/Plex expect.

## Screenshots

_TODO — captures of the discovery grid, the request/approval queue, and the `/status` dashboard
will land here (`docs/images/`)._

## Development

```sh
mix setup        # install deps, create + migrate the DB, build assets
mix phx.server   # http://localhost:4000
mix test         # the gate: compile (warnings-as-errors) + format + credo --strict + suite
```

Tidewave MCP is wired in dev. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for conventions.

## Documentation

- [`ROADMAP.md`](ROADMAP.md) — build plan and what's shipped.
- [`docs/operating.md`](docs/operating.md) — deploy, security, backups, hardlinks, troubleshooting, limits.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — dev setup, conventions, release process.

## License

[GPL-3.0-or-later](LICENSE) — `SPDX-License-Identifier: GPL-3.0-or-later`.
