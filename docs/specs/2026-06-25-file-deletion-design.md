# Design — Delete-file option on movie / show / season / episode deletion

**Date:** 2026-06-25.
**Goal:** mirror Sonarr/Radarr — when deleting a movie, a TV show, a season, or an episode,
offer to also delete the media file(s) from disk.

## Context — what already exists

The entity-delete plumbing is already in place and was built anticipating this feature:

- **`Catalog.delete_movie/2`** (`catalog.ex:224`) deletes the movie row, cancels a tracked
  client download first (best-effort), audits, broadcasts `{:movie_deleted, id}`. It
  **intentionally leaves on-disk files** with a comment pointing at a *"deferred unlink
  feature"* — this spec is that feature.
- **`Catalog.delete_series/2`** (`catalog.ex:689`) reaps grabs first, cascade-deletes the
  series tree (seasons + episodes), audits, broadcasts `{:series_deleted, id}`, and likewise
  leaves files on disk.
- **No `delete_season` / `delete_episode`** exist. Episodes and seasons belong to the
  TMDB-synced tree (the Refresher re-adds removed rows), so the only sensible "delete" at those
  levels is **deleting the file**, not removing a row.
- **`Movie.file_path`** and **`Episode.file_path`** hold the hardlinked library paths.
- **`Cinder.Library.Filesystem`** behaviour (`library/filesystem.ex`) exposes
  `dir?/find_files/mkdir_p/ln/lstat` — **no delete primitive**. Disk impl in
  `library/filesystem/disk.ex`; mock auto-derived for tests.
- Files are **hardlinks** into the library (`library.ex`, `link/2`), so deleting the library
  copy reclaims disk space only once the download client also drops its copy — same as
  Sonarr/Radarr.
- All four delete entry points live on **admin-gated routes** (`/library`, `/series/:id`), so
  authorization is already covered.

## Entity → operation mapping

| User action | Today | This spec adds |
|---|---|---|
| Delete movie | removes row | optional **delete file** → unlink `Movie.file_path` |
| Delete TV show | removes row + tree | optional **delete files** → unlink every episode's `file_path` |
| Delete episode | *(none)* | **delete file** → unlink + clear `file_path` (reverts to missing) |
| Delete season | *(none)* | **delete files** → unlink every episode file in the season |

## Decisions (all Sonarr/Radarr parity)

- **"Delete file(s)" defaults OFF** in the movie/show entity-delete dialogs (opt-in, safer).
- **"Also stop monitoring" defaults OFF** on the file-only (episode/season) deletes. Left
  monitored, the poller re-grabs next tick — true parity; the checkbox is the opt-out.
- **Empty folders are pruned** up to (never including) the library root after unlinking.
- **Hardlink reality** (space reclaimed only after the download client drops its copy) is a
  doc note, not code.
- **Failure handling:** file deletion in the *entity* deletes is **best-effort** (logged +
  flashed; the row delete still proceeds, consistent with existing client-removal). The
  *file-only* deletes **surface** errors (the file is the whole point).

## Components

### 1. FS primitive — `Cinder.Library.Filesystem`

Add one callback:

```elixir
@callback rm(path :: String.t()) :: :ok | {:error, term()}
```

Disk impl: `File.rm/1`, **idempotent on `:enoent`** (deleting an already-missing file → `:ok`).
The Mox mock derives the callback automatically; test expectations updated where the delete
paths are exercised.

### 2. `Cinder.Library.delete_file/1`

```elixir
@spec delete_file(String.t() | nil) :: :ok | {:error, term()}
```

- `nil`/`""` → `:ok` (nothing to delete).
- Unlink the path via `fs().rm/1`.
- Then prune now-empty parent directories walking **up**, stopping at the configured library
  root for the file (root is never removed, nor any non-empty dir). `File.rmdir` only removes
  empty dirs, so a stray sibling file halts the prune safely.
- Path-based and root-agnostic (works for both movie `Title (Year)/` and episode
  `Show (Year)/Season NN/` layouts); the prune walks up while the dir is empty and strictly
  under a known library root.

Lives in `Library` (it already owns the FS seam and the roots) so the filesystem concern stays
out of `Catalog`.

### 3. Movie & show entity-delete gain `delete_files?`

Extend the two existing functions with an opts keyword, default `delete_files: false`:

- `delete_movie(movie, actor, opts \\ [])` — capture `movie.file_path` before the row delete
  (unchanged), then on `delete_files: true` call `Library.delete_file/1`. Best-effort.
- `delete_series(series, actor, opts \\ [])` — collect every episode `file_path` in the tree
  before the cascade (unchanged), then on `delete_files: true` unlink each. Best-effort.

Audit row records whether files were deleted. Existing broadcasts unchanged.

### 4. File-only deletes (no row removal) — episode & season

New `Catalog` functions; state change goes through the episode choke-point:

- `delete_episode_file(episode, actor, opts \\ [])` — `unmonitor: false` default.
  `Library.delete_file/1`, then `transition_episode(ep, %{file_path: nil})` (the episode
  choke-point, broadcasts on the `"series"` topic); `unmonitor: true` also sets
  `monitored: false`. Returns `{:error, :no_file}` when `file_path` is nil. Errors surfaced.
  Audited.
- `delete_season_files(season, actor, opts \\ [])` — mirrors the existing bulk-season op
  `set_season_monitored/2`: unlink each episode file via `Library.delete_file/1` (best-effort),
  then in **one `Repo.transaction`** write `file_path: nil` (+ `monitored: false` on `unmonitor`)
  directly to each episode that had a file, and broadcast `{:series_updated, id}` **once** (not
  N `transition_episode` calls). Fileless episodes are skipped. Audited.

### 5. UI

- **`LibraryLive`** (movie + series delete dialogs): add a **"Delete file(s) from disk"**
  checkbox (default off) to the existing `ask_delete_movie`/`ask_delete_series` →
  `confirm_*` flow; pass the flag through to the context call.
- **`SeriesDetailLive`**: per-episode **"Delete file"** action (rendered only when the episode
  has a `file_path`) and per-season **"Delete files"** action. Each dialog carries the **"also
  stop monitoring"** checkbox (default off).
- Failures surface via flash. Live views already subscribe to `"movies"`/`"series"`, so the
  grid/tree updates from the existing broadcasts.

## Testing

- **FS:** `rm` idempotent on a missing path.
- **`Library.delete_file`:** unlinks the file; prunes the now-empty `Title (Year)/` and
  `Season NN/`→show folders; **stops at the library root**; leaves a non-empty dir untouched;
  `nil` path → `:ok`. (Against the Mox FS, asserting the `rm`/`rmdir` calls.)
- **`delete_movie`/`delete_series` with `delete_files: true`** unlink (mocked FS); **without it,
  files are left** (existing behavior preserved). File-delete failure does **not** block the
  row delete (best-effort).
- **`delete_episode_file`:** clears `file_path`; left monitored by default → derived `wanted`
  (re-grab); `unmonitor: true` sets `monitored: false`; `{:error, :no_file}` when no file.
- **`delete_season_files`:** clears every episode file in the season in one transaction; skips
  fileless episodes; one broadcast.
- **LiveView:** the checkbox path calls the context with the flag; the episode/season actions
  render only when a file exists.

## Out of scope (YAGNI)

- A "delete movie file but keep the movie" action (Radarr has one separate from delete-movie).
  Not requested; the four listed actions are entity-delete-with-files (movie/show) and
  file-only (season/episode). Easy to add later on the same `Library.delete_file` seam.
- Bulk multi-select delete.
- Removing the download-client copy as part of "delete file" (the hardlink/seed copy is the
  client's to manage; the existing cancel path already removes *active* client downloads).
