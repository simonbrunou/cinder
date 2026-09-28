# Subtitles engine — design (2026-07-07)

## Goal

Fetch subtitle sidecar files (`.srt`) for imported movies and episodes from OpenSubtitles.com,
in the household's chosen languages, so playback has subtitles without running a separate service
(Bazarr) or relying on the media server's own plugin. Two triggers: at import time, and via a
periodic retry sweep that backfills subtitles uploaded after a release landed.

Scope is a self-contained engine behind Cinder's usual behaviour seam. It is **best-effort**: a
subtitle fetch never blocks or fails a video import, mirroring the existing best-effort media-server
scan (`Cinder.Library.scan/2`).

## Decision record

Settled in brainstorming (2026-07-07):

- **Build our own engine, not Bazarr.** Bazarr has no standalone folder-scan mode — it reads its
  media list from Sonarr/Radarr's API, which Cinder doesn't expose. So a Bazarr sidecar would
  require also running Sonarr/Radarr against the same library, defeating the point of Cinder
  replacing them. The media-server plugin (Plex/Jellyfin) remains the zero-code alternative and is
  documented in `docs/operating.md`; this engine is for households that want subtitles owned by
  Cinder itself.
- **One provider: OpenSubtitles.com REST API.** Behind the required behaviour seam (Cinder
  convention), but no multi-provider registry — YAGNI until a second provider is actually wanted.
- **Global subtitle-language list, not per-item.** Subtitles are a different axis from the per-title
  *audio* preference (you often want `fr` subs on `en` audio). A single global
  `subtitle_languages` setting (e.g. `en,fr`); **blank = feature off** so the engine is inert until
  opted into.
- **id-based search, not moviehash.** Movies carry `imdb_id`/`tmdb_id`, episodes carry the series
  `tmdb_id` + season/episode — precise enough to search without fuzzy title matching. Ceiling:
  sync can drift on odd framerates because an id match returns subtitles for the *title*, not the
  specific release. `ponytail:` moviehash (size + first/last 64 KB checksum) is the upgrade path if
  drift is observed; deferred because it needs a read-bytes seam we don't have.
- **Sweep derives "needs subtitles" from the filesystem — no schema.** No `subtitles` table, no new
  writer through `Catalog.transition`. For each available movie / episode-with-`file_path`, the
  sweep checks whether `<basename>.<lang>.srt` exists per wanted language; missing → fetch. This
  matches the derived-state episode model ("never a bare status sweep"). Self-correcting: delete a
  sidecar and it re-fetches; add a language and it backfills.
- **No give-up marker.** A still-missing subtitle re-searches every sweep. Cheap, because failed
  *searches* don't consume the daily *download* quota (below). `ponytail:` add a per-item marker
  only if search rate-limits actually bite.
- **No forced / SDH variants.** Plain `<basename>.<lang>.srt` only. Hearing-impaired and
  machine-translated results are excluded when picking.

## OpenSubtitles.com API facts (shape the design)

- **Auth:** an **API key** (header `Api-Key`) authenticates search; the **`/login`** endpoint
  (username + password) returns a **JWT** required as `Authorization: Bearer <token>` for the
  `/download` endpoint. A `User-Agent` header is required on all calls.
- **Quota:** free account = **20 downloads/day** (anon = 5). The 20/day cap is on **downloads**
  (converting a subtitle to a fetch URL via `/download`), *not* on `/subtitles` search. Search has
  a request rate-limit only. So re-searching subtitle-less items is quota-free; the daily cap
  naturally paces how many *new* subtitles land per day. A `406`/quota-exceeded on download logs
  and stops fetching for that tick.
- **Endpoints used:** `POST /login` (token), `GET /subtitles` (search by `imdb_id` / `tmdb_id` /
  `parent_tmdb_id`+`season_number`+`episode_number`, `languages`), `POST /download` (`file_id` →
  temporary URL), then a plain GET of that URL for the `.srt` bytes (request `sub_format=srt`,
  utf-8; `ponytail:` write bytes as-is, revisit encoding only if a garbled file shows up).

## Architecture

Everything new lives under a new `Cinder.Subtitles` namespace, reached from `Cinder.Library` at
the two existing import choke-points. No change to the movie/TV pipeline state model.

### Components

**`Cinder.Subtitles.Provider`** (behaviour) — the network seam, config-resolved at runtime
(`Application.fetch_env!(:cinder, :subtitles_provider)`), so tests use a Mox mock and never hit the
network. Callbacks:

```elixir
@callback search(criteria :: map()) :: {:ok, [result :: map()]} | {:error, term()}
@callback download(file_id :: term()) :: {:ok, binary()} | {:error, term()}
@callback health() :: :ok | {:error, term()}
```

`criteria` carries `%{imdb_id, tmdb_id, season, episode, languages}` (nil fields omitted from the
query). A `result` carries at least `%{file_id, language, downloads, hearing_impaired, ai_translated}`.

**`Cinder.Subtitles.Provider.OpenSubtitles`** (impl) — thin `Req` client. Owns login/token
handling internally: JWT cached in `:persistent_term` with its expiry, re-login on 401.
`ponytail:` global token, single-instance so no coordination needed.

**`Cinder.Subtitles`** (context) — owns pick-best + write-sidecar logic (kept out of the impl so
it's testable and tunable):
- `fetch_missing(record, dest_path)` — for each configured language whose sidecar is *absent*,
  search → filter to that language, drop hearing-impaired & ai-translated → pick highest
  `downloads` → `download` → write `sidecar_path(dest_path, lang)` via the `Filesystem` behaviour.
  Returns `:ok` always in normal operation; the caller wraps it best-effort regardless.
- `sidecar_path(dest_path, lang)` — replace the video extension with `.<lang>.srt` in the same
  directory.
- `wanted_languages()` — parse the `subtitle_languages` setting (csv → downcased list); `[]` when
  blank (feature off — every entry point short-circuits).

**`Cinder.Subtitles.Sweeper`** (GenServer) — self-scheduling, mirrors `Cinder.Catalog.Refresher`:
12h interval (module config, not `/settings` — no int-coercion seam there), gated by the existing
`:start_poller` flag, supervised after PubSub. Each tick: if `wanted_languages() == []` do nothing;
else list `:available` movies with a `file_path` and episodes with a `file_path`, compute which
`(item, lang)` sidecars are missing, and call `fetch_missing` throttled (spaced requests to respect
the search rate-limit; downloads bounded by the daily quota, stop the tick on `406`).

### Filesystem behaviour addition

`Cinder.Library.Filesystem` gains **`write(path, content) :: :ok | {:error, term()}`** (the sidecar
write). Existence is checked with the existing `lstat/1`. Mox auto-covers the new callback.

## Data flow

**Import-time (movie).** `import_movie/2`, after `place` succeeds and before returning
`{:ok, dest, quality}`, calls `fetch_subtitles(movie, dest)` — a private best-effort wrapper around
`Cinder.Subtitles.fetch_missing/2` with the same `rescue`/`catch` + log-only shape as `scan/2`.
Runs alongside (not gating) the existing scan.

**Import-time (episodes).** `do_import_episodes/3`, after `link_all` returns `{:ok, imported}` and
the scan fires, iterates `imported` (`{episode_id, dest_path, quality}`) and calls the same
best-effort wrapper per imported file, building criteria from the episode's series `tmdb_id` +
season/episode. (Series carries no `imdb_id` — it was dropped at M4a — so episode search is
tmdb-only.)

**Sweep.** As above — the same `fetch_missing` path, on a schedule, for the whole library.

**Criteria construction.**
- Movie: `%{imdb_id: movie.imdb_id, tmdb_id: movie.tmdb_id, languages: wanted}` (both ids passed;
  the impl prefers `imdb_id`).
- Episode: `%{tmdb_id: series.tmdb_id, season: season_number, episode: episode_number,
  languages: wanted}` — the impl maps `tmdb_id` + `season`/`episode` to the API's
  `parent_tmdb_id` + `season_number` + `episode_number`.

## Configuration

Four new `Cinder.Settings` registry entries (DB-overlaid on env bootstrap, per the store's existing
pattern — **no new env vars beyond the bootstrap keys the loader already supports**):

| key | secret? | shape | notes |
|---|---|---|---|
| `subtitle_languages` | no | csv → `[String.t()]` | blank = feature off |
| `opensubtitles_api_key` | yes | string | Cloak-encrypted at rest |
| `opensubtitles_username` | yes | string | Cloak-encrypted at rest |
| `opensubtitles_password` | yes | string | Cloak-encrypted at rest |

Gated per the settings-field-gates rule: `SettingsLabels.known/0` entries, FR gettext strings, and
`settings_test` `@env_keys` all updated. A new `/settings` group ("Subtitles") with a per-service
**Test connection** using `Health.check_service(:subtitles)`.

## Health

`Provider.health/0` (reachability + auth: a cheap authenticated call, 3s connect/receive timeouts
per the health convention) wired into `Cinder.Health.check_all/0` and the per-service
`check_service(:subtitles)` used by the Test button. Skipped/`:not_configured` when no api key is set.

## Testing

- **Context:** provider mocked (Mox), Filesystem mocked. Assert: correct language filtering,
  hearing-impaired/ai-translated excluded, highest-`downloads` picked, sidecar path + content
  written, and a language whose sidecar already exists is **skipped** (no `download` call).
- **Import-time best-effort:** provider returns `{:error, _}` (or raises) → `import_movie` still
  returns `{:ok, dest, quality}` and the movie reaches `:available`. Same for an episode import.
- **Sweep:** mocked FS reports a missing sidecar for a wanted language → asserts a fetch+write;
  reports an existing sidecar → asserts skip; `wanted_languages() == []` → asserts no provider call.
- **Provider impl:** unit-test request building (correct query params per id/season/episode) and
  token re-login on a 401, with `Req.Test` stubs — no live network.

Every new behaviour gets a test; `mix test` (the alias: compile-warnings-as-errors + format + credo
--strict + suite) stays green.

## Cuts & ceilings (ponytail ledger)

- One provider (OpenSubtitles) — no multi-provider registry.
- Global language list — no per-item subtitle override.
- id-based search — sync-drift ceiling; **moviehash is the upgrade path**.
- No forced / SDH variants; HI + machine-translated excluded when picking.
- Schema-free — sweep derives from the filesystem; no `subtitles` table, no give-up marker.
- Best-effort throughout — a subtitle failure never affects the video import.

All reversible; none blocks a later moviehash / per-item / multi-provider extension.
