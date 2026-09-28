# Books B7 — Audiobook acquisition and Audiobookshelf publication

**Status:** planned 2026-09-02. Base: `main` @ `7c44d8dc` (post-B6, all three B6 slices merged).
**Milestone:** [B7](2026-08-20-readarr-replacement-roadmap.md#b7--audiobook-acquisition-and-audiobookshelf-publication)
of the [Readarr replacement roadmap](2026-08-20-readarr-replacement-roadmap.md).
**Governing spec:** [the B0 parity contract](../specs/2026-08-20-books-parity-contract.md) and the
[Bookshelf inventory audit](../audits/2026-08-20-bookshelf-inventory.md) own the audiobook format
list, the monitoring vocabulary, the naming/root contract, and the fact that the real deployment
has a *second*, separately-captured Bookshelf instance in front of Audiobookshelf. Decisions below
are *taken* from those two documents wherever they speak; §0 records the three places they are
silent and a judgment call had to be made instead — do not treat any of §0 as contract-derived.

## What B6 left, and what B7 owns

B6 shipped the e-book cutover only. Its own "What stays out" is explicit: "the audiobook Bookshelf
instance is untouched and unreachable from any B6 code path — no `MigrationSource` call targets it,
no `book_targets` row of `media_kind: :audiobook` is ever created here." B4c rendered an
`:audiobook` target **read-only** on `/books/:id` — status badge and hold reason, no search, no
Grab — and said so in its own moduledoc: "an `:audiobook` target ... render[s] read-only ... see
the B4c plan." B7 is the slice both of those notes hand off to.

Tracing the actual code (not assumed) shows the audiobook *target* pipeline is less green-field
than the roadmap's Work list makes it sound — most of the plumbing around it is already
kind-generic, and B7's real job is narrower than "build an audiobook stack from nothing":

- **`book_targets` already accepts `media_kind: 'audiobook'`** — the CHECK constraint added in
  `20260824101744_create_books_catalog_and_targets.exs` is `media_kind IN ('ebook', 'audiobook')`
  from day one, and `Cinder.Books.monitor_target/4` / `arm/3` dispatch on `media_kind` generically
  (`when kind == media_kind`), not `:ebook`-only. An audiobook request, once approved, already
  creates a real `:monitored` `book_targets` row today.
- **`media_profiles` already accepts `kind: :audiobook`** — `Cinder.Catalog.Profile.changeset/2`
  validates against `LibraryKind.all()`, which has always included `:audiobook`, and
  `CinderWeb.ProfilesLive` (`profiles_live.ex:273-280`) already offers "Audiobooks" in its kind
  `<select>` and already has `profile_kind_label(:audiobook)`. An operator can create an audiobook
  profile row today; it just has nothing to acquire against.
- **The `audiobooks` library root is already wired** — `Cinder.LibraryKind`'s `root_role(:audiobook)
  == :audiobooks` generates `audiobooks_library_path` through `Settings.Registry`'s existing
  per-role comprehension, and `Cinder.Health.library_checks/0` already iterates every non-video
  `LibraryKind` and reports `{:library, :audiobook}` (confirmed in B5's own plan, §"What B4c
  left"). `Cinder.Disk.import_space_available?/2` is kind-generic too.
- **Narrator identity needs no new schema.** The contract's Edition boundary already names
  narrator as a role-bearing edition credit ("may credit edition-specific contributors such as
  translator or narrator"), `book_credits.role` is an unconstrained string column, and
  `Cinder.Books.put_credit/2` already accepts and round-trips `role: "narrator"`
  (`test/cinder/books/schema_test.exs:119-130`). Both metadata adapters already normalize
  `asin`/`isbn13` for every edition regardless of media kind
  (`Cinder.Books.Metadata.{Hardcover,OpenLibrary}`), so an audiobook edition's identifiers are
  already sitting in `book_identifiers` today, unused until something reads them.
- **What is genuinely missing, verified by reading the code, not assumed:**
  `Cinder.Download.grab_book_target/3`'s `:ebook`-only clause and its explicit refusal comment
  ("`:audiobook` is a live media kind ... nothing downstream of here is audiobook-aware ...
  Audiobooks are B7"); `Cinder.Acquisition.Books`/`BookParser`/`BookScorer` are e-book-shaped
  throughout (EPUB/AZW3/MOBI format list, a 64 KB–200 MB size band with no duration axis);
  `Cinder.Library.BookSources`/`BookNaming`/`BookImport` resolve, name, and stage exactly one file
  per import; `book_files.format`'s CHECK constraint is `format IN ('epub', 'azw3', 'mobi')`; there
  is no Audiobookshelf adapter of any kind; and `BookDetailLive.searchable?/2` /
  `replaceable?/2` both pattern-match `media_kind: :ebook` explicitly.

## §0. Three things the evidence does not settle

**1. No numeric container/codec/size list for the audiobook profile.** The contract says
"`audiobook`: accepts M4B and common multipart audio containers in later acquisition
milestones, with M4B preferred for the captured deployment" and separately "Bitrate/codec,
abridgement, narrator, language, and part completeness are distinct facts" — it names M4B as
preferred and gestures at "common multipart audio containers" without enumerating them, and
defines no size or duration band (the e-book profile's 64 KB–200 MB band is BookScorer's own
module-attribute judgment call, not contract-derived, so there is no analogous number to inherit
for audio either). The audit's one real audiobook file is a single M4B — no MP3 sample, no
multi-track sample, no size figure survived sanitization. The roadmap's own "Likely files" and
"Done when" sections are the tie-breaker actually used here: "Validate M4B/MP3 and any
B0-required formats" and the test list ("single M4B, multi-track MP3, disc ordering..."). **B7a
below fixes `accepted_formats: [:m4b, :mp3]`** — the two formats the roadmap names by name — and a
5 MB–8 GB size band as an implementer judgment (an order of magnitude above the e-book band,
matched to real MP3/AAC bitrates across a 1–40+ hour audiobook). Both are called out as B7's own
call, not the contract's, exactly like BookScorer's existing 64 KB–200 MB band already is. A wider
container list (OGG/FLAC/AAC-in-M4A) is explicitly **out of scope** (§"What stays out") until a
real release sample justifies it — the same "no unrequested flexibility" discipline B4a applied to
the e-book list.

**2. No captured Audiobookshelf API evidence at all.** The B0 audit inspected Bookshelf's
`/api/v1` in detail (system status, authors, works, editions, files, profiles, roots, naming) and
committed a sanitized fixture (`bookshelf-api-v1.json`) precisely so B6 could build against real
response shapes. It did **not** do the same for Audiobookshelf — the audit only names it as "the
Audiobookshelf consumer" reading the `audiobooks` root, with zero captured request/response shape.
This is a strictly bigger gap than B6's §0.1 (which at least had a live, if ambiguous, API to
read). B7c below therefore builds against Audiobookshelf's own published, versioned public API
(`POST /api/libraries/:id/scan`, documented and stable across the project's own OpenAPI spec) —
never an invented shape — behind a Mox-mocked behaviour exactly like every other external service,
but there is no equivalent of `bookshelf-api-v1.json` to test against; the adapter test stubs the
documented request/response shape directly (`Req.Test`), the same technique
`migration_source/readarr_test.exs` uses for its *committed* fixture, minus the fixture. Flagged
here rather than silently presented as equally evidenced.

**3. Bookshelf is deployed twice (once per media kind), and the current migration source has no
per-instance config.** The B0 audit queried "eBooks instance" and "Audiobooks instance" as two
separately-addressed deployments, both running the same `pennydreadful/bookshelf:hardcover` image.
B6's `Cinder.Library.MigrationSource.Readarr` reads its base URL/API key from one global
`Application.get_env(:cinder, __MODULE__, ...)` block and `Cinder.Settings.Registry` generates one
`readarr_url`/`readarr_api_key` pair — there is no mechanism today for two simultaneously
configured instances of the same adapter module. Building one (per-instance config threaded through
`MigrationSource`, `MigrationAdoption`, the settings registry's `@migration_sources` list, and the
`/library/adopt` UI) is real, multi-slice-sized work with zero B0 evidence that the household needs
*both* instances migrated in the same sitting — B6c's own cutover runbook is already framed as a
one-time, operator-run, non-concurrent procedure ("An unattended background sweep... this is a
one-time cutover an operator actively runs"). **Judgment: B7e does not build multi-instance
config.** It fixes the one real bug that blocks audiobook migration regardless of instance count —
`MigrationAdoption.Readarr` hardcodes every classified candidate to `media_kind: :ebook`
(traced in `lib/cinder/library/migration_adoption/readarr.ex`) — and documents that migrating both
instances is two runs of the existing one-instance runbook, repointing `readarr_url`/`readarr_api_key`
between them, exactly as the operator already does for Radarr vs. Sonarr today (two different
services, one settings block each — Bookshelf-ebook and Bookshelf-audiobook are the same situation
Cinder already solves for the *other* two migration sources by having a **third** distinct
registry key, not a re-pointed shared one; see B7e for why that path was rejected in favor of the
repoint here).

## Slice decomposition

| Slice | Owns | Est. |
|---|---|---|
| **B7a** | Audiobook release search/scoring decision layer (parser, scorer, query planner, indexer callbacks); `book_files` schema widening | 3–4d |
| **B7b** | Grab dispatch, multi-track resolution/validation, atomic multi-file staging and import, poller integration | 5–6d |
| **B7c** | Audiobookshelf publisher behaviour/adapter, retryable post-import scan, health | 2–3d |
| **B7d** | Operator surface: manual search/Grab/replace on `/books/:id` for audiobook targets, deletion/recovery | 2–3d |
| **B7e** | Audiobook migration: fix `MigrationAdoption.Readarr`'s hardcoded `:ebook`, runbook addendum | 1d |

Total 13–17d, inside the roadmap's 12–18d estimate. Each ends in `mix test` green and is
independently reviewable/mergeable in order: B7a is a pure decision layer with no production
caller (mirrors B4a's own "no caller until B4b" precedent, explicitly, since it is the identical
shape of milestone-opening slice); B7b is the only slice that writes bytes or `book_files` rows and
depends on B7a's scorer/parser and schema; B7c depends on B7b's import path existing so there is
something to scan after; B7d depends on B7a (scorer reasons) and B7b (grab dispatch) to have
something to wire a UI to; B7e is independent of B7a–B7d entirely (it touches only
`migration_adoption/readarr.ex`) and could ship first, ordered last here only because it is the
smallest and least urgent piece.

---

## B7a — Audiobook release search and scoring

### 1. Why new modules, not extended `Books`/`BookParser`/`BookScorer`

Same judgment B4a already made for `BookParser`/`BookScorer` against the video `Parser`/`Scorer`
("the region rules differ, and the tokens differ"), and the one B4c's own §4 named explicitly
("forced reuse that needs media-kind conditionals threaded through it"). `BookScorer`'s size band,
format allow-list, and rejection vocabulary are e-book facts down to their comments (a 40 MB EPUB
being "a scan"; nothing in that reasoning transfers to a 40-hour audiobook, where the SAME file
size is unremarkable). Threading an `:audiobook` branch through `BookScorer.check_format/1`,
`check_size/1`, and their doc comments would make every future e-book-only tweak carry an
audiobook conditional it does not need, and vice versa. New sibling modules, reusing only the
pieces that are genuinely shared:

- `Cinder.Books.TitleFold` (`tokens/1`, `drop_article/1`) — pure text normalization, not
  book-format-specific.
- `Cinder.Acquisition.Parser.language_tags/0` and `.audio_codes/0` — the single language-tag
  registry every family (`Parser`, `BookParser`, now this) already draws from, per `BookParser`'s
  own moduledoc note about "two hand-synced language tables."
- The title/author containment-plus-remainder algorithm's *shape* (strip noise, subtract the
  matched author, reject an unrecognized leftover) is copied, not extracted into a shared helper —
  extracting it would force `BookScorer`'s heavily-commented, already-shipped edge cases (the
  subtitle-vs-sequel colon heuristic, the bracket-drop rules) to move to a module neither B4a's nor
  B7a's own tests were written against, for zero behavior change. This is the direct B4c-§4 case:
  copy the pattern, do not force a shared abstraction across two already-different domains
  (audiobooks add narrator tokens and abridged/unabridged the same way, but subtract duration/size
  reasoning e-books never had).

### 2. Files

Create:
- `lib/cinder/acquisition/audiobook_release.ex` — `%Cinder.Acquisition.AudiobookRelease{}`, the
  `BookRelease` sibling: same indexer-reported fields (`title`, `size`, `download_url`, `protocol`,
  `category_ids`, `indexer_id`, `published_at`, `query_origins`) plus name-parsed
  `formats`/`language`/`retail?`/`collection?`/`abridged?` **and** `narrator` — a best-effort,
  informational-only field (`"(Narrated by Ray Porter)"` / `"[Read by ...]"` patterns), never a
  scorer gate (§3.3).
- `lib/cinder/acquisition/audiobook_parser.ex` — `Cinder.Acquisition.AudiobookParser.parse/1`,
  copying `BookParser`'s format/language/retail/collection/abridged extraction verbatim in
  structure (tag-region discipline, bracket handling) with an audiobook format table
  (`~r/\bm4b\b/i` → `:m4b`, `~r/\bmp3\b/i` → `:mp3`, plus recognized-but-rejected
  `:m4a`/`:aac`/`:flac`/`:ogg`/`:wma` so an unsupported container fails closed with a named reason
  rather than `:format_unknown`) and one addition: `narrator/1`, matching
  `~r/\((?:narrated|read)\s+by\s+([^)]+)\)/i` in the tag region only (same reasoning as
  `BookParser`'s language-in-tag-region rule — a novel's own title can legitimately contain "narrated
  by" as prose; the parenthesized form does not).
- `lib/cinder/acquisition/audiobook_scorer.ex` — `Cinder.Acquisition.AudiobookScorer`, copying
  `BookScorer`'s `evaluate/3`/`evaluate_all/3` shape and rejection philosophy (fail closed on
  unknown format, no author evidence, no title evidence) with:
  - `@accepted_formats [:m4b, :mp3]`, `M4B` preferred (§0.1).
  - `@min_size 5 * 1024 * 1024`, `@max_size 8 * 1024 * 1024 * 1024` (§0.1).
  - The identical title/author/collection/language/protocol/blocklist checks, copied.
  - `check_abridgement/2` kept unchanged in spirit (an abridged audiobook is still a different
    text from the unabridged one).
  - **No narrator check.** Narrator evidence in a release name is real but unreliable (many
    releases omit it, some misattribute a series narrator to a guest reader) and there is no B0
    corpus measurement of narrator-name precision to gate a rejection on — inventing a threshold
    here would be exactly the unfounded-precision-bar mistake B5's §0 already flagged and refused
    to repeat for release selection. `narrator` rides through to `evidence` for informational
    display only (§B7d).
  - `@reasons` gains `:format_unknown`, `:format_rejected`, `:format_contradictory`,
    `:author_mismatch`, `:title_mismatch`, `:title_unfoldable`, `:collection_ambiguous`,
    `:abridged_edition`, `:language_mismatch`, `:wrong_protocol`, `:size_out_of_band`,
    `:blocked_term`, `:blocklisted` — the exact same closed set `BookScorer` has today (no new
    rejection *kind*, just a second scorer producing the same vocabulary against different bands).
- `lib/cinder/acquisition/audiobooks.ex` — `Cinder.Acquisition.Audiobooks`, the `Books` sibling.
  `search/1` and `candidates/2` with the identical shape (`{:ok, releases, complete?}` /
  `{:ok, %{accepted:, rejected:, complete?:}}`), same partial-failure semantics, same
  `max_queries/0` derivation. Query plan differs only in identity evidence: ASIN before ISBN
  (Audible ASIN is the dominant audiobook identifier; ISBN is the fallback for indie audiobooks
  that only ever had a print ISBN) — `identifiers(%Work{editions: editions})` filters
  `%Edition{media_kind: :audiobook}` and reads `Identifier{provider: "asin"}` then
  `Identifier{provider: "isbn"}`, capped at `@max_identifier_queries 3` exactly like `Books`'
  `@max_isbn_queries`. Structured query calls `indexer().search_audiobook/3`; free text calls
  `indexer().search_audiobook_query/2`.
- `test/cinder/acquisition/audiobook_parser_test.exs`, `audiobook_scorer_test.exs`,
  `audiobooks_test.exs` — mirroring `book_parser_test.exs`/`book_scorer_test.exs`/`books_test.exs`'s
  own structure and corpus style; reuses realistic audiobook release name fixtures (constructed the
  same hand-written way `book_scorer_test.exs` builds ebook ones — there is no committed B0
  audiobook release-name corpus, only the 11 "Audiobook-bearing accepted responses" work-identity
  cases in `corpus-v1.json`, which are provider search results, not indexer release names, and are
  out of scope for this test file).

Modify:
- `lib/cinder/acquisition/indexer.ex` — adds `@callback search_audiobook(author, title, opts) ::
  {:ok, [map()]} | {:error, term()}` and `@callback search_audiobook_query(query, opts) :: {:ok,
  [map()]} | {:error, term()}`, doc-commented identically to `search_book/3`/`search_book_query/2`.
  Per B4a's own precedent note: "Adding callbacks to a behaviour with a Mox mock means every
  existing `IndexerMock` expectation still compiles" — no test churn to existing ebook/movie/TV
  indexer tests.
- `lib/cinder/acquisition/indexer/prowlarr.ex` — `@audiobook_category 3030` (Newznab's standard
  Audio/Audiobook category — the sibling of the existing `@ebook_category 7020` under the Books
  parent 7000; Audio's parent is 3000), `audiobook_category/0` accessor, and
  `search_audiobook/3`/`search_audiobook_query/2` clauses mirroring `search_book/3`/
  `search_book_query/2` exactly (same `book_query/2` brace-token construction reused unchanged —
  Newznab's structured book-search type still carries `author`/`title` fields regardless of the
  category filtering the results to audio).
  `test/cinder/acquisition/indexer/prowlarr_audiobook_test.exs` mirrors `prowlarr_book_test.exs`.

### 3. Data model

`book_files.format`'s CHECK constraint (`format IN ('epub', 'azw3', 'mobi')`, added as an inline
SQLite column constraint in `20260831090000_create_book_grabs_and_files.exs`) must widen to admit
`'m4b'`/`'mp3'`. **SQLite cannot `ALTER TABLE` a CHECK constraint** — the same fact
`20260726180000_add_movie_episode_check_constraints.exs` (adding new CHECKs to movies/episodes)
and, the closer precedent, `20260824064512_add_book_profile_kinds.exs` already establish and solve
with the full-table-rebuild recipe. That migration is not merely "adding" a constraint — it
*widens* `media_profiles`'s existing `kind` CHECK from `'movies', 'tv'` to `'movies', 'tv',
'ebook', 'audiobook'` (its own `kinds/1`'s two clauses, `up/0` vs. `down/0`) — the identical
operation this migration performs on `book_files.format`, just a different table and value set,
so this is not the first time this codebase has widened a live CHECK constraint.
`PRAGMA foreign_keys = OFF`, `BEGIN IMMEDIATE`, create `book_files_new` with the widened CHECK and
the new columns below, copy every row by explicit column list, `PRAGMA foreign_key_check`, drop
the old table, rename the new one into place, then recreate every object the original table
carried — verified against the actual creation migration
(`20260831090000_create_book_grabs_and_files.exs:47-65`), not assumed: `unique_index(:book_files,
[:path])`, `index(:book_files, [:book_target_id])`, `index(:book_files, [:edition_id])`, and the
`book_target_id`/`edition_id` foreign keys (SQLite foreign keys are part of the table's own
`CREATE TABLE` DDL, so they are written into `book_files_new`'s definition directly, not recreated
as a separate step) — re-enable foreign keys last.

No backup-coverage gap: `Cinder.DatabaseBackup` backs up via `VACUUM INTO` (whole-database), so
`book_files`'s new columns and every other B7 table change are already covered with no B7-specific
backup work needed.

**The explicit trigger check the task requires:** `book_targets_profile_integrity_insert/update`
live **on `book_targets`**, not `book_files` — their `WHEN` clause and body both read
`FROM media_profiles` (per `create_books_catalog_and_targets.exs`'s own forward-looking comment
about a *future `media_profiles` rebuild*). This migration rebuilds `book_files`, never
`book_targets` or `media_profiles`, so those two triggers are never in the blast radius — nothing
in this migration issues `DROP TABLE book_targets` or `DROP TABLE media_profiles`. Verified by
`sqlite_master` query against the current schema: **no trigger's SQL currently mentions
`book_files`** (`SELECT name FROM sqlite_master WHERE type = 'trigger' AND sql LIKE
'%book_files%'` returns zero rows today). The migration still runs the same defensive
capture-and-reapply query the `media_profiles`/movies-episodes rebuilds established
(`SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND sql LIKE '%book_files%'`) before
dropping the old table and replays whatever it finds after the rename — a no-op today, but the same
generic recipe every other rebuild in this codebase uses, so a future trigger on `book_files`
(should one ever exist) is not silently dropped by this migration or any later one copying it.

New migration `priv/repo/migrations/<ts>_widen_book_files_for_audiobooks.exs`:
- Widened CHECK: `format IN ('epub', 'azw3', 'mobi', 'm4b', 'mp3')`.
- Four new **nullable** columns, added directly in the rebuilt `CREATE TABLE` (no separate `ALTER
  TABLE ADD COLUMN` step needed since the table is already being rebuilt): `narrator :string`,
  `duration_seconds :integer`, `track_number :integer`, `disc_number :integer`,
  `chapter_count :integer`. All four are **file-level facts, not identity** — the schema doc
  comment on `Cinder.Books.BookFile` gains a paragraph explaining why: an edition may be narrated
  differently across two *rips* of the same recording (rare, but the reason this rides on the file
  and not a re-derivation from `edition_id`, which is nullable anyway per B4b's own note), and
  track/disc/chapter/duration are inherently per-physical-asset for a multi-track set — two
  different rips of the same audiobook can legitimately split into a different number of tracks.

`lib/cinder/books/book_file.ex` — `changeset/2` gains the five new fields in its `cast` list
(optional, no `validate_required` addition — an e-book file leaves them all `nil`, unchanged
behavior); `field :format, Ecto.Enum, values: BookScorer.accepted_formats()` becomes `values:
BookScorer.accepted_formats() ++ AudiobookScorer.accepted_formats()`.

### Done when

- `Audiobooks.search/1` issues an ASIN-then-ISBN-then-structured-then-free-text query plan capped
  at `max_queries/0`, exactly mirroring `Books.search/1`'s own test assertions
  (`audiobooks_test.exs`, parametrized off `books_test.exs`'s structure) — property: a work with
  many audiobook editions never fans out past the cap, and one failing query still yields
  `complete?: false` rather than an error.
- `AudiobookScorer.evaluate/3` accepts an M4B or MP3 release naming the right work/author and
  rejects: wrong author, wrong title, an EPUB (recognized-but-wrong-family format), an
  unrecognized container, a release outside the 5 MB–8 GB band, and a release on the blocklist —
  each with its own reason from the closed `reasons/0` set, exhaustiveness-tested the same way
  `book_manual_search_component_test.exs` already tests `BookScorer.reasons/0`.
  Property: narrator evidence never changes accept/reject, only what rides in `evidence.narrator`.
- The `book_files` rebuild migration round-trips existing e-book rows unchanged (a migration test
  seeds e-book rows pre-rebuild, runs `up/0`, asserts every row and its `path`/`format`/`size`
  survive with the same id, and that `unique_index(:book_files, [:path])` plus the
  `book_target_id`/`edition_id` indexes and foreign keys all still exist post-rebuild) and accepts
  an `m4b`/`mp3` insert post-rebuild that a pre-migration insert would have rejected with a CHECK
  violation.
- `mix test` green.

---

## B7b — Grab dispatch, multi-track validation, atomic import

This is the slice that actually answers the roadmap's two hardest lines: "a multi-track audiobook
is imported atomically as one target" and "no mixed-book imports."

### 1. `Download.grab_book_target/3` gains an `:audiobook` clause

```elixir
def grab_book_target(%BookTarget{media_kind: :audiobook} = target, %AudiobookRelease{} = release, opts) do
  # identical Intent reserve/reconcile shape to the :ebook clause, `audiobook_release/1`
  # converting to the shared %Release{} the intent journal and download clients speak
end
```

Copied, not shared, for the same reason `grab_book_target/2`'s own moduledoc gives for keeping
`:ebook`-only until now: "the book-specific evidence stays in the books tables, not in the
downloader" — the *dispatch* shape (check `Intent`, reserve-or-reconcile) is identical scaffolding
between the two clauses, but the release struct being converted is different
(`%AudiobookRelease{}`, not `%BookRelease{}`), so a private `audiobook_release/1` mirrors
`book_release/1` rather than widening `book_release/1`'s pattern match to accept either struct
shape (which would make a `%BookRelease{}` reach the audiobook path or vice versa by accident — the
type match is the safety rail). The catch-all `def grab_book_target(%BookTarget{}, _, _), do:
{:error, :unsupported_media_kind}` moves below both concrete clauses and is now truly unreachable
for the two live kinds — it stays as the guard against any *future* third `LibraryKind.books()`
entry landing here with no clause of its own, matching the existing comment's own framing ("half-
works" is the failure mode being fenced, generalized from one kind to any not-yet-wired kind).

### 2. `Cinder.Library.AudiobookSources` — multi-track resolution

New module, `lib/cinder/library/audiobook_sources.ex`, the `BookSources` sibling. Reuses
`Cinder.Library.safe_walk/1`, `Cinder.Library.BookArchive.{Zip,Rar}` (unchanged), and
`Cinder.Library.path_policy()` exactly as `BookSources` does — the containment, symlink-refusal,
and archive-entry/size-ceiling guarantees are identical infrastructure, not reimplemented.

**What's genuinely different: resolving to *one ordered list* of files, not one file.**

```elixir
@spec resolve(String.t()) ::
        {:ok, [%{path: String.t(), format: atom(), track: track_evidence()}]}
        | {:error, reason()}
```

Pipeline, all pure/read-only until §3:

1. **Extraction** — identical to `BookSources.resolve/1`'s archive handling, with one real change
   to `BookArchive` itself, named explicitly rather than glossed over: `extract_and_resolve/2` is
   arity 2 with no `opts` parameter, and its private `extract/2` dispatcher
   (`lib/cinder/library/book_archive.ex:83-91`) calls `Zip.extract(archive_path, scratch_dir)` /
   `Rar.extract(archive_path, scratch_dir)` with no third argument — even though both
   `Zip.extract/3` and `Rar.extract/3` already accept and forward `opts` (`max_entries`,
   `max_expanded_size`), `BookArchive` itself never passes any today. `extract_and_resolve/2`
   becomes `extract_and_resolve/3` (`archive_path`, `resolve_fun`, `opts \\ []`), and the private
   `extract/2` becomes `extract/3`, threading `opts` to whichever extractor it dispatches to.
   `BookSources.resolve/1`'s own call site is unchanged (`opts` defaults to `[]`, exactly what it
   passes today by omission). `AudiobookSources.resolve/1` is the one caller that passes
   `max_expanded_size: AudiobookScorer.size_band() |> elem(1)` (8 GB).
   `@max_entries` (500, unchanged) bounds entry **count** only; total expanded size is bounded by
   `max_expanded_size` checked incrementally at ~4 MB per inflate step against the running
   cumulative total (`Zip`'s own moduledoc: "bounds worst-case decompressed output per step... to
   ~4MB — the granularity of the ceiling check") — there is no independent **per-entry** size cap
   distinct from that shared cumulative total, so one 8 GB entry is still caught by the same
   ceiling, just discovered across more incremental checks rather than by a dedicated per-entry
   comparison. Both extractors' own `opts` mechanism is documented as "a test seam only, so an
   adversarial-ceiling test proves the abort without generating gigabyte-scale fixtures"
   (`Zip.extract/3`'s own doc) — reused here for real per-media-kind configuration too, which the
   doc's wording does not forbid but does not anticipate either; noted so a reviewer does not read
   this as the documented intended use.
2. **Candidate collection** — every regular file under the (possibly-extracted) tree whose
   extension is `.m4b`/`.mp3` is a candidate; anything else present alongside them and not itself
   an archive/directory is **not silently ignored** — a stray `.nfo`/`.jpg`/`.txt` is fine (common
   release-scene padding) and excluded from the candidate list, but a stray *other audio* file
   (`.flac`, `.wav`) or a second, differently-named `.m4b` is exactly the "mixed folder" case
   `BookSources` already refuses for e-books, generalized: `resolve/1` classifies every audio-like
   extension it recognizes (the full audiobook + video-style audio set, not just the accepted two)
   so an unaccepted-but-present audio file becomes an explicit `:format_rejected` per-file finding
   folded into the mixed-book check below, never a file the resolver simply never looked at.
3. **Format-magic verification** — reused, not new: each `.mp3` candidate is checked for an
   `ID3`/`0xFFFB`-style frame sync at its head; each `.m4b` candidate is checked for an `ftyp` box
   signature (`....ftypM4B `/`....ftypmp42`/`....ftypisom` at offset 4, the same style
   `BookSources.verify_magic/2` already applies to EPUB/MOBI/AZW3). This is the format gate and it
   needs **no subprocess** — exactly like `BookSources`, a renamed executable or a mislabeled
   extension is refused before anything is staged, without depending on `ffprobe` being installed
   at all.
4. **Mixed-book detection — two independent checks, both must pass:**
   - **Filename-stem check**: strip a leading/trailing/embedded track-number token from each
     candidate's basename (`~r/\b(?:track|part|disc|cd)?\s*0?\d{1,3}\b/i` at the position a track
     number is conventionally written) and compare the remainders. All candidates must reduce to
     the *same* stem (mirroring `BookSources.stem/1`'s normalization: lowercase, collapse
     separators). A disagreement is `{:error, :mixed_book_filenames}`.
   - **Embedded-tag check (when `AudioProbe` is configured and answers, §3)**: every file's
     `album`/`title` container tag, when present, must agree across the whole set. This is the
     stronger signal — a filename can be renamed by an uploader, a container tag usually is not —
     so a *tag* disagreement is refused even if filenames happen to agree
     (`{:error, :mixed_book_tags}`), and a tag/filename disagreement in the other direction (tags
     agree, filenames look like two different books) is *not* separately refused — the filename
     check above already caught it. When `AudioProbe` is unavailable or errors, this check is
     skipped entirely (degrades to filename-only, matching §3's "verification floor" split below);
     it is never treated as a positive "they must be different" signal.
5. **Deterministic ordering** — three sources, most authoritative first, and this is the
   contract's ordering evidence, made explicit:
   - **Embedded track/disc tags** (`AudioProbe`, when available) — the file's own container
     metadata is what a real ripper/encoder wrote and survives a rename.
   - **Filename-embedded track numbers** (`track 03`, `03 - Title.mp3`, `CD2/07.mp3` for disc+track)
     — parsed the same way `BookScorer`'s existing filename-noise-stripping regexes already
     recognize track idioms, generalized to capture the number instead of discarding it.
   - **Nothing at all** (a single M4B, or a directory with no numeric evidence anywhere) — for a
     **single-file** result this is trivial (no ordering question exists). For a **multi-file**
     result with zero numeric evidence anywhere, ordering is **refused**, not guessed:
     `{:error, :track_order_unknown}`. Alphabetical sort is deliberately never used as a silent
     fallback for an *unordered* set — "Chapter 1", "Chapter 10", "Chapter 2" sorts wrong
     lexically, and a wrong silent order is worse than a visible refusal an operator can fix by
     renaming the files once, same trade `BookScorer`'s whole title-remainder philosophy already
     makes ("biased toward false negatives").
   - **Contradiction between sources** (tag says track 3, filename says track 5, for the *same*
     file) is `{:error, :track_order_contradictory}` — never "trust the tag" or "trust the
     filename" silently; this is exactly the ambiguous-evidence case the task calls out by name.
6. **Container consistency** — every candidate in the resolved set must share one format
   (`:m4b` or `:mp3`, never a mix): a set with both is `{:error, :container_mismatch}`. Unlike
   `BookSources`' multi-*format* collapse (which treats `Title.epub` + `Title.mobi` as one release
   offering two readable copies of the *same* book), an audiobook's tracks are not interchangeable
   copies of each other — they are sequential *parts*, so "the same book in two containers" is not
   a shape this resolver ever collapses; a release offering both an M4B rip and an MP3 rip of the
   same book is two different candidate sets from the scorer's perspective (each container
   evaluated as its own release, same as any real-world release naming would present them as
   separate torrents/nzbs in practice).

### 3. `Cinder.Library.AudioProbe` — a new bounded behaviour, not an extension of `MediaInfo`

**Judgment (task fact #8):** `Cinder.Library.MediaInfo` is shaped around one question — a media
file's audio/subtitle *language* tracks for movie/TV import policy — and its two production
probes (`probe/1`, `probe_policy/1`) share `run_probe/2`, which has **no execution timeout at all**
(only `health/0`'s `-version` call is `Task`-bounded). Reusing that behaviour for
duration/container/track/chapter facts would mean either (a) widening its callback shapes with
audiobook-only fields no movie/TV caller ever reads, or (b) adding a third probe-shape callback to
a behaviour whose entire moduledoc and every existing implementer is framed around language
policy. Both are the B4c-§4 "forced reuse" smell. **New behaviour instead:**

```elixir
# lib/cinder/library/audio_probe.ex
@callback probe(path :: String.t()) ::
  {:ok, %{
    container: :m4b | :mp3 | :unknown,
    duration_seconds: non_neg_integer() | nil,
    chapter_count: non_neg_integer(),
    track_tag: non_neg_integer() | nil,
    disc_tag: non_neg_integer() | nil,
    album_tag: String.t() | nil,
    title_tag: String.t() | nil
  }} | {:error, term()}
@callback health() :: :ok | {:error, term()}
```

`lib/cinder/library/audio_probe/ffprobe.ex` implements it, and **does** add the bound `MediaInfo`
lacks, reusing the *technique* already established twice in this codebase rather than a third
ad hoc timeout:
- **Time bound**: `Task.async/yield/shutdown(:brutal_kill)`, exactly `MediaInfo.Ffprobe.health/0`'s
  own pattern, generalized from the `-version` no-file call to a real per-file probe (a
  `@probe_timeout 10_000`, generous for even a large M4B's moov-atom-only read — `ffprobe` never
  decodes audio for `-show_entries`, only parses container metadata).
- **Output bound**: narrow `-show_entries format=format_name,duration:format_tags=album,title,
  track,disc:chapter=id -of json`, the same "ask only for the fields you need" discipline
  `MediaInfo.Ffprobe.args/1`'s CSV projection already uses, rather than a full `-show_streams
  -show_format` dump. `chapter_count` is `length(chapters)` from that same bounded call, not a
  second subprocess.
- **`health/0`** mirrors `MediaInfo.Ffprobe.health/0` exactly (`-version`, same `@health_timeout`).

Configured at `config :cinder, :audio_probe`, resolved via `Application.fetch_env!/2` (never
`compile_env!`, per AGENTS.md and the task's explicit constraint) — `nil` in `config/test.exs` by
default with a Mox mock (`Cinder.Library.AudioProbeMock`) opted into per test, matching
`MediaInfo`'s own test posture exactly.

**When `AudioProbe` is unavailable or errors** (missing binary, timeout, malformed output):
ordering and mixed-book detection fall back to filename-only evidence (§2.5/§2.4); this is a
"can't verify the *stronger* signal" degradation, not a "can't import" one — mirroring
`MediaInfo.probe/1`'s own soft-degrade philosophy for the *language* check. `duration_seconds`,
`chapter_count`, `track_number`/`disc_number` (from tags) simply stay `nil` on the imported
`book_files` row(s) in that case; they are never load-bearing for the format-magic gate (§2.3),
which needs no subprocess at all.

### 4. `Cinder.Library.AudiobookNaming` and `Cinder.Library.AudiobookImport`

`lib/cinder/library/audiobook_naming.ex` — the `BookNaming` sibling. `author_folder/1` and
`title_folder/1` are **reused unchanged** (`defdelegate`, not copied — folder-naming from a work's
credits/title has nothing audiobook-specific about it). New: `track_dest/4` names each file
`root/Author/Title/<disc-prefix><NN> - <basename-or-neutral-stem>.<ext>` where `NN` is the
resolved track order (zero-padded to the set's own width — 2 digits for ≤99 tracks) and
`<disc-prefix>` is `Disc <M>/` only when the resolved set spans more than one disc (a single-disc
or single-file set has no disc segment at all, so a single M4B lands at exactly
`root/Author/Title/Title.m4b`, unchanged from what an equivalent single-file e-book import would
produce). Every path component runs through the same `sanitize/1`/`reject_dot_only/1`/`visible/1`
hardening `BookNaming` already has — reused via `defdelegate`, not reimplemented, closing the exact
same hostile-input class (`../../etc/passwd` release names, dot-leading folders) for audio the same
way it is already closed for text.

**Deliberately named from (Author, Title, disc, track number) only, never from the incoming
release's own filenames.** The roadmap requires "deterministic audiobook folders," and a scheme
that varied with the release's own filenames would make two correct imports of the *same* book
(from two different uploaders) land at two different paths — the opposite of deterministic. This
determinism is exactly *why* §4a below exists: it guarantees that a "Find a better match" replace
whose new release has the same track/disc count computes the identical destination paths as the
target's own current files — the common case for audiobooks specifically, since near-universal
numeric track-naming conventions ("01 - Chapter 1.mp3", "02 - ...") recur across unrelated
releases far more often than an e-book's own arbitrary filename does.

`lib/cinder/library/audiobook_import.ex` — the `BookImport` sibling, and the one place the "atomic
as one target" and "partial failure mid-set" questions are actually answered:

```elixir
def import_grab(%BookGrab{book_target: %BookTarget{media_kind: :audiobook} = target} = grab, opts) do
  replace? = Keyword.get(opts, :replace, false)

  with {:ok, tracks} <- AudiobookSources.resolve(grab.content_path),
       {:ok, root} <- library_root(target),
       {:ok, staged} <- stage_all(tracks, target, root, replace?) do
    record(grab, target, staged, opts)
  end
end
```

#### 4a. `StageEngine.stage_book_place/3` gains a real replace path — fixing a false safety claim

**An earlier draft of this plan claimed a destination collision "surfaces as a per-track staging
refusal." It does not, and the actual behavior is a real defect worth stating plainly.** Traced
`stage_book_place_locked/3` (`lib/cinder/library/stage_engine.ex:123-154`) exactly: when the
destination already holds a regular file, it *always* journals a no-op and reports `placed?:
false` — "both a same-inode idempotent re-run and a genuinely different existing file... are kept
either way," by design, because "the contract parks automatic upgrades and format conversion for
the first release, so an existing file at the destination is always kept." That rule is correct
for a **fresh** (non-replace) import. It is silently wrong for a **replace**: combined with
`track_dest/4`'s deterministic naming above, a "Find a better match" replace whose new release has
the same track count computes the *same* destination paths as the target's current files, every
track's placement reports `placed?: false` with a no-op journal entry, `stage_all/4` reads that as
ordinary success, and §4c's own replay detection then sees the incoming path set and the target's
existing path set as identical — correctly, given that input, but the input is wrong: nothing was
ever staged. The operator is told the replace succeeded; nothing on disk or in the catalog
changed. This is the single most common audiobook replace scenario, and it must be fixed at the
staging layer, not narrated around.

**Fix: `stage_book_place/3` becomes `stage_book_place/4`, taking an `opts \\ []` keyword list —
`extensions` (default `BookSources.accepted_extensions()`, so `BookImport`'s existing e-book call
site, a bare `StageEngine.stage_book_place(source, dest, root)`, is unchanged) and `replace`
(default `false`, matching today's actual behavior exactly, since e-book "Find a better match"
never uses stage-level replace — it relies on source-filename-derived naming usually landing at a
different path in the first place, and the DB-level `Files.maybe_supersede/3` for cleanup).**
`stage_new/5`'s internal call site inside `stage_book_place_locked/4` (currently hardcoding
`BookSources.accepted_extensions()` directly at `stage_engine.ex:127`, not reading a parameter at
all) also changes to use the threaded-through `extensions` value — both the public head's default
*and* this internal call site, not one or the other.

When `opts[:replace]` is `false` (the e-book path, unchanged), a destination collision keeps the
existing file exactly as today — byte-for-byte the same behavior, regression-tested. When
`opts[:replace]` is `true` and the destination already holds a regular file,
`stage_book_place_locked/4` performs a **real, durable, backup-then-atomic-swap replacement** —
not new machinery, the *same* one `stage_place/8` already uses for a confirmed movie upgrade:

- **Same-inode check first**, mirroring `do_resolve/2`'s own first clause (`si == di and sdev ==
  ddev -> {:ok, ..., false}`): if the destination is already hardlinked to the exact source being
  staged, this is a replay of an already-completed replace — report `placed?: false` and change
  nothing, correctly idempotent, never a second backup-swap over content already swapped once.
- **Otherwise**, call `prepare_durable_stage/7` with `backup_source: dest` and the destination's
  current stat as `backup_stat` — the exact function `stage_replacement/4` already calls for a
  movie upgrade. This builds the new candidate at a private, operation-scoped temp path via
  `link_or_copy/4`, moves the CURRENT destination file to a private, operation-scoped backup path
  (`maybe_move_backup/2`, unchanged existing code), then lands the new candidate at `dest`
  (`land_candidate/2`, unchanged existing code) — all through the same durable `ImportStage`
  journal every other placement in this codebase uses. `placed?: true`. The OLD file is never
  deleted here — it is *moved* to a tracked backup path, so a later rollback can restore it
  (`restore_owned_backup/1`, unchanged existing code) and a later commit removes it
  (`cleanup_committed_stage/1`, unchanged existing code) — the identical lifecycle a movie
  upgrade's backup already has, reused for books for the first time here because books never
  needed a real replace-in-place before B7b.

Two alternatives were considered and rejected: naming each track's destination from the incoming
release's own filenames (rejected in the naming note above — it breaks "deterministic audiobook
folders" outright), and staging a whole replace generation into a fresh per-grab subdirectory then
renaming it into place post-commit (rejected because it needs its own after-the-fact, best-effort
filesystem mutation *after* the DB transaction commits — reintroducing exactly the class of
post-commit-mutation risk this codebase already treats as a hazard, for no benefit over reusing
the backup-swap machinery that already exists and is already crash-tested for movies).

#### 4b. Staging phase — accumulate-or-roll-back-everything, before any DB write

`stage_all/4` folds over the ordered track list, staging each one at its own `track_dest/4`
destination via `stage_book_place/4` (passing the caller's own `replace?` through to every track
uniformly). On the **first** staging failure (disk full mid-set, an `mkdir_p` permission error, or
any filesystem error other than the two cases §4a handles), every rollback token accumulated *so
far* is rolled back (`Enum.each(staged_so_far, &StageEngine.rollback/1)`) before the function
returns `{:error, reason}`. For a **fresh** import this means zero bytes land under the target's
folder. For a **replace**, §4a's backup-then-swap machinery means each already-swapped track's
rollback restores that track's *original* file from its own backup path — so a 12-track replace
that fails staging track 9 leaves tracks 1–8 restored to their pre-replace originals, not the new,
half-landed set, and the whole grab is retried (or held, past the attempt budget) as one unit next
tick. The original set is never left partially replaced.

#### 4c. Record phase — the exact `maybe_supersede/3` generalization, not a description of one

**This is the precise algorithm, because `Cinder.Books.Files.maybe_supersede/3` (`files.ex:59-74`)
is the function two prior review rounds already hardened against destroying a household's only
copy on import replay, and an earlier draft of this plan under-specified its multi-file
generalization as "runs it once against the whole incoming path set" — not itself a design.**
`Cinder.Books.Files` gains `record_import_set/3`:

```elixir
@spec record_import_set(BookTarget.t(), [map()], keyword()) ::
        {:ok, [BookFile.t()]} | {:ok, [BookFile.t()], [String.t()]} | {:error, term()}
```

`maybe_supersede_set/3` (the multi-file sibling of `maybe_supersede/3`):

```elixir
defp maybe_supersede_set(_target, _attrs_list, false), do: {:ok, []}

defp maybe_supersede_set(%BookTarget{id: id}, attrs_list, true) do
  existing = Repo.all(from f in BookFile, where: f.book_target_id == ^id)
  existing_paths = MapSet.new(existing, & &1.path)
  incoming_paths = MapSet.new(attrs_list, & &1.path)

  if MapSet.equal?(existing_paths, incoming_paths) do
    # Every incoming path is already this target's own current row, and the target has no path
    # the incoming set lacks — a full replay of an already-completed replace (§4a's staging step
    # already found each track's destination hardlinked to itself and made no filesystem change).
    # Delete nothing; `insert_or_existing/2` per track below hits the same unique-path conflict
    # `insert_conflict/3` already treats as a no-op success, N times.
    {:ok, []}
  else
    # ANY difference — disjoint, subset, superset, or partial overlap — deletes every existing row
    # unconditionally, including one whose path IS reused by the incoming set: that row's bytes
    # were already overwritten in place by §4a's backup-swap, so its OLD row (size, format,
    # duration, track/disc metadata) would otherwise describe bytes that no longer exist at that
    # path. Deleting it and letting the insert step recreate it fresh keeps metadata correct for
    # reused paths, not merely "not wrong."
    #
    # Only paths NOT present in the incoming set are returned as `superseded_paths` for
    # post-commit disk unlink (§4d) — a REUSED path's disk bytes are already the new content
    # (landed by the backup-swap); unlinking it would delete the file this same import just
    # staged. An orphaned path (an old track whose slot the new release doesn't reuse — e.g. the
    # new release has fewer tracks) has no landed replacement and is the only case whose bytes
    # must actually be removed from disk.
    Repo.delete_all(from f in BookFile, where: f.book_target_id == ^id)
    {:ok, MapSet.difference(existing_paths, incoming_paths) |> MapSet.to_list()}
  end
end
```

`record_import_set/3`'s transaction otherwise mirrors `record_import/3`'s exactly:
`maybe_supersede_set/3` first, then `insert_or_existing/2` once per incoming track (unchanged,
single-row function, reused per-item — the delete-then-insert ordering above guarantees no
unique-path conflict for this target's own reused paths, since they were just deleted; a
*different* target's path is still a real `:book_file_exists` conflict, unaffected), then
`arm_target/1` once, then `ImportStage.mark_committed!/1` over every stage id via
`Library.stage_ids(Enum.map(rollbacks, &%{rollback: &1}))` (`Library.stage_ids/1` already accepts
and `flat_map`s a list, used today for a movie's primary-plus-part-files case — no new
capability).

**The crash-replay invariant, stated explicitly:** because `track_dest/4` is deterministic and
`stage_book_place/4`'s same-inode check (§4a) makes re-staging already-landed bytes an idempotent
no-op, a full crash-and-replay of `import_grab/2` — whether or not the DB transaction ever ran on
the interrupted attempt — always re-resolves to the identical ordered track list and destination
paths, and the whole pipeline (stage, then record) converges to the same end state on replay:
nothing to stage twice, nothing to insert twice (`MapSet.equal?/2`'s replay branch), no double
supersession. This is the one-target, N-file generalization of the exact invariant
`record_import/3`'s own doc already states for one file: "Replay-safe by construction... only a
GENUINELY different existing row is ever removed."

#### 4d. Post-commit phase

`commit/2` calls `StageEngine.commit/1` once per rollback token (best-effort per §"commit already
logged, not retried" precedent — a single-file import already treats a post-commit
journal-bookkeeping failure as "logged, import stands," generalized to N calls with the same
log-and-continue per token); `finish/2` deletes the grab, best-effort unlinks every path in
`superseded_paths` (§4c — only ever a genuinely orphaned old track, never a reused, already-landed
path), and honors `move_on_import` once, on the whole payload's original `content_path` (a
multi-track release's source directory, not per-file) — unchanged shape from today's single-file
`finish/2`.

### 5. What a hostile archive/directory layout can and cannot do

Enumerated because the task asks for it explicitly, not left implicit:

- **Cannot** escape the extraction root or the eventual library root — every path this module
  touches passes through `Cinder.Library.path_policy()`'s `lstat`-every-component containment
  check (`safe_walk/1`, `BookSources.safe_source/1`-equivalent, `safe_destination/2`), unchanged
  infrastructure. A `../../etc/cron.d/evil` entry inside a `.zip` is refused by `BookArchive.Zip`
  before `AudiobookSources` ever sees a path for it.
- **Cannot** exhaust memory/disk via decompression — the archive extractors' existing entry-count
  (500) and expanded-size ceilings apply, with the size ceiling raised to 8 GB (the audiobook
  band's own maximum, §2.1) rather than left at the e-book-tuned 1 GB default — still a hard,
  enforced cap, not "no cap."
- **Cannot** publish a non-audio executable/script under an accepted extension — the magic-byte
  check (§2.3) is positive identification, the same discipline `BookSources.verify_magic/2` already
  applies, so a renamed ELF/PE at `book.mp3` is refused before staging, with no subprocess
  dependency.
- **Cannot** hang the import pipeline indefinitely via a crafted file that makes `ffprobe` spin —
  `AudioProbe.Ffprobe`'s `Task`-based timeout kills the process at `@probe_timeout`; the probe
  result for that one file degrades to "unavailable" (§3's fallback), it does not fail the whole
  import, and it does not block the poller tick (`BookPoller.isolate/2` already wraps every grab's
  processing in a rescue boundary).
- **Cannot** cause "no mixed-book imports" to be silently bypassed by naming files identically to a
  different, unrelated release already on disk — `AudiobookSources.resolve/1` only ever inspects
  the **one** grab's own `content_path` tree; it has no visibility into any other target's files,
  so cross-target confusion is structurally impossible at this layer. Nor can two *different*
  targets' tracks ever collide on a `track_dest/4` path in the first place: the path is derived
  from the target's own work's author/title folders, and `book_targets` carries a unique index on
  `[work_id, media_kind]`, so no two targets share those folders. The only real collision this
  scheme has is a target replacing its *own* prior files, which §4a's backup-swap now handles as
  a genuine, reversible replacement rather than the silent keep an earlier draft of this plan
  mistakenly relied on.
- **Can** still be tricked into a `:track_order_unknown` or `:mixed_book_*` refusal by a
  sufficiently adversarial-but-plausible layout (e.g., two real different books' tracks
  interleaved with a shared, generic naming convention and no tags) — this is the fail-closed
  outcome by design: an operator sees the held reason and can inspect/re-download rather than the
  system silently importing a spliced-together wrong book.

### 6. `BookPoller` changes

`do_import_one/2` dispatches by `target.media_kind`: `:ebook` → `BookImport.import_grab/2`
(unchanged call), `:audiobook` → `AudiobookImport.import_grab/2` (same return shape:
`{:ok, file}` / `{:ok, file, superseded}` / `{:error, reason}` — but note `file` is now a **list**
of `BookFile.t()` for the audiobook branch; `finish_import/2`'s log line and the `:book_available`
notify payload already carry the *target*, not the file, so no caller needs the list shape beyond
`Enum.each(superseded_paths, &unlink_superseded/1)`, which is unchanged).
`@permanent_import_errors` gains `:mixed_book_filenames`, `:mixed_book_tags`,
`:track_order_unknown`, `:track_order_contradictory`, `:container_mismatch` — every one is a fact
about the **payload**, exactly the same category `:no_book_file`/`:ambiguous_book_files` already
occupy, so they park the target immediately with an exact reason rather than burning the retry
budget re-reading bytes that will never resolve themselves. `:audio_probe_unavailable` is
deliberately **not** added to that list — per §3, a missing/erroring probe degrades the *ordering*
signal, it never surfaces as its own import error, so there is no such reason to bound.

### Test plan (properties)

- A single M4B imports with no track/disc segment in its path and no ordering ambiguity —
  regression-proving the trivial case stays trivial.
- A correctly-numbered multi-track MP3 set (embedded tags present and agreeing) imports as N
  `book_files` rows under one target, ordered by tag evidence even when filenames are out of
  lexical order (`"b.mp3"`, `"a.mp3"` numbered 2/1 in tags) — proves tag evidence outranks
  filename order.
- A set whose filenames carry sequential numbers but whose tags disagree with them on the SAME
  file is held `:track_order_contradictory`, not imported with either guess.
- A set with two files sharing no numeric evidence at all (`"intro.mp3"`, "outro.mp3"`) is held
  `:track_order_unknown`.
- A set mixing one real track with one unrelated audio file (different tag `album`, dissimilar
  filename stem) is held `:mixed_book_tags`/`:mixed_book_filenames`, never imported as a spliced
  book.
- **Partial staging failure is atomic — fresh import**: a fault injected on the Nth of M tracks'
  staging call, on a target with no prior files, leaves zero files under the target's destination
  folder and zero `book_files` rows — verified by asserting the destination directory does not
  exist (or is empty) and the target's status is unchanged, not `:available`.
- **Partial staging failure is atomic — replace**: the identical fault, injected during a "Find a
  better match" replace of an already-`:available` target, leaves the **original** N files
  byte-identical on disk (not empty, not the half-landed new set) and the original `book_files`
  rows unchanged — proving §4a's per-track backup-then-rollback, not just "nothing new landed."
- **A same-track-count replace actually replaces bytes** (the direct regression test for the
  defect an earlier draft of this plan did not catch): a replace whose new release resolves to the
  identical ordered path set as the target's current files lands the NEW bytes at every path
  (asserted by content, not merely by a reported success), the `book_files` rows are refreshed
  with the new release's metadata (size/track/duration), and `record_import_set/3` returns
  `superseded_paths: []` (every path was reused, not orphaned).
- **`maybe_supersede_set/3`'s combinations, each asserted directly against `Cinder.Books.Files`
  with no grab/poller involved:** identical incoming/existing path sets → zero rows deleted,
  `superseded_paths: []`; disjoint sets (different track count, no path shared) → every existing
  row deleted, every one of their paths in `superseded_paths`; partial overlap (some tracks
  reused, some old tracks orphaned) → every existing row deleted including reused-path ones, but
  `superseded_paths` contains only the orphaned paths, never a reused one; the incoming set a
  strict subset of the existing one (fewer tracks in the new release) → every existing row
  deleted, the paths absent from the incoming set are in `superseded_paths`.
- **Crash between DB commit and stage commit is safe for a multi-file set**: a fault injected
  between `record_import_set/3`'s transaction commit and the loop of `StageEngine.commit/1` calls
  leaves every `book_files` row intact and every underlying file on disk; a subsequent
  `Library.reconcile_stages/0` sweep converges every still-`:prepared`-or-`:committed` journal row
  to `:committed`/cleaned without deleting any of the N files — proving the existing
  `stage_ids`/journal mechanism generalizes correctly to N > 1.
- A hostile archive (a path-traversal entry, an entry-count flood, an expanded-size flood scaled to
  the new 8 GB ceiling) is refused by the existing archive-extractor error atoms, unchanged.
- `Download.grab_book_target/3` refuses an `%AudiobookRelease{}` submitted against an `:ebook`
  target and vice versa with `{:error, :unsupported_media_kind}` — regression-proving the dispatch
  guard the existing catch-all clause already gives, now exercised against two live kinds instead
  of one.
- `mix test` green.

---

## B7c — Audiobookshelf publisher and retryable scan

### 1. Why a new behaviour, not `Cinder.Library.MediaServer`

Task fact #6 says Audiobookshelf must be "a behaviour + adapter + Mox mock, exactly like
`Cinder.Library.MediaServer`" — read literally, not as "reuse `MediaServer` itself." Tracing
`MediaServer`'s actual shape shows why reusing the behaviour verbatim would be wrong: its
`scan(kind)` callback is parametrized over `Cinder.Library.kinds/0` (`:movies`/`:tv` — the *video*
subset, per `LibraryKind`'s own moduledoc: "`Cinder.Library.kinds/0` is the *video* subset... a
book kind inherits nothing it has not explicitly opted into"), and its other three callbacks
(`list_users/0`, `list_items/1`, `deep_link/1`) are Jellyfin/Plex account-import and deep-linking
features Audiobookshelf has no equivalent surface for in this pipeline. Implementing `MediaServer`
for Audiobookshelf would mean three no-op/`{:error, :not_supported}` callbacks purely to satisfy a
shape that does not fit — the same forced-reuse smell as everywhere else in this plan. New,
narrower behaviour instead, in the naming/adapter/mock **pattern** `MediaServer` establishes:

```elixir
# lib/cinder/library/audiobook_server.ex
@callback scan() :: :ok | {:error, term()}
@callback health() :: :ok | {:error, term()}
def impl, do: Application.fetch_env!(:cinder, :audiobook_server)
```

`lib/cinder/library/audiobook_server/audiobookshelf.ex` implements it against Audiobookshelf's own
documented API: `POST /api/libraries/:id/scan` (bearer-token auth), reusing `Cinder.HTTPPolicy`'s
existing response-size/timeout guard rail exactly like `Jellyfin`/`Plex` already do — no new HTTP
plumbing invented. `health/0` is a cheap `GET /api/libraries` reachability probe, mirroring
`Jellyfin.health/0`'s "guard the unconfigured case so `/status` shows a clean 'Not configured'"
pattern.

Configured at `config :cinder, :audiobook_server`; `config/test.exs` sets it to
`Cinder.Library.AudiobookServerMock` (`Mox.defmock/2` in `test/test_helper.exs`, matching every
other service mock's registration).

### 2. Settings

`lib/cinder/settings/registry.ex` gains `audiobookshelf_url`, `audiobookshelf_api_key`
(`secret: true`, Cloak-encrypted at rest exactly like `readarr_api_key`/every other secret field —
no new secret-handling mechanism, the existing `secret: true` flag is the whole story per B6's own
closing note), and `audiobookshelf_library_id` — three new rows in whatever settings section
already lists `jellyfin_url`/`plex_url`, following that section's existing form layout unchanged.

### 3. Retryable post-import scan — why `claim_post_commit_effects` is the wrong mechanism here

Movies/TV request a media-server refresh through `Cinder.Library.PostImport.refresh/2`, called from
`StageEngine.claim_post_commit_effects/1`'s **exactly-once** claim inside `commit_stage/1`. Traced
its actual failure handling: `refresh/2`'s own comment says a failed scan "must not strand a
correctly-imported movie" and its only action on `{:error, reason}` is `log_scan_failure/2` — **the
scan is never retried**, because Plex/Jellyfin already run their own periodic library scans
independently, so a missed on-demand refresh is cosmetic (the item appears on the *next* scheduled
scan regardless).

That assumption does not hold for Audiobookshelf the same way, and the roadmap's own Done-when is
explicit that it must not: "refresh failure is recoverable **without re-downloading**." Reusing
`claim_post_commit_effects`'s one-shot-forever-claimed semantics would mean a single transient
network blip permanently loses the scan request for that import (the effects-claim row is marked
claimed regardless of the scan's own success/failure) — recoverable only by a full manual
re-scan/re-import, which is exactly what the Done-when rules out. **New mechanism: a durable,
retried-until-success scan flag, not a one-shot claim.**

`book_targets` gains one nullable column, `audiobookshelf_scanned_at :utc_datetime`, via a plain
`ALTER TABLE ADD COLUMN` (no CHECK, no rebuild — the profile-integrity triggers are keyed on
`profile_id`/`media_kind`, neither touched by this column). `AudiobookImport`'s success path (via
`Files.record_import_set/3`'s `arm_target/1`, extended with one more `set:` field only when
`media_kind == :audiobook`) leaves `audiobookshelf_scanned_at: nil` on every fresh
`:available`-transition of an audiobook target — the signal "this target's on-disk content changed
and Audiobookshelf has not been told."

`BookPoller` gains one more phase in `do_poll/1`, `request_audiobookshelf_scans/0`:

```elixir
defp request_audiobookshelf_scans do
  for target <- Books.list_pending_audiobook_scans(),
      do: isolate("audiobookshelf scan for target #{target.id}", fn -> scan_one(target) end)
end
```

`Books.list_pending_audiobook_scans/0` is a plain indexed query (`media_kind: :audiobook, status:
:available, audiobookshelf_scanned_at: nil`); `scan_one/1` calls `AudiobookServer.impl().scan/0`
and, on `:ok`, sets `audiobookshelf_scanned_at: DateTime.utc_now()` through
`Books.mark_audiobookshelf_scanned/1` (a small new one-liner in `Cinder.Books`, the
media-kind-agnostic choke-point every target write already goes through) — **no broadcast**, since
this is not a `status` transition and no LiveView renders scan state, matching
`Books.clear_blocklist/1`'s existing "no side effect" precedent for a write that changes nothing
the UI displays. On `{:error, reason}`, the flag stays `nil` and the same target is retried on
every subsequent tick — throttled logging via the existing `warn_throttled/2` helper
(`{:audiobookshelf_scan, target.id}` key), the identical pattern `BookPoller.warn_disk_full/1`
already uses for its own indefinite, non-attempt-budgeted retry. This is deliberately **not**
bounded by `@max_attempts` — like `:library_not_configured`/`:download_roots_not_configured`
already established, a failed scan request is a fact about *configuration/connectivity*, not about
the payload, so there is nothing to hold on and no reason a fixed operator typo should need a
re-download to recover from once corrected. The already-`:available`, already-on-disk file is never
touched by any of this — recoverable without re-downloading is the property by construction, since
the download/import path and the scan-request path share no failure state.

### 4. Health

`lib/cinder/health.ex` gains `check_service(:audiobook_server)`, dispatching to
`run(Application.fetch_env!(:cinder, :audiobook_server))` — a **plain atom** clause, matching
`check_service(:media_server)`'s own shape exactly (`health.ex:34`: `def
check_service(:media_server), do: run(Application.fetch_env!(:cinder, :media_server))`), not a
`{:audiobook_server}` tuple as an earlier draft of this plan wrote. A tuple shape belongs only to
a service parametrized over multiple instances (`{:library, kind}`, `{:download, protocol}`,
`{:books_metadata, provider}`) — Audiobookshelf, like Jellyfin/Plex, has exactly one configured
instance, so it takes the same plain-atom shape `:media_server` already does. Appended to
`check_all/0` via a new `audiobook_server_check/0`, `media_server_check/0`'s own sibling, and
wired into `check_service/1`'s "Test connection" dispatch the same way.

### Test plan (properties)

- A fresh audiobook import leaves `audiobookshelf_scanned_at: nil`; the poller's scan phase calls
  `scan/0` exactly once per pending target per tick and sets the timestamp only on `:ok`.
- A scan failure leaves the target `:available` with its file(s) untouched and
  `audiobookshelf_scanned_at` still `nil`; a **second** tick retries the same target with no
  attempt-count field ever exhausting (bounded log frequency asserted via the throttle key, not a
  hold).
- Fixing the (mocked) failure between two ticks lets the very next tick succeed and stamp the
  timestamp — "recoverable without re-downloading," demonstrated end-to-end with no grab, no
  `BookImport`/`AudiobookImport` call, involved in the recovery at all.
- `Health.check_all/0` includes the `:audiobook_server` row and a simulated failure there does
  not affect any other row's result.
- `mix test` green.

---

## B7d — Operator surface: audiobook search, Grab, replace, deletion

### 1. `BookDetailLive` gains audiobook clauses, not a widened guard

```elixir
defp searchable?(%BookTarget{media_kind: :audiobook, status: :monitored}, nil), do: true
defp searchable?(%BookTarget{media_kind: :ebook, status: :monitored}, nil), do: true
defp searchable?(_target, _grab), do: false

defp replaceable?(%BookTarget{media_kind: :audiobook, status: :available}, nil), do: true
defp replaceable?(%BookTarget{media_kind: :ebook, status: :available}, nil), do: true
defp replaceable?(_target, _grab), do: false
```

Two clauses, not one guard widened to `media_kind in [:ebook, :audiobook]` — kept split because the
render branch each gates is genuinely different (§2): the ebook branch also renders the
language-preference `<select>` (§3's own comment already explains this is deliberately audiobook-
guarded out today, and stays guarded out — nothing in B7 adds an audiobook language picker; the
scorer's language check already works from the *release's* parsed tag exactly like the e-book
path, with no separate preference control needed for B7's scope).

The template's manual-search/replace panel is rendered per-target with the component chosen by
`target.media_kind`:

```heex
<.live_component
  :if={target.media_kind == :ebook}
  module={CinderWeb.BookManualSearchComponent}
  ...
/>
<.live_component
  :if={target.media_kind == :audiobook}
  module={CinderWeb.AudiobookManualSearchComponent}
  ...
/>
```

`handle_info({:manual_grab, :book, target, release}, socket)` (the single forwarding clause both
components already send through, per `BookManualSearchComponent`'s own moduledoc: "forwards a
chosen release back here — it owns no writes of its own") needs **no change**: it already calls
`Download.grab_book_target(target, release, ...)` generically, and B7b's new `:audiobook` clause on
that function makes the exact same call site handle both release struct types correctly by pattern
match. `book_grab_flash/3`'s fallback branch (re-reading `hold_reason` off the target rather than
pattern-matching every error atom) also needs no change — it was written kind-agnostic already.

### 2. `CinderWeb.AudiobookManualSearchComponent` — a new component, not a bolt-on

Same B4c-§4 judgment as `BookManualSearchComponent` itself made against the video
`ManualSearchComponent`: different acquisition module (`Cinder.Acquisition.Audiobooks`, not
`Books`), different scorer reason vocabulary needing its own exhaustive
`reject_reason_text/1` dictionary (built against `AudiobookScorer.reasons/0`, tested the same
exhaustiveness way `book_manual_search_component_test.exs` already tests `BookScorer.reasons/0`),
and one genuinely new render element: a **narrator** line under each accepted result
(`evidence.narrator`, informational, blank when unparsed — never a filter, never a sort key,
matching B7a's own "no narrator gate" decision). Everything else — the async-search skeleton,
`handle_async(:search, ...)`'s three clauses, `fetch_release/2`'s by-index resolution, `replace?/1`
— is copied verbatim from `BookManualSearchComponent`, the identical "reuse the *pattern*, not the
module" `BookManualSearchComponent` itself already documents against `ManualSearchComponent`.

New file: `lib/cinder_web/components/audiobook_manual_search_component.ex`.
New test: `test/cinder_web/components/audiobook_manual_search_component_test.exs`.

### 3. Retry, blocklist, pause/resume — already generic, verified rather than assumed

Traced against B5's actual code, not assumed: `Books.retry_target/1`, `Books.pause_target/1`,
`Books.resume_target/1`, `Books.hold_target/5`, `Books.blocked_release_titles/1`,
`Books.clear_blocklist/1`, and `AudiobookScorer`'s own `check_not_blocklisted/2`/`check_blocked/2`
(copied in B7a from `BookScorer`'s identical logic) all operate on `BookTarget`/`book_target_id`
with no `media_kind` branch anywhere in their bodies. **No B7d code is needed for retry, blocklist,
or pause/resume to work for an audiobook target** — they already do, the moment a real audiobook
grab/hold exists to exercise them, which B7b supplies. `library_live.ex`'s Wanted/Held filters and
Pause/Resume buttons (B5c) are similarly already `media_kind`-agnostic (`t.status`-keyed, not
kind-keyed). Confirmed by extending `book_target_transition_test.exs`'s and `library_live_test.exs`'s
existing parametrized cases to include an `:audiobook` fixture target alongside the `:ebook` one
already there, rather than writing new test logic — the property under test ("pause refuses with an
in-flight grab", "held target shows Retry") is kind-independent and the test should say so.

### 4. Deletion and recovery

The roadmap names "audiobook-specific ... deletion, and recovery" in its Work list. Traced: B5's own
"What stays out" is explicit that **no book target/file deletion exists at all yet** ("Per-work
'unmonitor and forget' (deletion)... is not named anywhere in B5's Work list and is left for a
future milestone if ever requested"). B7's roadmap line is therefore not asking for an
audiobook-only deletion feature bolted onto a missing general one — read against the parity
contract's own file boundary (checksum-as-evidence, path stored once) and B5's restraint, "deletion"
here means: an audiobook import that fails validation (§B7b's held reasons) leaves its **payload
on disk, untouched**, exactly like every existing permanent e-book import error already does
(`BookPoller`'s own `:no_book_file`/`:ambiguous_book_files` handling — "the failed payload is left
on disk untouched"), and "recovery" is the existing Retry/"Find a better match" path (§3) — **both
already work generically** the moment B7b's held reasons exist. No new deletion UI or context
function is added in B7d; this line is discharged by B7b's held-reason handling plus B7d§3's
already-generic Retry, not by new code. Recorded explicitly here rather than silently treated as
already covered by an implementer who has to go looking for it.

### Test plan (properties)

- A monitored audiobook target renders the manual-search panel; an `:ebook` target on the same work
  still renders its own — independent panels, independently operable, on one page (the roadmap's
  own "Done when: same work can be Available as e-book, audiobook, both, or neither independently,"
  exercised at the UI layer here, at the acquisition/data layer in B7a/B7b).
- Every `AudiobookScorer.reasons/0` atom has a non-fallback `reject_reason_text/1` clause
  (exhaustiveness test, mirroring the e-book one).
- Retry/blocklist-clear/pause/resume all operate correctly against an `:audiobook`-kind fixture
  target — proving genericity by demonstration, not by reading the source and trusting it.
- A held audiobook target (any B7b reason) shows its exact reason and a working Retry button; no
  new "delete" affordance exists anywhere in the diff.
- `mix test` green.

---

## B7e — Audiobook migration: fix the hardcoded `:ebook` classification

### 1. The bug

`Cinder.Library.MigrationAdoption.Readarr` (B6b) and `Cinder.Books.Adoption.adopt_work/3` (B6c)
were built and tested exclusively against the e-book Bookshelf instance — traced in
`lib/cinder/library/migration_adoption/readarr.ex`, every classified candidate and every
`book_targets` row `adopt_work/3` creates is hardcoded `media_kind: :ebook`, regardless of what
format the source `book_files`/`bookfile.quality.quality.name` snapshot field actually reports.
Pointing `readarr_url`/`readarr_api_key` at the *audiobook* Bookshelf instance and running the exact
same B6c runbook today would misfile every M4B/MP3 as an `:ebook` target — wrong, not merely
incomplete.

### 2. The fix

**Correcting an earlier draft's claim:** `adopt_work/3`'s current signature is `adopt_work(resolution,
files, _opts \\ [])` (`lib/cinder/books/adoption.ex:95`) — the leading underscore means `_opts` is
accepted but never read anywhere in the function body, and the moduledoc says plainly "Adopts
`files` onto `resolution`'s work's `:ebook` target," with the literal atom `:ebook` hardcoded at
the one call site that matters, `Books.ensure_target(work, :ebook)` (`adoption.ex:100`). This is
not "already accepts `media_kind` internally" — it is an unused parameter slot sitting next to a
hardcoded atom, and the fix has to actually thread a real value through, not merely propagate one
along an existing pathway.

`format/0`'s existing lowercased raw string (`"epub"`, `"m4b"`, `"mp3"`, or an unrecognized raw
value, per B6b's own `file/0` type doc: "the raw `bookfile.quality.quality.name`, lowercased ...
or the raw unrecognized string when Bookshelf reports something else") already carries everything
needed to classify. `lib/cinder/library/migration_adoption/readarr.ex` gains one classification
function:

```elixir
defp media_kind_for(format) when format in ["epub", "azw3", "mobi"], do: {:ok, :ebook}
defp media_kind_for(format) when format in ["m4b", "mp3"], do: {:ok, :audiobook}
defp media_kind_for(_unrecognized), do: :error
```

used at the same point classification already branches on `:unsupported_format` — a file whose
format resolves to neither kind is `:unsupported_format`, unchanged behavior for anything that
was already refused. The resolved `media_kind` rides on the candidate through to `adopt_work/3`,
whose signature actually changes: `adopt_work(resolution, files, media_kind, opts \\ [])` — a new
required positional argument, not the pre-existing (unused) `_opts` repurposed, since threading a
value every call site always has through a keyword list would be an unnecessary indirection. Two
concrete edits inside `adoption.ex`: the moduledoc's "onto `resolution`'s work's `:ebook` target"
becomes "onto `resolution`'s work's `media_kind` target," and line 100's
`Books.ensure_target(work, :ebook)` becomes `Books.ensure_target(work, media_kind)`. Every other
step (`insert_files/2`, `arm_available/1`, `refuse_grab_in_progress/1`, `refuse_held/1`) operates
on the already-resolved `%BookTarget{}` and needs no change — the kind only matters at the one
line that decides *which* target to get-or-create.

`format/0`'s Ecto.Enum-equivalent widening in B7a (`book_files.format` CHECK now includes `m4b`/
`mp3`) is a prerequisite this slice depends on but does not itself modify — ordered last only
because it is the smallest, not because of a hard dependency on B7a/B7b's runtime import path
(migration adoption never calls `BookImport`/`AudiobookImport`; it writes `book_files` rows
directly for already-correct, already-placed files, exactly as B6c already does for e-books).

### 3. Runbook addendum

`docs/readarr-migration.md` (B6c) gains one paragraph: an operator with both a legacy e-book and a
legacy audiobook Bookshelf instance runs the existing six-step runbook **twice** — once with
`readarr_url`/`readarr_api_key` pointed at each instance in turn, confirming/adopting between runs.
This is not a new procedure; it is the existing one-time, operator-driven runbook stated to be
safely repeatable across a settings repoint, which it already is (`adopt_work/3`'s
`:already_managed` re-classification on a repeat `Preview` already makes a second run over
already-migrated content a no-op, per B6c's own test plan) — the addendum only states this
explicitly so an operator with two real instances is not left to discover it by trial.

### Test plan (properties)

- A snapshot fixture built with `m4b`/`mp3` format values classifies to `media_kind: :audiobook`
  candidates; the existing e-book fixture's classification is byte-for-byte unchanged (regression).
- `adopt_work/3` on an `:audiobook`-classified candidate creates a `book_targets` row with
  `media_kind: :audiobook`, `status: :available`, and a `book_files` row at the unchanged source
  path — the same end-to-end property B6c's own test plan already asserts for `:ebook`, parametrized
  over both kinds now instead of duplicated.
- A format value resolving to neither kind (`"pdf"`, a raw unrecognized Bookshelf value) still
  classifies `:unsupported_format`, unchanged.
- `mix test` green.

---

## Roadmap Done-when → slice mapping

| Roadmap criterion | Satisfied by |
|---|---|
| The same work can be Available as e-book, audiobook, both, or neither independently | Already true at the data-model layer (unique index on `[work_id, media_kind]`, unchanged); made *reachable* end-to-end by **B7a** (search/score) + **B7b** (grab/import) + **B7d** (UI exposes both independently on one page) |
| A multi-track audiobook is imported atomically as one target | **B7b** (`AudiobookSources.resolve/1`'s deterministic-or-refuse ordering, `stage_all/3`'s roll-back-everything-on-partial-failure, `Files.record_import_set/3`'s one-transaction/N-rows write, reusing `Library.stage_ids/1`'s existing multi-stage-id journal mechanism) |
| Audiobookshelf sees the item after refresh, and refresh failure is recoverable without re-downloading | **B7c** (durable `audiobookshelf_scanned_at` flag retried every tick until success, independent of and never touching the already-committed download/import state) |
| An audiobook migration dry run and repeat adoption are safe | **B7e** (fixes `media_kind` classification; reuses B6b's already-proven zero-write `preview/1` and B6c's already-proven `:already_managed` idempotent re-adopt, neither of which needed new safety logic — only the kind label was wrong) |

## What stays out

- **Automatic release selection.** No `best_audiobook_release/2` — `Cinder.Acquisition.Audiobooks`
  is exports-only `search/1`/`candidates/2`, exactly like `Cinder.Acquisition.Books`, for the
  identical reason B4a/B5's §0 already established for e-books (no B0 corpus-precision threshold
  exists for automatic *release* matching, for either media kind) and the roadmap's own B7 Work
  list only ever says "audiobook-specific manual search," never automatic.
- **Containers beyond M4B/MP3.** OGG/FLAC/AAC-in-M4A audiobooks are recognized-but-rejected by the
  parser/scorer (a named `:format_rejected`, not a silent `:format_unknown` miss) rather than
  accepted — no B0 evidence names a real release in any of those containers, and widening the
  accepted list is a one-line scorer change whenever one is (§0.1).
- **A generic book-target deletion feature.** B5 deliberately left this out entirely; B7 does not
  introduce a kind-specific one either (§B7d.4) — a held audiobook's payload stays on disk exactly
  like a held e-book's, recoverable by the same generic Retry.
- **Multi-instance migration-source configuration.** §0.3's judgment: the real fix (per-instance
  settings threaded through `MigrationSource`/`MigrationAdoption`/the registry/the UI) is
  independent, multi-slice-sized work with no evidence the household needs both instances migrated
  concurrently rather than sequentially; B7e ships the one-line classification fix and a runbook
  addendum instead.
- **An audiobook language-preference picker.** The e-book one exists because `BookScorer`'s
  `check_language/2` gates on it; `AudiobookScorer`'s language check works identically from the
  release's own parsed tag with no additional UI control needed for B7's scope — adding one is a
  future request, not something this milestone's Work list names.
- **A book-side quality-upgrade sweep for audiobooks.** "Find a better match" (B5a, now reachable
  for audiobook targets per §B7d.3) remains manual-only, for the identical reason B5's own "What
  stays out" already gives for e-books (no automatic selection exists to drive an unattended
  sweep).

## Constraints carried into execution

- Every new user-facing string — the audiobook search/replace panel's labels, narrator display,
  every `AudiobookScorer.reasons/0` rejection sentence, the audiobookshelf settings form fields,
  any new flash copy — goes through `gettext` with a real, non-fuzzy French translation in
  `priv/gettext/fr/LC_MESSAGES/default.po` before that slice's `mix test` is green
  (`test/cinder_web/translations_complete_test.exs` enforces this; per B4c's and B5's own
  documented experience, a `gettext.extract --merge` fuzzy match onto an unrelated existing string
  is not a substitute for a reviewed translation). No em dashes in any of it.
- No slice runs a project-wide formatter/linter/build pass mid-flight; `mix test` (which already
  runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the
  suite, per AGENTS.md) is the sole gate, run once per slice.
- Secrets (`audiobookshelf_api_key`) are Cloak-encrypted at rest through the existing
  `Cinder.Settings` `secret: true` field mechanism and never echoed back to the settings form — no
  new secret-handling code.
