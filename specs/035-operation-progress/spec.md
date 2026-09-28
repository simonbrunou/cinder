# Feature Specification: Operation Progress

**Feature Branch**: `035-operation-progress`

**Created**: 2026-07-10

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-10-operation-progress-design.md`), plan.md (originally `docs/superpowers/plans/2026-07-10-operation-progress.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See live download progress (Priority: P1)

**Why this priority**: The design replaces vague in-flight download badges with a visible
percentage, current speed, and ETA — the core value of this feature.

**Independent Test**: Start a movie or TV episode download and watch its badge on the movie
detail, Activity, Library, Dashboard, or My Requests page update with a live percentage.

**Acceptance Scenarios**:

1. **Given** a movie or TV grab actively downloading, **When** the download client reports a new
   percentage, speed, and ETA, **Then** the badge shows a progress indicator with the percentage,
   formatted rate, and time remaining.
2. **Given** a download client that cannot supply speed or ETA for a given download, **When** the
   badge renders, **Then** only the unavailable value is omitted — the system never shows an
   invented zero or fabricated ETA.
3. **Given** an active download, **When** its measurement has not changed since the last check,
   **Then** the displayed badge does not flicker or update with a redundant refresh.

### User Story 2 - See named search and import phases (Priority: P2)

**Why this priority**: Searching and importing are not "downloading," so the badge shows a named,
indeterminate phase instead of a download percentage.

**Independent Test**: Trigger a search for a movie or episode and observe the badge names the
searching phase; observe the badge again once the file is downloaded and awaiting import.

**Acceptance Scenarios**:

1. **Given** a movie or episode search in progress, **When** the badge renders, **Then** it shows
   a labelled, indeterminate "searching" indicator rather than a download percentage.
2. **Given** a movie at the downloaded state or a TV grab whose file has landed, **When** the
   badge renders, **Then** it shows a labelled, indeterminate "importing" indicator because the
   item is awaiting import, not finished.

### User Story 3 - Progress stays accurate across the pipeline (Priority: P3)

**Why this priority**: Entering a new download or leaving an active state clears prior progress,
speed, and ETA so a new operation never displays a prior operation's rate or ETA as live.

**Independent Test**: Complete, cancel, or retry a download and confirm the badge no longer shows
the previous operation's percentage, speed, or ETA.

**Acceptance Scenarios**:

1. **Given** a movie entering a new download or upgrade, **When** the operation begins, **Then**
   any previously stored progress, speed, and ETA are cleared before new measurements appear.
2. **Given** a download that completes, is cancelled, fails, or is retried, **When** the badge
   next renders, **Then** it does not display the prior operation's stale percentage, speed, or
   ETA.

### Edge Cases

- A download client (e.g. SABnzbd) that reports only queue-wide speed must never present that
  value as the speed of one specific TV grab.
- A malformed or invalid value from a client (e.g. an out-of-range ETA sentinel) becomes absent
  rather than being shown as-is.
- A completion, cancellation, or deletion racing a slow client response must not resurrect a
  stale measurement.
- Request, approval, episode, health, and monitoring badges are unrelated to a running download
  and must keep their current appearance unchanged.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST show a determinate progress indicator with percentage, formatted
  download rate, and estimated time remaining for a movie or TV grab actively downloading or
  actively upgrading.
- **FR-002**: The system MUST show a labelled, indeterminate "searching" indicator for a movie or
  episode currently being searched.
- **FR-003**: The system MUST show a labelled, indeterminate "importing" indicator for a movie at
  the downloaded state or a TV grab awaiting import.
- **FR-004**: The system MUST omit only the specific value (speed or ETA) a download client cannot
  supply, and MUST NOT display a fabricated zero or invented ETA in its place.
- **FR-005**: The system MUST NOT present a download client's queue-wide speed as the speed of an
  individual item when the client cannot report per-item speed.
- **FR-006**: The system MUST clear previously stored progress, speed, and ETA whenever a movie or
  TV grab enters a new downloading or upgrading run.
- **FR-007**: The system MUST clear stored progress, speed, and ETA on completion, cancellation,
  abort, retry, error, or removal of the corresponding download or grab.
- **FR-008**: The system MUST update operation progress on every movie detail, Activity, Library,
  Dashboard, and My Requests location where the download badge already appears, and on the TV
  in-flight grab badge on Activity.
- **FR-009**: The system MUST leave request, approval, episode, health, and monitoring badges
  unchanged, since they describe a different state than a running download.
- **FR-010**: The system MUST refresh progress, speed, and ETA at the same interval the existing
  movie and TV pollers already use, without adding browser-side polling.
- **FR-011**: Users MUST see progress update automatically on every connected view without
  manually refreshing the page.

## Key Entities *(include if feature involves data)*

- **Movie download operation**: the in-flight download or upgrade state of a movie, including its
  current progress fraction, rate, and time remaining.
- **TV grab**: the in-flight download state of a single TV episode acquisition, including its
  current progress fraction, rate (when available), and time remaining.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user viewing any badge location for an actively downloading item sees a
  percentage, and sees rate and time-remaining whenever the download client supplies them.
- **SC-002**: A user viewing a searching or import-pending item sees a named phase indicator
  instead of an ambiguous "downloading" label.
- **SC-003**: No user-visible badge ever shows a speed or ETA value left over from a prior,
  already-finished, cancelled, or failed operation.
- **SC-004**: Progress updates reach every connected view without the user taking any manual
  refresh action, on the same cadence as the existing polling interval.

## Assumptions

- No browser polling, new JavaScript, or new UI dependency is introduced; the existing five-second
  poll and broadcast mechanism is the only update path.
- An upgrade has no durable post-download "awaiting import" state; the design intentionally shows
  determinate progress only while the client supplies it, without inventing an interim state.
- Request, approval, episode, health, and monitoring badges are explicitly out of scope for this
  change.
