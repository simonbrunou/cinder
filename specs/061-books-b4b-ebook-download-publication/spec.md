# Feature Specification: E-book Download, Validation, and Publication

**Feature Branch**: `061-books-b4b-ebook-download-publication`

**Created**: 2026-08-31

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-31-books-b4b-ebook-download-and-publication.md`)

This is the second of three slices of the [053 books/Readarr-replacement umbrella](../053-books-readarr-replacement/spec.md)'s B4 milestone. Given one chosen release from the [B4a search/scoring layer](../060-books-b4a-ebook-search-scoring/spec.md), this slice durably submits it, tracks it, validates what arrives, publishes it under the books root, and records the file — carrying an approved e-book target to Available. It ships with no production caller yet (the manual-search-and-Grab UI is the next slice, B4c) and adds no automatic selection.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A chosen release is durably submitted and tracked through completion (Priority: P1)

Why this priority: a download that is not durably tracked can be silently lost on a crash, double-submitted on a retry, or leave a target permanently stuck with nothing in flight — the core reliability guarantee of the whole acquisition pipeline.

Independent Test: submit one chosen release for a monitored e-book target, kill and restart the process mid-download, and confirm the download resumes tracking without a duplicate submission.

**Acceptance Scenarios**:

1. **Given** a monitored e-book target and one chosen release, **When** the release is submitted, **Then** the submission is durably reserved before any external side effect, so a crash immediately after submission is recoverable rather than lost.
2. **Given** a download is in flight for a target, **When** a repeated poll tick runs, **Then** no second download can be started for the same target (one in-flight download per target is enforced).
3. **Given** a target stops being monitored while a submission is in flight (e.g., an operator cancels or the underlying request is deleted), **When** the pipeline notices, **Then** the reserved submission is cleaned up instead of being submitted.

---

### User Story 2 - Downloaded content is validated before it is treated as a real book (Priority: P1)

Why this priority: an unvalidated download could publish a scan, a mismatched file, a disguised executable, or an unhandled archive as if it were the requested book — validation is what keeps the library trustworthy.

Independent Test: feed a completed download containing no acceptable e-book file, an ambiguous multi-file payload, and an archive, and confirm each is refused with its own specific, distinct reason.

**Acceptance Scenarios**:

1. **Given** a completed download with no file carrying an accepted e-book extension, **When** it is validated, **Then** it is refused with a reason naming the absence of any accepted book file.
2. **Given** a completed download with two or more accepted files that do not represent the same book, **When** it is validated, **Then** it is refused as ambiguous, while a multi-format release of the same book (e.g., matching `.epub` and `.mobi` of the same title) is not treated as ambiguous.
3. **Given** a completed download whose payload is a `.rar`, `.zip`, `.7z`, or split archive, **When** it is validated, **Then** it is refused as an unsupported archive rather than expanded, and an `.epub` file itself (a zip container) is imported as an opaque file, never expanded.

---

### User Story 3 - A validated file is published under the books root and the target reaches Available (Priority: P1)

Why this priority: this is the terminal, user-visible outcome of the whole B4 milestone — an approved e-book that cannot reach Available has not delivered the feature regardless of how well search and validation work.

Independent Test: run a validated e-book payload through publication and confirm it lands under the books root named by author/title with its original filename preserved, is recorded against the target, and the target's status becomes Available.

**Acceptance Scenarios**:

1. **Given** a validated e-book file, **When** it is published, **Then** it is placed under the books root in an author/title folder derived from catalog metadata, with the original release filename preserved unchanged.
2. **Given** publication completes, **When** the target is inspected, **Then** the published file is recorded against the target and the target's status is Available.
3. **Given** a crash occurs between placement and commit, **When** the pipeline recovers, **Then** the pending placement resolves through the existing crash-recovery mechanism rather than being lost or double-placed.

### Edge Cases

- A permanently rejected submission, or a download client reporting a dead/missing download, holds the target with an exact, operator-visible reason rather than leaving it monitored with nothing in flight and nothing looking at it again.
- A single transient "not found" response from a download client (as opposed to a confirmed rejection) is treated against a shared retry budget before it is allowed to hold or delete a target, so a routine blip cannot destroy a live download.
- An e-book file whose payload turns out to be a renamed non-EPUB archive (passing only a superficial container check) is refused, not published, once its actual internal structure is checked.
- A book target of a media kind other than e-book is refused outright by this slice, since nothing downstream of it is audiobook-aware yet.
- An operator-disabled stall-reaper switch, a stale reap clock, insufficient free disk space, and a missing content-policy detail are each handled explicitly rather than silently mishandling the target.
- A held target and a newly available book are surfaced to operator-facing status displays and notifications, not silently dropped from either.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST track in-flight e-book downloads on a separate record from the target itself, since the target's status vocabulary has no "downloading" state; the target remains "monitored" for the whole download.
- **FR-002**: System MUST enforce exactly one in-flight download per e-book target, so a repeated poll tick cannot start a second download for the same target.
- **FR-003**: System MUST durably reserve a submission before performing any external side effect, and MUST recover a reservation left incomplete by a crash rather than losing or duplicating it.
- **FR-004**: System MUST clean up a reserved-but-not-yet-submitted download if its target stops being monitored before submission completes.
- **FR-005**: System MUST poll in-flight downloads in three passes — crash-recovery reconciliation, status advancement, and import of completed downloads — with no automatic search pass in this slice.
- **FR-006**: System MUST refuse to validate a completed download as a book when it contains no file with an accepted e-book extension, returning a specific reason distinct from other refusal reasons.
- **FR-007**: System MUST refuse a completed download containing two or more accepted files that are not the same book, while treating same-book multi-format files (matching normalized names, different accepted formats) as one book, not ambiguous.
- **FR-008**: System MUST refuse archive payloads (`.rar`, `.zip`, `.7z`, split volumes) without expanding them, and MUST import `.epub` files as opaque files without expansion.
- **FR-009**: System MUST reject any file under an unrelated or unsafe path (symlink escape, path traversal, non-regular file, or extension-spoofed executable) rather than publishing it.
- **FR-010**: System MUST validate that an `.epub` payload's actual internal container structure matches the format, not merely its outer archive signature, before accepting it.
- **FR-011**: System MUST publish a validated e-book under the books root in an author/title folder derived from catalog metadata, preserving the original release filename unchanged.
- **FR-012**: System MUST record the published file against its target, leaving an explicit unresolved edition link when the release name cannot determine which edition was obtained, rather than guessing an edition.
- **FR-013**: System MUST recover a placement left incomplete by a crash between placement and commit, without losing or double-placing the file.
- **FR-014**: System MUST hold a target with an exact, operator-visible reason whenever a submission is permanently rejected, a download is confirmed dead, or a downloaded payload is refused — never leaving a target monitored with nothing in flight and no path to be reconsidered.
- **FR-015**: System MUST refuse to process a target of any media kind other than e-book in this slice, returning an explicit unsupported-media-kind result.
- **FR-016**: System MUST honor operator-level acquisition controls (an operator switch disabling stall detection, available free disk space) and MUST NOT reap a healthy in-flight download after a monitoring outage.
- **FR-017**: System MUST surface a held target's exact reason and an available target's status to the operator-facing status display and notification channel used for other book state changes.
- **FR-018**: System MUST NOT introduce any automatic release-selection function or automatic search sweep in this slice.

### Key Entities

- **In-flight download record**: tracks a submitted download's protocol, identifiers, content location, progress, and import attempts, separate from the target's own status.
- **Published book file**: the validated e-book file recorded against its target after publication, with an optional link to a specific edition when determinable.
- **Held target reason**: the exact, operator-visible cause recorded whenever a target is parked instead of advancing.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A monitored e-book target with a chosen release reaches Available end-to-end — submitted, tracked, validated, published, and recorded — without manual database intervention.
- **SC-002**: Every refusal reason (wrong/absent format, ambiguous payload, unsupported archive, unsafe path) is distinct and traceable to its specific cause, never a generic failure.
- **SC-003**: Repeated poll ticks against the same target never produce a duplicate download submission or a duplicate import of the same content.
- **SC-004**: A process crash at any point between submission and commit leaves the system recoverable to a consistent state on restart, with no target stuck indefinitely.
- **SC-005**: No target that fails partway through this pipeline is left in a state indistinguishable from "not yet started" — every give-up path results in an exact, visible hold reason.

## Assumptions

- This is slice two of three (B4a/B4b/B4c) of the B4 milestone within the [053 books/Readarr-replacement umbrella](../053-books-readarr-replacement/spec.md); the operator search/Grab UI, automatic release selection, audiobooks, adoption/migration, and wanted/monitoring sweeps are explicitly out of scope and covered by other slices.
- Automatic selection remains gated: no automatic release-selection function exists, and the poller runs no search pass — the same settled no-automatic-selection decision carried from the prior slice, preserved unchanged.
- This slice is `:ebook`-only; an audiobook target is explicitly refused rather than silently mishandled, pending a later audiobook milestone.
- Archive extraction (`.rar`/`.zip` expansion) is deliberately deferred rather than implemented in this slice; unhandled archive payloads fail closed with an exact reason instead.
