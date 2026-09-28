# Feature Specification: Move-on-import (Usenet-scoped download cleanup)

**Feature Branch**: `021-move-on-import`

**Created**: 2026-06-25

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-25-move-on-import-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Stop completed Usenet downloads from lingering (Priority: P1)

An operator running Cinder with downloads and library on the same mergerfs pool wants imported
files removed from the downloads folder once they are safely in the library, so downloads don't
accumulate clutter that has to be cleaned by hand.

**Why this priority**: This is the entire feature — without it, every completed Usenet grab stays
in the downloads folder forever even though the library already has a hardlinked copy.

**Independent Test**: Enable the "remove source after import" option, complete a Usenet grab, and
confirm the download is removed from the download client after the item reaches its available
state while the library file remains intact.

**Acceptance Scenarios**:

1. **Given** the "remove source after import" option is enabled and a movie's download protocol
   is Usenet, **When** the movie transitions to available after import, **Then** the source
   download is removed from the download client, including its downloaded files.
2. **Given** the "remove source after import" option is enabled and a TV grab's protocol is
   Usenet, **When** the grab finishes importing, **Then** the source download is removed the same
   way.
3. **Given** the "remove source after import" option is disabled (the default), **When** any
   import completes, **Then** the download is left untouched and behavior matches pre-feature
   Cinder exactly.

---

### User Story 2 - Never touch seeding torrents (Priority: P2)

An operator who mixes Usenet and torrent downloads wants torrents excluded from automatic removal
so their seeding ratio is never disrupted by an import-time cleanup.

**Why this priority**: Auto-removing a torrent would break seeding, an unacceptable regression for
torrent users; the feature must fail toward inaction on anything but a confirmed Usenet item.

**Independent Test**: Enable the "remove source after import" option, complete a torrent-protocol
import, and confirm no removal call is made to the download client.

**Acceptance Scenarios**:

1. **Given** the "remove source after import" option is enabled and an item's download protocol
   is torrent, **When** the item finishes importing, **Then** no remove call is issued and the
   torrent keeps seeding.
2. **Given** the "remove source after import" option is enabled and an item's download protocol
   is unknown or missing, **When** the item finishes importing, **Then** no remove call is issued
   (fails safe rather than guessing).

---

### User Story 3 - Cleanup never risks a stranded or corrupted import (Priority: P3)

An operator wants the cleanup step to be strictly best-effort, so a failure to delete a completed
download can never turn into a data-loss incident or a stuck import.

**Why this priority**: The whole design exists to avoid the data-loss and re-import hazards a naive
move-during-import would introduce, so the safety property (remove only after a durable DB commit)
is as important as the cleanup itself.

**Independent Test**: Force the download-client remove call to error or raise after a successful
import and confirm the item's status is untouched and the failure is only logged.

**Acceptance Scenarios**:

1. **Given** an import has already committed the item as available, **When** the subsequent
   best-effort remove call returns an error, **Then** the item's status stays available, no error
   is surfaced to the user, and the failure is logged.
2. **Given** the best-effort remove call raises instead of returning an error, **When** it is
   invoked, **Then** the exception is swallowed and does not interrupt the poller.
3. **Given** a TV season pack import where only some episodes matched, **When** the "remove source
   after import" option is enabled, **Then** the download is still removed for the matched
   episodes (the unmatched episode re-searches and its bytes are simply re-fetched later; no
   tracked-state loss).

---

### Edge Cases

- A download the client has already dropped on completion returns "not found," which is treated as
  a successful no-op removal.
- A row with a blank or missing download id and the toggle on results in no removal call rather
  than an invalid call to the client.
- A cross-filesystem import that cannot hardlink is parked before this step is ever reached, so the
  toggle never fires on a failed import.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to enable or disable a "remove source after import" option from
  Settings, defaulting to disabled so existing installs see no behavior change until opted in.
- **FR-002**: System MUST remove the source download only after the corresponding movie or episode
  has been durably recorded as imported/available — never before or during the import write.
- **FR-003**: System MUST restrict automatic removal to Usenet-protocol downloads; torrent
  downloads MUST never be automatically removed.
- **FR-004**: System MUST treat an unknown, missing, or nil download protocol as "do not remove"
  rather than guessing.
- **FR-005**: System MUST treat any failure or exception raised while removing a download as
  best-effort: the failure is logged and does not change the item's status, retry behavior, or
  trigger a re-import.
- **FR-006**: System MUST apply this behavior symmetrically to both the movie and TV/episode import
  pipelines.
- **FR-007**: System MUST still remove the download for a partially-matched TV season pack (some
  episodes imported, others unmatched), rather than leaving completed-episode clutter behind
  because one episode didn't match.
- **FR-008**: The setting MUST be surfaced only in the main Settings UI, not in the first-run setup
  wizard, since a first-run operator has not yet validated their hardlink topology.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the option enabled, a completed Usenet import leaves no trace in the download
  client's download list while the library file remains playable, without any manual cleanup step.
- **SC-002**: With the option enabled, torrent downloads observed after import continue seeding
  with zero automatic removals.
- **SC-003**: With the option left at its default, import behavior (file placement, retry counts,
  timing) is indistinguishable from a build without the feature.
- **SC-004**: A forced removal failure never changes an item's visible status or produces a
  user-facing error, in 100% of exercised failure-injection cases.

## Assumptions

- Cross-filesystem import (copying into the library when a hardlink is impossible) is explicitly
  out of scope for this feature and was deferred to a later fast-follow (delivered separately, see
  026-copy-move-import-fallback).
- A blunt "remove every completed download regardless of protocol" design was considered and
  rejected because it would break torrent seeding.
- No per-library or per-quality removal policy is offered; the toggle is a single global boolean.
- No environment-variable override exists for the toggle; it is a database-backed setting only.
