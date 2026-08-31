---
description: Books/Readarr-replacement track — phase order, where each phase's plan lives, and which decisions belong to B0 rather than to the phase being implemented.
globs:
  - lib/cinder/books/**
  - lib/cinder/books.ex
  - lib/cinder/acquisition/book_*
  - lib/cinder/download/book_*
  - lib/cinder/library/book_*
  - docs/plans/*books*
  - docs/specs/*books*
---

The books work replaces Readarr. The track is planned as milestones B0–B6.

| Phase | Owns |
| ----- | ---- |
| B0 | Readarr inventory, parity contract, labeled corpus, frozen fixtures |
| B1 | Media-kind and lifecycle foundation |
| B2 | Books catalog, metadata adapters, identity resolution |
| B3 | Discover, request, approval, book library UI |
| B4 | E-book search, scoring, download, validation, publication |
| B5 | Monitoring, wanted state, author policies, operations |
| B6 | Readarr migration, adoption preview, e-book cutover |

Two milestones matter for release framing: **book MVP after B4** (a household member
requests an e-book, an admin acquires and imports it end to end) and **e-book Readarr
cutover after B6** (monitored e-books and the existing library migrate safely; Readarr
can be switched off).

## Finding the current position

Do not assume from this file which phase is next — it does not track state. Determine it:

- `git log --oneline -- lib/cinder/books lib/cinder/acquisition/book_* lib/cinder/library/book_*`
- the newest `docs/plans/*-books-*.md` — one per phase or slice, named
  `<date>-books-<phase>-<slug>.md`
- the roadmap itself: `docs/plans/2026-08-20-readarr-replacement-roadmap.md`

Read **only the section for the phase you are implementing**, plus that phase's own plan
doc. The roadmap is 1,100+ lines and the rest of it is history.

## Phases ship in slices

A large phase is split, and the split is recorded in a "Shipped as two slices" subsection
under that phase, along with amendments discovered while executing it. Those amendments are
the authoritative record of decisions that contradict or refine the original plan — read
them before re-deriving anything. For example B4 split into B4a (the decision layer:
indexer queries, parser, scorer) and B4b (download intent, poller, archive validation,
publication).

## Decisions that belong to B0, not to your phase

B0's own acceptance criterion is that these are already explicit. Take them from
`docs/specs/2026-08-20-books-parity-contract.md` and
`docs/audits/2026-08-20-bookshelf-inventory.md` (plus
`docs/audits/data/books-parity-matrix-v1.json`). Do not choose them yourself, and do not
infer them from what is convenient to implement:

- e-book vs audiobook order
- accepted formats — whether AZW3/PDF are cutover-critical or EPUB alone suffices
- the publisher adapter — filesystem or Calibre
- the naming contract
- the author-monitoring policy
- the corpus precision threshold that gates automatic release selection

If one of these genuinely is not settled in B0's artifacts, say so and stop. An unsettled
B0 decision is a gap in B0, not a judgement call for the phase consuming it.
