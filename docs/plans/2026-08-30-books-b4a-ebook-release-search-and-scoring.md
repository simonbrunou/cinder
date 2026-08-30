# Books B4a — e-book release search, parsing, and scoring

**Status:** planned 2026-08-30. Base: `origin/main` @ `7d3f0347`.
**Milestone:** the first slice of [B4](2026-08-20-readarr-replacement-roadmap.md#b4--e-book-search-scoring-download-validation-and-publication).

## Why this is a slice, not all of B4

B4 is estimated at 10–15 developer-days and spans indexer queries, a parser/scorer, a download
intent, a poller, archive validation, and a publisher. That is four or five reviewable units, and
B2/B3 were both split for the same reason (B2a/B2b, B3a/B3b).

The roadmap itself names the seam:

> Ship manual release search/selection first; enable automatic choice only after corpus precision
> meets the B0 threshold.

So B4a is the **decision layer**: given an approved book target, produce a ranked, explained list of
candidate releases. It grabs nothing, writes nothing, and downloads nothing. B4b takes that list and
adds the intent, the poller, validation, and publication.

That split is also what makes "automatic choice only after precision is measured" mechanically
possible: precision is a property of this layer, and B4a is where it can be measured before any
code is authorized to act on it.

## Scope

**In:**

- `Indexer` behaviour + Prowlarr adapter: book queries, narrow categories.
- A book release struct, parser, and scorer.
- Bounded query planning in descending evidence order.
- `:ebook` only.

**Out (B4b and later):** download intent, poller, archive/content validation, publisher,
`book_files`, UI, audiobooks, automatic grabbing.

## Design

### 1. Indexer behaviour (`lib/cinder/acquisition/indexer.ex`)

Two callbacks, mirroring the existing `search_tv/3` (identity-scoped) + `search_tv_query/2`
(free-text) pair:

```elixir
@callback search_book(author :: String.t() | nil, title :: String.t(), opts :: keyword()) ::
            {:ok, [map()]} | {:error, term()}
@callback search_book_query(query :: String.t(), opts :: keyword()) ::
            {:ok, [map()]} | {:error, term()}
```

`search_book/3` is the structured Newznab **book** search; `search_book_query/2` is the basic text
search, used for the ISBN probe and the bounded free-text fallback.

Adding callbacks to a behaviour with a Mox mock means every existing `IndexerMock` expectation still
compiles (Mox mocks implement the whole behaviour), so no test churn.

### 2. Prowlarr adapter

Prowlarr's `/api/v1/search` takes `type=book` and re-parses `{Author:…}`/`{Title:…}` brace tokens
out of `query` into real Newznab `author`/`title` params — verified against
`NewznabRequest.QueryToParams` (`BookRegex`) and `ReleaseSearchService.BookSearch` on
`Prowlarr/develop`. So the structured search is:

    query: "{Author:Ursula K. Le Guin} {Title:The Dispossessed}", type: "book"

`}` is stripped from interpolated values: the regex captures `[^{]+`, so an embedded `}` would
silently truncate the token and change which field the rest of the string lands in.

**Categories.** `7020` (Books/EBook) only, per the roadmap's "begin with e-book category evidence
and do not use an unrestricted parent category by default". Not `7000` — the parent sweeps in
comics, magazines, and technical manuals. Hardcoded module attribute, exactly like
`Cinder.Acquisition.Anime`'s `@anime_category 5070`; no settings-registry entry until an operator
actually needs a per-install override.

### 3. `Cinder.Acquisition.BookRelease`

The indexer-reported fields plus the name-parsed ones, mirroring `Acquisition.Release`. A separate
struct rather than more nil columns on `Release`: video fields (`resolution`, `season`, `episodes`,
`codec`) are meaningless for a book, and `LibraryKind` already keeps the two families apart on
purpose.

### 4. `Cinder.Acquisition.BookParser`

Pure, best-effort, `nil` for anything unrecognized. Extracts:

- `formats` — a **set**, not one value. `Author - Title (EPUB, MOBI, AZW3)` is one legitimate
  multi-format release, and collapsing it to a single value would either drop the acceptable format
  or invent a preference the release does not state.
- `language` — reuses `Parser.language_tags/0`, so books and video cannot drift apart on what
  "FRENCH" means.
- `year`, `authors_segment`/`title_segment` from the `Author - Title` convention book releases
  overwhelmingly follow.
- `retail?` — a scene marker worth ranking on, not gating.

### 5. `Cinder.Acquisition.BookScorer`

`evaluate/3` returns `{:accept, evidence}` or `{:reject, reason}`. Reasons are atoms, one per
independent fact, because the B4 "done when" requires *deterministic reasons* rather than a
disappearing candidate:

`:format_unknown`, `:format_rejected`, `:author_mismatch`, `:title_mismatch`,
`:language_mismatch`, `:size_out_of_band`, `:blocked_term`.

**Fail-closed rules** (contract: "Unknown or contradictory formats fail closed to manual review"):

- Format allow-list is `epub > azw3 > mobi` per the parity contract's e-book profile. A release with
  no parseable format is rejected `:format_unknown` — *not* accepted-with-nil. This is the opposite
  of the video scorer's `allowed_source?/2` nil-passes valve, and deliberately so: a video release's
  untagged source is a parser gap on an otherwise-playable file, whereas an e-book of unknown format
  may be a PDF scan or a DRM'd AZW the household cannot read.
- Author evidence is required and is a **token-set** test, not a substring one — reusing the rule
  `Cinder.Books.Identity` already justifies at length ("Cixin Liu" ≡ "Liu Cixin"). No author
  evidence, no candidate.
- Title evidence is required, folded the same way.

**Size band.** 64 KB – 200 MB. A book is not a video, and `movies_min_size` has no meaning here.
Bounds are module attributes, not settings: the floor rejects the stub/placeholder torrent, the
ceiling rejects the 4 GB "complete works" pack that is a different release from the one requested.

**Ranking** among survivors: format preference → language exactness → retail marker → smaller size
(for a book, a 40 MB EPUB of a 300-page novel is a scan, not a better copy — so smaller wins, the
inverse of video). Then `published_at` desc, then title, for determinism.

### 6. `Cinder.Acquisition.Books`

Query planning and aggregation. Descending evidence order per the roadmap:

1. **ISBN-13/ISBN-10** of each `:ebook` edition, via `search_book_query/2` — at most 3, newest
   edition first, so a work with 40 editions cannot fan out into 40 indexer hits.
2. **Structured** `{Author:…} {Title:…}` via `search_book/3`.
3. **Bounded free text** `"Title Author"` via `search_book_query/2`.

Capped at `@max_queries 6` total. Results are unioned and deduped by `download_url`, merging
`query_origins` so a release found by both an ISBN probe and free text keeps both provenances —
the same diagnostic `Release.query_origins` already carries for TV.

A failing query does not fail the search; `search/2` returns `{:ok, candidates, complete?}` with
`complete? == false` when any query errored, so a caller can tell "nothing matched" from "we did not
actually look". Every provider down ⇒ `{:error, reason}`.

`candidates/3` returns `%{accepted: [{release, evidence}], rejected: [{release, reason}]}` — the
rejected list is the point, not a debugging leftover: it is what a manual-search panel shows so an
operator can see *why* the obvious release was refused.

**No automatic selection function exists in this slice.** There is no `best_book_release/2`. That is
the gate, expressed as absence of code rather than a disabled flag.

## Done when

- `Prowlarr.search_book/3` issues `type=book` with the brace tokens and `categories=7020`, and
  `search_book_query/2` issues `type=search`; both normalize like the existing searches.
- The parser extracts multi-format sets, language, and year from realistic book release names.
- The scorer rejects wrong author, wrong title, wrong language, unknown format, rejected format,
  out-of-band size, and blocked terms — each with its own atom.
- `Books.search/2` plans queries in evidence order, is capped, dedupes, merges provenance, and
  distinguishes an incomplete search from an empty one.
- No module in this slice writes to the Repo, grabs, or downloads.
- `mix test` is green.

## Verification beyond the suite

The corpus fixture (`test/support/fixtures/books/corpus-v1.json`) carries the 40 operator-confirmed
titles B0 froze. B4a adds no new frozen fixture — release names are not in it — but the scorer test
draws its author/title cases from those same works so the two layers are exercised on one
vocabulary.
