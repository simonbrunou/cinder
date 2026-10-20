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
are written only inside `Cinder.Catalog` and its submodules under `lib/cinder/catalog/`:

- `Cinder.Catalog.MovieLifecycle` for every movie status write, upgrades and adoption included.
  Each event is a named verb (`attach/2`, `import_staged/2`, `record_failure/2`, `cancel/2`, ...)
  whose write is a compare-and-swap on the struct the caller read: that is the race-safe poller
  write. `record_submission_failure/3` and `adopt/3` read their own row inside their transaction
  instead. `MovieLifecycle.transitions/0` lists every legal movie edge.
- `Catalog.transition_episode/3`. Its `expect:` form is the race-safe poller write.
- Audited siblings that each own one lifecycle: TV grabs, TV release verification, episode
  adoption, deletion, TMDB refresh.

Books and audiobooks follow the same rule through `Cinder.Books.transition_target/3` and
`BookTargetTransition.guarded/4`, plus their audited siblings: `hold_target/4`, `pause_target/1`,
`monitor_target/4`, `import_resolution/1`, `Files.record_import/3` and `record_import_set/3`.
Every `book_grabs` mutation lives in `Cinder.Books.Grabs`.

Each transition emits exactly one broadcast, after commit, never inside the enclosing
`Repo.transaction`.

Direct `Repo` writes are not banned. Creation, deletion, monitor flags, language, counters and
the TMDB/metadata refresh are sanctioned direct writes inside `Catalog` and `Books`. Find the
current write sites by searching for `Repo\.(insert|update|delete|update_all)` across
`lib/cinder/catalog.ex` and `lib/cinder/catalog/` rather than recalling them. Include
`catalog.ex`, because the choke-points themselves live there.

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

## Imports go through the staged import

Every file an import places in a library goes through `Cinder.Library.StagedImport`. The stager
(`Cinder.Library`, `BookImport`, `AudiobookImport`) places the files. `commit/2` hands the
caller's Catalog or Books write the stage ids, and that write marks them committed inside its own
transaction. The journal then settles each file: a committed one runs its post-commit effects, and
everything else rolls back. Callers never look inside the handle; the one value they read is its
record.

The pollers hold the household import lock (`StagedImport.run/1`) from an import's first placement
until it settles, and `StagedImport.reconcile/0` takes the same lock. The lock is not re-entrant
through `:global` itself, so take it only through `run/1`. The residual-file Part decision from
`/activity` does not take it yet (#783).

## Operator attention has one owner

Whether an item is in flight, needs attention or waits, and which operator actions it offers, come
from `Cinder.Catalog.Attention.classify/1` (movies, TV grabs) and `Cinder.Books.Attention.classify/2`
(book targets). Views render badges, buttons and counts from it; they never decide attention or an
action from raw status fields or status sets. Each operator function refuses an item that does not
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

The reason: one unbounded call in a single-tick poller freezes every target sharing that tick,
not just the file or request in flight.
