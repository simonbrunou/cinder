# Feature Specification: Readarr Migration, Adoption Preview, and E-Book Cutover

**Feature Branch**: `064-books-b6-migration-cutover`

**Created**: 2026-09-01

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-09-01-books-b6-migration-and-cutover.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Preview an existing e-book library before touching it (Priority: P1)

An admin running a legacy Readarr-protocol e-book library (via a Bookshelf-style instance) wants to
see exactly what would be adopted before anything changes, with every ambiguous or risky file
called out rather than silently guessed.

**Why this priority**: A destructive or silently-wrong migration is unrecoverable trust damage; a
safe, read-only preview is the precondition for everything else in this feature.

**Independent Test**: Configure a migration source, run Preview, and confirm the resulting
candidate list with zero database writes and zero changes to source files.

**Acceptance Scenarios**:

1. **Given** a configured Readarr-protocol source with existing e-books, **When** the admin runs
   Preview, **Then** every file-bearing work is classified as ready, needs-decision, blocked, or
   already-managed, and running Preview again with no adoption in between returns identical
   results.
2. **Given** a library larger than the per-batch resolution cap, **When** Preview runs, **Then** it
   processes candidates in bounded batches and reports how many remain unprocessed, rather than
   issuing an unbounded burst of identity-resolution requests.
3. **Given** a work whose file has already been adopted, **When** Preview runs again later,
   **Then** that work resolves locally with no repeated network lookup.

### User Story 2 - Adopt in place with explicit decisions on ambiguity (Priority: P1)

An admin wants to bring matched files into the catalog without moving or rewriting them, resolving
only the genuinely ambiguous cases (multiple formats for one work) by hand.

**Why this priority**: This is the actual cutover action; it must never guess and must never risk
source data.

**Independent Test**: Adopt a straightforward candidate and confirm its file path on disk is
unchanged; adopt a multi-format candidate after choosing "preferred format only" or "all formats."

**Acceptance Scenarios**:

1. **Given** a ready candidate, **When** the admin adopts it, **Then** a durable target/work/file
   association is created and the file's on-disk path is unchanged.
2. **Given** a candidate with two accepted-format files for the same work, **When** the admin
   chooses "preferred format," **Then** only the preferred file is adopted and the other is left
   untouched on disk; choosing "all formats" adopts both under one target.
3. **Given** an already-adopted candidate, **When** the admin re-runs adoption on it, **Then** the
   action is a no-op rather than a duplicate or an error.

### User Story 3 - Resolve blocked and conflicting candidates explicitly (Priority: P2)

An admin needs a clear, fixable reason whenever a candidate cannot be safely adopted, rather than a
silent skip or an incorrect guess.

**Why this priority**: Correctness depends on every risky case surfacing to a human, not on a best
guess.

**Independent Test**: Trigger a path conflict, an identity conflict, and an out-of-root path, and
confirm each blocks with a distinct, actionable reason.

**Acceptance Scenarios**:

1. **Given** a candidate's resolved destination path already belongs to a different work's file,
   **When** Preview classifies it, **Then** it is blocked as a path conflict, not silently skipped
   or adopted.
2. **Given** a candidate's translated path falls outside every configured e-book library root,
   **When** Preview classifies it, **Then** it is blocked rather than adopted into the wrong place.
3. **Given** a candidate's resolved work already has a held target, **When** Preview classifies it,
   **Then** it is blocked rather than overriding the more recent operator/system decision.

### Edge Cases

- Monitored works from the source library that have no associated file are never treated as
  migration candidates; their count is surfaced separately with guidance to use per-author
  monitoring afterward.
- A work that identity-resolution genuinely cannot resolve becomes a visible blocked candidate with
  an explained reason, never a silent omission.
- An unrecognized file format blocks only that file, not its siblings for the same work.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Admin MUST be able to configure a Readarr-protocol migration source (address,
  credential, path prefixes) using the same settings mechanism as existing migration sources.
- **FR-002**: System MUST report reachability health for the configured Readarr-protocol source.
- **FR-003**: Preview MUST classify every file-bearing candidate work into one of: ready,
  needs-decision, blocked, or already-managed.
- **FR-004**: Preview MUST perform zero database writes — running it MUST change nothing.
- **FR-005**: System MUST bound the number of new identity-resolution requests issued per
  preview/adopt batch, and MUST report the count of not-yet-processed candidates.
- **FR-006**: A candidate already durably associated with the source (from a prior adoption) MUST
  be classified without a repeated network identity-resolution call.
- **FR-007**: A candidate with more than one accepted-format file for the same work MUST require an
  explicit operator decision — adopt only the preferred format, or adopt every accepted format —
  before it can be adopted.
- **FR-008**: A candidate MUST be blocked, not adopted, when its destination path already belongs
  to a different work's file, when its resolved work identity conflicts with an existing different
  file, when its resolved work's target is already held, or when its resolved destination path
  falls outside every configured e-book library root.
- **FR-009**: Adopting a candidate MUST leave its source file unchanged on disk — no move, copy,
  rename, or delete of the source file.
- **FR-010**: Re-adopting an already-adopted candidate MUST be idempotent — a no-op, not an error
  or a duplicate record.
- **FR-011**: Adoption MUST be refused for a candidate whose resolved target has an in-progress
  download or is currently held.
- **FR-012**: Monitored source-library works with no associated file MUST NOT be imported by
  migration; their count MUST be surfaced to the operator as a separate figure.
- **FR-013**: System MUST provide a documented cutover procedure covering: disabling source
  automation, taking backups, running Preview, resolving all flagged rows, adopting, verifying
  counts/paths, and enabling Cinder monitoring.
- **FR-014**: Rollback MUST be achievable by re-enabling the legacy source from its own backup,
  since adoption never deletes, moves, or rewrites a source file.

### Key Entities *(include if feature involves data)*

- **Migration source snapshot**: a normalized read of the legacy source's authors, works,
  editions, files, monitoring state, profiles, and roots.
- **Migration candidate**: a per-work classification result (ready / needs-decision / blocked /
  already-managed) with its reason when blocked or needing a decision.
- **Cutover runbook**: the documented operator procedure and rollback path for the migration.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Running Preview twice with no adoption in between produces identical candidate
  results.
- **SC-002**: An operator can classify and resolve every candidate in a real-scale legacy library
  (hundreds of works) through bounded preview batches, with no unbounded burst of provider
  requests at any point.
- **SC-003**: After adoption, every migrated file's on-disk path is unchanged from before
  migration.
- **SC-004**: An operator can fully restore the prior system from its own backup at any point
  before sign-off, with no data loss.

## Assumptions

- This is one slice (B6) of the umbrella books/Readarr-replacement track (see
  `053-books-readarr-replacement`); it depends on the monitoring/policy machinery shipped in the
  prior slice and covers the e-book cutover only.
- Audiobook migration is explicitly out of scope for this slice; a second, separately-addressed
  legacy instance for audiobooks is left untouched and unreachable from any code path in this
  feature, deferred to a later slice.
- No Calibre integration is built; the observed deployment topology needed none.
- No automatic format conversion or quality upgrade happens during adoption — every accepted file
  is adopted exactly as found; "Find a better match" (from the prior monitoring slice) remains the
  only upgrade path and works unmodified against a migration-adopted target.
- No fallback "stage into a managed root" path is built for a candidate outside every configured
  library root; such a candidate fails closed as a blocked, fixable operator error instead, since
  the existing migration precedent for other media kinds has no such fallback either and no
  observed deployment needed one.
- A short follow-up fix (GitHub issue #488, unreleased at time of writing) corrected the migration
  source's snapshot fetch to scope the `bookfile` and `edition` endpoints correctly against the
  real deployment's API behavior, after the original unscoped fetch made Preview produce zero
  candidates against a live Bookshelf instance (CHANGELOG "Unreleased": "The Readarr migration
  source can now snapshot a live Bookshelf at all (#488)"); that correction is implementation
  detail of this same feature, not a scope change.
