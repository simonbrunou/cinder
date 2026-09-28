# Feature Specification: Books Monitoring, Wanted State, Author Policies, and Operations

**Feature Branch**: `063-books-b5-monitoring-operations`

**Created**: 2026-09-01

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-09-01-books-b5-monitoring-and-operations.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Retry, blocklist, and replace a problem release (Priority: P1)

An admin whose e-book target failed acquisition needs to recover it without re-triggering the same
failed release, and needs to swap an already-downloaded file for a better one without leaving
duplicate copies behind.

**Why this priority**: Without this, a held target is a dead end and an available-but-imperfect
target can never be improved — both interventions the prior milestone (B4c) explicitly named as
left for this one to pick up.

**Independent Test**: Hold a target with a specific bad release, retry it, confirm the same release
is skipped on the next search; separately, replace an available target's file and confirm exactly
one file remains.

**Acceptance Scenarios**:

1. **Given** a book target is held with a known release name, **When** the admin clicks Retry,
   **Then** the target returns to monitored and the failed release stays blocklisted so a
   subsequent search does not re-offer it.
2. **Given** an available target with an existing file, **When** the admin finds and confirms a
   better release through "Find a better match," **Then** the target ends with exactly one current
   file and the old file is no longer reachable.
3. **Given** a replace import is replayed after a crash (the same import re-runs), **When** the
   second attempt completes, **Then** no additional file is reported as superseded and nothing is
   deleted from disk.

### User Story 2 - Bounded per-author monitoring policies (Priority: P2)

An admin wants to opt a favorite author into automatically monitoring their future or entire
bibliography, without triggering an unbounded, unreviewed flood of new targets.

**Why this priority**: This is the only bulk-monitoring path in the product; it must be safe by
construction before it can be offered at all.

**Independent Test**: Set an author's policy to "all works," preview the eligible count, confirm,
and verify exactly that count of new targets was created and nothing was downloaded.

**Acceptance Scenarios**:

1. **Given** an author with no policy set, **When** the admin selects "Future works" or "All
   works," **Then** a preview shows the exact count of eligible not-yet-monitored works before any
   write happens.
2. **Given** a held preview list, **When** the admin confirms, **Then** exactly that many new
   targets are created as monitored and idle, with zero downloads triggered automatically.
3. **Given** an unattended bibliography refresh runs later, **When** a provider is unreachable for
   one author, **Then** every existing target's monitoring state is unchanged and other authors'
   refreshes are unaffected.

### User Story 3 - Wanted/Held visibility, pause/resume, and health (Priority: P3)

An admin browsing the library wants to see and act on targets waiting for acquisition or stuck in a
held state, and wants operational confidence that the metadata provider is reachable.

**Why this priority**: Visibility and light inline control complete the operator surface but do not
block the acquisition or policy flows above.

**Independent Test**: Filter the books list to "Wanted," pause a target with no active download,
confirm it disappears from the wanted view, then resume it.

**Acceptance Scenarios**:

1. **Given** a monitored target with no active download, **When** the admin pauses it, **Then** it
   becomes unmonitored and drops off the Wanted filter; resuming reverses this.
2. **Given** a target has an in-progress download, **When** the admin attempts to pause it,
   **Then** the action is refused rather than silently discarding the in-flight download.
3. **Given** a target enters a held state, **When** the hold is recorded, **Then** the household is
   notified exactly once, with no duplicate notification for the same unresolved hold.

### Edge Cases

- A held target whose failure reason is deterministic/permanent (e.g., an unsupported archive or a
  rejected submission) must never be picked up by the unattended retry sweep.
- An author bibliography larger than the resolution cap must be worked through gradually across
  multiple previews/refresh ticks rather than dropping the remainder silently.
- A candidate that cannot be identified unambiguously must be reported as an explicit
  "could not be identified" count, never auto-included as monitored.
- A retry racing a concurrent import must fail cleanly rather than corrupt state or crash.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Admin MUST be able to retry a held e-book target, returning it to a searchable
  monitored state.
- **FR-002**: System MUST record the specific release title a target was held against so it can be
  excluded from future manual searches until cleared.
- **FR-003**: Admin MUST be able to clear a target's blocklist independently of retrying it.
- **FR-004**: Admin MUST be able to replace an available target's current file with a better
  release found via manual search; after a successful replace the target MUST have exactly one
  current file, with no duplicate rows even if the replace import is replayed after a crash.
- **FR-005**: System MUST refuse to pause a target that has an in-progress download, rather than
  risk silently losing an already-downloaded file.
- **FR-006**: Admin MUST be able to pause a monitored target and resume a paused target.
- **FR-007**: System MUST support three author monitoring policies — selected works (the default,
  requiring no explicit setting), future works only, and all works.
- **FR-008**: System MUST show a preview of exactly how many not-yet-monitored works an author
  policy change would add, and separately report a count of candidates that could not be
  unambiguously identified, before any confirmation is possible.
- **FR-009**: Confirming an author policy MUST create targets only for the exact previewed eligible
  set, never a re-derived or expanded set.
- **FR-010**: System MUST bound the number of new candidate resolutions performed per preview or
  refresh cycle to a fixed cap, reporting any remainder rather than silently dropping it.
- **FR-011**: An unattended bibliography refresh MUST run on a bounded schedule, MUST only ever add
  new monitoring, and MUST NOT delete or demote an existing work, target, or file, or broaden
  monitoring beyond newly-identified, unambiguous candidates.
- **FR-012**: System MUST provide a bounded, unattended retry sweep for held targets whose failure
  is marked transient, and MUST NOT retry a target held for a permanent or deterministic reason.
- **FR-013**: A target retried by the unattended sweep MUST keep its previously blocked release on
  the blocklist so the next search does not re-offer it.
- **FR-014**: The books library view MUST support filtering to Wanted (monitored) and Held targets.
- **FR-015**: System MUST report reachability health for the metadata provider, in addition to
  existing book-storage-location health.
- **FR-016**: A held book target MUST notify the household exactly once per hold occurrence, with
  no duplicate notification while the hold remains unresolved.
- **FR-017**: System MUST NOT perform any automatic, unattended release search or selection for
  book targets — every acquisition action remains an explicit admin decision.

### Key Entities *(include if feature involves data)*

- **Book target**: a monitored/available/held/unmonitored work-and-media-kind pairing being tracked
  for acquisition.
- **Blocked release**: a release title excluded from future consideration for a specific target
  after a proven-bad attempt.
- **Author monitoring policy**: a bulk-monitoring rule (future works or all works) attached to a
  credited author, with an associated acquisition profile.
- **Bibliography candidate**: a work from an author's provider-reported catalogue considered for
  automatic monitoring, resolved and classified as eligible or unresolved/ambiguous.
- **Metadata provider health check**: a reachability status for each configured metadata source.
- **Hold notification event**: a one-time household alert emitted when a target enters a held
  state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can recover a held e-book target to a re-searchable state in a single
  action, and the previously-failed release is never re-offered until explicitly cleared.
- **SC-002**: Replacing an available target's file leaves exactly one current file, verified across
  both a clean run and a simulated crash-and-replay of the same import.
- **SC-003**: Confirming a bulk author policy against a large bibliography (e.g., a 200-work
  author) creates exactly the previewed count of new targets and triggers zero automatic downloads.
- **SC-004**: A metadata provider outage during an unattended bibliography refresh leaves every
  existing target's monitoring state byte-identical afterward.
- **SC-005**: An operator is notified within one operational cycle of a target entering a held
  state, and is never notified twice for the same unresolved hold.

## Assumptions

- This is one slice (B5) of the umbrella books/Readarr-replacement track (see
  `053-books-readarr-replacement`); it builds on the request/approval and e-book acquisition
  vertical shipped in prior slices and hands off remaining work (audiobooks, migration cutover,
  hardening) to later slices.
- Automatic/unattended release *selection* stays explicitly out of scope for this slice and the
  whole milestone that follows it — no corpus-precision threshold for automatic release matching
  was defined by the governing parity contract, so none is invented here; "Find a better match"
  remains manual-only by design, not as an interim limitation.
- Author monitoring policies create only e-book targets in this slice; extending a policy to also
  arm an audiobook target is explicitly deferred until audiobook acquisition exists downstream.
- No general author browse/search page is introduced; the policy control lives on the existing
  work detail page.
- No book-target deletion feature is introduced; pausing only changes monitoring status and never
  removes a target, work, or imported file.
- No publisher-specific (e.g., Calibre/Audiobookshelf) health check is added in this slice — the
  book/audiobook filesystem library roots already had health coverage from an earlier slice, and no
  non-filesystem publisher adapter exists yet to diverge from it.
