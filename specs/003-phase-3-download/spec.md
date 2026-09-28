# Feature Specification: Download — Hand Off and Track

**Feature Branch**: `003-phase-3-download`

**Created**: 2026-06-18

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-18-phase-3-download-design.md`), plan.md (originally `docs/superpowers/plans/2026-06-18-phase-3-download.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Hand off a requested movie to the download client (Priority: P1)

Given a requested movie, the system resolves the best available release, submits it to the
configured download client, and records the resulting download so it can be tracked, advancing
the movie's status from requested through searching to downloading (or to a terminal "no match"
state if nothing qualifies).

**Why this priority**: This is the step that turns a selected release into an actual, trackable
download — without it, acquisition's release choice is inert.

**Independent Test**: Can be fully tested by calling the hand-off function on a requested movie
with a mocked release search and download client, and asserting the movie's status and download
identifier update correctly.

**Acceptance Scenarios**:

1. **Given** a requested movie with a known IMDb id, **When** hand-off is run and a release is
   found and accepted by the download client, **Then** the movie's status becomes "downloading"
   and its download identifier is recorded.
2. **Given** a requested movie with no IMDb id yet recorded, **When** hand-off is run, **Then**
   the system resolves the IMDb id from the movie catalog first, persists it, and then proceeds
   with the search.
3. **Given** no release survives selection for a movie, **When** hand-off is run, **Then** the
   movie's status becomes a terminal "no match" state rather than remaining stuck mid-flow.
4. **Given** the download client rejects the chosen release, **When** hand-off is run, **Then**
   the hand-off reports failure and the movie remains at its in-progress ("searching") status
   rather than silently advancing.

---

### User Story 2 - Track an in-progress download to completion (Priority: P1)

A background process periodically checks each downloading movie's status with the download
client and, once a download completes, advances the movie's status to "downloaded" and notifies
any listening UI live.

**Why this priority**: Without this, a movie could be successfully downloading but the app would
never know or reflect that to the user.

**Independent Test**: Can be fully tested by inserting a movie in "downloading" status, running a
single tracking pass against a mocked download client reporting completion, and asserting the
movie's status advances and a live update is broadcast.

**Acceptance Scenarios**:

1. **Given** a movie in "downloading" status whose download has completed at the client, **When**
   a tracking pass runs, **Then** the movie's status becomes "downloaded" and a status-change
   notification is broadcast.
2. **Given** a movie in "downloading" status whose download is still in progress or stalled,
   **When** a tracking pass runs, **Then** the movie's status is left unchanged and is checked
   again on the next pass.
3. **Given** the tracking process crashes and restarts, **When** it resumes, **Then** it
   re-derives the set of active downloads from the database and continues tracking correctly,
   losing no in-flight work.

---

### User Story 3 - See a movie's download status update live (Priority: P2)

A user watching the home page sees a movie's status badge update automatically as it progresses,
without needing to reload the page.

**Why this priority**: This closes the feedback loop for the user but depends on User Stories 1
and 2 already producing status changes to display.

**Independent Test**: Can be fully tested by broadcasting a status-change notification while a
user's session is subscribed and asserting the rendered badge updates without a page reload.

**Acceptance Scenarios**:

1. **Given** a user has the home page open, **When** a movie's status changes in the background,
   **Then** the corresponding badge on the page updates live to reflect the new status.

---

### Edge Cases

- A download client failure during release search or submission leaves the movie at its
  in-progress status rather than a distinct "failed" status; this is a deliberate, scoped
  limitation for a single-household deployment (no automatic retry/backoff yet).
- A movie whose IMDb id cannot be resolved at all is treated the same as "no match" — it can't be
  searched, so it can't match.
- A background tracking pass that finds a download in an error/stalled state at the client leaves
  the movie unchanged rather than introducing a new failure status.
- The download-tracking process does not run during automated tests, so tests never race a live
  background process against test fixtures.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST be able to hand off a requested movie to the configured download client
  by resolving its best available release and submitting it.
- **FR-002**: System MUST resolve and persist a movie's IMDb identifier automatically during
  hand-off if it is not already known.
- **FR-003**: System MUST advance a movie's status through requested → searching → downloading as
  hand-off progresses successfully.
- **FR-004**: System MUST place a movie into a terminal "no match" status when no acceptable
  release exists or when its IMDb identifier cannot be resolved.
- **FR-005**: System MUST leave a movie at its in-progress status (not advance and not silently
  fail) when release search or client submission errors, and MUST report that failure to the
  caller.
- **FR-006**: System MUST periodically check the status of every movie currently downloading
  against the download client.
- **FR-007**: System MUST advance a movie from downloading to downloaded once the download client
  reports completion.
- **FR-008**: System MUST broadcast a live notification whenever a movie's status changes, so
  connected user interfaces can update without reloading.
- **FR-009**: System MUST recover download tracking automatically after a crash or restart by
  re-deriving the active download set from persisted data, without losing track of any download.
- **FR-010**: System MUST NOT auto-trigger the hand-off process from a movie being newly
  requested in this phase — hand-off and tracking are available as built and tested capabilities,
  not yet wired to run automatically.

### Key Entities

- **Movie**: A watchlisted title, now also carrying an IMDb identifier and a download identifier
  used to track its in-flight download.
- **Download**: The client-side representation of an in-progress or completed transfer,
  identified by a download identifier and reporting a completion state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A movie handed off successfully always ends up in exactly one of: downloading, or a
  terminal no-match state — never stuck in an ambiguous state.
- **SC-002**: A completed download is reflected as "downloaded" on the movie without any manual
  user action.
- **SC-003**: A crash of the background tracking process never loses track of an in-progress
  download; tracking correctly resumes after restart.
- **SC-004**: A status change is visible on an open page within one live update cycle, without a
  page reload.

## Assumptions

- Scope is split deliberately: the hand-off function and the tracking process are both built and
  fully tested in isolation, but automatically triggering hand-off when a movie is newly
  requested is explicitly deferred to a later phase ("wire the loop").
- There is no distinct "download failed" status in this phase; a failed hand-off simply leaves the
  movie at its current in-progress status with no automatic retry — accepted as sufficient for a
  single-household deployment, revisited only if it proves problematic.
- Live validation of the specific download-client protocol's authentication and status-mapping
  quirks against a running instance is deferred to a later phase's live smoke test; this phase's
  client tests are shape sanity-checks against stubbed responses.
- Only download links that resolve to a magnet-style identifier are supported for extracting a
  trackable download identifier in this phase; other download link forms are explicitly
  unsupported here and deferred.
