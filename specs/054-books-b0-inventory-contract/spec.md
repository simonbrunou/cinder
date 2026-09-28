# Feature Specification: Books B0 — Inventory, Parity Contract, and Labeled Corpus

**Feature Branch**: `054-books-b0-inventory-contract`

**Created**: 2026-08-20

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-20-books-b0-inventory-contract.md`), contracts/books-parity-contract.md (originally `docs/specs/2026-08-20-books-parity-contract.md`)

This is the first of three sliced specs under the umbrella replacement of the household's two `pennydreadful/bookshelf:hardcover` (Readarr-fork) instances with a native Cinder books feature (see `053-books-readarr-replacement`). B0 adds no production book code; it freezes the compatibility contract and evidence that B1 onward build against.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Freeze the current deployment as a migration baseline (Priority: P1)

Why this priority: this milestone freezes the current deployment as executable, versioned evidence for later milestones to build against, and changing a locked decision afterward requires an explicit spec change and fixture update.

Independent Test: inspect the committed aggregate inventory and parity matrix and confirm every currently relied-on behavior has an explicit disposition and migration consequence, with no raw household data present.

**Acceptance Scenarios**:

1. **Given** the two active Bookshelf instances, **When** they are inventoried read-only through their API, **Then** the aggregate counts (authors, works, editions, files, formats, quality profiles, download clients, indexers, consumers) are captured and committed without any raw title, author, path, or credential.
2. **Given** the captured behavior list, **When** each behavior is classified, **Then** every row carries one of `required for cutover`, `required later`, `already provided by Cinder`, or `deliberately parked`, plus an acceptance criterion and a migration consequence.
3. **Given** the raw snapshot lives only in a private directory, **When** the committed transformer is rerun against a manifest-matched snapshot, **Then** it deterministically reproduces the same aggregate inventory and synthetic API fixture.

### User Story 2 - Decide the metadata provider set from a labeled corpus (Priority: P2)

Why this priority: later discovery milestones (B2+) need a corpus-backed, not popularity-backed, decision on which metadata providers are mandatory for cutover.

Independent Test: run the frozen 40-case corpus against the evaluated providers and confirm the resulting provider decision meets its stated reliability threshold with explicit unresolved cases, not silent fallbacks.

**Acceptance Scenarios**:

1. **Given** the operator-confirmed 40-title public corpus covering every roadmap edge-case family, **When** Open Library alone is evaluated, **Then** its reliable-resolution rate is recorded and found insufficient against the 90% acceptance threshold.
2. **Given** Open Library is paired with the captured Hardcover/bookinfo evidence, **When** the pair is evaluated against the same corpus, **Then** the combined reliable-resolution rate is recorded and meets the threshold, and the three still-unresolved cases remain explicit unresolved states rather than guesses.
3. **Given** Google Books is evaluated keyless, **When** all 40 requests return HTTP 429, **Then** no theoretical coverage is inferred and Google Books is marked optional enrichment, not mandatory for cutover.

### User Story 3 - Lock data-model and consumer-handoff boundaries before code exists (Priority: P3)

Why this priority: later schema and acquisition milestones must not each re-litigate identity boundaries or file-handoff rules; those decisions need to be settled once, in evidence, before implementation.

Independent Test: read the locked data-boundary and consumer-handoff sections and confirm every stated boundary (author/work/edition/file identity, monitoring states, import naming, Booklore/Audiobookshelf handoff) has no open question.

**Acceptance Scenarios**:

1. **Given** the parity contract's data boundaries, **When** a work, edition, and file are considered, **Then** each is a distinct identity layer with its own stable identifier, and a work may have many contributors through a role-bearing, ordered join.
2. **Given** the locked import-naming decision, **When** a file is migrated, **Then** its existing filename is preserved by default and no automatic rename is applied.
3. **Given** the locked consumer-handoff decision, **When** an import completes, **Then** ebook assets are published under the shared books root for Booklore and audiobook assets under the shared audiobooks root for Audiobookshelf, with no consumer database mutation.

### Edge Cases

- Co-authored works, pen names, translations, multiple editions, series position, omnibus/anthology, missing ISBN, duplicate titles, punctuation/Unicode titles, and future releases are all represented in the 40-case corpus.
- One corpus case is an already-correct file (adoption should be a no-op, not a rewrite); one is an irreconcilable identity (must resolve to an explained held/unresolved state, never a first-result guess).
- Monitoring flags on the live instances do not imply acquisition intent: the eBook instance monitors an entire two-author bibliography while only a fifth of works have files, and the audiobook instance has far more monitored editions than monitored works — a naive import of monitoring flags would create a back-catalogue acquisition flood.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The contract MUST record aggregate inventory (authors, works, editions, files, formats, quality profiles, download clients, indexers, consumers) for both live instances without committing raw titles, authors, paths, or credentials.
- **FR-002**: The contract MUST classify every currently relied-on behavior into exactly one of four dispositions (`required for cutover`, `required later`, `already provided by Cinder`, `deliberately parked`), each with an acceptance criterion and migration consequence.
- **FR-003**: The corpus MUST contain exactly 40 uniquely identified, operator-confirmed public titles covering every named edge-case family, each with an explicit expected outcome and a frozen provider fixture reference.
- **FR-004**: The metadata provider decision MUST be corpus-backed: a provider or provider pair is mandatory for cutover only if it reaches at least 90% reliable work identity on the corpus with zero silent first-result fallbacks.
- **FR-005**: Unresolved corpus cases MUST remain explicit unresolved/ambiguous outcomes; no future milestone may treat added evidence as license to guess.
- **FR-006**: The data model MUST keep author/contributor, work, edition, and file as four distinct identity layers, each with a stable internal ID plus namespaced provider IDs, related through explicit many-to-many, role-bearing, ordered joins.
- **FR-007**: Series membership MUST be modeled as a join separate from work identity, preserving provider position without lossy coercion.
- **FR-008**: Monitoring MUST be modeled as explicit per (work, media kind) state; migrated source monitoring flags MUST be preserved as evidence only, never as automatic acquisition intent.
- **FR-009**: Import behavior MUST preserve parity: prefer hardlink with safe copy fallback, preserve existing release filenames by default (no automatic rename), and publish to role-based `books`/`audiobooks` roots.
- **FR-010**: Consumer handoff MUST publish completed imports to the Booklore (`books` root) and Audiobookshelf (`audiobooks` root) mount points without Cinder ever writing to either consumer's database.
- **FR-011**: Quality/format policy MUST accept EPUB, AZW3, and MOBI for ebooks (EPUB preferred) and M4B for audiobooks in the frozen baseline, with unknown or contradictory formats failing closed to manual review.
- **FR-012**: Raw live-instance responses MUST remain outside version control; only aggregate counts, policy values, and a deterministically synthesized, secret-free fixture may be committed.

### Key Entities

- **Author/Contributor**: A person or organization credited to a work or edition, identified by internal ID plus namespaced provider IDs; many-to-many with works and editions.
- **Work**: The abstract intellectual work that is discovered, requested, and monitored; has many editions and optional series memberships.
- **Edition**: A specific publication or recording manifestation (language, format, publisher, date, identifiers) belonging to exactly one work.
- **File**: One imported physical asset belonging to one edition and one media kind.
- **Corpus case**: One of the 40 curated public titles with operator-confirmed expected identity/edition outcomes used to evaluate provider and adapter behavior.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the 40 corpus cases have an explicit, operator-confirmed expected outcome and a frozen fixture reference.
- **SC-002**: The chosen metadata provider pairing resolves at least 90% of corpus cases reliably, with the remainder recorded as explained unresolved states.
- **SC-003**: 100% of currently relied-on migration behaviors have a locked disposition, acceptance criterion, and migration consequence with no open question.
- **SC-004**: Zero raw household titles, authors, paths, or credentials appear in any committed artifact.
- **SC-005**: Re-running the committed transformer against a manifest-matched private snapshot reproduces byte-identical committed aggregate and fixture artifacts.

## Assumptions

- This spec covers only the contract-freezing milestone (B0) of the umbrella books/Readarr-replacement effort (`053-books-readarr-replacement`); it adds no production book code.
- The corpus is a curated public 40-title set chosen by the operator, not a sample of household data, so B0 evidence intentionally cannot be validated against real household titles.
- Google Books keyless evaluation returned HTTP 429 for all 40 requests; no coverage claim is made for it, and it remains optional enrichment rather than a cutover requirement.
- Calibre integration and automatic quality upgrade/format conversion are explicitly out of scope for the first cutover release (`deliberately parked` in the parity matrix).
- The 100 MB pre-import space-reservation figure is captured migration evidence, not an adequate universal default; later milestones must use asset-size-aware headroom.
