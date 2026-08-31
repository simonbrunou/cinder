# Books B4b — e-book download, validation, and publication

**Status:** planned 2026-08-31. Base: `origin/main` @ `123f0c15`.
**Milestone:** the second slice of
[B4](2026-08-20-readarr-replacement-roadmap.md#b4--e-book-search-scoring-download-validation-and-publication).

## What B4a left, and what this slice owns

[B4a](2026-08-30-books-b4a-ebook-release-search-and-scoring.md) landed the **decision layer**:
`Cinder.Acquisition.Books.candidates/2` turns an approved book target into a ranked, explained
list of candidate releases. It grabs nothing and writes nothing.

B4b is the **acquisition-to-disk layer**: given one chosen release, durably submit it, track it,
validate what arrives, publish it under the books root, and record the file. The target reaches
`:available`.

**Out of scope, deliberately:**

- **The operator UI.** The manual-search panel that lets a human pick from `candidates/2` and
  press Grab is B4c. B4a shipped its decision layer with no production caller for the same
  reason — the reviewable unit for a decision layer is the decision layer.
- **Automatic selection.** Still gated: there is no `best_book_release/2`, so the book poller has
  **no search sweep**. This is the one structural difference from `Download.Poller` and
  `Download.TvPoller` and it is the roadmap's precision gate, expressed as absent code.
- **Audiobooks** (B7), **adoption/migration** (B6), **wanted/monitoring sweeps** (B5).

## Design

### 1. In-flight state lives on a grab row, not on the target

`book_targets.status` is locked by the parity contract to exactly four values — `unmonitored`,
`monitored`, `available`, `held`. There is no `:downloading`. That is not an oversight to route
around: the contract fixes those states, and `movies.status` (a 12-value acquisition state
machine) is the video model, not the book one.

So in-flight download state goes on **`book_grabs`**, the books sibling of `grabs`:
`book_target_id`, `download_id`, `download_protocol`, `release_title`, `content_path`, progress
fields, and `import_attempts`. The target stays `:monitored` for the whole download — which is
exactly what `monitored` means in the contract ("eligible for missing-item search") — and moves
to `:available` only after a durable import commit, or to `:held` with an exact reason on a
terminal failure ("operator-visible … import conflict; never auto-grab").

`book_grabs` carries a **unique index on `book_target_id`**: one in-flight download per target is
the invariant that makes a repeated poll tick unable to double-grab.

### 2. The download intent gains a `:book_target` kind

`download_intents` already is the durable pre-side-effect reservation, and reusing it is what
makes book submission crash-safe for free: `reserve_intent/1` → `submit_intent/1` →
`reconcile_intent/1`, encrypted download URL, bounded exponential retry,
`find_by_operation_key/1` recovery, and `cleanup_pending` teardown all apply unchanged.

- `Intent.kind` gains `:book_target`; `target_id` is a `book_targets.id`.
- A partial unique index `download_intents_book_target_index` (`where: kind = 'book_target'`)
  mirrors the movie one, so two concurrent grabs of one target cannot both reserve.
- `reconcile_intent/1` gains a book clause that creates the `book_grabs` row, mirroring
  `reconcile_episodes/1` creating a `grabs` row.
- `submission_target_active?/1` gains a book clause: a target that stopped being `:monitored`
  mid-flight (operator cancelled, request deleted) makes the reserved intent ineligible, and it
  is cleaned up instead of submitted.

### 3. `Cinder.Download.BookPoller`

`use Cinder.Download.PollerSkeleton`, like its two siblings. Three passes, **no search pass**:

1. `reconcile_pending_intents([:book_target])` — crash recovery.
2. `advance_downloading` — client status per `book_grabs` row; `:completed` + `content_path` ⇒
   ready to import; a client-reported dead download or a blocked content verdict releases the
   grab and holds the target with the reason.
3. `import_downloaded` — validate, publish, record, `:available`.

Every unit runs inside the skeleton's `isolate/2`, and every pass re-derives its work from the
DB, so a restart mid-download recovers.

### 4. Validation: `Cinder.Library.BookSources`

The books sibling of `Cinder.Library.MovieSources` — resolve a completed download to **one**
accepted book file, or an explained refusal.

| Refusal | Meaning |
|---|---|
| `:no_book_file` | nothing in the download carries an accepted extension |
| `:ambiguous_book_files` | two or more accepted files that are not the same book |
| `:unsupported_archive` | the payload is `.rar`/`.zip`/`.7z`/split volumes |

Accepted extensions are `.epub`, `.azw3`, `.mobi` — the parity contract's e-book profile, and the
same allow-list `BookScorer` already gates releases on, read from one shared definition so the
scorer and the importer cannot drift into accepting different formats.

**Archives are refused, not expanded.** The roadmap asks for "bounded entry count and expanded
size, no traversal/symlink escapes, no executable substitution". Meeting that honestly means an
extractor: `.rar` needs an external `unrar` binary (a new runtime dependency and a large parser
attack surface), and a zip extractor must defend against zip bombs and traversal entries. That is
its own slice with its own tests. Until then the pipeline **fails closed with an exact reason**,
which is what the contract requires of an unhandled payload anyway, and which is precisely what
`MovieSources` already does with `.rar`. `.epub` is itself a zip container and is imported as an
opaque file — it is never expanded, so no extraction surface exists in this slice.

The remaining roadmap requirements are met without an extractor:

- **regular files only / no symlink escape / no traversal** — `Cinder.Library.PathPolicy`
  `lstat`s every component and refuses anything that is not a regular file under a configured
  import root. Reused unchanged; not reimplemented.
- **no executable substitution** — the extension allow-list is a *positive* list, so a `.epub.exe`
  or a bare ELF is `:no_book_file`.
- **no mixed unrelated release** — two accepted files whose names disagree is
  `:ambiguous_book_files`, never "pick the biggest". Multi-format releases are the exception the
  rule has to allow: `Title.epub` + `Title.mobi` is one book, so files that share a normalized
  stem collapse to the single best-ranked format rather than being called ambiguous.

### 5. Publication: `Cinder.Library.BookImport` + `Cinder.Library.BookNaming`

Placement reuses `Cinder.Library.StageEngine` — the same durable two-phase-commit journal, the
same hardlink-then-copy fallback, the same `ImportStage` crash recovery — so books get
crash-safety without a second implementation of it.

`BookNaming.dest/3` is `root/Author/Title/<original release filename>`.

**The file name is preserved; only the folders are derived.** That is the contract's "Automatic
renaming remains off for migration parity … Preserve release filenames is the B0 default", read
exactly: the rename policy is about the *file*. A flat books root is not a layout any consumer
reads, and Booklore expects `Author/Title/`. Author and title come from the Cinder catalog (not
from the release name), sanitized through the same illegal-character and dot-only rules
`Library.Naming` already applies, so no provider title can escape the root.

The imported asset is recorded in **`book_files`** (`book_target_id`, `path`, `size`, `format`,
nullable `edition_id`). Nullable on purpose: the contract's File boundary belongs to an edition,
but it also forbids resolving identity from "a title, ISBN, ASIN, path, or filename alone", and a
release name usually cannot name an edition. An explicit null is the contract's "explicitly
incomplete" signal; inventing an edition to satisfy a foreign key would be the exact silent
fallback the contract exists to prevent.

### 6. Write discipline

Book status and derived state stay behind the books choke-points, matching AGENTS.md:

- `book_targets.status` → `Books.transition_target/3` (guarded, `expect:`-style, one post-commit
  broadcast) — already exists.
- `book_grabs` → `Cinder.Books.Grabs`; `book_files` → `Cinder.Books.Files`.
- Parking a target `:held` with a reason → `Books.hold_target/2`. Both halves of the pipeline reach
  it (`Cinder.Download` on a permanently rejected submission, `BookPoller` on a dead download or a
  refused payload), so the reason a household member reads renders the same way whichever half
  gave up, and no failure path can invent its own.

`Cinder.Download.BookPoller` and `Cinder.Library.BookImport` hold **no `Repo` mutations of their
own**, exactly as `download/poller.ex` and `library/*` hold none today.

## Done when

- A monitored target with a chosen release is submitted, tracked, validated, published under the
  books root, recorded in `book_files`, and left `:available`.
- Wrong/absent format, ambiguous multi-book payloads, and archives are refused with their own
  atoms and hold the target with that reason.
- Repeated poll ticks cannot double-grab (unique intent + unique `book_grabs` target index) or
  double-import (`ImportStage` journal + idempotent same-inode placement).
- A crash between placement and commit recovers through `Library.reconcile_stages/0`.
- The books pipeline still exports no automatic selection: no `best_book_release/2`, and the book
  poller has no search pass.
- `mix test` is green.

## Amendments from review

Recorded here rather than silently folded in, because several contradict what the first pass
shipped.

- **Every terminal verdict is bounded, and every give-up holds the target.** The dominant bug class
  in this slice is a failure that leaves a target `:monitored` with nothing in flight: with no
  search pass, that state is indistinguishable from "nobody picked a release yet" and nothing looks
  at it again. Two paths still did it — `Download.abandon_reserved/2` on a permanently rejected
  submission, and the download phase acting on a single `{:error, :not_found}`. Both clients derive
  `:not_found` from a *successful* empty queue/history lookup, so a routine blip was destroying live
  downloads with `delete_files: true`. The download phase now takes the shared `import_attempts`
  budget, matching all three video sites.
- **`grab_book_target/2` is `:ebook` only.** Nothing under it is audiobook-aware, so an audiobook
  target would have published an EPUB into the audiobook root. `{:error, :unsupported_media_kind}`
  until B7.
- **EPUB validation checks the OCF container, not just the ZIP header.** `PK\x03\x04` says "some
  ZIP", and `.zip` is a format this pipeline refuses outright — a renamed archive was publishing as
  an available book. The mandatory uncompressed `mimetype`/`application/epub+zip` first entry sits
  inside the prefix already read for MOBI.
- **Parity gates the first pass missed:** `StallReaper.enabled?()` (books ignored the operator
  switch), the reap clock (read pre-write, so a >24h outage reaped a healthy download),
  `Disk.import_space_available?/2` (a full disk burned the budget and parked the target), and the
  `ContentPolicy` detail (dropped, so a hold named no file).
- **`:held` reaches the UI.** `LiveHelpers.book_badge_state/2` deferred `:held` to B4 in as many
  words; this is B4, five paths now produce one, and a held target read "Approved" forever.
  `Notifier.Email` likewise dropped `:book_available`, so the requester never heard.
