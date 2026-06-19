# Phase 4 — Library (import into Jellyfin) — Design

**Council review: 3 rounds — sound. R1 surfaced 6 material flaws (stale `content_path` via
`moving`-as-completed, `normalize/1` dropping `content_path`, nil-`file_path` crash-loop,
Mox-in-GenServer test regime, `find_files` raising/dir hazards, silent permanent-error retry); all
fixed or documented. R2 caught that the R1 `moving` fix was a no-op (the `progress >= 1.0` fallback
re-catches it) and that "error isolation" was under-specified; both corrected (special-case
`classify("moving", …)`, explicit `try/rescue` + extracted passes). R3 verified the corrected
`classify/2` change is sound with no stuck-state regression. Residual (accepted by the user, noted in
Assumptions): no `:import_failed` status — permanent failures surface only as "stuck at `:downloaded`"
+ a log line; hardlink same-filesystem / same-path assumption to be validated in the Phase-5 live test.**

**Date:** 2026-06-19
**Context:** `Cinder.Library`
**Roadmap goal:** On a movie reaching `:downloaded`, hardlink its file into a Jellyfin
library renamed to `Title (Year)/Title (Year).ext`, trigger a Jellyfin scan, and set status
`:available`. Filesystem ops sit behind a thin behaviour so import is testable without disk.

## Decisions taken (during brainstorming)

1. **Crash-recoverable import via persisted path.** The completed download's on-disk path is
   persisted to a new `Movie.file_path` field on the `:downloaded` transition. The poller then
   processes `:downloaded` movies → import → `:available`. A crash (or scan failure) between
   `:downloaded` and `:available` leaves the movie at `:downloaded`, and a later poll tick
   re-attempts the import. This keeps the Phase-3 stateless-poller philosophy (work re-derived
   from the DB each tick; no in-memory state). The path is persisted (not re-read from qBittorrent
   at import time) so import survives the torrent being removed from the client after seeding.
2. **Handle folder releases now.** qBittorrent's `content_path` is the file for single-file
   torrents but the root folder for multi-file releases. When it is a directory, the import picks
   the **largest file with a video extension** (so samples/extras are skipped).

## Changes to the Phase-3 completion signal (resolves the stale-path risk)

`Cinder.Download.Client.QBittorrent` currently classifies completion as:

```elixir
@completed ~w(uploading stalledUP pausedUP forcedUP queuedUP checkingUP moving)
defp classify(state, progress) when state in @completed or progress >= 1.0, do: :completed
defp classify(_state, _progress), do: :downloading
```

`moving` means qBittorrent is **relocating the finished file** (the common incomplete-dir →
completed-dir setup), so `content_path` captured in that window can be stale/transient. **Note the
trap:** simply removing `moving` from `@completed` is a **no-op**, because a `moving` torrent reports
`progress == 1.0` and the `or progress >= 1.0` arm re-classifies it `:completed`.

**Fix (a deliberate Phase-3 touch, called out here):** add a `moving`-specific clause *before* the
completed clause, and drop `moving` from `@completed`:

```elixir
@completed ~w(uploading stalledUP pausedUP forcedUP queuedUP checkingUP)
@in_transit ~w(moving)   # finished downloading but relocating — path not at rest yet
defp classify(state, _progress) when state in @in_transit, do: :downloading
defp classify(state, progress) when state in @completed or progress >= 1.0, do: :completed
defp classify(_state, _progress), do: :downloading
```

(`@in_transit` is the relocation set, kept symmetric with `@completed`/`@errored` and ordered
*before* the completed clause so it wins top-down; the existing `@errored` clause stays first of all.)
The `or progress >= 1.0` fallback is **kept** so a genuinely-finished torrent in any non-`moving`
state (including ones not enumerated in `@completed`) still classifies `:completed` — no
stuck-at-`:downloading`-forever regression. A torrent that finishes with move-on-completion stays
`:downloading` through the brief `moving` window, then lands on `stalledUP`/`uploading` (or just
`progress >= 1.0`) and transitions to `:downloaded` with a **final, at-rest** `content_path`.
Because the snapshot is taken at rest, importing in the same tick is safe and the persisted path is
stable across retries.

## New modules

### `Cinder.Library.Filesystem` (behaviour)
Thin disk primitives so the import orchestration is testable with a Mox mock.

```elixir
@callback dir?(path :: String.t()) :: boolean()
@callback find_files(dir :: String.t()) :: {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
@callback mkdir_p(dir :: String.t()) :: :ok | {:error, term()}
@callback ln(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
```
- `find_files/1` lists **regular files recursively** under `dir`, each paired with its size in
  bytes. Selection policy (largest video) lives in the context, not here.

### `Cinder.Library.Filesystem.Disk` (real impl)
- `dir?` → `File.dir?/1` (note: `File.dir?(nil)` raises — see the `nil`-guard in the context; the
  context never calls `dir?` with a `nil`/blank path).
- `find_files` → `Path.wildcard(Path.join(dir, "**/*"))` returns **directories too** and **omits
  dotfiles by default**, so: filter `File.regular?/1` **first**, then map to `{path, size}` using
  the **non-raising** `File.stat/1` (skip any entry whose `stat` fails, e.g. vanished mid-scan, so
  the impl never raises and honours the `{:error, term()}` contract). Recursion is intentional so a
  feature inside the release folder is found even when a `Sample/` subdir exists.
- `mkdir_p` → `File.mkdir_p/1`
- `ln` → `File.ln/2` (hardlink). `ponytail:` hardlink only — the library must live on the same
  filesystem as the downloads, and the Cinder process must see the **same paths** qBittorrent
  reports. Add copy-fallback / path-translation only if a real deployment needs it (see Assumptions).

### `Cinder.Library.MediaServer.Jellyfin` (real impl)
Implements the existing `Cinder.Library.MediaServer` behaviour (`@callback scan() :: :ok |
{:error, term()}`, already defined in Phase 0; mock already wired).
- `scan/0` → `POST {url}/Library/Refresh` with header `X-Emby-Token: {api_key}` via `Req`.
  Full-library refresh (the behaviour is arg-less). Read `url`, `api_key`, and `req_options`
  (test stub) via `Application.get_env(:cinder, Cinder.Library.MediaServer.Jellyfin, [])` — matching
  `QBittorrent`'s non-bang config read so an arg-less `scan/0` returns a clean `{:error, _}` (rather
  than raising at config-read time) when Jellyfin isn't configured.

### `Cinder.Library` (context)
```elixir
@spec import_movie(Cinder.Catalog.Movie.t()) :: {:ok, dest :: String.t()} | {:error, term()}
```
Steps:
0. **Guard:** if `movie.file_path` is `nil` or blank → return `{:error, :no_file_path}` (no FS
   calls). This prevents a `File.dir?(nil)` crash for any `:downloaded` row lacking a path (e.g.
   pre-migration rows or Phase-3 test fixtures).
1. **Resolve source** from `movie.file_path`:
   - `fs().dir?(path)` true → `fs().find_files(path)` → pick the largest `{file, size}` whose
     extension (downcased) is in `@video_exts` (`.mkv .mp4 .avi .m4v .mov .wmv .ts`); tie-break
     **deterministically** (largest size, then lexicographically smallest path) so the chosen
     source — and thus the dest path — is identical across retries. None → `{:error, :no_video_file}`.
   - false → use `path` directly.
2. **Build dest** = `Path.join([library_path(), name, name <> ext])` where
   `name = "#{sanitize(title)} (#{year})"`, `ext = Path.extname(source)`. `sanitize/1` strips the
   filename-illegal set `/ \ : * ? " < > |`. Dest is fully deterministic given (title, year, ext).
3. `fs().mkdir_p(Path.dirname(dest))` → `link(source, dest)` → `media_server().scan()` → `{:ok, dest}`.
   - `link/2` treats `fs().ln` returning `{:error, :eexist}` as `:ok` (**idempotent**). The
     precondition chain that makes this sound: snapshot taken at rest (above) ⇒ the release folder's
     file set is stable across retries ⇒ the deterministic tiebreak picks the same winner ⇒ the
     same `ext` ⇒ the same dest ⇒ a retry hits the existing link, so `:eexist` genuinely means "this
     exact import already happened." (Exact-size tie between two *different* extensions is resolved
     by the lexicographic path tiebreak, so even that yields one stable winner.)
- `library_path/0`, `fs/0`, `media_server/0` are resolved at runtime via
  `Application.fetch_env!/2` (project rule: never `compile_env!`, or Mox breaks
  `--warnings-as-errors`). `library_path/0` uses `fetch_env!` (fail-fast: raises only when an import
  actually runs unconfigured, consistent with the qBittorrent pattern).
- Keep the orchestration as a tight `with` plus small single-purpose private helpers
  (`resolve_source/1`, `pick_video/1`, `build_dest/2`, `link/2`) to stay under `credo --strict`
  complexity/nesting thresholds (mirror `Download.start/1`'s style).
- The context owns **filesystem + Jellyfin only**. It does not change status — `Catalog` remains
  the single status/broadcast choke-point.

## Changes to existing code

- **`Cinder.Catalog.Movie`** + migration: add `field :file_path, :string`;
  `transition_changeset/2` also casts `:file_path` (currently casts `[:status, :download_id,
  :imdb_id]`). `Ecto.Changeset.cast/3` only writes keys present in `attrs`, so a later
  `%{status: :available}` transition does **not** wipe `file_path`. (`:downloaded`/`:available`
  statuses already exist — no enum change.)
- **`Cinder.Download.Client.QBittorrent`**:
  - `normalize/1` (not just `status/1`) must include `content_path` in the returned map — `status/1`
    returns the output of `normalize/1`, which currently keeps only `%{state:, progress:}` and
    discards the rest. The `{:ok, map()}` callback spec is unchanged; this is a map-shape convention.
  - Tighten `@completed` per "Changes to the Phase-3 completion signal" above.
- **`Cinder.Download.Poller`** — `do_poll/0` calls two stateless passes, **each extracted into its
  own private function** (`advance_downloading/0`, `import_downloaded/0`) to keep nesting/complexity
  under `credo --strict` (the existing single-pass `do_poll/0` already nests `Enum` + `case`; adding
  a second inline pass would breach `Refactor.Nesting` depth 2). Pass 1 runs and commits before
  pass 2 queries, so a just-completed movie is imported the same tick (safe — snapshot is at rest).
  1. `advance_downloading/0` — `Catalog.list_by_status(:downloading)`: read status; on `:completed`,
     take `content_path = Map.get(status, :content_path)` (**`Map.get`, not a rigid pattern**, so a
     missing key yields `nil` rather than failing the match and stranding the movie at
     `:downloading`), then `Catalog.transition(movie, %{status: :downloaded, file_path: content_path})`.
  2. `import_downloaded/0` — `Catalog.list_by_status(:downloaded)`: `Cinder.Library.import_movie(movie)`;
     `{:ok, _}` → `Catalog.transition(movie, %{status: :available})`; `{:error, reason}` →
     `Logger.warning` (reason included) + leave at `:downloaded` (retried next tick). **This is the
     crash-recovery hook**: a movie stranded at `:downloaded` (crash after download, before import)
     is picked up on a later poll.
  - **Per-movie error isolation (concrete):** the body for each movie in both passes is wrapped in a
    `try/rescue` that logs the exception and moves on — so an *unexpected raise* (a real-impl `ln`
    blowing up, a vanished path) skips that one movie and leaves it at its current status, rather
    than crashing the tick for every later movie in the batch. The `{:error, _}` return path handles
    *expected* failures; `try/rescue` handles raises. Both are needed.
  - Permanent vs transient errors are **not** modelled as distinct statuses (see Assumptions); they
    are logged distinctly. The movie remaining at `:downloaded` (rather than `:available`) is itself
    the user-visible signal in the dashboard badge.
- **Existing Phase-3 poller tests**: their `Cinder.Download.ClientMock` stubs return the *normalized*
  map `{:ok, %{state: :completed}}` (the `:completed` atom is `classify/1`'s output, so these stubs
  bypass `classify/1` — the `@completed`/`moving` change does **not** affect them). Because pass 1
  uses `Map.get(status, :content_path)` (nil-safe), an un-updated stub does not crash and the
  existing `status: :downloaded` assertions still pass — but `file_path` would be `nil`. Update the
  three `:completed` stubs to include a `content_path:` for fidelity (so the import pass has a real
  path) and to assert `file_path` round-trips. Listed in the build order.
- **Config**:
  - `config/config.exs`: `config :cinder, media_server: Cinder.Library.MediaServer.Jellyfin`,
    `config :cinder, filesystem: Cinder.Library.Filesystem.Disk`. (Without these, `fetch_env!` raises
    in dev/prod — `test.exs` already sets `media_server`.)
  - `config/runtime.exs`: guard every new env read with `if System.get_env(...)` (matching the
    existing TMDB/qBittorrent idiom, so dev/test boot without them): `JELLYFIN_URL` /
    `JELLYFIN_API_KEY` → `config :cinder, Cinder.Library.MediaServer.Jellyfin, url:, api_key:`;
    `LIBRARY_PATH` → `config :cinder, :library_path`.
  - `config/test.exs`: `filesystem: Cinder.Library.FilesystemMock`, a throwaway
    `library_path: "/tmp/cinder-test-library"` (never written — FS is mocked). Keep
    `media_server: Cinder.Library.MediaServerMock` (already set) — do **not** repoint it at the real
    `Jellyfin` impl, or the poller/library tests' Mox expectations break. The optional `Req.Test`
    stub block is only for an isolated thin `Jellyfin` unit test that calls the impl directly.
  - `test/test_helper.exs`: `Mox.defmock(Cinder.Library.FilesystemMock, for:
    Cinder.Library.Filesystem)`.

## Tests (mocked FS + Jellyfin; no disk, no network)

Two regimes — keep them separate (this is the Mox-in-GenServer constraint):

- **`Cinder.Library` unit tests** run in the **test process** → use `expect/3` + `verify_on_exit!`,
  `async: true`. These carry the call-shape and negative assertions:
  - single-file source → asserts `mkdir_p(dir)`, `ln(source, dest)`, `scan/0` called, returns `{:ok, dest}`.
  - folder source → `find_files` returns a small sample `.mkv` + a large feature `.mkv`; asserts the
    **feature** is the `ln` source (deterministic tiebreak).
  - `ln` returns `{:error, :eexist}` → still `{:ok, dest}` (idempotent).
  - folder with no video → `{:error, :no_video_file}`, **`scan` not called** (expressible here via
    `expect` count 0 / absence).
  - `movie.file_path == nil` → `{:error, :no_file_path}`, no FS calls.
  - dest is the sanitized `Title (Year)/Title (Year).ext`.
- **Poller integration tests** run cross-process (mock called from the Poller GenServer) → use
  `setup :set_mox_global` + `stub` (no `verify_on_exit!`), `use Cinder.DataCase, async: false`
  (required by `set_mox_global` and the shared SQL sandbox). Assert **observable outcomes**, not Mox
  counts:
  - the Done-when: a `:downloaded` movie with `file_path` set, FS+Jellyfin stubbed to succeed →
    after a synchronous `handle_call(:poll)` the movie ends **`:available`** (and broadcasts
    `{:movie_updated, _}` via `Catalog.subscribe()`).
  - failure-retry: stub `ln`/`scan` to return `{:error, _}` → movie **stays `:downloaded`**, no
    `:available`.
  - **crash recovery:** construct a `:downloaded` movie with `file_path` directly (simulating a crash
    after download, before import), run a poll → it reaches `:available` (proves stateless
    re-derivation closes the download→import gap; does not depend on pass 1).
- `transition/2` round-trip: `transition(movie, %{status: :downloaded, file_path: "/x/y.mkv"})`
  persists `file_path` (fails loudly if the `:file_path` cast is missed).
- Optional thin impl tests as time allows: `Filesystem.Disk` against a `tmp_dir` ExUnit tag (this is
  the one place real disk is acceptable, isolated), `MediaServer.Jellyfin` via a `Req.Test` stub
  asserting `POST /Library/Refresh` + token header.

## Build order

1. Migration: add `file_path` to `movies`.
2. `Movie` schema: add field + cast in `transition_changeset` (+ round-trip test).
3. `Cinder.Library.Filesystem` behaviour + `Filesystem.Disk` impl (regular-files-first, non-raising stat).
4. `Cinder.Library.MediaServer.Jellyfin` impl.
5. `Cinder.Library` context (`import_movie/1`: nil-guard, source resolution w/ deterministic
   tiebreak, dest building, `library_path/0`, `:eexist` idempotency).
6. `QBittorrent`: add `content_path` to `normalize/1`; tighten `@completed` (drop `moving`/checking).
7. `Download.Poller`: snapshot `file_path` on `:downloaded` (`Map.get`, nil-safe); add the
   `:downloaded` import pass with per-movie error isolation + logging; **update existing poller test
   stubs** to carry `content_path` + at-rest state.
8. Config: `config.exs`, guarded `runtime.exs`, `test.exs`, `test_helper.exs`.
9. Tests: Library unit (expect/verify), poller integration (global/stub/async:false), transition
   round-trip (+ optional thin impl tests).

## Deliberate simplifications (ponytail) & assumptions

- Import runs **synchronously** inside the poll tick (single-household volume; hardlink + one POST
  are fast). Upgrade to a Task/queue only if it measurably blocks polling.
- `scan/0` is a **full** Jellyfin library refresh, not a targeted folder scan.
- **No `:import_failed` status** (per the brainstorming decision). Failures keep the movie at
  `:downloaded` + retry, logged distinctly. Trade-off the council flagged and the user accepted:
  permanent errors (`:no_video_file`, `:enoent`, `:exdev`) retry every tick and surface only as
  "stuck at `:downloaded`" + a log line, not a labelled failure. Revisit a terminal/failed status
  if the dashboard needs explicit failure visibility.
- **Path/mount assumption (Phase-5 prerequisite):** the Cinder process must see the file at the same
  `content_path` qBittorrent reports, and the library must be on the same filesystem (hardlink, no
  `:exdev`). Containerised qBittorrent with a different mount namespace, or separate download/library
  volumes, will fail `ln` with `:enoent`/`:exdev` — to be validated in the Phase-5 live smoke test;
  path-translation/copy-fallback is out of scope for Phase 4's mocked slice.
- **Release-format limitations (named, not silently mishandled):** full-disc rips (`.iso`, `BDMV`,
  `VIDEO_TS`), RAR-packed scene releases (`.r00`/`.rar` — no video extension → `:no_video_file`), and
  multi-part `CD1`/`CD2` releases are **unsupported** by the largest-video heuristic and are Parked.
  The heuristic targets the standard single-`.mkv`/`.mp4`-in-a-folder case (~90% of movie torrents).

## Done when

`mix test` (the alias: compile `--warnings-as-errors`, `format --check-formatted`, `credo
--strict`, suite) is green **and** a test proves a completed download produces the correct
hardlink + rename + scan call against mocked FS and Jellyfin, with the movie ending `:available`,
**and** a test proves a `:downloaded` movie is imported on a later poll (crash recovery), **and**
the existing Phase-3 poller tests still pass with their stubs updated for the `content_path` shape.
