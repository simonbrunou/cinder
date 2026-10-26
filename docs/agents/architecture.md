# Architecture invariants

## Stack

- One self-hosted instance per household: low concurrency, a single admin who approves, a handful
  of requesters. Design and defaults target that scale, not multi-tenant SaaS.
- Ecto with `ecto_sqlite3` is the only database engine. Cinder uses SQLite on purpose, not
  Postgres.
- The UI is Phoenix LiveView (HEEx) with Tailwind v4, daisyUI (the Phoenix 1.8 default) and
  heroicons. There is no React, so shadcn does not apply. State renders through the shared
  `status_badge` primitive: icon, text and color, never color alone.

## External services go through behaviours

Every external service (TMDB, Prowlarr, torrent and Usenet clients, Jellyfin/Plex,
Audiobookshelf, Booklore) is reached only through a behaviour, never directly from a context:
`Cinder.Catalog.TMDB`, `Cinder.Acquisition.Indexer`, `Cinder.Download.Client`,
`Cinder.Library.MediaServer`, `Cinder.Books.Metadata`, `Cinder.Library.AudiobookServer`.

- Resolve the implementation at runtime with `Application.fetch_env!/2`, never `compile_env!/2`.
  The Mox mock is defined at runtime, so compile-time resolution breaks
  `compile --warnings-as-errors`.
- Req is the HTTP client. It belongs inside an adapter that implements one of these behaviours,
  not in a context module.
- Search indexers by IMDb id rather than free-text title. `Catalog.get_movie/1` carries
  `imdb_id` through for this.

## Status writes go through the choke-points

A movie's `:status` and an episode's derived state (`file_path`, `part_file_paths`, `grab_id`)
are written only by the catalog's concept modules under `lib/cinder/catalog/`:

- `Cinder.Catalog.MovieLifecycle` for every movie status write, upgrades and adoption included.
  Each event is a named verb (`attach/2`, `import_staged/2`, `record_failure/2`, `cancel/2`, ...)
  whose write is a compare-and-swap on the struct the caller read: that is the race-safe poller
  write. `record_submission_failure/3` and `adopt/3` read their own row inside their transaction
  instead. `MovieLifecycle.transitions/0` lists every legal movie edge.
- `Cinder.Catalog.Episodes.transition/3` (`Catalog.transition_episode/3` outside the catalog).
  Its `expect:` form is the race-safe poller write.
- Audited siblings that each own one lifecycle: TV grabs and their verification holds
  (`Cinder.Catalog.Grabs`), episode adoption (`Cinder.Catalog.Adoption`), deletion
  (`Cinder.Catalog.TitleDeletion`), TMDB refresh (`Cinder.Catalog.MetadataRefresh`).

Books and audiobooks follow the same rule through `Cinder.Books.transition_target/3`, plus their
audited siblings: `hold_target/5`, `pause_target/1`, `monitor_target/3`, `import_resolution/1`,
`Files.record_import/3` and `record_import_set/3`. Every `book_grabs` mutation lives in
`Cinder.Books.Grabs`. A request's status (an admin's approval or denial) is written only by
`Cinder.Requests`.

## Guarded writes have one contract

The compare-and-swap status write on movies, episodes, book targets and requests is
`Cinder.GuardedWrite.write/4`. Each table has one adapter, named only by its owner (the
`MovieLifecycle` verbs, `Episodes.transition/3`, `transition_target/3` and `Cinder.Requests`;
`test/code_health_test.exs` fences it). The audited siblings above still write episodes their own
way (`Grabs.finish_grab`, episode adoption, deletion), as does `Requests.reopen_request/2`;
moving them is #788.

- A miss is `{:error, :stale_status}`. An owner may rename it at its public boundary
  (`:not_pending` for `/api/v1`, `:not_cancellable`, ...).
- `update_all` skips Ecto's `to_constraints`, so a trigger abort arrives as a raw
  `Exqlite.Error`. The adapter's `refusal/2` names it by the constraint's message; anything else
  re-raises, a transient busy included.
- A guarded write inside a transaction must run in `GuardedWrite.transaction/2`; it raises in a raw
  `Repo.transaction`. A refused write rolls that transaction back, even if the caller carries on,
  so nothing commits around it.
- Callers never publish. A write publishes after its own statement outside a transaction, or after
  the outermost `GuardedWrite.transaction/2` commits inside one.

Each transition emits exactly one broadcast, after commit, never inside the enclosing
transaction.

Direct `Repo` writes are not banned. Creation, deletion, monitor flags, language, counters and
the TMDB/metadata refresh are sanctioned direct writes inside `Catalog` and `Books`. Find the
current write sites by searching for `Repo\.(insert|update|delete|update_all)` across
`lib/cinder/catalog/` rather than recalling them; `catalog.ex` itself only delegates.

Callers hold no `Repo` mutations of their own: `lib/cinder/download/*` (including
`Cinder.Download.BookPoller`), `acquisition.ex` and `lib/cinder/library/*`. The sanctioned
exceptions each own one table and nothing derived:

- `lib/cinder/library/import_stage.ex` owns `import_stages`.
- `lib/cinder/library/sidecar_quarantine.ex` owns `sidecar_quarantines`.
- `lib/cinder/download.ex` writes only its own `download_intents` tables.

A new exception is legitimate only when a plan calls it out. When it lands, add it to this list.

The reason: SQLite runs WAL with `busy_timeout: 5000` in dev, test and runtime, so a web write
racing the poller waits instead of failing with "database busy". That holds only while writes go
through the choke-points.

## The catalog is split by concept

Code outside `lib/cinder/catalog/` reaches most of the catalog through `Cinder.Catalog`, which
only delegates. Some modules it names directly: every movie status write is a `MovieLifecycle`
verb, a caller announcing a change after its own commit uses `Events`' announcements, and
modules with an interface of their own (`Attention`, `AnimeResolver`, `Genres`,
`Grabs.get_grab_file/1`, ...) have no facade name. Whether the facade stays is #829. Inside the
catalog, a concept module calls the modules it needs directly and never the facade.
`test/code_health_test.exs` fences that the facade only delegates and that nothing under
`lib/cinder/catalog/` calls it. A new catalog function goes in the concept that owns it; it gets
a `defdelegate` in the facade only when a caller outside the catalog needs it.

- The kernel is called by every concept and calls none of them: `Cinder.Catalog.Events` (every
  announcement on the `"movies"` and `"series"` topics, and `[:cinder, :transition]`) and
  `Cinder.Catalog.Episodes` (an episode's derived state, its search budget and its guarded
  write).
- The concepts:
  - `MovieLifecycle`: every movie status write.
  - `MovieCatalog`, `SeriesCatalog`: movie and series rows, the series tree and monitoring.
  - `EpisodeSearch`: what the TV sweep and the manual season panel search for.
  - `Grabs`: the TV grab lifecycle, verification holds included.
  - `ManualGrab`: a release the operator picked.
  - `BlockedReleases`: the release blocklist.
  - `MediaProfiles`, `Profiles`: a title's preferences.
  - `TitleDeletion`: deleting and cancelling titles, and their audit.
  - `MetadataRefresh`: TMDB metadata and probed media info.
  - `Discovery`: TMDB reads.
  - `Identity`, `SceneNumbering`: aliases and episode coordinates.

## Imports go through the staged import

Every file an import places in a library goes through `Cinder.Library.StagedImport`. The stager
(`Cinder.Library`, `EbookImport`, `AudiobookImport`) places the files. `commit/2` hands the
caller's Catalog or Books write the stage ids, and that write marks them committed inside its own
transaction. The journal then settles each file: a committed one runs its post-commit effects, and
everything else rolls back. Callers never look inside the handle; the one value they read is its
record.

The pollers hold the household import lock (`StagedImport.run/1`) from an import's first placement
until it settles, and `StagedImport.reconcile/0` takes the same lock. `Cinder.Download.Cleaner`
takes it for its ownership check and removals, because an import releases its owner before it
settles. The lock is not re-entrant through `:global` itself, so take it only through `run/1`.
The residual-file Part decision from `/activity` does not take it yet (#783).

## Most library writes go through the rooted helper

For a path inside a library root, `Cinder.Library.Filesystem.Disk` runs these operations in a
bounded subprocess, `priv/rooted_fs_main.py`, whose code is in `priv/rooted_fs.py`: `hold` (the
open descriptor a write goes through), `mkdir`, `mkdir_near`, `rename`, `rename_exclusive`,
`exchange`, `unlink`, `rmdir`, `chmod`, `reconcile_duplicates` and `sync_parent`. Each one opens
the path's directories from the configured root through `open_beneath`, so a symlink swapped into
a directory fails the call instead of redirecting it. `mkdir_p`, `ln`, `cp` and `cp_exclusive`
stay plain `File` calls, guarded only by the caller's `PathPolicy` checks. A path outside every
root falls back to `File` calls or `mv --exchange`.

On a `fuse.mergerfs` mount, the creating operations (`hold` of a new file, `rename_exclusive`,
`mkdir_near`) work on a backing branch, and so does an `exchange` the union refuses. The helper
reads the branch from mergerfs's own `user.mergerfs.*` xattrs (`mergerfs_backing_location_fd`).
A creating operation then proves that the union shows its file under the new name
(`wait_for_unique_path`). When the union shows another branch's container there too,
`rename_exclusive` moves its file back to the source (`move_back_shadowed`). It reports a plain
`EEXIST` once the identity it held before the rename proves the file at the source is still
Cinder's and both directories are synced; otherwise it reports the rename as committed.
`mkdir_near` and the file create leave theirs committed (#905). The other operations act on the
union path, and the mergerfs opens never cross into a nested mount.

A library root may sit below the mount, as in prod, where the pool is at `/media` and each root is
a folder in it. Take a path's place on a branch from the backing path of its directory or of the
root, as `mergerfs_near_relative` does. Deriving it from the mount point breaks under a bind of a
pool subdirectory, which `reconcile_duplicates` still does (#884).

Tests have no mergerfs. In `test/cinder/library/filesystem/disk_rooted_test.exs`,
`mergerfs_rename_shim!` and `mergerfs_shim!` (reached through `duplicate_tombstones!`) fake the
mount check and the xattrs around the real helper. The `branch:` option of
`mergerfs_rename_shim!` puts the mount above the library root.

## The imported quality has one owner

What a movie or episode recorded about its file lives in its `imported_*` columns, and
`Cinder.Library.ImportedQuality` is the one list of them: a struct with one field per column.
Stagers record what `capture/3` and `for_outcome/4` return, and an arbitrated TV decline what
`declined/3` returns. Writers set the columns only through
`columns/2`, the schemas cast `column_names/2`, and the import and upgrade decisions read a row
through `of/1`; only display code and queries read a single column directly. Episodes have no
default-audio column, and the module records that. A new column is one field in that module, plus
the migration and the schema `field`; `test/cinder/library/imported_quality_test.exs` fences the list
against both schemas and runs probe → quality → row → quality through each import writer.

## Operator attention has one owner

Whether an item is in flight, needs attention or waits, which operator actions it offers and which
fix on another page clears it, come from `Cinder.Catalog.Attention.classify/1` (movies, TV grabs,
series on an anime hold) and `Cinder.Books.Attention.classify/2` (book targets). Views render
badges, buttons, fix links and counts from it; they never decide attention or an action from raw
status fields or status sets. Each anime hold reason maps to its phase and fix in one place in
`Attention`. Each operator function refuses an item that does not
offer its action. `test/cinder/catalog/offered_actions_test.exs` (movies, grabs) and
`test/cinder/books/attention_test.exs` (book targets) run every action against every state, so a
new operator action is one classification entry, its guard, and a row in the matching test.

The exception is a residual-files grab's per-file decisions: they render from
`Grabs.unresolved_grab_files/1`, and `Cinder.Download.TvPoller` claims each file.

## The approval gate lives in the data model

`Cinder.Requests` is the only path that creates a `:requested` movie or series row, or a book
target, from a user action, the API included. A non-admin request writes only a `:pending`
`Request` row until an admin approves it or `auto_approve_all` is on. `auto_approve_all` is a
live-read DB setting (`nil` means false) that an admin writes in `/settings`.

The gate sits upstream of row creation because the poller consumes any `:requested` or wanted
row with no further auth check. Once the row exists, the pipeline grabs it.

- Movie creation is a separate insert: `Catalog.add_movie/1`, and
  `Catalog.find_or_create_at_requested/2`, the only one reachable from a user action, gated by
  `Cinder.Requests`.
- Every approval, admin or automatic, runs through one transaction in `Cinder.Requests`
  (`approve_target/3`). Each target kind's part sits in an adapter under
  `Cinder.Requests.Approval.*`, and only `Cinder.Requests` calls it.
- The movie adapter announces creation after commit (`{:movie_created, movie}`) so open `/` views
  update. The Catalog insert never broadcasts mid-transaction.
- `/api/v1` request mutations route through `Cinder.Requests`. API actions never write request
  lifecycle state directly.

## Translation stays in the web layer

The domain (`lib/cinder/`) emits a code or an English msgid, and `CinderWeb` translates it at
render time: `CinderWeb.SettingsLabels` for settings and health labels, `CinderWeb.LiveHelpers`
for reasons such as `book_hold_reason/1`. Beyond translation, a domain module references no
`CinderWeb` module at all. `@allowed_refs` in `test/code_health_test.exs` lists each exception
with its reason; the test fails on a reference it does not list, and on an entry nothing uses.

A notifier transport runs outside the caller's process in production and dev: under the default
`:async` dispatch, `Cinder.Notifier.Dispatcher` runs it in a `Task.Supervisor` child, so the
caller's Gettext locale never reaches it. A transport's own test calls it directly, in the test
process, where a locale the test sets does reach it. A transport that translates pins its locale
itself.

## Background work is supervised and bounded

Download polling, import and the book/audiobook pollers run under the supervision tree, not in
the request path. Crash recovery is a feature: prove it with a test.

Every call a poller makes has a bound:

- Provider HTTP goes through `Cinder.HTTPPolicy.bounded_request/2`, which enforces a size ceiling
  and receive and hard-deadline timeouts.
- A subprocess goes through `Cinder.BoundedCommand.run/4`: a supervised `Port` killed with
  `SIGKILL` by its OS pid on timeout. `Task.shutdown(:brutal_kill)` kills only the Elixir task,
  so a child that never reads stdin (ffprobe, ffmpeg, unrar) keeps running and leaks one process
  per retry. A condition other than time, such as `BookArchive.Rar`'s expanded-size ceiling
  during `unrar x`, is a `check:` option on the same call, not a second receive loop. A port kept
  open across calls closes through `BoundedCommand.kill_and_close/1`. The exceptions are
  `Cinder.Disk.CommandProbe`, a GenServer that owns its port across messages, and
  `Subtitles.Sync.Ffsubsync`, which runs under coreutils `timeout --kill-after`.
- Archive extraction carries entry-count and expanded-size ceilings.
- The directory walk every importer and the completion content check run,
  `Cinder.Library.safe_walk/1`, goes through `Cinder.Library.BoundedWalk.run/3`: a supervised
  task with a 30 s deadline that answers `{:error, :timeout}`. The three download pollers hold an
  import on it without spending the retry budget, as on a full disk. A walk past its deadline is
  never killed, since its read may still hold a dirty I/O scheduler thread. The guard counts it as
  stuck until it returns, and while it does, a new walk under its root is refused at once, as is
  any new walk once two are stuck. The walk's reads, `Filesystem.Disk.ls/1` and `lstat/1`, are raw
  calls that skip the VM's one file server, so a read on a wedged mount blocks only its own
  process, not every `File` call in the app. The `Sidecars` walks and the adoption scan have no
  deadline yet (#944).

The reason: one unbounded call in a single-tick poller freezes every target sharing that tick,
not just the file or request in flight.
