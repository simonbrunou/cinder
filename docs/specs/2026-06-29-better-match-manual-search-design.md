# Design — Manual search + "find a better match"

**Date:** 2026-06-29. Size M. Branch `better-match-manual-search` (suggested).
**Driver:** user request — "an option for finding a better match for a movie or a TV show,
and an option for searching for a missing episode or all missing episodes."

## Goal

Add two user-initiated actions on top of the automatic pipeline:

1. **Find a better match** — an *interactive* manual search: query the indexer live, list every
   parsed release with its score and the scorer's reason for rejecting it, and let the user grab
   any one. For an already-`:available` movie this **replaces** the library file with the chosen
   release. For TV it grabs for a season's still-wanted episodes.
2. **Search missing episode / all missing episodes** — *automatic* re-queue of wanted TV
   episodes (per-episode and per-series), picked up by the existing sweep on the next tick.

**Done when:** conventions pass (`mix test` green) + the load-bearing tests in *Testing* pass —
in particular, a manual grab on an `:available` movie swaps the library file through the existing
atomic `replace/2` and a *failed* upgrade reverts to `:available` with the old file intact and the
bad release blocklisted.

## Reframing — what already exists

Most of this is wiring, not new machinery. A read of the current code shows:

- **The atomic file-swap is already built and dormant.** `Library.import_movie/1` routes a
  same-record collision (tmdb-keyed dest folder) through `place/6` → `do_resolve/6` →
  `Upgrade.better?` → **`replace/2`** (`library.ex:161`): sweep stale temps, link-or-copy the new
  source into a unique `.cinder-tmp-N` on the *dest* filesystem, then `rename` over the old dest.
  The old inode is dropped only at the instant the new one lands — crash-safe, never delete-first.
  It is never reached today only because nothing re-grabs an `:available` title. The same path
  serves episodes (`import_episodes/2` → `place_episode_file/4`).
- **The release blocklist already shipped** (the ROADMAP still lists it as "parked"). `BlockedRelease`
  is keyed per `movie_id`/`series_id`; the scorer drops blocklisted titles via `release_blocklist`;
  `retry_movie/1` deliberately *preserves* it. (FK `on_delete: :delete_all` means delete + re-add
  wipes it — a key reason the in-place replace below beats "delete the movie and re-request".)
- **Movie "Search now" for parked titles already exists** as `Catalog.retry_movie/1`
  (`catalog.ex:170`) — the existing Retry button. It zeros `search_attempts` (bypassing backoff),
  clears stale download fields, and re-queues at `:requested`. We reuse it as-is; the new movie
  control is only the manual-search panel.
- **The TV sweep is already wanted-driven** (`TvPoller.search_wanted/1`): `wanted_episodes/0`
  (`is_nil(file_path) and is_nil(grab_id)`, monitored, aired) → group by `{series, season}` →
  `Acquisition.best_releases`. "Search missing now" just resets `search_attempts` so a parked /
  backed-off episode re-enters that sweep.

So the genuinely new code is: a manual-search results surface, a "grab this specific release"
path, and **one new movie state (`:upgrading`)** for the replace-available flow.

## Scope (locked via council, 2026-06-29)

A three-member council (architecture / implementation / contrarian) settled the upgrade scope.
**Locked: the hybrid.**

- **Auto path acts on stuck/wanted titles only**, never on `:available`. The scorer has *no
  cutoff / quality-target concept* — it returns the best of each list — so an automatic re-search
  of an available title has no stopping rule (it would re-download and re-trigger a Plex/Jellyfin
  rescan every tick for zero gain). Building that stopping rule *is* the ROADMAP-parked "Quality
  upgrades & cutoffs" epic. Keep it parked.
- **Replacing an available file is allowed only through the interactive manual-search path**,
  where the user picks the exact release and confirms "replace." A human picking *is* the stopping
  rule, so no cutoff model is needed; the grab reuses the existing atomic `replace/2`.
- **Movies get replace; replacing an already-imported TV episode is deferred** (see *Deferred*) —
  it would put an episode in a `file_path` + `grab_id` dual state that breaks the derived-state
  model. The asymmetry is deliberate (movies are 1:1 row=file with a status enum; TV is derived).
- **Manual grab rules:** the panel lists *every* result with its scorer verdict and lets the user
  grab anything — overriding the size band, language preference, and blocklist for *selection*.
  (A manual grab that then *fails* is still blocklisted.)
- **TV bulk:** per-series "Search all missing" + per-episode "Search". No global button.

## Architecture

### User-facing surfaces

| Surface | Control | Behaviour |
|---|---|---|
| Movie views (`activity_live`, `library_live`) | **Search now** | Existing Retry → `retry_movie/1`. Parked movies only (server-guarded). |
| Movie views | **Find a better match** | Opens the manual-search panel. Parked → grab → `:downloading`. `:available` → "Replace current file?" confirm → `:upgrading`. |
| `series_detail_live` | per-episode **Search** | `search_episode_now/1` — zero that episode's `search_attempts`. |
| `series_detail_live` | per-series **Search all missing** | `search_series_now/1` — zero `search_attempts` on every wanted episode of the show. |
| `series_detail_live` | **Find a better match** (per season) | Manual-search panel (season results) → grab → `create_grab` over the season's still-wanted episodes. |

A single shared `CinderWeb.ManualSearchComponent` (LiveComponent) renders the async query + results
table + grab/confirm, mounted in the movie views and `series_detail_live`. One implementation, two
mount points (the implementation council member flagged duplicating it would add ~60 LOC).

### New / changed modules

- **`Cinder.Catalog.Movie`** — add `:upgrading` to `@statuses`. *No migration* (Ecto.Enum is stored
  as a string; adding a value to the `values:` list needs no DB change). `:upgrading` means "an
  available movie is re-downloading a user-chosen replacement; its `file_path` still points at the
  live library file."
- **`Cinder.Acquisition`** — `list_releases(imdb_id, opts)` and `list_releases_tv(series, season,
  opts)`: return `[{%Release{}, verdict}]` where `verdict` is `:ok | {:rejected, reason}`
  (`:out_of_band` / `:blocklisted` / `:wrong_language` / `:wrong_protocol`), sorted by score. Reuses
  `Release.new/1` + a new `Scorer.verdict/2` (or `explain/2`) helper that runs the existing rule
  checks without collapsing to a single pick.
- **`Cinder.Download`** — `grab(release) :: {:ok, download_id} | {:error, term}`: add one specific
  release to its protocol's client (extracted from the existing search-and-add path).
- **`Cinder.Catalog`**:
  - `manual_grab_movie(movie, release)` — server-guards on status. Parked (`@retryable`) →
    `Download.grab` + `transition(:downloading, download_id, protocol, release_title)`. `:available`
    → `Download.grab` + `transition(:upgrading, …)` **leaving `file_path` and `imported_*`
    untouched** (the live file + the upgrade-comparison baseline).
  - `manual_grab_tv(series, season_number, release, wanted_numbers)` — `Download.grab` +
    `create_grab/4` over the covered wanted episodes (reuses the existing grab path).
  - `search_episode_now(episode)` / `search_series_now(series)` — set `search_attempts: 0` on the
    wanted episode(s) via `transition_episode/2`, so the sweep re-grabs within ≤5s.
- **`Cinder.Library`** — `import_movie/2` with `replace: true`, forcing the `place/6` upgrade thunk
  to `fn -> true end` (a user-chosen manual replace bypasses `Upgrade.better?`). ~3 LOC; `import_movie/1`
  delegates with `replace: false`.
- **`Cinder.Download.Poller`** — handle `:upgrading` in the advance phase (see data flow).

### Data flow — movie "find a better match" on an `:available` movie

```
user picks release (panel)
  → Catalog.manual_grab_movie(movie, release)        # movie.status == :available
      → Download.grab(release) → {:ok, download_id}
      → transition(:upgrading, download_id, protocol, release_title)   # file_path UNCHANGED
  → Poller advance (:upgrading branch), next ticks:
      client.status(download_id):
        still downloading            → wait (no write)
        completed, content_path set  → Library.import_movie(%{movie | file_path: content_path}, replace: true)
            {:ok, dest, new_q}  → transition(:available, file_path: dest, imported_*: new_q)   # replace/2 swapped the file
            {:error, _}         → revert: transition(:available)        # old file_path intact
                                  + Catalog.block_release(movie, release_title)
                                  + Notifier.notify({:movie_upgrade_failed, movie, reason})
        error / :not_found (bounded retry, then) → same revert + blocklist + notify
```

Key point: the download's content path is passed to `import_movie` **in the same tick it completes**
(via an in-memory struct), so it is never persisted into `file_path`. The live library `file_path`
is overwritten only by the success transition, after `replace/2` has already atomically swapped the
file. A crash between completion and import just re-polls next tick (client still reports completed)
and re-imports — `replace/2` is idempotent.

For a *parked* movie the manual grab transitions to `:downloading` and rides the **existing** import
path unchanged (its `file_path` is a download path, not a library file — nothing to preserve).

### Data flow — TV

- **Search missing:** `search_episode_now` / `search_series_now` zero `search_attempts` →
  `wanted_episodes/0` includes them next tick → existing `search_wanted` grabs them. No new path.
- **Find a better match (season):** panel lists `list_releases_tv` results → user picks →
  `manual_grab_tv` → `create_grab` over the season's still-wanted episode ids → existing TvPoller
  advance/import. Wanted episodes only (no file to replace).

## Error handling & invariants

- **Choke-point:** every status write goes through `Catalog.transition` / `transition_episode`.
- **Server-guards:** `manual_grab_movie` and the search-now helpers guard on the record's *current*
  status server-side — the panel/button events are client-sent and must not be trusted to fire only
  for valid states (mirrors `retry_movie`'s `when status in @retryable`).
- **A failed upgrade never parks an available title** — it reverts to `:available` with the old
  file. Parking would strand a movie that still has a perfectly good file (DB/disk divergence).
- **Atomic replace only** — the upgrade import reuses `place/6`/`replace/2`; no bespoke
  delete-then-link anywhere.
- **Blocklist:** a manual grab may *override* the blocklist when selecting a release, but a manual
  grab that subsequently *fails* (download or import) is blocklisted like any other failure. The
  previously-installed (successful) release is never blocklisted.
- **No re-grab-for-nothing:** the auto path never touches `:available`, so the scorer can't
  re-pick the installed release in a loop. The manual path is user-gated, so a redundant pick is
  the user's explicit choice.
- **Immediacy:** re-queued items wait up to one poll interval (≤5s); no manual poke channel is
  added (`ponytail`: not worth a GenServer cast for ≤5s).

## Deferred (explicit, documented)

- **Replacing an already-imported TV episode.** Creating a grab for an episode that already has a
  `file_path` would leave it with both `file_path` and `grab_id` set, contradicting the entire
  derived-state TV model (`wanted_episodes/0`, badges, calendar, refresh `reconcile_tree`). The fix
  (guard `link_grab_episodes` on `is_nil(file_path)` + audit every derived-state reader, ~140 LOC)
  is out of scope. TV better-match covers *wanted* episodes only.
- **Any automatic upgrade / cutoff sweep of available titles.** Requires a quality-target model the
  scorer does not have; building it is the ROADMAP-parked "Quality upgrades & cutoffs" epic. Stays
  parked.
- **A global "search all wanted" button.** Per-series only, per the locked scope.

## Testing (ExUnit + Mox; never touches network/disk)

Load-bearing:

- Manual grab on a **parked** movie → `:downloading` (mock indexer + download client).
- Manual grab on an **`:available`** movie → `:upgrading`; the poller's `:upgrading` advance, on a
  mocked completed download, calls `import_movie(_, replace: true)`, the FS mock shows the atomic
  replace (link-or-copy temp + rename over dest), and the movie ends `:available` with the new
  `imported_*` quality.
- **Failed upgrade reverts cleanly:** an import error (e.g. `:wrong_audio_language`) on an
  `:upgrading` movie ends it back at `:available` with the *original* `file_path` unchanged and the
  attempted `release_title` blocklisted; a `{:movie_upgrade_failed, _, _}` notifier event fires.
- **Idempotent across restart:** re-running the `:upgrading` advance after the success transition is
  a no-op (the movie is already `:available`); re-importing the same completed download replaces to
  the same dest without error.
- `list_releases/2` annotates each release with the right verdict (`:out_of_band` for a
  size-band miss, `:blocklisted`, `:wrong_language`), and a manual grab can pick a `:rejected` one.
- TV: `search_series_now/1` zeros `search_attempts` on all wanted episodes (and leaves
  available/in-flight ones untouched); `manual_grab_tv` creates a grab covering only the season's
  still-wanted numbers.

## Open implementation choices (settle in the plan)

- Exact movie surface(s) for the manual-search panel (`activity_live` vs `library_live` vs both) —
  one shared component, mounted wherever movie cards already render.
- Whether `Scorer` exposes `verdict/2` or `Acquisition` reimplements the rule checks for the
  annotated list — prefer a `Scorer` helper so the panel and the auto-pick can't drift.
