# Changelog

All notable changes to Cinder are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Cinder aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **BREAKING (behavior):** release size bands now ship with defaults — movies 0.3–15 GB, TV
  0.05–4 GB per wanted episode — instead of unbounded, so a fresh install can't legally match a
  multi-hundred-GB batch archive for a single wanted episode (#108). An instance that ran with a
  band left blank applies the defaults after upgrade: releases outside them stop matching. A blank
  `/settings` field now means "use the default"; enter an explicit `0` to restore the old
  unbounded behavior. Bands already set in `/settings` are unaffected.

### Added
- **Anime-aware handling.** A per-title opt-in profile (`Auto`/`Standard`/`Anime` on movies and
  series — `Auto` stays `Standard` unless a title is explicitly confirmed, either directly or as a
  requester's proposal an admin approves) makes release search alias- and absolute/scene-number-aware
  (native/romaji/licensed titles; releases like `One Piece 1122v2` resolve without TMDB season math),
  searches Season 0 specials only when they're explicitly classified story-special/recap and
  monitored, holds an ambiguous downloaded batch as **Needs mapping** on `/activity` instead of
  guessing (**Retry import** after fixing the files, or **Discard**), and enforces global Anime
  audio/subtitle/release-group preferences (`/settings`) with a post-download `ffprobe` verification
  that rejects and blocklists a release whose actual audio/subtitles provably violate them (`ffprobe`
  availability now also shows up as a `/status` health check and a `/settings` Test connection, like
  every other service).
- **Subtitles.** Optional OpenSubtitles.com integration fetches `.srt` sidecars for imported
  movies and episodes in configured languages, at import time and via a 12h backfill sweep.
  Opt-in: set `Subtitle languages` + OpenSubtitles credentials in Settings. Best-effort — never
  blocks an import.
- **Discord notifications.** Optional webhook (Settings → Notifications) posts embeds on
  approvals, availability, and failures; log-only when unset.
- **Movie/series detail pages** with TMDB metadata and per-file info (resolution, size,
  audio/subtitle languages captured at import via ffprobe).
- **Login rate limiting.** Password login capped at 10 failures per `{ip, email}` per 15 min;
  blocked attempts return the same generic error (no enumeration oracle).
- **TV search exhaustion is visible.** An episode whose 10 search attempts run out shows a
  "Search failed" badge (series page + calendar), logs a warning, and notifies — the per-episode
  Search button re-queues it.
- Season badges reach **Available** for requesters (series page + My requests) once every aired
  episode of the season has a file.

### Fixed
- Dependency updates clearing all known CVE advisories (phoenix, plug, mint, hpax, swoosh).
- `Show.S01-E02`-style names no longer parse as whole-season packs (and spaced-dash variants
  parse as episodes).
- Short/numeric series titles ("24", "1883") no longer match other shows' release names on the
  free-text indexer path; non-Latin titles fail closed instead of matching everything.
- A transient filesystem error (unreadable/unmounted downloads dir, at any depth) is retried
  instead of permanently parking + blocklisting a good release.
- Season approvals run off the LiveView — a single approve no longer freezes the page during
  TMDB fetches.
- The manual-search panel bands TV releases per episode, so season packs no longer all read
  "out of band".
- `find_files` walks directories instead of globbing, so `{tmdb-N}` library folders are
  searchable.

### Changed
- `docker-compose.yml` binds `127.0.0.1:4000` by default — claim your admin before exposing the
  port (see the compose comments for LAN/proxy exposure).
- **BREAKING (dogfood only — never released):** the anime per-title release-preference overrides
  (audio mode, subtitle languages, embedded-subtitle mode, preferred/blocked groups, fallback delay
  — added on movies/series earlier in this same development cycle) are dropped in favor of the
  global `/settings` → Anime releases values only; anyone testing off `main` who had set per-title
  values loses them. Nothing changes for a tagged release, since this tier never shipped in one.
- **BREAKING (dogfood only — never released):** the global `/settings` → Anime releases **Audio
  mode** setting and the single-axis per-title `anime_audio_mode` override (added earlier in this
  same cycle) are merged into the existing per-title **Audio** pick (`preferred_language`): the
  values are now Original / French / French + original / Any, chosen once per movie/series with
  no global fallback. On the standard (non-anime) path, French + original filters exactly like
  French. The migration best-effort materializes each anime title's previously effective mode onto
  its Audio pick (per-title override first, else the global setting, else unchanged); nothing
  changes for a tagged release.
- The interim anime grab-mapping-correction page is removed; a `Needs mapping` hold now resolves
  through the same `/activity` **Retry import** / **Discard** actions used everywhere else. The
  underlying safety guarantee — an ambiguous batch never stages a file — is unchanged.
- The one-shot `mix cinder.anime.probe` research tool used to make the A0 anime-provider decision
  is removed; the decision itself is recorded in `docs/audits/2026-07-12-anime-provider-contracts.md`.

## [1.0.0] - 2026-07-03

First public release — a single-container, self-hosted replacement for the Sonarr/Radarr/Seerr
loop (movies + TV + multi-user request/approval), validated ahead of launch by a full pre-v1.0
audit of functionality, security, and UI/UX.

### Added
- **Manual search ("Find a better match")** — an interactive release panel for any title: every
  release the indexer returns, with the scorer's verdict (in band / blocklisted / wrong
  resolution…) and the option to **grab any one manually**, overriding the auto-pick. Movies:
  on `/activity` and the library; TV: per season on the series page. Grabbing a replacement for an
  **already-available movie** downloads it in the background (`:upgrading`) and **atomically swaps**
  the library file on completion — any failure reverts to the existing file untouched, and the
  upgrade can be cancelled mid-download.
- **Release blocklist** — a release that terminally fails (confirmed wrong-language import,
  exhausted download retries) is remembered per title and excluded from future searches, so the
  same bad release is not re-grabbed every cycle. A manual **Retry** clears the slate for a fresh
  pick.
- **`move_on_import` setting** — optionally remove the source download after a successful import
  (Usenet only; torrents are never auto-removed so seeding survives).
- **French interface** — full interface localization with a language switcher (English/French);
  translation completeness is enforced by the test suite.
- **Navigation & pages restructure** — `/dashboard` (service health, approval queue, recent
  activity), `/activity` (live movie pipeline + TV downloads; absorbs the old `/status` and
  `/grabs`, which now redirect), and `/library` (browse + manage everything you've added).
- **Admin efficiency** — bulk approve/deny with row selection in the approval queue, and
  **Reopen** (undo) for a mistakenly denied request.
- **UI overhaul** — a unified design system (buttons, badges, forms, empty states), light/dark
  theme toggle, mobile responsiveness across every page, AA-contrast text, and
  accessibility labels on icon-only controls.
- **Cross-filesystem import** — when the download and library live on different filesystems, import
  no longer fails (`:exdev`). Cinder hardlinks when it can and **automatically falls back to an atomic
  copy** (copy into a temp on the library filesystem, then rename into place) when it can't — a common
  self-host layout that previously parked at `:import_failed`. Same-filesystem imports are unchanged
  (instant hardlink). Trade-off: a copy keeps both files (2× disk unless `move_on_import` is on) and
  takes time proportional to file size; see `docs/operating.md`.
- **Import-time audio-language verification** — Cinder probes a completed download's actual audio
  tracks (via `ffprobe`, shipped in the Docker image) before importing and refuses a file whose
  audio is a confirmed different language from the request — the safety net behind the name-based
  filter (à la Radarr's MediaInfo check), for releases whose name lies or omits the language. Covers
  **movies and TV**: a wrong-language movie parks at `:import_failed`; a wrong-language episode file
  in a pack is skipped so that episode re-searches, while correctly-languaged episodes still import.
  Conservative: a language outside the recognized set, an unrecognized audio code, or a missing
  probe all import rather than reject, so a correctly-languaged file is never stranded. Enabled by
  default; set `media_info: nil` (config) to disable.
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
- Per-kind **preferred sources** setting (Blu-ray / WEB-DL / HDTV / …) in `/settings` → Release
  size bands, mirroring preferred resolutions. Empty = accept any source; untagged releases are
  always kept; only a recognized-but-unlisted source is rejected.

### Changed
- The import-time upgrade decision now honors the per-kind **preferred sources** setting
  (`language → resolution → source → size`), consistent with release selection — so when a
  collision occurs at the library destination, a same-resolution better-source release replaces an
  imported lesser-source file instead of being discarded on a size tie. Persists a new
  `imported_source` per movie/episode (additive migration; existing rows rank a missing source
  last, and are never re-grabbed, so the change is inert for already-imported items).
- **BREAKING (config):** library config keys are regularized per kind — the movie env vars gain the
  `MOVIES_` prefix the TV ones already had:
  - `LIBRARY_PATH` → `MOVIES_LIBRARY_PATH`
  - `PLEX_SECTION` → `MOVIES_PLEX_SECTION` (plus a new `TV_PLEX_SECTION` for the Shows library)

  Stored `/settings` rows are renamed automatically by a migration on upgrade — **but environment
  variables are not.** If you bootstrap via `docker-compose.yml` / `.env`, rename these there
  before redeploying, or the movie library path/section reverts to unset (movie imports then hold,
  shown red on `/status`, until you set it).

### Fixed
- **Low-resolution grabs** — a movie/episode could be grabbed below the requested resolution (e.g.
  asking for a French film in 1080p and getting 480p). The preferred-resolution setting only
  *re-ordered* candidates, so when the only in-band release was a lower resolution it was grabbed
  anyway. It is now a **strict allow-list**: a release whose resolution isn't in
  `movies_preferred_resolutions` / `tv_preferred_resolutions` (default `1080p, 720p`) is rejected
  outright, and an **untagged** release (no resolution in its name) is rejected too. If nothing in
  the allow-list is available, the item parks and re-searches rather than grabbing a worse release —
  widen the list (e.g. add `2160p`) to accept more resolutions. Clearing the field reverts to the
  default `1080p, 720p` allow-list; it does not turn filtering off.
- **Wrong-language matches** — a movie could be grabbed and imported in the wrong language (e.g. a
  French film matched in Hungarian). The release parser recognized only five languages, so a foreign
  dub parsed as "no tag" and the language filter then assumed an untagged release was the title's
  *original* audio. The parser now recognizes ~40 audio-language tags (adapted from Radarr's GPL
  `LanguageParser`; subtitle markers like `ENG.SUBS` / `LATINO.SUBS` are stripped so they don't read
  as audio), and an untagged release is treated as **English** (scene convention) rather than the
  title's original.
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
  - **qBittorrent:** an indexer download URL that redirects to a `magnet:` URI (standard Prowlarr
    behavior for magnet-only trackers) now routes through the magnet add path instead of crashing
    the search unit and re-searching every 5s forever; redirects are followed manually with a hop
    limit, and a redirect to a non-HTTP scheme parks cleanly. Wrong credentials now make **one**
    login attempt per poller per 10 minutes instead of one per item per tick — which tripped
    qBittorrent's consecutive-failure IP ban (default: 5 failures → 1 h) within a single tick.
  - **TV search:** the wrong-series title guard now applies only to free-text (no TVDB id)
    searches, and equates `&`/`and` — previously every season of an ampersand-titled
    ("Law & Order") or AKA-titled ("Money Heist" vs `La.Casa.de.Papel.…`) show was rejected and
    permanently stranded at *couldn't find*.
  - **Cancel races:** every poller write-back is now guarded on the status it read, so cancelling
    a movie mid-search/mid-download can no longer be silently overwritten by the in-flight poller
    unit; a season pack grab links only still-monitored episodes, so **Cancel series** can no
    longer be resurrected by a search that was already in flight; and a TV grab that fails to link
    removes the just-added client download instead of orphaning it.
  - **Approval queue:** approve/deny are now guarded on the row's live status, so two admin
    sessions racing (e.g. a slow bulk approve vs a concurrent deny) can no longer silently reverse
    each other's decision; deleting a request updates other admins' open queues live; a failed
    deny/approve shows an error instead of silently doing nothing; and the per-row deny form has a
    Cancel button.
  - **/activity delete:** deleting a download now also removes it from the download client
    (previously it kept downloading and collided with the automatic re-grab) and reports failure
    instead of always flashing "Download deleted."
  - **Parser:** word-form multi-season packs (`Season 1-5`) are rejected instead of read as
    season 1, and a group fragment like `-S1CK` on a season-less name no longer masquerades as a
    whole-season pack.
  - **Manual-search panel:** verdicts now use your configured size band, preferred
    resolutions/sources, and blocklist — they previously ignored them and contradicted the
    auto-pick.
  - **Settings:** typing a replacement secret while also ticking "Clear saved value" now keeps the
    typed value (previously both were discarded and the service silently lost auth); an unusable
    size-band value (`abc`, `0`) is rejected with an error naming the field instead of persisted
    and silently treated as *no limit*; deleting an episode/season file also resets its search
    counter so a previously parked episode really is re-grabbed.
  - **Health checks:** every probe is bounded (3 s connect + receive, no retries) so a blackholed
    host can't hang "Test connection" for minutes; TMDB/Prowlarr calls no longer triple-retry on
    top of the pollers' own retry budget; an unconfigured Plex shows "Not configured" instead of
    an opaque failure.
  - **UI polish:** warning-level flashes (e.g. a partial season-file delete) now actually render;
    the per-season "Search all missing" button searches only that season (was series-wide);
    dates are localized in French; the admin **Users** nav entry no longer lights up on the
    Account page; a specials-only series shows an explanatory empty state instead of a blank
    list; a TMDB outage on the series page says so instead of "Series not found."; a deleted
    movie's *Available* badge clears live on the discover page.

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

[Unreleased]: https://github.com/simonbrunou/cinder/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/simonbrunou/cinder/compare/v0.7.0...v1.0.0
[0.7.0]: https://github.com/simonbrunou/cinder/releases/tag/v0.7.0
