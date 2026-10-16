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
  - specs/*books*/**
---

**The track is finished** and released in v3.0.0. Work on these paths is incremental: one issue,
fix or feature at a time. `docs/agents/history.md` has the status, including the two open roadmap
items, which are operator actions that no commit can close.

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

The write choke-points, the approval gate, the external-service behaviours and bounded work are
the same rules as for video, in `docs/agents/architecture.md`; its Books paragraph lists the book
choke-points. The books-specific parts:

- **No automatic release search, by design** (see `docs/agents/history.md`). The
  `Cinder.Download.BookPoller` moduledoc states it: `Cinder.Acquisition.Books` exports no
  `best_book_release/2`. An admin picks a release in manual search on `/books/:id`; the
  unattended pipeline takes over only after that.
- **The whole `BookPoller` tick is one synchronous `GenServer` call**, so an unbounded call there
  freezes every book and audiobook target, not just one file. The books-side bounded calls are
  `AudioProbe.Ffprobe.probe/1`, `BookArchive.Rar.list_entries/3`, and the archive ceilings in
  `library/book_archive/{zip,rar}.ex`. Evidence: `docs/audits/2026-09-02-books-bounded-work-audit.md`.

## Decisions that are already settled — do not re-derive them

B0 closed these, and `test/cinder/books_b0_contract_test.exs` asserts the parity matrix still
traces to real tests. Read them from `specs/054-books-b0-inventory-contract/contracts/books-parity-contract.md`,
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

`specs/053-books-readarr-replacement/plan.md` is the build record for the track, one
section per milestone, each ending in a "Shipped as N slices" subsection plus the execution notes
and amendments discovered while building it. **Those notes are authoritative** where they
contradict the original plan prose — read them before reconstructing why something works the way
it does. Per-slice plans are `specs/NNN-books-<phase>-<slug>/plan.md` (`specs/054-…` through
`specs/066-…`).
