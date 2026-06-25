# Move-on-import (Usenet-scoped) — design

**Date:** 2026-06-25
**Status:** design approved; ready for implementation plan.

A Radarr/Sonarr-style import option: instead of **hardlinking** a completed download into the
library (leaving the original in the downloads folder), **move** it. Gated behind a toggle,
**default off** so current behavior is byte-for-byte unchanged until flipped. Useful for mergerfs
and for setups where downloads and the library sit on different mounts (where hardlink import
currently fails outright).

## Why this exists

Today `Library` hardlinks the file into the library (`File.ln`, the `link/2` choke-point at
`library.ex:274`). The library must share the downloads' filesystem. Two problems this solves:

1. **Cross-mount setups fail today.** If downloads and the library are on different underlying
   filesystems, `File.ln` returns `:exdev` and the import parks. A move (rename, or copy+delete on
   `:exdev`) is what makes import work at all — this is exactly Radarr's "copy if hardlink isn't
   possible."
2. **Usenet leaves a dead copy.** Usenet has no seeding, so keeping the original in downloads is
   pure clutter. Moving empties the downloads folder.

## Locked decisions

- **Usenet-scoped, not blunt-global.** When on, only `download_protocol == :usenet` downloads are
  moved; torrents always hardlink so seeding survives. `download_protocol` is already persisted on
  both `Movie` (`movie.ex:34`) and `Grab` (`grab.ex:16`), so scoping is free.
- **Default off.** Preserves today's hardlink behavior; no migration, no BREAKING config note.
- **Covers movies + TV.** Both pipelines funnel through the same `link/2` choke-point and both carry
  the protocol, so symmetric coverage is nearly free.
- **Exposed in `/settings` only** (Library section), not the onboarding wizard — it's an advanced
  knob, and an unset value already means the safe default.

## Architecture

### The seam

All four import paths (`import_movie`, and `import_episodes` via `link_all`) already funnel through
one private function, `link/2`. That becomes:

```
place(source, dest, mode)   # mode :: :link | :move
```

`:link` is today's hardlink logic verbatim (including the `:eexist` same-inode idempotency /
collision check). `:move` is the new path. `Library` stays a pure filesystem executor.

### Who decides the mode

`Library` already reads app-env for `library_path` in `root/1`. It reads one more key the same way:

```elixir
Application.get_env(:cinder, :move_on_import, false)
```

Combined with the protocol it already has (`movie.download_protocol`; for episodes the grab's
protocol is passed into `import_episodes`), the rule is:

```elixir
mode = if move_on_import? and protocol == :usenet, do: :move, else: :link
```

Keeping the decision inside `Library` (next to the FS ops) means the pollers stay nearly untouched —
only `import_episodes` gains a `protocol` argument (`import_movie` already has the movie).

### `:move` semantics

`place(source, dest, :move)`:

1. `File.rename(source, dest)` — atomic; the common mergerfs same-pool case.
2. `{:error, :exdev}` → `File.cp(source, dest)` then `File.rm(source)` — the cross-mount case. A
   failed `cp` propagates as `{:error, _}` (the item retries / parks, source untouched). The `rm`
   after a successful `cp` is best-effort-but-surfaced: a copied-but-not-removed file is a correct
   import with leftover clutter, not a failure.
3. `{:error, :eexist}` → reuse today's `idempotent_or_collision` (source still present on this
   branch, so the inode compare works unchanged).
4. other `{:error, _}` → propagate.

### Retry idempotency (the one real wrinkle)

A move destroys the source, so a **post-move retry** must not burn the attempt budget and park a
movie/pack that actually imported. The retry window: `place` succeeded, then the
`:available` transition (`import_one`, `poller.ex:177`) or `finish_grab` (TvPoller) failed, so the
item is retried next tick with the source now gone.

Guard, in the `:move` path: **if the source is missing but the deterministic destination already
holds the file, treat it as imported** (return success, let the poller transition).

- **Movies:** dest folder `root/Title (Year)/` is deterministic; if it already contains a video,
  return `{:ok, that_path}`. (`import_one` ignores the dest value beyond `{:ok, _}`, so even a
  coarse "already there" answer is safe.)
- **TV:** reconcile the grab's episodes against the `SxxEyy` files already present at the
  deterministic destination (`Show (Year)/Season NN/`) using the existing `Parser`/`SxxEyy` match
  logic, so each episode still gets its real dest path for `finish_grab`. A source that is gone and
  whose dest exists counts as imported; one that is gone with no dest is genuinely lost (logged,
  parks) — same honesty as today's unmatched-file handling.

### Filesystem behaviour

`Cinder.Library.Filesystem` gains two callbacks, with `Disk` impls and Mox expectations:

```elixir
@callback rename(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
@callback cp(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
```

(`rm` already exists.) `Disk.rename` = `File.rename`, `Disk.cp` = `File.cp`.

### Settings

One registry entry in `Cinder.Settings`: `move_on_import`, boolean, default false, **non-secret**,
overlaid onto `:cinder, :move_on_import` exactly like the existing flat keys (`library_path`,
`tv_library_path`). One checkbox in the `/settings` Library section. No new env var required (a
boot bootstrap from `MOVE_ON_IMPORT` is optional and can be skipped — the default is safe).

## Testing

- usenet + move_on_import on → `rename` called, no hardlink.
- torrent + move_on_import on → hardlink (no move), seeding preserved.
- `:exdev` on rename → `cp` then `rm`.
- move_on_import off (default) → today's hardlink path, unchanged.
- retry after a successful move (source gone, dest present) → idempotent `{:ok, _}`, no park, no
  extra attempt.
- TV: a season pack moved; a post-move retry reconciles against the destination.
- `import_episodes` protocol threading: torrent grab hardlinks, usenet grab moves.

## Out of scope

- Blunt global move (moving torrents) — rejected; breaks seeding.
- Onboarding-wizard exposure — `/settings` only.
- An env var for the toggle — DB setting only (default safe).
- Configurable per-library or per-quality move policy — YAGNI.
