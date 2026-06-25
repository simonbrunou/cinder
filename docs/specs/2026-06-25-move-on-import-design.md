# Move-on-import (Usenet-scoped) — design

**Date:** 2026-06-25
**Status:** **shipped 2026-06-25.** Design v2 (council-revised) implemented as specced; see the
done note at the bottom.

A Radarr/Sonarr-style import option: after a completed download is imported into the library,
**remove the original from the downloads folder** so it doesn't linger. Gated behind a toggle,
**default off** so current behavior is byte-for-byte unchanged until flipped. Useful for mergerfs.

## What changed from v1 (council-driven)

The first draft modeled this as a new **move** mode for the import itself: turn the `link/2`
hardlink choke-point into `place(source, dest, :link | :move)`, where `:move` did
`File.rename` (+ `cp`/`rm` on `:exdev`). A perspective-diverse council (architecture /
implementation / red-team) killed that approach — every one of its blocking findings traced to the
same root cause: **a move destroys the source file during import**, and that breaks the safety the
current hardlink path gets for free:

- **Silent-overwrite data loss.** POSIX `rename(2)` (and `File.rename`) *silently replaces* an
  existing regular-file destination — it does **not** return `:eexist`. So the planned `:eexist`
  collision branch is dead code on Linux, and a second title that sanitizes to the same
  `Title (Year)` would **overwrite and destroy the first title's library file**. The hardlink path
  gets this collision-park protection for free (`File.ln` genuinely returns `:eexist`,
  `idempotent_or_collision` compares inodes and parks); a move loses it.
- **Non-atomic copy → truncated file accepted as success.** A `File.cp` that dies mid-stream leaves
  a truncated destination; the proposed "dest exists ⇒ imported" idempotency guard would accept it.
- **Post-move retry strand.** `import_movie`'s `with` chain runs `resolve_source` (which reads the
  source) *before* the move step, so on a retry after a successful move the source is gone and the
  chain parks at `:no_video_file` before any idempotency guard can fire. The guard is fundamentally
  a *caller-level* concern, not something `place/3` can own.
- **TV is worse.** A moved season pack re-scans the now-empty `content_path`, gets `{:ok, []}`, and
  the TvPoller **parks the grab** and re-searches episodes that already imported. The "reconcile
  against the destination directory" fix is genuinely new matching logic in the highest-bug-density
  area the roadmap already flags.

**v2 sidesteps all of it: don't touch the import.** The file gets into the library exactly as today
(hardlink). The toggle adds one thing — **deleting the source download after a successful import** —
using the client capability that already exists.

## Why this still delivers the ask

For the canonical mergerfs setup (downloads and library on one pool, the trash-guides layout),
hardlinks work, so today's import already places the file in the library. The only thing missing is
that the download copy lingers in the downloads folder. v2 removes it. End state: the file is in the
library and gone from downloads — a move, achieved by hardlink-then-remove-original, with zero new
data-loss surface.

## Locked decisions

- **Remove-after-import, not move-during-import.** The import path (`Library.import_movie`,
  `import_episodes`, the `link/2` hardlink choke-point, `idempotent_or_collision`) is **unchanged**.
- **Reuse the existing client remove.** `Cinder.Download.Client` already exposes
  `remove(id, opts)` with `delete_files:` (client.ex:29), and `best_effort_remove/2`
  (catalog.ex:299) already calls `client.remove(id, delete_files: true)` with best-effort logging.
  The same mechanism, fired after import, deletes the whole download item safely (the client owns
  its path — no arbitrary `rm_rf` from Cinder).
- **Usenet-scoped, fails safe.** Remove only when `download_protocol == :usenet` (an allowlist, so a
  `nil`/unknown protocol falls to the safe no-op). Torrents are never auto-removed — seeding
  survives. `download_protocol` is persisted on both `Movie` (movie.ex:34) and `Grab` (grab.ex:16).
- **Default off.** No migration, no BREAKING config note; today's behavior (download stays) until
  flipped.
- **Covers movies + TV.** Both pipelines reach a terminal imported state with a tracked
  `download_id` and a protocol, so the post-import remove is symmetric.
- **Exposed in `/settings` only** (Library section), not the onboarding wizard.
- **Cross-filesystem (`:exdev`) support is explicitly deferred.** Today a cross-fs import parks at
  the hardlink step; v2 leaves that unchanged (the toggle only removes the source *after* a
  successful import, so a parked cross-fs import is never touched). True cross-fs import (copy into
  the library when hardlink can't work) is a separate, clearly-scoped fast-follow — see Deferred.

## Architecture

### The seam

A new best-effort step in each poller, fired only after the item has reached its terminal imported
state in the DB:

- **Movies** — in `import_one` (poller.ex:172), after `Catalog.transition(movie, :available)`
  succeeds and the notifier fires, if `move_on_import?` and `movie.download_protocol == :usenet`,
  remove the download.
- **TV** — in `import_grab` (tv_poller.ex), after `Catalog.finish_grab(grab, imported)` succeeds, if
  `move_on_import?` and `grab.download_protocol == :usenet`, remove the download.

"After the DB commit" is the safety property: the file is already recorded as imported, so deleting
the source can never strand or corrupt anything. A failed remove is logged and leaves clutter —
never an error, never a status change, never a re-import. The item only revisits this code via
explicit operator action (e.g. a future Retry), where the remove is an idempotent no-op.

### The remove call

**Extract `best_effort_remove/2` to one public shared helper** (it is currently private in
`Catalog`, catalog.ex:299, the canonical "swallow + log, always `:ok`" wrapper around
`client.remove(id, delete_files: true)`). Both pollers and the existing delete/reap sites call the
one helper — no duplicated delete-files primitive. While extracting, ensure it also **catches a
raise/throw** from `client.remove` (not just `{:error, _}`), so a misconfigured client can't unwind
past the poller. The name already reads "remove the download best-effort," which fits both the
cancel/delete and the import callers; keep it.

The gate is `move_on_import? and protocol == :usenet and download_id not in [nil, ""]` — the
`download_id` guard means a usenet row that somehow reached import without a tracked id no-ops
instead of calling `client.remove(nil, ...)`. The poller re-resolves `Download.client_for(protocol)`
at the import point (a cheap map lookup; not a reuse of the advance-time client).

For TV, read `download_id`/`download_protocol` off the **pre-fetched `grab` struct already in hand**
in `import_grab` — `finish_grab/2` deletes the grab row but returns the in-memory struct with fields
intact (catalog.ex:951), so a re-fetch would be `nil`. Remove fires on the `finish_grab` success
branch only.

Idempotent: a download the client already dropped on completion returns `:not_found` → `:ok`.

### Settings

One registry entry in `Cinder.Settings`: `move_on_import`, a **standalone global boolean**,
default false, non-secret.

NOTE (council finding): this does **not** fit the existing `flat_keys` overlay (that path is
per-`kind` *string* config — `#{kind}_library_path` and the size-band suffixes) nor the `@toggles`
path (those collapse into the `:cinder, :download_clients` map). It needs its **own** small overlay,
wired in four spots to match house style:

1. A new `apply_move_on_import(rows)` private (~2 lines: `enabled?`-parse the stored `"true"/"false"`
   → `Application.put_env(:cinder, :move_on_import, bool)`), plus one dispatch line in the
   `load_into_env/0` body (settings.ex:328) calling it — not an inline `put_env` in the dispatcher.
2. **No `base/1` snapshot.** Every read uses `Application.get_env(:cinder, :move_on_import, false)`
   with an inline default, so a cleared setting reverts safely without the bootstrap-snapshot dance
   the path settings need. This apply branch is genuinely simpler than its `apply_*` siblings — do
   not pattern-match it into needing a `base/1` entry.
3. A `plan/1`-side line to persist the checkbox (mirroring the `@toggles`/media-server `Map.put` in
   `plan/1`, settings.ex:561) — it is not in `@config_fields`/`@toggles`/`flat_keys`, so the
   existing reducers won't pick it up.
4. A `form_state` entry so the checkbox reflects stored state.

One checkbox in the `/settings` Library section.

### Reading the setting

The poller reads `Application.get_env(:cinder, :move_on_import, false)` at the decision point. The
pollers already read config and resolve clients, so no new coupling.

## Testing

- usenet + `move_on_import` on → after import, `client.remove(id, delete_files: true)` is called;
  movie ends `:available` (TV: grab finished, episodes have `file_path`).
- torrent + `move_on_import` on → **no** remove (seeding preserved).
- `move_on_import` off (default) → **no** remove; import path and all existing tests unchanged.
- remove returns `{:error, _}` → logged, movie still `:available` (no strand, no re-import).
- nil/unknown protocol (or blank `download_id`) + toggle on → no remove (fails safe).
- TV: a usenet grab → remove fired once after `finish_grab`.
- TV partial-match pack (9/10 episodes import, 1 unmatched) + toggle on → remove **still** fires
  (don't strand 9 episodes' clutter for 1); the unmatched episode re-searches. The download bytes
  for the unmatched file are gone and re-fetched — no tracked-state loss; `unmatched` is logged.

The import/link tests are untouched — that's the point of the pivot.

### `/settings` help text

The toggle's help text notes the consequence: "After a Usenet import, delete the original from the
download client. Ensure your library is a separate folder from your downloads." (Operator hygiene;
the hardlink already guarantees the library copy survives the delete.)

## Out of scope / deferred

- **Cross-filesystem import (the `:exdev` copy fallback).** Deferred to a fast-follow. Would teach
  the import to copy into the library when a hardlink isn't possible — necessary only if downloads
  and library are on genuinely different filesystems. Must be done with write-temp-then-atomic-
  rename (never a bare `cp` to the final path) and an explicit `File.exists?(dest)` collision check
  *before* writing (never relying on `rename`/`cp` to report `:eexist`, which they don't). Out of v1
  to keep the toggle a small, safe change.
- Blunt global move (auto-removing torrents) — rejected; breaks seeding.
- Onboarding-wizard exposure — `/settings` only.
- An env var for the toggle — DB setting only (default safe).
- Configurable per-library or per-quality policy — YAGNI.

## [done 2026-06-25]

Shipped exactly as specced, with one DRY refinement: instead of duplicating the gate
(`move_on_import? and usenet and id present`) in both pollers, it lives in one
`Cinder.Download.remove_after_import/2` so each poller is a single call. The low-level
`best_effort_remove/2` moved from a private in `Cinder.Catalog` to public in `Cinder.Download`
(its two reap callers repointed) and gained the `catch` the spec asked for, so a raising client
can't unwind a poller. Wired on the import-success branch of each poller (`poller.ex` after
`transition(:available)` + notify; `tv_poller.ex` after `finish_grab`, reading id/protocol off the
in-hand grab). Settings: `move_on_import` is a standalone global bool with its own tiny overlay
(`apply_move_on_import`, inline `false` default, no `base/1`), persisted in `plan/1`, reflected in
`form_state`, and one checkbox in the `/settings` Library section — no `Settings` read accessor
needed since `remove_after_import/2` reads the env directly. Tests: 11 (gate matrix incl.
raise/error swallow, both pollers, partial-pack still-removes) + 2 settings overlay round-trips.

The checkbox lives in the shared `service_fields/1` `:library` group, which the first-run wizard
(`SetupLive`) also renders — so it initially leaked into the wizard, against the settings-only
decision above. A council (perspective-diverse) confirmed honoring the spec: the toggle is
destructive-by-name and a first-run operator hasn't yet validated their hardlink topology, so it's
gated out via `attr :show_move_on_import, :boolean, default: true` (the wizard passes `false`; a
non-rendered checkbox simply persists `false`, the desired default). `/settings` is unchanged.
`mix test` green (725).
