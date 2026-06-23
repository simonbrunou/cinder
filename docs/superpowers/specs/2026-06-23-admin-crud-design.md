# Admin CRUD on entities — design

- **Date:** 2026-06-23
- **Status:** Approved (brainstorming) → council review → ready for implementation plan
- **Branch:** `feat/admin-crud`

Council review: 3 rounds — sound. R1 reshaped scope (cancel-via-transition,
audit table, deferred on-disk file removal); R2 caught the TV-cancel re-grab, the
`:cancelled` badge-render crash, and the FK/`monitor_strategy` issues; R3 verified
closure and folded in 3 precision edits. No residual disagreement.

## Problem

Cinder has an admin role (`User.role :admin|:user`), a working `require_admin`
on_mount hook + plug, and an `:admin` `live_session`. But admins cannot freely
update/delete the core entities: today they can only *list* users + set a
request quota, *approve/deny* pending requests, and run pipeline ops on the
catalog (watchlist add, status transition, retry). There is no general
edit/delete over the entities, and no admin pages at all for Movies or Grabs.

## Goal & decisions

Curated, hand-rolled admin management screens — **not** a generic data console
and **not** an off-the-shelf admin framework (Backpex/Kaffy). Locked decisions:

- **Style:** purpose-built LiveViews matching the existing no-framework codebase.
- **Entities in scope:** Users, Catalog (Movies & Series + nested Seasons &
  Episodes), Requests, Grabs.
- **Excluded:** `Setting` (already CRUD via `/settings`), `UserToken`.
- **What "CRUD" means per entity** (the request/approval flow already *creates*
  catalog rows, so we don't build dead-weight create paths):
  - **Users:** full C/R/U/D (create is genuinely new).
  - **Movies/Series (+Seasons/Episodes):** R/U/D. *Create* = the existing TMDB
    discovery/add flow.
  - **Requests:** R/D (plus existing approve/deny).
  - **Grabs:** R/D (created by the pipeline only).
- **In-flight items** are **cancelled**, not bare-deleted, and the cancel removes
  the orphaned download from the client (new `Download.Client.remove/2`).
- **On-disk file removal is DEFERRED** to its own spec (see "Deferred"). Delete is
  **DB-record-only**. An already-imported movie/series that is hard-deleted
  leaves its hardlinked library file on disk (orphaned) — accepted, recoverable,
  reaped later by the future unlink feature.
- **Audit logging:** a `admin_audit` table records every destructive admin action
  (who/what/when).

## Approach (A — extend in place, add the two missing pages)

The `:admin` `live_session` already owns `/users`, `/requests`, `/series/:id`.
Add the missing CRUD to those; add `/movies` (`MoviesLive`) and `/grabs`
(`GrabsLive`) to the same session. `require_admin` + `require_setup` already gate
it — no new auth scheme.

**Routing correction (council):** `/series` (`SeriesLive`) is in the
**`:authenticated`** session — a non-admin product view. Admin series-management
controls are **gated in-component** for admins only (precedent: commit `bfb5537`);
the route is *not* moved to `:admin`. `SeriesDetailLive` (`/series/:id`) is
already `:admin`.

Rejected: a `/admin/*` namespace (the `:admin` `live_session` already gates by
role, not URL); a single generic config-driven CRUD LiveView (entities diverge —
cancel-vs-delete, last-admin guard, approve/deny — abstraction leaks); Backpex
(steel-manned and rejected — the destructive edges are bespoke and the codebase
is deliberately framework-free).

## Architecture & routing

| Route          | LiveView           | Change                                    |
|----------------|--------------------|-------------------------------------------|
| `/users`       | `UsersLive`        | extend (CRUD + guards)                    |
| `/requests`    | `RequestsLive`     | extend (list-all + delete)                |
| `/series`      | `SeriesLive`       | extend; admin controls gated in-component |
| `/series/:id`  | `SeriesDetailLive` | extend (edit/cancel/delete)               |
| `/movies`      | `MoviesLive`       | **new** (`:admin`)                        |
| `/grabs`       | `GrabsLive`        | **new** (`:admin`)                        |

## Shared infrastructure (Phase 0 — built first, used by every entity)

1. **`Cinder.Audit` + `admin_audit` table.** Columns: `id`, `actor_id`
   (FK users, `:nilify_all`), `action` (string), `entity_type`, `entity_id`,
   `detail` (`:map` — ecto_sqlite3 stores JSON TEXT, supported), `inserted_at`.
   `Audit.log(actor, action, entity, detail)`. **The audit write happens inside
   the same `Repo.transaction` as the destructive op, after the guard passes,
   before commit** — so a rolled-back (e.g. last-admin) delete leaves no orphan
   audit row.

2. **`:cancelled` status — Movie only.** Add `:cancelled` to `Movie.@statuses`.
   **Episodes have NO status enum** (state derived from `file_path`/`grab_id`) —
   there is no episode status to add `:cancelled` to; TV cancel is handled
   differently (see Catalog API). **Required co-edit (round-2 crash finding):**
   `status_badge_class/1` in `core_components.ex` has **no catch-all** — add a
   `:cancelled` clause, or `/status`, `/`, `/my-requests` raise
   `FunctionClauseError` *at render* (compile/credo won't catch this; a LiveView
   test rendering a cancelled badge will). Audit the status-derived display sites
   (`status_live.ex @parked`, `watchlist_live.ex` composite status) for the new
   value.

3. **Delete broadcast events + subscriber handlers.** `Catalog.transition` (the
   single state-change choke-point) cannot express a *delete*. Add
   `{:movie_deleted, id}` on `"movies"` and `{:series_deleted, id}` on `"series"`.
   Add `handle_info` clauses to **every** subscriber so open views drop the row:
   - `"movies"`: `StatusLive`, `WatchlistLive`, `MyRequestsLive`.
   - `"series"`: `SeriesDetailLive`, `CalendarLive`.
   `StatusLive` currently has **no catch-all `handle_info`**; it — and any view we
   newly subscribe (e.g. `SeriesLive`, if it subscribes `"series"` to drop deleted
   rows live) — must get a catch-all so an unmatched topic message can't crash it.
   (`UsersLive` has no movie/series topic and no `{:user_*}` event is defined, so
   it gains no subscription.) `:cancelled` itself is a normal transition → already
   broadcasts `{:movie_updated, _}`.

4. **`Download.Client.remove/2` callback.** `remove(id, opts) :: :ok | {:error, term}`
   where `id` is the tracked download id (qBit infohash / SAB nzo_id, as passed to
   `status/1`). **Idempotent: an unknown/missing id returns `:ok`** (the download
   may have auto-removed on completion). Callers **skip it when `download_id` is
   nil**. `opts` carries `delete_files:` (default **true** for cancel — an active,
   pre-`:available` item has no library copy yet, so its partial download is junk).
   Implement in the qBittorrent impl (`POST /api/v2/torrents/delete`,
   `hashes` + `deleteFiles`) and SABnzbd impl (`mode=queue|history&name=delete`
   + `del_files`), plus the Mox mock. Client I/O stays **outside** the DB
   transaction (existing rule for external I/O).

5. **Cancel active-set predicate.** `transition/2` does **not** validate
   transitions, so "legal transition into `:cancelled`" must be an explicit guard.
   Define `@cancellable_movie_statuses` (`:requested, :searching, :downloading,
   :downloaded`) — mirror `retry_movie/1`'s `@retryable` pattern. `cancel_movie/2`
   returns `{:error, :not_cancellable}` for anything else. **`delete_movie/2`
   shares this predicate**: a movie with a non-nil `download_id` in an active
   status must be cancelled (which removes the client download), not bare-deleted
   — otherwise delete orphans the download.

6. **Transactional guard helper.** Last-admin / self-delete guards run inside one
   `Repo.transaction` with a **post-write re-count** (write/delete, then
   `count_admins/0`, rollback if it would hit zero) — the precedent is the
   request-quota race in `requests.ex` (`create_pending/2`). Guards live in the
   **context** and use the server-side `current_scope` actor, never a client
   `phx-value` id.

7. **FK cascade tests + pin the pragma.** `delete_user` (cascade `requests.user_id
   :delete_all`) and `delete_series` (cascade seasons/episodes `:delete_all`)
   depend on SQLite FK enforcement — which is **already ON** by the ecto_sqlite3 /
   exqlite default (applied as `foreign_keys: :on` on every connect; not set in any
   config file, but on regardless). Deliverable: **explicit cascade tests** for
   `delete_user`/`delete_series` (don't trust the implied green add-path tests),
   plus **pin `foreign_keys: :on`** in the Repo config for the same
   defend-against-dep-default-drift reason `journal_mode`/`busy_timeout` are pinned.

## Context API additions

Each destructive op takes the acting admin and writes an audit row (in-txn); each
broadcasts where open views must refresh. **Status changes route through
`Catalog.transition`**; only non-status edits and deletes get new functions.

**`Cinder.Accounts`**
- `create_user/1` — sets `role` + `confirmed_at` via `put_change` (not castable);
  validations via `registration_changeset`.
- `update_user_role/2` — refuses to demote the **last admin** (`{:error,
  :last_admin}`), transactional.
- `admin_update_email/2` — direct edit (reuse `email_changeset`, no token round-trip).
- `admin_reset_password/2` — sets password directly and **expires the target's
  tokens** via `update_user_and_delete_all_tokens/1`.
- `delete_user/1` — `Repo.delete` (cascades requests; nilifies `approved_by_id`);
  refuses **last admin** and **self-delete**, transactional. Audit `detail`
  records the deleted email + that the user's request history cascaded.
- `count_admins/0`.

**`Cinder.Catalog`**
- `update_movie/2` — metadata edit (reuse `Movie.changeset/2`; status stays in
  `transition`).
- `update_series/2` — metadata edit via **its own changeset** that **does NOT
  cascade `monitor_strategy`** to existing seasons/episodes (the request flow sets
  `monitor_strategy: :none` while flipping per-season `monitored: true`; cascading
  strategy would clobber it — `refresh_changeset` already excludes it for this
  reason). Per-season/episode monitoring stays on the **existing**
  `set_season_monitored/2` / `set_episode_monitored/2` writers.
- `cancel_movie/2` — guard `@cancellable_movie_statuses`; `Client.remove/2` (if
  `download_id`); `transition` to `:cancelled`.
- `cancel_series/2` — **no episode status to set.** Collect the series' grabs via
  the episode join (**all grab states**, incl. `:downloaded` awaiting import — the
  same collection `delete_series` uses, **not** `list_grabs_downloading`, or a
  `:downloaded` grab survives and re-imports next tick). For each: `Client.remove/2`
  (if `download_id`) then `delete_grab/1`; then `set_*_monitored(false)` on the
  affected seasons/episodes so the TV poller's `wanted_episodes` does **not**
  re-grab. Broadcast `{:series_updated, id}`.
- `delete_movie/2` — DB delete (after cancel for active rows); broadcast
  `{:movie_deleted, id}`.
- `delete_series/2` — **reap grabs first** (before episode cascade removes the
  `episode.grab_id` link): collect the series' grabs via the episode join,
  `Client.remove/2` + `delete_grab/1` each, then `Repo.delete(series)` (seasons/
  episodes cascade at the DB). Broadcast `{:series_deleted, id}`.
- `list_grabs/0` — all grabs ordered, preloaded `episode → season → series`.
  `delete_grab/1` **already exists**.

**`Cinder.Requests`**
- `list_requests/0` — all requests with status, preload `:user`.
- `delete_request/2` — audited. **Accepted behavior (warn in UI, not "handled"):**
  there is no FK request→movie/series, so deleting a request does **not** remove a
  catalog row it spawned; and deleting a non-pending request re-opens the partial
  unique `requests_pending_unique`, allowing the title to be requested again.

## Per-entity behavior

- **Users (`/users`):** create; edit email; toggle role; quota (exists); reset
  password (expires sessions); delete. Last-admin / self-delete refused (flash).
- **Movies (`/movies`):** list w/ status; edit metadata; cancel (active →
  `:cancelled` + client remove); delete (DB row).
- **Series (`/series` admin section, `/series/:id`):** edit; cancel (remove grabs
  + unmonitor); delete (cascade + grab reaping); per-season/episode toggles via
  existing writers.
- **Requests (`/requests`):** list all w/ badges; approve/deny; delete (with the
  orphan/re-request warning).
- **Grabs (`/grabs`):** list newest-first w/ derived series/episode + status; delete.

## Delete / cancel UX

- Destructive actions use an **in-LiveView confirm step** — an assign-based panel
  mirroring `RequestsLive`'s existing `denying` pattern (not `data-confirm`/JS).
- If an item has an active download, the confirm offers **cancel** (transition/
  reap + client remove); otherwise **delete** removes the DB row. Delete and cancel
  share the active-set predicate so delete can't orphan a live download.

## Authorization & safety guards

- Cannot delete/demote the **last admin** (`count_admins/0`, transactional).
- Cannot delete **your own** account.
- Guards enforced in the **context** (forged `phx-value` ids can't bypass).
- Non-admins blocked by `require_admin`; add a LiveView authorization test for
  **every** new/changed admin surface (`/movies`, `/grabs`, the in-component
  series-admin gating).

## Testing (TDD)

`mix test` (compile `--warnings-as-errors`, `format --check-formatted`,
`credo --strict`, suite) is the gate and must stay green. Tests never hit the
network or disk (Mox — incl. the new `Client.remove/2` mock).

- **Context tests first:** role toggle + last-admin guard; self-delete guard
  (both transactional); **`delete_user`/`delete_series` cascade tests** (FK-pragma
  proof); `delete_series` grab-reaping + ordering; `cancel_movie` guard + `:cancelled`
  + `Client.remove` expectation; `cancel_series` removes grabs + unmonitors so
  `wanted_episodes` returns nothing; `Client.remove` idempotent on unknown id +
  skipped on nil; `update_series` does not cascade `monitor_strategy`; request
  delete; **audit row written (in-txn) per action**.
- **LiveView tests:** each CRUD/confirm interaction; **a cancelled-movie badge
  renders** (catches the `status_badge_class` crash); authorization redirect of a
  non-admin on every new/changed surface.
- **credo/warnings traps:** `@moduledoc` on new modules; alias ordering; no unused
  vars/aliases; `@impl true` on new behaviour impls; `Application.fetch_env!/2`
  (not `compile_env!`); keep the catch-all `handle_event/3`; add catch-all
  `handle_info/2` to newly-subscribed views.

## Implementation phases (one per session)

- **Phase 0 — Shared infra:** `admin_audit` + `Cinder.Audit`; `:cancelled` on
  Movie + `status_badge_class(:cancelled)` + status-site review; delete broadcast
  events + `handle_info` across all subscribers (+ catch-alls); `Download.Client.remove/2`
  (+ qBit + SAB impls + mock); cancel active-set predicate; transactional guard
  helper; **`foreign_keys = ON` verification + cascade tests**. Tests.
- **Phase 1 — Users:** `Accounts` CRUD + transactional guards + audit; extend
  `UsersLive`. Tests.
- **Phase 2 — Catalog R/U/D + cancel:** `update_/cancel_/delete_movie`,
  `update_/cancel_/delete_series` (grab reaping + unmonitor), broadcasts + audit;
  new `MoviesLive`; admin-gated controls in `SeriesLive`/`SeriesDetailLive`; new
  `GrabsLive`. Tests.
- **Phase 3 — Requests:** `list_requests/0` + `delete_request/2` (+ orphan/
  re-request warning) + audit; extend `RequestsLive`. Tests.

## Deferred (own future spec)

- **On-disk media-file removal.** Requires: persist the library destination on
  movie import (movie currently stores the *download* path, not the library file;
  `import_movie` returns the dest but the poller discards it); a `Filesystem.rm/1`
  **and** a link-count read callback; path-confinement; media-server rescan; typed
  confirmation. The hardlink **link-count "only-copy" check is a heuristic, not a
  guarantee** (`nlink ≥ 2` proves *a* second link exists, not that it's the
  download) — this feature needs an honest safety model, so it gets its own spec.

## Open items to verify during planning (not blockers)

- Exact qBit/SAB delete-endpoint parameter names + response shapes (validated
  against a live client in the Phase-5-style integration check; first build
  follows the API docs).
- `Movie.@statuses` exact location/shape and which transitions UI offers into
  `:cancelled`.
- Confirm the `foreign_keys` pragma site (Phase-0 gate, above).

## Success criteria

- An admin can: create/edit/role/reset-password/delete Users (never the last
  admin, never self); edit/cancel/delete Movies & Series (cancel removes the
  client download; series cancel/delete reaps grabs and won't re-grab; series
  delete cascades); list/delete Requests (with the orphan/re-request warning);
  list/delete Grabs.
- Cancel/delete never leaks an orphaned client download. (On-disk library files
  are intentionally left for the deferred unlink feature.)
- Every destructive action writes an `admin_audit` row (in-transaction).
- Adding `:cancelled` does not crash any status badge render.
- Non-admins cannot reach any of these screens.
- `mix test` is green (warnings-as-errors + format + credo --strict + suite).
