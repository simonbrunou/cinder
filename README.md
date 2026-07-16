# Cinder

[![CI](https://github.com/simonbrunou/cinder/actions/workflows/ci.yml/badge.svg)](https://github.com/simonbrunou/cinder/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Cinder is a single-household, self-hosted replacement for the **Sonarr + Radarr + Seerr** loop:
request a movie or TV show → find the best release → download it → import it into **Jellyfin or
Plex**. It's one Phoenix/LiveView app on SQLite — a single container, no external database. Every
external service (TMDB, Prowlarr, qBittorrent/SABnzbd, Jellyfin/Plex) sits behind a behaviour and
is configured in-app.

> **Status:** **v1.0** — movies + TV + multi-user (request → admin approval) are built, validated
> live, and released. Build history in [`ROADMAP.md`](ROADMAP.md).

## Quickstart (Docker)

Requires Docker with the Compose plugin.

```sh
git clone https://github.com/simonbrunou/cinder.git
cd cinder
cp .env.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48)" >> .env   # or edit .env by hand
echo "CINDER_BOOTSTRAP_TOKEN=$(openssl rand -hex 32)" >> .env
mkdir -p media/{movies,tv,downloads} && sudo chown -R 65534:65534 media
docker compose up --build      # builds the image locally on first run
```

Cinder runs as `nobody` (uid 65534), so the bind-mounted `media/` directory must be owned by it —
otherwise the first-run wizard can't create the library roots and won't let you finish. (The
database volume is set up by the image itself.)

Open <http://localhost:4000>. Paste the `CINDER_BOOTSTRAP_TOKEN` from `.env` into the registration
form to claim the first admin, then remove both that `.env` value and its environment entry from
`docker-compose.yml`. The **first-run wizard** then collects your TMDB / indexer / download-client /
media-server details, validating each before it lets you finish. Later household self-registration
stays open and always creates a normal user. A fresh instance without a bootstrap token fails
closed: it cannot create the first account.

> ⚠️ **Secure it before exposing it.** Keep the one-time bootstrap token private, and don't expose
> port 4000 to an untrusted network — run Cinder behind a reverse proxy (with TLS) or a VPN. See
> [`docs/operating.md`](docs/operating.md).

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
| `CINDER_BOOTSTRAP_TOKEN` | **first claim only** | — | One-time credential required while no account exists. Generate with `openssl rand -hex 32`, use it to create the first admin, then remove it from the deployment. |
| `DATABASE_PATH` | **yes** | — | Path to the SQLite database file (compose: `/data/cinder.db`). |
| `PHX_SERVER` | set `true` | — | Start the web server in the release. |
| `PHX_HOST` | no | `localhost` | Public hostname; used in generated URLs + HSTS. |
| `PORT` | no | `4000` | HTTP listen port. |
| `POOL_SIZE` | no | `5` | SQLite connection-pool size. |
| `RELEASE_NAME` | auto | — | Set by the release; its presence triggers DB migrations on boot. |
| `DNS_CLUSTER_QUERY` | no | — | DNS-based clustering (unused on a single node). |
| `CINDER_BASIC_AUTH_USER` / `CINDER_BASIC_AUTH_PASSWORD` | no | — | Set **both** to require HTTP Basic auth in front of the whole app — an optional outer gate while no admin exists yet, or a second layer when you can't front Cinder with a proxy/VPN. Unset ⇒ no gate. |

### In-app service configuration (set in the wizard / `/settings`)

| Group | Settings |
|---|---|
| TMDB | API read token (v4 bearer) |
| Indexer | Prowlarr URL + API key |
| Download | qBittorrent URL / username / password, SABnzbd URL + API key, per-client enable toggles |
| Media server | Jellyfin URL + API key **or** Plex URL + token + a per-library section (Movies, TV); media-server type |
| Library paths | `movies_library_path` **and** `tv_library_path` — a separate import root per kind, both required |
| Release size bands | Per-kind min/max size (decimal GB) + preferred-resolution list + preferred-source list (`remux, bluray, webrip, webdl, hdtv, dvd, cam`); for TV the band is per episode (a season pack of N is allowed N× the max). Ships with defaults — movies 0.3–15 GB, TV 0.05–4 GB per episode; blank = default, an explicit `0` = no limit |
| Subtitles | OpenSubtitles API key + username + password, LibreTranslate URL + API key (optional fallback translation), preferred subtitle languages (csv) — fetched automatically after each import and swept every 12 h; local/ID subtitle results stay provisional for later upgrades |
| Notifications | Discord webhook URL — posts an embed on availability and failures; approvals stay in-app (unset ⇒ log-only) |
| Behaviour toggles | `auto_approve_all` (trusted households: every request grabs immediately), `move_on_import` (move instead of hardlink), media-server type (Jellyfin/Plex) |
| Anime releases | Embedded-subtitle mode (allow/prefer/require), preferred/blocked release-group lists, preferred-group fallback delay (hours) — global, applies to every title switched to the Anime profile (audio mode is per-title — see the Audio picker below); `ffprobe_bin` (the `ffprobe` binary path/name used for post-download verification) |

Each can be **bootstrapped** from an environment variable (`TMDB_API_TOKEN`, `PROWLARR_URL`,
`MOVIES_LIBRARY_PATH`, `TV_LIBRARY_PATH`, `MOVIES_PLEX_SECTION`, `TV_PLEX_SECTION`,
`OPENSUBTITLES_API_KEY`, `LIBRETRANSLATE_URL`, `LIBRETRANSLATE_API_KEY`, `SUBTITLE_LANGUAGES`, …) for an unattended first boot, but the in-app
value wins once set. The size bands and the Anime releases settings (including `ffprobe_bin`) have
no env bootstrap — the bands start at their shipped defaults; tune them in `/settings`.

## How it works

Four contexts mirror the pipeline: **Catalog** (TMDB discovery + movie/series requests), **Acquisition**
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

**Anime** is a per-title opt-in profile (`Auto`/`Standard`/`Anime` on any movie or series — `Auto`
stays `Standard` unless explicitly confirmed, either directly or as a requester's proposal an admin
approves). An Anime title gets alias- and absolute/scene-number-aware release search (native,
romaji, and licensed titles; releases like `One Piece 1122v2` resolve without TMDB season math) and
searches Season 0 specials only when they're classified story-special/recap and monitored. A
downloaded batch only imports once every file is certainly mapped to one episode (one narrow
exception: a lone non-ignored file with no episode markers, against a lone reserved episode, is
inferred rather than held) — anything ambiguous holds the whole batch as **Needs mapping** on
`/activity` for review (**Retry import** after fixing the files, or **Discard**). Each title's
Audio pick (Original/French/French + original/Any — the same per-title picker movies and TV
already have) doubles as its Anime audio mode; global Anime preferences in `/settings` (subtitle
mode, preferred/blocked release groups) apply on top, and — if `ffprobe` is available — a
completed download's actual audio/subtitles are verified against them before import, rejecting
and blocklisting a release that provably violates the policy. `ffprobe` is optional but
recommended; without it, Cinder skips that verification step and imports permissively.

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
