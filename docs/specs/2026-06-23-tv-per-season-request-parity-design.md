# TV per-season request/approval parity — design

**Date:** 2026-06-23
**Status:** approved (brainstorm), pre-implementation

## Context

Cinder replaces Radarr + Sonarr + **Seerr**. Movies are a full multi-user feature: any user
searches on `/`, hits **Request**, a non-admin's request becomes `:pending`, an admin
approves/denies, quota applies, it shows in **My requests** with a per-title badge, and approval
find-or-creates the movie at `:requested` so the poller grabs it. The approval gate lives in the
data model (`Cinder.Requests` + the `requests` table) — security-critical.

TV never got this. TV is **admin-only and admin-direct**: `/series` (and `/series/:id`) sit in the
`:admin` live_session, and adding a series calls `Catalog.add_series_to_watchlist/2` straight away
— no request, no approval, no quota, no requester visibility. That second-class state is the "TV
beta" we are removing. The TvPoller already auto-grabs the wanted episodes of any monitored series,
so an approval flow is consumable end-to-end today.

**Goal:** make TV iso-perimeter with movies for the multi-user request loop — but at **season**
granularity (the natural unit for a series; a user requests "Show, Season 2", not a whole show or a
single episode).

## Decisions (settled in brainstorm)

- **Full multi-user parity** for TV (not just discovery/UX): request → approve → quota →
  My-requests → badge → grab.
- **Per-season** request unit (not whole-series, not per-episode).
- **Parallel pages**: movies stay on `/` (untouched); the TV pages become user-facing. No unified
  discovery grid (the validated movie discovery LiveView is not rewritten).
- The `Requests` gate stays the **single polymorphic choke-point** — dispatch on `target_type`, do
  not fork a parallel TV request path.

## Out of scope

Per-*episode* requests (season is the floor); a unified movie+TV discovery grid; TV on the `/status`
dashboard (admin pipeline view — TV management lives on `/series/:id` + `/calendar`); a
"request the whole series" convenience that fans out to N season requests (can be added later).

## Architecture

### 1. Data model — one additive migration

`requests` already carries `target_type` / `target_id` / `title` / `year` / `poster_path`. Add:

- `season_number :integer` (nullable — null for movies, set for seasons).
- `target_type` allowlist (`Request.create_changeset` `validate_inclusion`) gains `"season"`.
  A season request is `target_type: "season"`, `target_id: <series tmdb_id>`, `season_number: N`,
  with `title`/`year`/`poster_path` carrying the series' display fields.

**Uniqueness.** The existing unique index `requests_user_id_target_type_target_id_index` would
collapse all of a user's season requests for one show into a single row. Replace/augment it with a
**`COALESCE(season_number, -1)` expression unique index** on
`(user_id, target_type, target_id, COALESCE(season_number, -1))` so movies keep their dedup (a movie
row's `-1` is constant per `target_id`) and `S1`/`S2` of the same show are distinct. `create_changeset`'s
`unique_constraint/2` `:name` is updated to the new index name. (Migration recreates the index.)

### 2. `Cinder.Requests` — dispatch on approval

`create_request/2` is already target-agnostic (routes non-admin → `create_pending`, admin /
`auto_approve_all` → `create_approved`; `over_quota?/1` counts pending rows per user — unchanged,
each season request counts). The one movie-specific step is in `create_approved`/`approve_request`:
today `Catalog.find_or_create_at_requested(movie_attrs_from(request))`. Dispatch on
`request.target_type`:

- `"movie"` → `Catalog.find_or_create_at_requested(...)` — **unchanged**.
- `"season"` → `Catalog.find_or_create_series_at_requested(request.target_id, request.season_number)`.

`announce_approved/1` already fires `{:request_approved, request}` generically (Notifier + the
requests PubSub topic) — works for seasons (the Notifier.Log message uses `request.title`).

**Security invariant (regression test):** a non-admin season request writes only a `:pending` row —
no series, no monitored season — until an admin approves. Mirrors the movie security test.

### 3. `Cinder.Catalog` — season creation on approval

New `find_or_create_series_at_requested(tmdb_id, season_number)`:

1. Find the series by `tmdb_id`; if absent, create the season/episode tree from TMDB (reuse
   `add_series_to_watchlist`'s persistence — the 1+N TMDB fetch).
2. Set **only** the requested season `monitored: true` and its episodes monitored (per the existing
   `set_season_monitored/2` cascade); leave other seasons as-is. A later approval for another season
   just flips that one on.
3. Broadcast on the existing `"series"` topic so open views update.

Run the TMDB-fetch path **off-process** (a supervised `Task`, mirroring `SeriesLive`'s existing
`start_async` add) so the admin's approve action doesn't block on 1+N TMDB calls; the request flips
`:approved` synchronously, the series/season materializes shortly after, and the TvPoller grabs the
season's wanted episodes on its next tick (no poller change). If the series already exists, the
monitor flip is a cheap synchronous write.

Monitoring exactly the requested season (not `:all`) is both correct-to-intent and avoids the
whole-series flood the `monitor_strategy: :future` default was created to prevent.

### 4. Discovery — a dedicated user-facing discovery page (two single-purpose surfaces)

A user requesting a season of a show *not yet in the library* has no local series to view — its
season list lives only in TMDB. So discovery and admin-management are **separate pages**, avoiding
in-page role-gating:

- `/series` (TMDB TV search) moves `:admin → :authenticated`; results link to the discovery page.
  No admin-direct add.
- **New `SeriesDiscoveryLive` at `/series/tmdb/:tmdb_id`** (`:authenticated`, all users): keyed by
  tmdb_id (works for not-yet-added shows), fetches the season list from TMDB
  (`Catalog.tmdb_series/1` → `get_series/1`, one call — season stubs, no episodes), and renders per
  season a **Request** button or the current user's **state badge** (Pending / Approved / Denied).
  Request builds `%{target_type: "season", target_id: tmdb_id, season_number: n, title:, year:,
  poster_path:}` → `Requests.create_request(user, attrs)` (non-admin → `:pending`; an admin's own →
  auto-approved + monitored immediately, like movies on `/`). No monitor toggles here.
- **`/series/:id` (local series, admin-only) is unchanged** — it keeps the per-episode/season
  monitor management. Admins reach it via existing entry points (`/calendar`, direct), and the
  discovery page may show admins a "Manage monitoring →" link when the series exists locally.

### 5. Requester views — per-season, mostly generic

- **`MyRequestsLive`** (`/my-requests`, already authenticated): `list_for_user/1` returns all the
  user's requests; render season requests as "Show — Season N" with the request status. The state
  badge handles a `"season"` target (Pending / Approved / Denied — a season request's terminal
  state is Approved-and-monitored; per-episode availability is surfaced on `/series/:id` +
  `/calendar`, not duplicated here).
- **`RequestsLive`** (`/requests`, admin approval queue): already lists pending requests with
  poster/title target-agnostically; the row label gains the season number.
- Badge/queue updates ride the existing **requests PubSub topic**, like movies.

## Files touched

- `priv/repo/migrations/<ts>_add_season_to_requests.exs` (new) — `season_number` column +
  recreate the unique index as the `COALESCE(season_number,-1)` expression index.
- `lib/cinder/requests/request.ex` — `season_number` field; `create_changeset` cast +
  `validate_inclusion` (`"season"`) + `unique_constraint` name.
- `lib/cinder/requests.ex` — `create_approved`/`approve_request` dispatch on `target_type`;
  a `season_attrs`/dispatch helper alongside `movie_attrs_from/1`.
- `lib/cinder/catalog.ex` — `find_or_create_series_at_requested/2` (find-or-create + monitor one
  season); a thin `tmdb_series/1` passthrough for the discovery page; reuse
  `add_series_to_watchlist` persistence + `set_season_monitored/2`.
- `lib/cinder_web/router.ex` — move `/series` to `:authenticated`, add
  `/series/tmdb/:tmdb_id`; **`/series/:id` stays in `:admin`**.
- `lib/cinder_web/live/series_live.ex` — search grid links to the discovery page; drop admin-direct add.
- `lib/cinder_web/live/series_discovery_live.ex` (new) — TMDB-sourced seasons + per-season Request +
  per-user badge (all users); no monitor toggles.
- `lib/cinder_web/live/series_detail_live.ex` — **unchanged** (admin monitor management).
- `lib/cinder_web/live/my_requests_live.ex` — render season requests + badge.
- `lib/cinder_web/live/requests_live.ex` — season label in the queue row.

## Testing

`mix test` (the alias: compile-as-errors + format + credo --strict + suite) green at every boundary.

- **Security:** a non-admin season request creates a `:pending` row and **no** series / no monitored
  season until an admin approves (the load-bearing regression, mirroring movies).
- **Approval:** request S2 → approve → series exists, **only S2 monitored** (S1 untouched), TvPoller
  grabs S2's wanted episodes (mocked indexer/client).
- **Uniqueness:** two seasons of one show are two distinct requests; re-requesting the same season
  is deduped; movie dedup is unaffected.
- **Quota:** each season request counts; over-quota is rejected.
- **Admin auto-approve:** an admin's own season request creates + monitors the season immediately.
- **Views:** My-requests + the `/series/:id` badge reflect a season's request state; the approval
  queue renders the season.
- **Movie path unchanged:** all existing movie request/approval tests stay green, byte-for-byte.

## Verification (manual / Tidewave)

- A non-admin requests a season on `/series/:id` → it appears in `/my-requests` as Pending and in
  the admin `/requests` queue; the series is not created yet.
- Admin approves → the series + that season are created/monitored; `/calendar` and `/series/:id`
  show the season's episodes; the TvPoller grabs them.
- `grep` shows `/series*` routes under `:authenticated`, monitor toggles gated admin-only.
