# Feature Specification: E-book Release Search, Parsing, and Scoring

**Feature Branch**: `060-books-b4a-ebook-search-scoring`

**Created**: 2026-08-30

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-30-books-b4a-ebook-release-search-and-scoring.md`)

This is the first of three slices of the [053 books/Readarr-replacement umbrella](../053-books-readarr-replacement/spec.md)'s B4 milestone (e-book search, scoring, download validation, and publication). It is the decision layer only: given an approved e-book target, it produces a ranked, explained list of candidate releases. It grabs nothing, writes nothing, and downloads nothing — that is B061 (B4b) and B062 (B4c).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Indexers are queried for e-book releases in descending evidence order (Priority: P1)

Why this priority: without a bounded, evidence-ordered query plan, a work with many editions could fan out into an unbounded burst of indexer queries.

Independent Test: for an approved e-book target with known editions, verify queries run ISBN probes first, then a structured author/title search, then a bounded free-text fallback, capped at a fixed total query count.

**Acceptance Scenarios**:

1. **Given** an approved e-book target with up to 3 ISBN-bearing editions, **When** a search runs, **Then** each edition's ISBN is probed via a free-text query, newest edition first, before any other query type runs.
2. **Given** ISBN probes are exhausted, **When** the search continues, **Then** a structured author/title query runs against the e-book category only, followed by a bounded free-text fallback if needed, with the total query count capped.
3. **Given** one indexer query fails while others succeed, **When** the search completes, **Then** the result distinguishes "nothing matched" from "the search was incomplete because a query errored."

---

### User Story 2 - Release names are parsed into format, language, and edition facts (Priority: P1)

Why this priority: scoring and later validation both depend on facts extracted from a release name; a wrong split can hand the author gate a title and the title gate an author, turning a clean rejection into a confident mismatch.

Independent Test: feed realistic e-book release names through the parser and confirm the extracted format set, language, retail marker, and collection/abridgement flags match the name's actual content.

**Acceptance Scenarios**:

1. **Given** a release name listing multiple formats (e.g., "Author - Title (EPUB, MOBI, AZW3)"), **When** it is parsed, **Then** all listed formats are captured as a set, not collapsed to one value.
2. **Given** a release name carrying a recognizable language tag, **When** it is parsed, **Then** the same language vocabulary used for video releases is applied so the two families cannot drift apart on what a language tag means.
3. **Given** a release name indicating an omnibus/collection or an abridged edition, **When** it is parsed, **Then** those facts are captured so a later rejection can name them explicitly.

---

### User Story 3 - Candidate releases are scored and explained, never silently dropped (Priority: P1)

Why this priority: the whole point of this slice is a legible decision — every candidate release must end up either accepted with evidence or rejected with a specific, deterministic reason, never silently discarded.

Independent Test: run the scorer against known-good and known-bad release fixtures and confirm each rejection carries one of a fixed set of reason atoms, and each acceptance carries supporting evidence.

**Acceptance Scenarios**:

1. **Given** a release with no recognizable e-book format, **When** it is scored, **Then** it is rejected as unrecognized format rather than accepted with a blank format.
2. **Given** a release whose parsed format is not on the accepted e-book format list, **When** it is scored, **Then** it is rejected as a rejected format, distinct from an unrecognized one.
3. **Given** a release matching neither the target's author nor its title by token-set comparison, **When** it is scored, **Then** it is rejected with the specific mismatch reason, and surviving candidates are ranked by format preference, language exactness, retail marker, and smaller file size before publication date and title as tiebreakers.

### Edge Cases

- A release name that cannot be reliably split into author/title segments is scored on the whole name as a token set, not forced into a segmentation guess that could hand the wrong side to the wrong gate.
- A release below or above the e-book size band (too small to be a real book, or too large to be the single requested edition) is rejected on size, independent of format or language correctness.
- A release name carrying a blocked term is rejected regardless of otherwise-matching format, author, and title.
- Every provider being unreachable for a given search yields an explicit error, distinct from a completed search that simply found nothing.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST query indexers for e-book releases using a bounded, descending-evidence query plan: ISBN probes (at most 3, newest edition first), then a structured author/title query, then a bounded free-text fallback, capped at a fixed total number of queries per search.
- **FR-002**: System MUST scope e-book indexer queries to the e-book category only, never an unrestricted parent category that would sweep in comics, magazines, or technical manuals.
- **FR-003**: System MUST deduplicate search results by download identity and merge the provenance of each query that found a given release, so a release found by more than one query keeps every query's provenance.
- **FR-004**: System MUST report whether a search is complete (every query succeeded) or incomplete (at least one query errored), distinct from an empty result set, and MUST return an error only when every provider is unreachable.
- **FR-005**: System MUST parse a release name into a set of e-book formats (not a single value), a language, a retail marker, and collection/abridgement flags, using the shared language vocabulary already used for video releases.
- **FR-006**: System MUST score each candidate release and return either an acceptance with supporting evidence or a rejection with one specific, deterministic reason drawn from a fixed set — never a silently dropped candidate.
- **FR-007**: System MUST reject a release whose e-book format cannot be recognized ("format unknown") and treat that as distinct from a release whose recognized format is not on the accepted list ("format rejected") — the opposite of a permissive fallback.
- **FR-008**: System MUST require token-set author evidence and token-set title evidence (not substring matching) to accept a candidate, so author-name-order variants are treated as equivalent.
- **FR-009**: System MUST reject a candidate outside a fixed minimum/maximum file-size band appropriate to an e-book, independent of other match quality.
- **FR-010**: System MUST rank accepted candidates by format preference, then language exactness, then retail marker, then smaller file size, then publication date, then title, for a fully deterministic order.
- **FR-011**: System MUST NOT provide any automatic release-selection function in this slice — no code path may choose and act on a release without a human decision, until corpus-precision evidence gathered from this decision layer meets the project's precision threshold.
- **FR-012**: System MUST NOT write to storage, submit a download, or grab any release as part of search, parsing, or scoring.

### Key Entities

- **Book release candidate**: an indexer-reported e-book release enriched with parsed format, language, and edition facts, distinct from the video release model.
- **Scoring evidence / rejection reason**: the explained outcome attached to each candidate — supporting evidence for an acceptance, one deterministic reason atom for a rejection.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For an approved e-book target, a search returns a ranked, explained candidate list (accepted-with-evidence and rejected-with-reason) without ever silently omitting a discovered release.
- **SC-002**: Every rejection reason returned by scoring is one of a fixed, enumerable set of reasons, never a generic or unexplained rejection.
- **SC-003**: No search, parse, or score operation performed by this slice results in a stored write, a submitted download, or a grabbed file.
- **SC-004**: A search that queries multiple indexers where at least one is unreachable is distinguishable, in its result, from a search that queried every indexer successfully and found nothing.

## Assumptions

- This is slice one of three (B4a/B4b/B4c) of the B4 milestone within the [053 books/Readarr-replacement umbrella](../053-books-readarr-replacement/spec.md); download intent, polling, archive/content validation, publication, `book_files`, the operator UI, and audiobooks are explicitly out of scope and covered by later slices.
- Automatic release selection remains gated by the absence of an automatic-selection function, not a feature flag — this slice exists precisely so that release-decision precision can be measured before any code is authorized to act on it unattended. This is a settled books-track decision preserved from the source document and must not be reintroduced without meeting the corpus-precision threshold.
- Only `:ebook` releases are in scope; audiobook search/scoring is a later milestone.
