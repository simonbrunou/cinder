# Feature Specification: Books and Audiobooks — Readarr Replacement

**Feature Branch**: `053-books-readarr-replacement`

**Created**: 2026-08-20

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-20-readarr-replacement-roadmap.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Discover and request a book (Priority: P1)

A household member searches for a book by title or author, views its editions, series position,
and language, and requests it as an e-book or an audiobook. This is the same calm request flow
Cinder already gives movies and TV, extended to a third media kind without exposing indexer,
format, or scoring jargon to the requester.

**Why this priority**: Nothing else in the track has value until a household member can express
"I want this book."

**Independent Test**: Search Discover for a book with a Books filter, open its work detail page,
choose e-book or audiobook, and submit a request without seeing any pending managed target.

**Acceptance Scenarios**:

1. **Given** a household member browsing Discover, **When** they filter to Books and open a work,
   **Then** they see cover, author, year, editions, series position, and current
   request/available state.
2. **Given** a work with both e-book and audiobook targets possible, **When** the requester picks
   one, **Then** the request is recorded against that specific work and media kind, independent of
   any request for the other kind.
3. **Given** a normal user, **When** they submit a request, **Then** no managed target is created
   until an admin approves it.

### User Story 2 - Admin approves and the household never floods the download client (Priority: P1)

An admin reviews pending book/audiobook requests, approves or denies with the existing quota,
audit, and notification behavior, and separately opts specific authors into ongoing monitoring so
future or backlisted works are pursued automatically without per-title requests.

**Why this priority**: Approval and monitoring are the gate between "wanted" and "the system may
act," and are required before any acquisition automation is safe to enable.

**Independent Test**: Approve a pending book request as admin, and separately mark an author
monitored; confirm resulting monitored/wanted state without any request that skipped approval.

**Acceptance Scenarios**:

1. **Given** a pending book or audiobook request, **When** an admin approves it, **Then** a
   managed target moves to a monitored state and appears in wanted/missing tracking.
2. **Given** an admin denies or reopens a request, **When** the action is taken, **Then** the
   target and audit trail reflect it and no acquisition starts.
3. **Given** monitoring is enabled for an author, **When** a new or existing work by that author
   is evaluated, **Then** it is tracked for acquisition according to the household's stated
   policy, not fetched unconditionally.

### User Story 3 - Unattended e-book search, download, validation, and publication (Priority: P1)

For a monitored, approved e-book target, an admin opens manual release search on the work's
pipeline page and selects a release; the system then downloads, validates the file for safety,
and publishes it into the household's e-book library without further manual steps, or parks it
with an exact reason if anything is wrong.

**Why this priority**: This is the Book MVP gate — the first complete request-to-available path
and the reason the track exists.

**Independent Test**: Approve a labeled corpus title, run manual search, grab a release, and
observe it validated, imported, and shown Available, or parked with a legible reason if the
release is wrong.

**Acceptance Scenarios**:

1. **Given** an approved, monitored e-book target, **When** an admin searches and selects a
   release, **Then** the release is downloaded, validated (format, structure, no unsafe archive
   content), and published into the library, and the target shows Available.
2. **Given** a release with wrong title, author, language, format, or ambiguous edition, **When**
   it is evaluated, **Then** it is rejected with a specific, deterministic reason rather than
   imported.
3. **Given** an in-flight download or import, **When** the poller ticks again before completion,
   **Then** no duplicate grab or duplicate import occurs.

### User Story 4 - Monitoring, wanted tracking, and operator recovery (Priority: P2)

An admin can see which monitored works are wanted, missing, downloading, or parked with a reason,
pause or resume monitoring, and adjust author-level policy, so unattended operation stays legible
and controllable over time rather than a black box.

**Why this priority**: Sustained unattended operation without visible state and recovery controls
is not trustworthy enough to replace Readarr.

**Independent Test**: With several monitored works in different states, view the operations
surface and confirm each shows an accurate, exact status and, where applicable, an actionable
parked reason.

**Acceptance Scenarios**:

1. **Given** monitored works in mixed states, **When** an admin views the library/operations
   panel, **Then** wanted, downloading, available, and held states are each shown with an exact
   reason where relevant.
2. **Given** a parked or held target, **When** the underlying cause is resolved, **Then** the
   admin can resume monitoring and the system retries appropriately.
3. **Given** an author is set to monitor future or backlisted works, **When** the policy is
   changed, **Then** only works matching the stated policy are pursued.

### User Story 5 - Migrate the existing Readarr-compatible library and cut over (Priority: P1)

An admin previews the household's existing e-book library (served through a Readarr-compatible
API) inside Cinder, resolves any flagged conflicts or ambiguities explicitly, adopts matched
items without moving or deleting source files, and then disables the legacy service while keeping
it recoverable until the operator is confident.

**Why this priority**: Without a safe migration path, existing files and monitoring history would
be lost or duplicated, blocking real-world cutover — this is the E-book Readarr replacement gate.

**Independent Test**: Run a migration preview against the existing library twice with no changes
in between and confirm it is idempotent, then adopt a batch and confirm source files are
untouched and each adopted file has a durable work/edition/target association.

**Acceptance Scenarios**:

1. **Given** the existing library, **When** an admin runs a preview, **Then** every item is
   classified as ready, needs decision, blocked, or already managed, and nothing is adopted
   silently.
2. **Given** a preview with no changes since the last run, **When** it is repeated, **Then** the
   result and any prior adoption remain unchanged (idempotent, no duplicate downloads).
3. **Given** ambiguous, conflicting, or missing-file rows, **When** the admin reviews them,
   **Then** each requires an explicit decision before adoption proceeds.
4. **Given** adoption has completed and monitoring is enabled in Cinder, **When** the legacy
   service is stopped, **Then** its data remains available for rollback until the admin
   explicitly decommissions it.

### User Story 6 - Audiobook acquisition and library publication (Priority: P2)

A household member requests a work as an audiobook independently of any e-book request for the
same work; an admin searches, grabs, and the system validates single- or multi-track audio
releases and publishes them so the household's audiobook server can see the finished item after a
refresh.

**Why this priority**: Audiobook parity is the second, larger half of full replacement, built on
the e-book pipeline once it is proven.

**Independent Test**: Approve an audiobook target, grab a multi-track release, and confirm it
imports atomically as one item and appears in the audiobook server after refresh.

**Acceptance Scenarios**:

1. **Given** a work already Available as an e-book, **When** it is also requested and approved as
   an audiobook, **Then** the two targets progress independently and either may be Available,
   in-progress, or absent without affecting the other.
2. **Given** a multi-track audiobook release, **When** it is imported, **Then** all tracks are
   imported together as a single item with deterministic ordering, never partially.
3. **Given** a completed audiobook import, **When** the library server is refreshed, **Then** the
   item appears there; if the refresh itself fails, the import is not lost and can be retried
   without re-downloading.

### User Story 7 - Operational hardening and production sign-off (Priority: P2)

Before the household relies on the books track as its sole e-book/audiobook system, an admin can
trust it through documented recovery from common failure modes, visible operational history for
audit, and a supervised dogfood period with the legacy service stopped but recoverable.

**Why this priority**: Closes the Full Replacement gate — proves the track is trustworthy under
real household use, not merely feature-complete.

**Independent Test**: Review the operations log/panel for evidence of tracked failure and
recovery categories, and confirm setup/status documentation accurately describes manual-search,
not automatic, e-book/audiobook acquisition.

**Acceptance Scenarios**:

1. **Given** a scan, download, or provider outage occurs, **When** it resolves, **Then** the
   transition is recorded and visible to an admin without manual log inspection.
2. **Given** a fresh install, **When** first-run setup runs, **Then** it validates book and
   audiobook library paths the same way it validates movie/TV paths.
3. **Given** the documented dogfood window, **When** the legacy service is stopped, **Then** no
   unexplained missing acquisition, wrong import, duplicate grab, unrecoverable parked state, or
   file loss occurs over the observation period.

### Edge Cases

- Co-authors, pen names, translations, multiple editions, series/omnibus works, missing ISBN,
  duplicate titles, and Unicode/punctuation variation in titles or author names.
- A work with an irreconcilable identity that cannot be resolved to one catalog entry.
- Provider (metadata, indexer, download client, or library-server) outages must not corrupt state,
  strip acquisition identity, or silently drop a request.
- A release of unknown or contradictory format fails closed to manual review rather than being
  guessed.
- An unsafe archive (path traversal, symlink escape, executable substitution, unbounded size or
  entry count) must never be extracted into the library.
- A work monitored as both e-book and audiobook must let each media kind progress, park, or
  recover independently of the other.
- Migration rows that are missing files, duplicate paths, ambiguous editions, or multi-format
  conflicts must block for an explicit operator decision, never be guessed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to search and browse books/authors and view work and edition
  detail, including series position, language, and current request/available state.
- **FR-002**: Users MUST be able to request a specific work as an e-book or an audiobook
  independently, with format/language reflected on the request.
- **FR-003**: System MUST require admin approval before a request becomes a managed, acquirable
  target, applying the household's existing quota, audit, and notification rules.
- **FR-004**: System MUST support explicit author-level monitoring policy (including future or
  backlisted works) rather than defaulting to unattended acquisition of everything.
- **FR-005**: System MUST let an admin manually search and select a release for a monitored,
  approved target; automatic/unattended release selection is not offered at any milestone in
  this track (see Assumptions).
- **FR-006**: System MUST search using narrow, configured book/audiobook categories and score
  candidate releases on author/title match, edition/ISBN evidence, language, accepted format,
  size, and provenance, rejecting wrong or ambiguous matches with an exact, deterministic reason.
- **FR-007**: System MUST validate downloaded files/archives before publication (allowed formats,
  no traversal/symlink escape, no executable substitution, bounded size/entries) and MUST never
  import an unsafe or unidentified release.
- **FR-008**: System MUST publish validated e-books into the configured e-book library without
  losing or duplicating files, and MUST record the resulting state atomically.
- **FR-009**: System MUST prevent duplicate grabs or duplicate imports when repeated unattended
  polling passes evaluate the same target.
- **FR-010**: System MUST expose wanted, missing, downloading, available, and held/parked states
  with an exact reason for each monitored target, and MUST let an admin pause/resume monitoring.
- **FR-011**: System MUST let an admin preview migration of the existing Readarr-compatible
  e-book library, classifying every item as ready, needs decision, blocked, or already managed,
  and MUST require explicit operator decisions for ambiguous/conflicting/missing rows rather than
  guessing.
- **FR-012**: System MUST make migration preview and adoption idempotent (a repeated dry run
  changes nothing) and MUST never move, modify, or delete source files during adoption.
- **FR-013**: System MUST allow the legacy service to remain stopped-but-recoverable through a
  cutover/dogfood window, with rollback available by re-enabling it from backup.
- **FR-014**: System MUST support independent e-book and audiobook targets for the same work, so
  each may be requested, monitored, and made Available without affecting the other.
- **FR-015**: System MUST validate and import multi-track audiobook releases atomically, in
  deterministic order, never as a partial or mixed-book import.
- **FR-016**: System MUST request a library-server refresh after publishing an audiobook, and a
  failed refresh MUST NOT require re-downloading to recover.
- **FR-017**: System MUST record operationally significant events (at minimum: scan/provider
  failure and recovery transitions) so an admin can audit recent history without manual log
  inspection.
- **FR-018**: System MUST validate book and audiobook library paths during first-run setup on the
  same terms as movie/TV paths.
- **FR-019**: System MUST keep book/audiobook requester-facing surfaces free of indexer, scoring,
  and import implementation detail.

### Key Entities

- **Author** — a person or credited entity associated with one or more works.
- **Work** — a durable, provider-resolved book identity independent of any specific edition.
- **Edition** — a specific published form of a work (format, ISBN, language, publisher).
- **Book target** — the household's managed pursuit of a work in a specific media kind (e-book or
  audiobook), with its own lifecycle state.
- **Request** — a household member's ask for a work in a given media kind, subject to approval.
- **Release** — a candidate download evaluated and scored against a target before it is grabbed.
- **Migration candidate** — an item discovered in the legacy library during preview, classified
  for adoption.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A household member can go from search to a pending book or audiobook request in
  under a minute, using the same interaction pattern as an existing movie/TV request.
- **SC-002**: For the labeled acceptance corpus, an approved e-book request reaches Available
  through search, download, validation, and publication without manual file handling.
- **SC-003**: Incorrect or ambiguous releases (wrong title/author/language/format/edition) are
  rejected before import in effectively all corpus cases, each with a specific, legible reason.
- **SC-004**: Repeated unattended evaluation of the same target never produces a duplicate grab or
  duplicate import.
- **SC-005**: The existing e-book library can be adopted with every file classified and every
  adopted file durably linked to a work/edition/target, with zero source files moved, modified, or
  deleted.
- **SC-006**: A migration preview run twice with no intervening changes produces the same result
  (idempotent), and a repeated adoption of already-adopted items is a no-op.
- **SC-007**: A work can be independently Available, in-progress, or absent as an e-book and as an
  audiobook at the same time, verified for at least one dual-target work.
- **SC-008**: A multi-track audiobook release is imported as a single atomic item, never partially,
  in every tested multi-track scenario.
- **SC-009**: Across the supervised dogfood window with the legacy service stopped, there is no
  unexplained missing acquisition, wrong import, duplicate grab, unrecoverable parked state, or
  file loss.

## Assumptions

- This umbrella spec summarizes the books/audiobooks track at user-story level only. Fine-grained,
  per-milestone requirements, implementation notes, and the corrections/amendments recorded during
  execution live in the milestone-specific spec directories `specs/054-*` through `specs/066-*`
  (one or more per B0–B8 milestone slice), which are the authoritative detailed specs for this
  track.
- Google Books integration, described in the original roadmap as an optional fallback, was
  dropped before shipping (all evaluation calls returned HTTP 429); Open Library and Hardcover are
  the shipped metadata adapters. This is a scope reduction from the source doc, not an omission
  from this spec.
- Automatic (unattended) release selection is deliberately not offered for either e-books or
  audiobooks at any milestone in this track; the shipped design is manual search/selection
  followed by unattended download, validation, import, and retry. Product documentation was
  corrected during B8 to state this plainly after being found to claim otherwise.
- Two of the roadmap's own Done-when criteria for full replacement are operator-gated, not
  engineering-closable: the two-week elapsed dogfood window, and keeping the legacy service
  recoverable until an explicit, out-of-band decommission decision. This spec's Status reflects
  that the engineering track shipped in v3.0.0; the operator-gated conditions are process, not
  code.
- "Readarr" in this track's migration code refers to the wire protocol/API shape (a
  Readarr-v3-compatible read-only API served by the household's actual Bookshelf deployment), not
  the retired Readarr project itself; no shipped code talks to the original Readarr product.
- Author aliases and local author search, and operator metadata overrides, were repeatedly
  deferred between milestones in the source doc before finally shipping; their final landing
  milestone is authoritative in the corresponding per-milestone spec, not repeated here.
