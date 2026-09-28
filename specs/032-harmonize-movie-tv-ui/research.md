# Harmonize movie & TV UI/UX — design

**Date:** 2026-07-09
**Status:** approved

## Problem

Movies and TV shows drifted apart in the UI even after the earlier UX consolidation
(shared `media_card` / `status_badge` / `empty_state` / `confirm_action` /
`language_select`, unified `/`, `/library`, `/activity`, nav). Residual differences:

- **Library grid:** movie cards show a pipeline status badge; series cards show a plain
  *"Configure monitoring →"* text link — no status indicator.
- **Discover grid:** movie cards show per-title request state (Pending/Approved/Available);
  TV cards always show only *"View seasons"*, even after a season is requested/available.
- **Where management lives:** movie actions are scattered — edit/cancel/delete on `/library`,
  retry / "Find a better match" / cancel-upgrade / language on `/activity`, while `/movies/:id`
  is read-only. A series does everything on one page, `/series/:id`. So clicking a series poster
  opens a management console; clicking a movie poster opens a read-only dead-end.
- Detail-page poster size differs (`w-40` movie vs `w-24` series).

## Principle

Mirror what series already does:

- **`/library`** = roster + quick Cancel/Delete, drill into detail.
- **`/{movies,series}/:id`** = the console (everything about one title).
- **`/activity`** = live in-flight watch board (status, no management).

## Changes

### 1. `/movies/:id` (`MovieDetailLive`) → console

Restructured to mirror `SeriesDetailLive`. Gains:

- Action bar: **Edit / Cancel / Delete** (Cancel shown only when `Catalog.cancellable?/1`,
  else Delete) — moved from `/library`.
- Inline **Edit form** (title/year) + **confirm dialogs** for cancel/delete (delete carries the
  "also delete file from disk" checkbox).
- **Language select** (`Catalog.set_movie_language/2`) — moved from `/activity`.
- In the file/pipeline area: **Retry** (parked), **Find a better match** (inline
  `ManualSearchComponent`, `mode: :movie`), **Cancel upgrade** (upgrading) — moved from `/activity`.
- Keeps existing metadata + overview + "Downloaded file" panel.

All writes use existing `Catalog` functions (`update_movie`, `cancel_movie`, `delete_movie`,
`retry_movie`, `manual_grab_movie`, `abort_upgrade`, `set_movie_language`). The
`{:manual_grab, :movie, movie, release}` message handler moves here from `ActivityLive`.
`/movies/:id` is already in the `:admin` live_session — no gating change.

### 2. `/library` (`LibraryLive`) → identical cards

- **Movie card:** poster (→ `/movies/:id`) + status badge + `[Cancel] [Delete]`. Drop the inline
  Edit form + its handlers (`edit` / `save` / `cancel_edit` / the `editing`/`form` assigns).
- **Series card:** poster (→ `/series/:id`) + **`status_badge kind={:monitored}`** (new) +
  `[Cancel] [Delete]`. Drop the *"Configure monitoring →"* text.
- End shape for both: `poster(→detail) + badge + Cancel/Delete`.

### 3. `/activity` (`ActivityLive`) → status board only

- **Movie rows:** title + status badge + link to `/movies/:id`. Remove inline Retry /
  Find a better match / Cancel upgrade / language dropdown / `manual_search` toggle /
  `{:manual_grab, :movie, …}` handler / `searching_movie_id` assign.
- **Downloads (grabs):** unchanged (Delete stays — it cancels an in-flight download).

### 4. Cosmetic parity

- **Discover** TV cards get a per-title state badge computed from the current user's season
  requests + `Catalog.available_season_keys/0`, using the same precedence as movies
  (Available > Pending/Approved > Denied); falls back to "View seasons".
- Detail-page poster size aligned (both `w-40`).

## Explicitly out of scope

- Episode file-info stays a terse `1080p · 2.1 GB` chip (it's a list row, not a hero) — no
  per-episode file panel.
- No changes to `MyRequestsLive` (already type-consistent).
- No pipeline / approval-gate / `Catalog.transition` changes — pure UI relocation, so the
  security invariants are untouched.

## Tradeoff (accepted)

Retry moves off the `/activity` board to `/movies/:id`. Retrying a parked movie is now one click
into detail — consistent with how a parked *episode* is retried on `/series/:id` today.

## Tests

Relocate the moved-action tests from `LibraryLive` (movie edit) and `ActivityLive` (retry, manual
search, language, cancel-upgrade) to `MovieDetailLive`, and add coverage for the new console.
Update `LibraryLive`/`ActivityLive` tests to the reduced surface. Add a Discover test for the TV
per-title badge.
