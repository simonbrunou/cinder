---
description: Books/audiobooks track (B0–B8) is shipped and released — where the code and its write choke-points live, the invariants an incremental change must not break, and which decisions are already settled.
globs:
  - lib/cinder/books/**
  - lib/cinder/books.ex
  - lib/cinder/acquisition/book_*
  - lib/cinder/acquisition/books.ex
  - lib/cinder/acquisition/audiobook*
  - lib/cinder/acquisition/audiobooks.ex
  - lib/cinder/download/book_*
  - lib/cinder/library/book_*
  - lib/cinder/library/audio*
  - lib/cinder/library/**/audiobook*
  - lib/cinder/library/**/readarr.ex
  - lib/cinder_web/live/book_*
  - docs/plans/*books*
  - docs/specs/*books*
---

**The track is finished.** B0–B8 all shipped and released in v3.0.0 (`CHANGELOG.md`, tagged
2026-09-03). There is no next phase and no "current slice" — work on these paths is incremental
now: one issue, fix, or feature at a time, under AGENTS.md's normal workflow. Do not open a new
`docs/plans/*-books-*.md` phase doc for a bug fix.

Two roadmap criteria remain open and **neither is closable by a commit**: the two-week
Readarr/Bookshelf-stopped dogfood window and the explicit Bookshelf decommission that follows
sign-off. Both are operator actions — `docs/books-dogfood-checklist.md` and
`docs/readarr-migration.md#decommissioning-bookshelf-after-sign-off`.

## Where the code lives

| Concern | Modules |
| ------- | ------- |
| Catalog + context | `lib/cinder/books.ex`, `lib/cinder/books/` (`work`, `edition`, `author`, `credit`, `identifier`, `series_membership`, `book_target`, `book_file`, `book_grab`) |
| Metadata | `Cinder.Books.Metadata` + `metadata/open_library.ex`, `metadata/hardcover.ex`; `identity.ex`, `title_fold.ex`, `refresher.ex`, `bibliography_refresher.ex` |
| Decision layer | `Cinder.Acquisition.{Books,BookParser,BookScorer,BookRelease}` and `{Audiobooks,AudiobookParser,AudiobookScorer,AudiobookRelease}` |
| Download | `Cinder.Download.BookPoller` (single tick, all book + audiobook targets) |
| Import + publish | `library/book_import.ex`, `audiobook_import.ex`, `book_naming.ex`, `audiobook_naming.ex`, `book_sources.ex`, `audiobook_sources.ex`, `book_archive/{zip,rar}.ex`, `audio_probe/`, `audiobook_server/audiobookshelf.ex` |
| Migration | `library/migration_source/readarr.ex`, `library/migration_adoption/readarr.ex`, `books/adoption.ex` |
| Monitoring + ops | `books/{rehunter,book_author_policy,book_blocked_release,book_ops_log}.ex` |
| UI | `lib/cinder_web/live/book_detail_live.ex`, `book_discovery_live.ex`, plus the books tabs on `/library` and `/dashboard` |

## Invariants an incremental change must not break

- **Write choke-points, same discipline as the video catalog.** A `book_targets` status or
  derived-state write goes through `Cinder.Books.transition_target/3` →
  `Cinder.Books.BookTargetTransition.guarded/4` (its `:expect` is the race-safe poller write), or
  one of the audited siblings that owns a lifecycle (`hold_target/4`, `pause_target/1`,
  `monitor_target/4`, `import_resolution/1`). Imported files go through
  `Cinder.Books.Files.record_import/3` and `record_import_set/3`. Every `book_grabs` mutation
  lives in `Cinder.Books.Grabs`. `Cinder.Download.BookPoller` and `Cinder.Download` hold **no**
  `Repo` writes of their own — keep it that way.
- **The approval gate is the same one.** A user-facing book or audiobook request goes through
  `Cinder.Requests`; nothing else may create a target from a user action.
- **External services stay behind behaviours** resolved with `Application.fetch_env!/2`:
  `Cinder.Books.Metadata`, `Cinder.Acquisition.Indexer`, `Cinder.Download.Client`,
  `Cinder.Library.AudiobookServer`. Tests use the Mox mocks, never the network. See
  `rule://external-services-via-behaviours`.
- **There is no automatic release search for books, and that is deliberate.**
  `lib/cinder/download/book_poller.ex:18-21` states it: `Cinder.Acquisition.Books` exports no
  `best_book_release/2`, because the roadmap gates automatic selection on a measured corpus
  precision threshold. An admin picks a release in manual search on `/books/:id`; the unattended
  pipeline takes over only after that. Do not "fix" this as a missing feature — adding automatic
  selection is a product decision with a stated prerequisite, not a bug.
- **Bounded work everywhere.** Provider HTTP goes through `Cinder.HTTPPolicy.bounded_request/2`
  (4 MB ceiling, 15s receive, 60s hard deadline). Archive extraction carries entry-count and
  expanded-size ceilings (`library/book_archive/{zip,rar}.ex`). Any subprocess uses the
  `Task.async` + `Task.yield(timeout)` + `Task.shutdown(:brutal_kill)` idiom, with the
  missing-binary `rescue` **inside** the task — see `AudioProbe.Ffprobe.probe/1`
  (`@probe_timeout 10_000`) and `BookArchive.Rar.list_entries/3` (`@list_timeout_ms 5_000`).
  The whole `BookPoller` tick is one synchronous `GenServer` call, so an unbounded call there
  freezes every book and audiobook target, not just the one file. The one accepted exception is
  the video-shared `Cinder.Library.MediaInfo.Ffprobe` — tracked in issue #447, do not widen it.
  Evidence for all of the above: `docs/audits/2026-09-02-books-bounded-work-audit.md`.

## Decisions that are already settled — do not re-derive them

B0 closed these, and `test/cinder/books_b0_contract_test.exs` asserts the parity matrix still
traces to real tests. Read them from `docs/specs/2026-08-20-books-parity-contract.md`,
`docs/audits/2026-08-20-bookshelf-inventory.md`, and
`docs/audits/data/books-parity-matrix-v1.json`:

- e-book vs audiobook order
- accepted formats (EPUB/AZW3/MOBI e-book, M4B/MP3 audiobook)
- the publisher adapters (Booklore filesystem layout, Audiobookshelf scan handoff)
- the naming contract
- the author-monitoring policy
- the corpus precision threshold that would gate automatic release selection

Changing one of these is a product decision with a written contract behind it, not a judgement
call inside a fix.

## Where the history is

`docs/plans/2026-08-20-readarr-replacement-roadmap.md` is the build record for the track, one
section per milestone, each ending in a "Shipped as N slices" subsection plus the execution notes
and amendments discovered while building it. **Those notes are authoritative** where they
contradict the original plan prose — read them before reconstructing why something works the way
it does. Per-slice plans are `docs/plans/<date>-books-<phase>-<slug>.md`. The roadmap is 1,100+
lines: read only the section you need, never the whole file.
