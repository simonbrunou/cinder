# One release judge for the book family

The B7a audiobook plan (`specs/065-books-b7-audiobooks/plan.md`, B7a §1 and B7d §2) built the
audiobook scorer, parser and manual-search panel as copies of the e-book ones, so that no "future
e-book-only tweak" would carry an audiobook conditional. The history showed the opposite: every
commit to the audiobook scorer also touched the e-book one, and the differences between the two
kinds turned out to be data. So one judge (`Cinder.Acquisition.BookScorer`), one parser
(`Cinder.Acquisition.BookParser`) and one panel serve both book kinds, and everything that differs
between e-book and audiobook (formats, size band, release-name vocabulary, the narrator credit)
lives as data in `Cinder.Acquisition.BookKind` (#734).

## Considered options

- A behaviour with one adapter module per kind: every callback would return a constant, because
  the only non-data difference, the narrator rule, uses wording shared by the whole family.
- Per-kind rules owned by each release struct: the file-side callers hold a media-kind atom, not
  a struct module.

## Consequences

The book kind comes from the release struct, so `Cinder.Download.grab_book_target/3` keeps its
two release structs as a safety rail. A change to title, collection or language judging lands
once and is tested for both kinds by the shared suites.
