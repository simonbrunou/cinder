# Feature Specification: Audiobook Acquisition and Audiobookshelf Publication

**Feature Branch**: `065-books-b7-audiobooks`

**Created**: 2026-09-02

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-09-02-books-b7-audiobooks.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Search for and grab an audiobook release (Priority: P1)

An admin wants to manually search for, evaluate, and download an audiobook release for a work,
independently of that work's e-book state.

**Why this priority**: Without a decision layer and grab path, no audiobook can be acquired at all
— every other capability depends on it.

**Independent Test**: Open manual search on a monitored audiobook target, review scored candidates
with rejection reasons, and grab an accepted release.

**Acceptance Scenarios**:

1. **Given** a monitored audiobook target, **When** the admin opens manual search, **Then**
   candidates are evaluated against audiobook-specific format (M4B/MP3), size, title, author, and
   language checks, each rejection carrying an explained reason.
2. **Given** an accepted release, **When** the admin grabs it, **Then** the download is dispatched
   through the same acquisition pipeline as e-books, keyed to the audiobook target.
3. **Given** the same work also has an e-book target, **When** the admin acts on either target,
   **Then** the other target's state is unaffected — each is independently searchable and
   gradable.

### User Story 2 - A multi-track audiobook imports atomically (Priority: P1)

An admin who grabs a multi-file audiobook release needs the whole set to import together and
correctly ordered, never as a partial or mixed-up set.

**Why this priority**: A partially-imported or misordered multi-track audiobook is worse than no
import at all — this is the core "no mixed-book imports" guarantee the milestone exists to deliver.

**Independent Test**: Import a multi-track MP3 release and confirm every track lands under one
target in the correct order, then simulate a validation failure and confirm nothing partial is
recorded.

**Acceptance Scenarios**:

1. **Given** a release with correctly ordered, single-work tracks, **When** it imports, **Then**
   all tracks are recorded under one target as one atomic operation.
2. **Given** a release whose files appear to mix two different works, **When** import is attempted,
   **Then** the import is refused rather than silently accepting a mixed set.
3. **Given** a single-file M4B release, **When** it imports, **Then** it succeeds with no
   track-ordering logic getting in the way of the trivial case.

### User Story 3 - Audiobookshelf is told about new imports, reliably (Priority: P2)

An admin relies on their audiobook player picking up newly imported titles without manual
intervention, even if the notification service is briefly unreachable.

**Why this priority**: A silently-missed scan means an imported audiobook is invisible to the
household until someone notices and manually intervenes — this closes that gap without requiring a
re-download.

**Independent Test**: Import an audiobook while the scan target is unreachable, confirm the import
still succeeds, then restore reachability and confirm the scan completes without re-downloading.

**Acceptance Scenarios**:

1. **Given** a freshly imported audiobook target, **When** the next operational cycle runs,
   **Then** a library scan is requested.
2. **Given** the scan request fails, **When** later cycles run, **Then** the same target is retried
   until the scan succeeds, with the already-imported file never touched or re-downloaded.
3. **Given** the scan later succeeds, **When** it completes, **Then** the target is marked scanned
   and is not retried again.

### Edge Cases

- A release whose container is outside the accepted formats is rejected with a named reason, not a
  generic unknown-format failure.
- A track set larger than the bounded limit is refused outright before any per-track inspection
  begins.
- When per-file technical inspection is unavailable or times out, import proceeds using
  filename-based evidence rather than failing.
- A held audiobook import leaves its downloaded payload on disk, recoverable through the existing
  retry path, with no separate deletion feature.
- A legacy audiobook library file migrated from a second instance of the same protocol classifies
  to the audiobook media kind, not the e-book kind.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to monitor an audiobook target for a work independently of that
  work's e-book target.
- **FR-002**: System MUST search and score audiobook releases in M4B and MP3 formats, rejecting
  unsupported or contradictory format evidence with a named reason.
- **FR-003**: A candidate release's title, author, language, protocol, collection, and size
  evidence MUST be validated before acceptance, using explained rejection reasons.
- **FR-004**: System MUST NOT perform automatic, unattended audiobook release selection — every
  grab remains an explicit admin action.
- **FR-005**: A multi-track audiobook MUST import as a single atomic operation: either every track
  is recorded, or none are; tracks that appear to belong to different works MUST be refused rather
  than accepted together.
- **FR-006**: System MUST reject a track set exceeding a bounded track-count limit, and MUST bound
  the total time spent inspecting a track set so one import cannot block the pipeline
  indefinitely.
- **FR-007**: When per-track technical inspection is unavailable, System MUST degrade to
  filename-based evidence rather than failing the import outright.
- **FR-008**: After a successful audiobook import, System MUST request an audiobook-server library
  scan and MUST retry the request until it succeeds, without ever re-downloading the already
  imported file.
- **FR-009**: System MUST report reachability health for the configured audiobook server.
- **FR-010**: Retry, blocklist-clearing, pause/resume, and "Find a better match" replace MUST work
  for audiobook targets exactly as they already do for e-book targets.
- **FR-011**: A held audiobook import MUST leave its downloaded payload untouched on disk,
  recoverable via the existing retry path; no separate deletion capability is required.
- **FR-012**: Admin MUST be able to manually search for and grab an audiobook release from the same
  work detail surface used for e-books, operating independently of the e-book panel.
- **FR-013**: System MUST classify migration-adopted candidates by their actual file format into
  the correct media kind (e-book or audiobook), never defaulting every candidate to one kind.
- **FR-014**: A work MUST be able to be Available as e-book, audiobook, both, or neither,
  independently, with acting on one never changing the other's state.

### Key Entities *(include if feature involves data)*

- **Audiobook release**: a scored candidate download with parsed format, language, narrator,
  and abridgement evidence.
- **Audiobook target**: a monitored/available/held/unmonitored audiobook tracking record for a
  work, independent of that work's e-book target.
- **Audiobook file/track**: an imported audio file carrying narrator, duration, track, disc, and
  chapter metadata.
- **Audiobook-server scan state**: a durable, retried-until-success flag recording whether the
  audiobook server has been told about a target's imported content.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A single-file audiobook import succeeds with no ordering ambiguity.
- **SC-002**: A multi-track audiobook import lands as one target with every track correctly
  ordered, or none of its tracks are recorded.
- **SC-003**: An audiobook-server outage during scan request never loses or requires re-downloading
  an already-imported file; the scan completes automatically once the server recovers.
- **SC-004**: An operator can independently request, search, and monitor e-book and audiobook
  versions of the same work with no cross-effect on the other's state.
- **SC-005**: Migrating a legacy audiobook library classifies every recognized file to the correct
  media kind with no file re-downloaded or moved.

## Assumptions

- This is one slice (B7) of the umbrella books/Readarr-replacement track (see
  `053-books-readarr-replacement`); it builds on the e-book acquisition, monitoring/policy, and
  migration machinery shipped in prior slices.
- Accepted audiobook containers are limited to M4B (preferred) and MP3; this is an explicit
  implementation judgment made in the absence of a governing contract list, not an exhaustive
  format survey — other containers are recognized-but-rejected rather than silently unrecognized,
  and the list can widen later if a real release sample justifies it.
- Automatic release selection stays out of scope for audiobooks for the same reason it stays out of
  scope for e-books: no measured precision threshold exists to gate an automatic match.
- No general audiobook-target deletion feature is introduced, consistent with the prior monitoring
  slice's decision not to build one for e-books either.
- No multi-instance migration-source configuration is built; migrating both a legacy e-book and a
  legacy audiobook instance is documented as two sequential runs of the existing one-instance
  cutover procedure, repointing settings between runs, rather than adding concurrent per-instance
  configuration.
- No audiobook language-preference picker is added; the audiobook release scorer works from the
  release's own parsed language tag with no additional control needed.
- Narrator information is informational display only; it is never used as an acceptance gate for a
  release, since no reliable precision measurement exists for narrator-name evidence in release
  names.
