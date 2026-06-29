# Design — Manual search + "find a better match"

**Date:** 2026-06-29. Size M. Branch `better-match-manual-search`.
**Driver:** user request — "an option for finding a better match for a movie or a TV show,
and an option for searching for a missing episode or all missing episodes."

> **Review status:** scope locked by a design council (2026-06-29); spec then reviewed by a
> 3-member correctness/feasibility/contrarian council and corrected (see *Resolved review
> findings*, bottom). Claims below are verified against the code at the cited `file:line`.

## Goal

Add two user-initiated actions on top of the automatic pipeline:

1. **Find a better match** — an *interactive* manual search: query the indexer live, list every
   parsed release with its score and the reason the auto-pick would reject it, and let the user
   grab any one (overriding the size band / language / blocklist for selection). For an
   already-`:available` movie this **replaces** the library file with the chosen release. For TV it
   grabs for a season's still-**wanted** episodes — replacing an already-imported episode is
   deferred (see *Deferred*), so on a fully-present season this action is honestly limited and the
   panel says so rather than appearing broken.
2. **Search missing episode / all missing episodes** — *automatic* re-queue of wanted TV episodes
   (per-episode and per-series), picked up by the existing sweep on the next tick.

**Done when:** conventions pass (`mix test` green) + the load-bearing tests in *Testing* pass — in
particular, a manual grab on an `:available` movie swaps the library file through the existing
atomic `replace/2` (including the **different-container** case, which must not leave the old file
behind) and a *failed* upgrade reverts to `:available` with the old file intact and the bad release
blocklisted.

## Reframing — what already exists

Most of this is wiring, not new machinery (verified):

- **The atomic file-swap is already built and dormant.** `Library.import_movie/1` routes a
  same-record collision (tmdb-keyed dest folder) through `place/6` → `do_resolve/6` →
  `Upgrade.better?` → **`replace/2`** (`library.ex:161`): sweep stale temps, link-or-copy the new
  source into a unique `.cinder-tmp-N` on the *dest* filesystem, then `rename` over the old dest —
  crash-safe, never delete-first. Reached today only on an `:eexist` collision; never on an
  `:available` title because nothing re-grabs one. **Caveat (load-bearing):** the collision only
  fires when the new dest filename *exactly* matches the existing one, and `build_dest/3` derives
  the extension from the *source* download (`library.ex:505`). A different-container replacement
  therefore writes a **new** path and leaves the old file — handled explicitly below.
- **The release blocklist already shipped** (the ROADMAP still lists it as "parked"). `BlockedRelease`
  is keyed per `movie_id`/`series_id`; the scorer drops blocklisted titles via `release_blocklist`;
  `retry_movie/1` deliberately *preserves* it. `block_release(%Movie{}, reason)` (`catalog.ex:1061`)
  reads the title off `movie.release_title` and is nil-safe / non-raising.
- **Movie "Search now" for parked titles already exists** as `Catalog.retry_movie/1`
  (`catalog.ex:170`) — the existing Retry button. Reused as-is.
- **The TV sweep is already wanted-driven** (`TvPoller.search_wanted/1`): `wanted_episodes/0`
  (`is_nil(file_path) and is_nil(grab_id)`, monitored, aired) → group by `{series, season}` →
  `Acquisition.best_releases`. "Search missing now" just resets `search_attempts`.

So the genuinely new code is: a manual-search results surface, a "grab this specific release" path,
and **one new movie state (`:upgrading`)** for the replace-available flow plus its consumer edits.

## Scope (locked via council, 2026-06-29)

**Hybrid.**

- **Auto path acts on stuck/wanted titles only**, never `:available`. The scorer has *no cutoff /
  quality-target concept* — an automatic re-search of an available title has no stopping rule (it
  would re-download + re-trigger a media-server rescan every tick for nothing). That stopping rule
  *is* the ROADMAP-parked "Quality upgrades & cutoffs" epic. Keep it parked.
- **Replacing an available file is allowed only through interactive manual search**, where the user
  picks the exact release and confirms "replace." A human picking *is* the stopping rule; the grab
  reuses the atomic `replace/2`.
- **Movies get replace; replacing an already-imported TV episode is deferred** (see *Deferred*) — it
  would put an episode in a `file_path` + `grab_id` dual state that breaks the derived-state model.
- **Manual grab rules:** the panel lists *every* result with its verdict and lets the user grab
  anything (overriding band / language / blocklist for selection). A manual grab that then *fails*
  is still blocklisted.
- **TV bulk:** per-series "Search all missing" + per-episode "Search". No global button.

## Architecture

### User-facing surfaces

| Surface | Control | Behaviour |
|---|---|---|
| Movie views (`activity_live`, `library_live`) | **Search now** | Existing Retry → `retry_movie/1`. Parked movies only (server-guarded). |
| Movie views | **Find a better match** | Opens the manual-search panel. Parked → grab → `:downloading`. `:available` → "Replace current file?" confirm → `:upgrading`. |
| `series_detail_live` | per-episode **Search** | `search_episode_now/1` — zero that episode's `search_attempts` (no-op if it isn't wanted). |
| `series_detail_live` | per-series **Search all missing** | `search_series_now/1` — zero `search_attempts` on every wanted episode of the show. |
| `series_detail_live` | **Find a better match** (per season) | Manual-search panel (season results) → grab → `create_grab` over the season's still-wanted episodes. **Zero wanted episodes ⇒ the panel renders "All episodes present — replacing existing TV files isn't supported yet," not an empty results table.** |

A single shared `CinderWeb.ManualSearchComponent` (LiveComponent) renders the async query + results
table + grab/confirm, mounted in the movie views and `series_detail_live`. The grab *action* is
parametrised (movie single-pick-replace vs TV season-cover), so budget for an internal fork; if it
gets branchy, split into two small components. `start_async`/`handle_async` is the established
pattern (used in `dashboard_live`, `series_live`); the panel must render explicit **loading**,
**zero-results**, and **indexer-error** states (`list_releases` can return `{:error, term}` or `[]`).

### `:upgrading` — the one new state, and every consumer it touches

`:upgrading` means "an `:available` movie is re-downloading a user-chosen replacement; its
`file_path` still points at the live library file." Adding it to `Movie.@statuses` needs **no
migration** — `movies.status` is a plain `:string` column (`priv/repo/migrations/…create_movies.exs:10`)
with no CHECK constraint; the enum is a compile-time list. But it is **not** a one-line change; the
following consumers must be updated (verified — each currently excludes it):

- **`Catalog` cancel / delete-cleanup** — `:upgrading` must abort cleanly, but **do NOT just add it
  to `@cancellable_movie_statuses`** (`catalog.ex:258`): that one list drives *both*
  `cancel_movie/2` → `do_cancel_txn` → `transition(:cancelled)` *and*
  `maybe_cancel_download_for_delete/1`, so membership would send an aborted upgrade to `:cancelled` —
  the exact forbidden outcome (an `:upgrading` movie still has a good library file; it must end
  `:available`). Instead: (a) a **dedicated abort path** for `:upgrading` that removes the new
  download and reverts to `:available` (clearing `download_id`/`download_protocol`/`release_title`,
  mirroring the import-failure revert); and (b) ensure `delete_movie/2` removes the in-flight
  replacement download for an `:upgrading` movie (else it's orphaned) — via its own branch, not by
  widening the shared cancellable list. The "cancel an upgrade ⇒ `:available`, not `:cancelled`"
  rule is the reason a single predicate can't express this.
- **Poller advance sweep** — `advance_downloading` sweeps `list_by_status(:downloading)`
  (`poller.ex:40`); extend it to also pick up `:upgrading`, dispatched to a **separate `advance`
  clause** (below).
- **`dashboard_live` counts** — `@pipeline`/`@parked` (`dashboard_live.ex:15-16`) exclude
  `:upgrading`; add it to the in-flight bucket so an upgrading movie isn't dropped from every count.
- **Badge** — add `badge_spec(:movie, :upgrading)` in `core_components.ex` (a real colour/icon;
  without it the neutral `humanize_status` fallback shows but is unstyled).

### New / changed modules

- **`Cinder.Catalog.Movie`** — add `:upgrading` to `@statuses`.
- **`Cinder.Acquisition`** — `list_releases(imdb_id, opts)` and `list_releases_tv(series, season,
  opts)`: return `[{%Release{}, verdict}]` where `verdict` is `:ok | {:rejected, reason}`, sorted by
  the scorer's ranking key. The verdict is **assembled in `Acquisition`** from three layers, because
  the scorer alone can't produce all reasons:
  - **scorer-layer** (`:out_of_band`, `:blocklisted`, `:wrong_resolution`, `:wrong_source`) — a new
    `Scorer.verdict/2` that runs the existing rule predicates (`within_band?`, `blocked?`/
    `title_blocked?`, `allowed_resolution?`, `allowed_source?`) per-release instead of collapsing to
    `select/2`'s single pick. Must share the predicates with `select/2` so they can't drift.
  - **protocol** (`:wrong_protocol`) — checked in `Acquisition` against `Download.available_protocols()`
    (the scorer has no protocol awareness).
  - **language** (`:wrong_language`) — the parser's name-derived `language` tag vs the
    movie/series preference. **This is an unreliable hint** (a title word can collide; ground truth
    is the post-download audio probe in `Library.verify_audio`); surface it as a soft "language
    mismatch (by name)" note, never as a hard verdict.
- **`Cinder.Download`** — `grab(release) :: {:ok, download_id} | {:error, term}`: add one specific
  release to its protocol's client, carrying the existing `:no_client` guard. Extracted from the
  private `add_to_client/2` (`download.ex:137`) minus its `Catalog.transition` (the caller
  transitions).
- **`Cinder.Catalog`**:
  - `manual_grab_movie(movie, release)` — server-guards on status; **rescues `Ecto.StaleEntryError`**
    (movie deleted between panel-open and grab, like `set_movie_language/2`). Allowed set:
    - `:available` → `Download.grab` + `transition(:upgrading, download_id, protocol, release_title)`
      (the *new* grab's values; `file_path` + `imported_*` left untouched).
    - `@retryable` (`:no_match`/`:search_failed`/`:import_failed`) → `Download.grab` +
      `transition(:downloading, …)` (rides the existing import path; nothing to preserve).
    - **anything else → `{:error, :not_grabbable}`** — rejects in-flight (`:searching`/
      `:downloading`/`:downloaded`), `:upgrading` (blocks double-click), and `:cancelled`.
      "Find a better match" on an in-flight movie requires cancelling first.
  - `manual_grab_tv(series, season_number, release)` — **recomputes the still-wanted episode
    numbers server-side at grab time** (don't trust the panel's snapshot), then `create_grab/4`
    over them (`create_grab` already skips episodes with a `grab_id`, so a mid-action sweep grab
    can't be double-linked). Empty wanted set ⇒ `{:error, :nothing_wanted}`.
  - `search_episode_now(episode)` / `search_series_now(series)` — set `search_attempts: 0` via
    `transition_episode/2` (its `transition_changeset` casts `:search_attempts`, `episode.ex:50`).
    Harmless no-op on a non-wanted episode (`wanted_episodes/0` already excludes it).
- **`Cinder.Library`** — `import_movie/2` with `replace: true`, forcing the `place/6` upgrade thunk
  to `fn -> true end` (a user-chosen replace bypasses `Upgrade.better?`). `import_movie/1` delegates
  with `replace: false`. **`replace: true` must also record `new_q` on the same-inode short-circuit:**
  on a same-fs crash-recovery the new file may already be hardlinked, so `do_resolve/6`'s `si == di`
  branch (`library.ex:99`) returns `existing_quality` (the *old* `imported_*`) — under a forced
  replace it must return `new_q`, else the recovered movie is `:available` with the swapped file but
  stale quality metadata. (Decided fix, not an open edge.)
- **`Cinder.Download.Poller`** — a **separate `advance` clause for `:upgrading`** (below).
- **`Cinder.Notifier`** — emit `{:movie_upgrade_failed, movie, reason}`. No `Notifier.Log` change
  needed (its catch-all already logs unknown events, `log.ex:21`); add a named clause only for a
  prettier line.

### Data flow — movie "find a better match" on an `:available` movie

```
user picks release (panel) → confirm "replace"
  → Catalog.manual_grab_movie(movie, release)            # movie.status == :available
      → Download.grab(release) → {:ok, download_id}
      → transition(:upgrading, download_id, protocol, release_title, import_attempts: 0)   # file_path + imported_* UNCHANGED; zero the retry budget for this upgrade
  → Poller advance, :upgrading clause (SEPARATE from the :downloading clause), next ticks:
      client.status(download_id):
        still downloading            → no DB write, live file untouched
        completed, content_path set  → Library.import_movie(%{movie | file_path: content_path}, replace: true)
            {:ok, dest, new_q} → transition(:available, file_path: dest, imported_*: new_q,
                                            download_id/protocol/release_title: <new grab>)
                                 if dest != <old file_path>: best_effort Library.delete_file(<old file_path>)   # different-container guard; log+ignore an rm error (movie is already :available at the new dest)
                                 Download.remove_after_import(new_protocol, new_download_id)
            {:error, reason}   → REVERT:
                                 Catalog.block_release(movie, :upgrade_failed)   # reads movie.release_title (= the new/failed title) off the struct, BEFORE the revert clears it
                                 transition(:available, download_id: nil, download_protocol: nil, release_title: nil)  # old file_path intact
                                 Notifier.notify({:movie_upgrade_failed, movie, reason})
        error / :not_found  → bounded retry, then the same REVERT branch
```

Invariants this encodes:
- The download's content path is passed to `import_movie` **in the same tick it completes** (in-memory
  struct) and **never persisted** into `file_path` — the `:upgrading` clause must not reuse the
  `:downloading` clause that writes `file_path: content_path` (`poller.ex:99`).
- The live `file_path` is overwritten **only** by the success transition, after `replace/2` (or the
  fresh-path link, for a different container) has already placed the new file; a crash before that
  just re-polls (client still reports completed) and re-imports idempotently.
- **Different container:** if the computed `dest` differs from the old `file_path`, the old file is
  deleted after success (`Library.delete_file/1` is idempotent and prunes empty dirs) so the library
  never holds two files for one movie.
- **Revert clears the new download fields** (the original release's `download_id`/`release_title`
  are not recoverable — overwriting them to start the upgrade is a one-way step, an accepted
  pre-existing limitation; the still-seeding original torrent handle is likewise lost, as with any
  re-grab). The blocklist call happens **before** the clear, while `release_title` still holds the
  failed title.

For a *parked* movie the manual grab transitions to `:downloading` and rides the existing import
path unchanged.

### Data flow — TV

- **Search missing:** `search_episode_now` / `search_series_now` zero `search_attempts` →
  `wanted_episodes/0` includes them next tick → existing `search_wanted` grabs them. No new path.
- **Find a better match (season):** panel lists `list_releases_tv` → user picks → `manual_grab_tv`
  recomputes wanted numbers → `create_grab` over them → existing TvPoller advance/import. Wanted
  episodes only.

## Error handling & invariants

- **Choke-point:** every status write goes through `Catalog.transition` / `transition_episode`.
- **Server-guards:** `manual_grab_movie` guards on the record's *current* status and rejects any
  non-allowed state (`{:error, :not_grabbable}`); it rescues `Ecto.StaleEntryError`. The
  panel/button events are client-sent and untrusted.
- **A failed upgrade never parks an available title** — it reverts to `:available` with the old file.
- **Atomic replace only**, plus the explicit different-container old-file delete; no bespoke
  delete-then-link.
- **Blocklist:** a manual grab may override the blocklist for *selection*; a manual grab that then
  *fails* is blocklisted (`block_release(movie, :upgrade_failed)`).
- **Aborting an upgrade** (cancel/delete of an `:upgrading` movie) removes the new download and, for
  cancel, reverts to `:available`.
- **Immediacy:** re-queued items wait up to one poll interval (≤5s); no manual poke channel
  (`ponytail`).

## Deferred (explicit, documented)

- **Replacing an already-imported TV episode.** Creating a grab for an episode that already has a
  `file_path` would leave it with both `file_path` and `grab_id` set, contradicting the derived-state
  TV model (`wanted_episodes/0`, badges, calendar, refresh `reconcile_tree`); the fix (guard
  `link_grab_episodes` on `is_nil(file_path)` + audit every derived-state reader, ~140 LOC) is out of
  scope. TV better-match covers *wanted* episodes only, and the panel says so on a full season.
- **Automatic upgrade / cutoff sweep of available titles** — the parked "Quality upgrades & cutoffs"
  epic; needs a quality-target model the scorer lacks.
- **A global "search all wanted" button** — per-series only, per the locked scope.
- **Restoring the original release identity / torrent handle after a failed or aborted movie
  upgrade** — accepted limitation (the available movie's download fields are informational).

## Testing (ExUnit + Mox; never touches network/disk)

Load-bearing:

- Manual grab on a **parked** movie → `:downloading` (mock indexer + download client).
- Manual grab on an **`:available`** movie → `:upgrading`; a still-downloading tick performs **no DB
  write** and leaves `file_path` unchanged; on a mocked completed download the poller's `:upgrading`
  clause calls `import_movie(_, replace: true)`, the FS mock shows the atomic replace, and the movie
  ends `:available` with the new `imported_*`.
- **Different-container upgrade leaves no orphan:** `.mkv` installed, `.mp4` chosen ⇒ the old file is
  deleted and only the new dest remains.
- **Failed upgrade reverts cleanly:** an import error (e.g. `:wrong_audio_language`) ends the movie
  back at `:available` with the *original* `file_path` unchanged, the new download fields cleared,
  the attempted release blocklisted, and a `{:movie_upgrade_failed, _, _}` event emitted.
- **Idempotent across restart:** re-running the `:upgrading` advance after success is a no-op;
  re-importing the same completed download (same-fs, file already hardlinked) replaces to the same
  dest without error **and records the new quality, not the stale old `imported_*`** (the forced-replace
  fix above).
- **`remove_after_import` runs on upgrade success** (the new download is cleaned up).
- **Guard rejects an invalid-state grab:** `manual_grab_movie` on a `:downloading`/`:cancelled`/
  `:upgrading` movie returns `{:error, :not_grabbable}`; a movie deleted mid-action surfaces the
  rescued `StaleEntryError` path, not a crash.
- **Abort:** cancelling an `:upgrading` movie reverts to `:available` and removes the new download;
  deleting one removes the new download (no orphan).
- `list_releases/2` annotates each release with the right verdict (`:out_of_band`, `:blocklisted`,
  `:wrong_resolution`, `:wrong_source`, `:wrong_protocol`, soft language note), and a manual grab can
  pick a `:rejected` one.
- TV: `search_series_now/1` zeros `search_attempts` on all wanted episodes (available/in-flight ones
  untouched); `manual_grab_tv` covers only the still-wanted numbers even if the sweep grabbed one
  mid-action; a full season yields `{:error, :nothing_wanted}` (panel shows the "not supported yet"
  state).

## Open implementation choices (settle in the plan)

- Exact movie surface(s) for the panel (`activity_live` vs `library_live` vs both) — one shared
  component, mounted wherever movie cards render.
- `Scorer.verdict/2` should **share** the rule predicates with `select/2` (the round-2 council
  confirmed this is a zero-risk refactor — the predicates are already module-private), so the panel
  verdicts and the auto-pick can't drift; a thin parallel is the fallback only if sharing proves awkward.

## Resolved review findings (round 1, 2026-06-29)

A correctness/feasibility/contrarian council reviewed the first draft against the code. Verified-OK
and left unchanged: no-migration claim, `transition_changeset` field preservation, `create_grab/4`,
`transition_episode` casting `search_attempts`, `import_movie/2` mechanism, the `Notifier` catch-all,
`start_async` availability, and the `:upgrading`-as-status decision (a transient field would need a
migration *and* still require the discriminator — worse). Corrected into the spec above:

1. **Different-container upgrade stranding the old file** (major correctness hole) → explicit
   `Library.delete_file` when `dest != old file_path` + a test.
2. **`block_release/2` arity** (`(movie, reason)`, reads title off struct) → fixed in the data flow;
   call ordered before the revert clears `release_title`.
3. **Revert leaving stale download fields** → revert now clears `download_id`/`protocol`/
   `release_title`; original-identity loss documented as accepted.
4. **`:upgrading` consumer audit** → cancellable/active set (+ special revert-on-cancel), poller
   advance sweep, dashboard buckets, badge spec.
5. **Separate advance clause** that never persists `content_path` into `file_path` → made explicit.
6. **Verdict reasons mis-sourced** → reasons split across scorer (`:out_of_band`/`:blocklisted`/
   `:wrong_resolution`/`:wrong_source`) + protocol (`:wrong_protocol`) + a soft, unreliable language
   hint; `:wrong_language` is no longer a hard scorer verdict.
7. **Under-specified cases** → in-flight guard set, StaleEntryError rescue, `remove_after_import` on
   success, TV recompute-wanted-at-grab, TV full-season panel state, panel loading/empty/error states.

**Round 2 (2026-06-29):** all three members verdicted **READY-TO-PLAN** against the corrected spec.
Final residuals folded in: (a) the **`cancellable?/1` shared-predicate trap** — `:upgrading` gets a
dedicated abort path, never added to `@cancellable_movie_statuses` (which would force `:cancelled`);
(b) the success-path old-file delete is **best-effort** (log+ignore); (c) the cancel-revert clears
the download fields like the import-failure revert; (d) `import_attempts: 0` on the `:upgrading`
transition; (e) the same-fs crash-recovery stale-quality edge is now a **decided fix** (`replace: true`
records `new_q`), not an open choice; (f) `Scorer.verdict/2` shares predicates with `select/2`
(confirmed zero-risk). No new blockers; nothing else outstanding.
