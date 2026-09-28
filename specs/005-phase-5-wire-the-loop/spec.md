# Feature Specification: Wire the Loop — Automatic End-to-End Requests

**Feature Branch**: `005-phase-5-wire-the-loop`

**Created**: 2026-06-19

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-19-phase-5-wire-the-loop-design.md`), plan.md (originally `docs/superpowers/plans/2026-06-19-phase-5-wire-the-loop.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A requested movie flows automatically to available (Priority: P1)

A user adds a movie to their watchlist and, without taking any further action, the movie is
automatically searched, downloaded, and imported until it becomes available in their media
server.

**Why this priority**: This is the entire point of the project — closing the loop so that
"requesting" a movie is genuinely all a user has to do; every prior phase built a piece of this
but left the trigger manual.

**Independent Test**: Can be fully tested by inserting a requested movie and driving the
background process through several ticks against mocked search, download, and import services,
asserting the movie reaches "available" with no manual function calls in between.

**Acceptance Scenarios**:

1. **Given** a movie is newly added to the watchlist (status "requested"), **When** the
   background process runs its next several ticks, **Then** the movie proceeds through searching,
   downloading, and importing to "available" with no manual steps.
2. **Given** a movie has just been handed off to the download client in one tick, **When** the
   same tick continues, **Then** the movie is not immediately status-checked against the download
   client in that same tick — it is checked no earlier than the next tick, avoiding a wasted call
   against a torrent registered moments earlier.

---

### User Story 2 - Transient search or hand-off failures are retried, not permanently stuck (Priority: P1)

If a movie's search or hand-off fails due to a temporary problem (e.g. the indexer or metadata
service is briefly unreachable), the system retries automatically with a backoff, rather than
hammering the external service every few seconds or leaving the movie stuck forever.

**Why this priority**: Real-world external services are unreliable; without bounded, backed-off
retry, a transient blip would either strand a movie forever or spam a rate-limited external
service.

**Independent Test**: Can be fully tested by making a mocked search dependency fail repeatedly,
driving several background ticks with retry backoff disabled for the test, and asserting the
movie is retried up to a bounded number of attempts before landing on a terminal, distinctly
labelled failure state.

**Acceptance Scenarios**:

1. **Given** a movie's search fails with a transient error, **When** the background process
   retries it, **Then** it is not retried on every single tick — retries are spaced out so the
   external service isn't hit continuously during an outage.
2. **Given** a movie's search has failed transiently repeatedly and exhausted its retry budget,
   **When** the final retry also fails, **Then** the movie is parked at a terminal,
   operator-actionable failure state distinct from "no match," so the user knows to check their
   service configuration rather than assume the movie is simply unavailable.
3. **Given** a movie has no resolvable identifier for search at all (a permanent condition),
   **When** search is attempted, **Then** the movie is parked immediately at "no match" without
   consuming retry attempts.
4. **Given** a release is found but its download link form cannot be handled by the download
   client, **When** hand-off is attempted, **Then** the movie is parked immediately at the
   operator-actionable failure state, since this is something an operator can potentially fix.

---

### User Story 3 - View every movie's live status on a dashboard (Priority: P2)

A user can visit a status dashboard page that lists every requested/tracked movie together with
its current state, updating live as movies progress through the pipeline.

**Why this priority**: Gives the user visibility into the now-automatic pipeline, but is
secondary to the pipeline actually running automatically and reliably.

**Independent Test**: Can be fully tested by loading the dashboard with movies in various states
and confirming a background status change updates the corresponding row live without a page
reload.

**Acceptance Scenarios**:

1. **Given** movies in several different pipeline states, **When** the status dashboard is
   loaded, **Then** every movie is listed along with its current state.
2. **Given** the dashboard is open, **When** a movie's status changes in the background, **Then**
   the dashboard updates that movie's row live, without a page reload.

---

### Edge Cases

- A movie whose search fails at the IMDb-identifier-resolution step (before "searching" status is
  recorded) and one whose search fails after that point (after "searching" status is recorded)
  are both picked up by the same retry sweep regardless of which status they're resting at.
- A crash mid-retry-cycle does not lose the retry count or reset the backoff schedule, since both
  are derived from persisted data, not in-memory state.
- A hung connection to an external search-related service does not wedge the entire background
  pipeline indefinitely — such calls are time-bounded.
- A movie manually re-requested after being permanently parked keeps its prior retry count and
  may re-park quickly on the very next automatic attempt; a UI to reset this is explicitly not
  provided.
- Torrent download links in non-magnet forms (e.g. `.torrent` URLs) and base32-encoded magnet
  hashes are explicitly supported/unsupported per documented rules rather than silently mishandled.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automatically initiate the search-and-download process for a movie as
  soon as it is requested, with no manual trigger required.
- **FR-002**: System MUST NOT perform the search-and-download hand-off synchronously as part of
  the user's request action (e.g. the watchlist-add interaction); it MUST run under background
  processing.
- **FR-003**: System MUST retry a movie whose search or hand-off failed for a transient reason, up
  to a bounded number of attempts, rather than retrying indefinitely or abandoning it after one
  failure.
- **FR-004**: System MUST space out retries of a transiently failing movie rather than retrying on
  every background processing cycle, to avoid overloading external services during an outage.
- **FR-005**: System MUST distinguish, in the movie's terminal state, between "no acceptable
  release exists" (passive, not the operator's fault) and "search/hand-off could not be completed
  after retrying" (operator-actionable, e.g. a misconfigured or unreachable external service).
- **FR-006**: System MUST park a movie immediately at a terminal failure state — without
  consuming retry attempts — when the failure reason is permanent (no resolvable identifier, or an
  unsupported release link form), rather than retrying something that cannot succeed.
- **FR-007**: System MUST bound how long any single external service call in the background
  process can take, so a hung external service cannot stall the entire pipeline.
- **FR-008**: System MUST provide a status dashboard listing every tracked movie and its current
  pipeline state.
- **FR-009**: System MUST update the status dashboard live as a movie's state changes, without
  requiring the user to reload the page.
- **FR-010**: System MUST avoid re-checking a download's status in the same processing cycle in
  which it was just handed off, so a newly created download isn't checked before it could
  plausibly have progressed.
- **FR-011**: Users MUST be able to see, for any movie stuck in a failure state, which of the two
  distinct failure categories it is in, so they can tell whether any action on their part is
  warranted.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A newly requested movie reaches "available" (given a healthy environment and a
  real, obtainable release) with zero manual steps between the initial request and the movie
  appearing in the media server.
- **SC-002**: A transient outage of a search-related external service never permanently strands a
  movie and never causes continuous, unspaced retry traffic against that service during the
  outage.
- **SC-003**: An operator can distinguish, for any parked movie, whether nothing usable exists for
  it versus whether something on their end (indexer, credentials, connectivity) needs attention.
- **SC-004**: The status dashboard reflects a movie's true current state within one live update
  cycle of that state changing, with no page reload needed.
- **SC-005**: No single hung external service call blocks pipeline processing for other movies
  beyond a bounded timeout.

## Assumptions

- Running the full live end-to-end smoke test (with real, credentialed external services) was
  explicitly deferred beyond this session's scope; this feature delivers the environment-variable
  setup and a smoke-test checklist, with the live run left to the user/operator to execute
  afterward. The roadmap records that this live validation was subsequently completed
  (2026-06-20): a real movie went from requested to available, imported as a true hardlink, and
  scanned into the media server.
- Only one style of BitTorrent info-hash (the older, shorter form) is supported; the newer
  hybrid/alternate hash form is explicitly out of scope.
- No manual "retry now" user interface is provided for a movie parked in a failure state; an
  operator must intervene via lower-level tooling to reset and re-request it.
- Periodic re-search of movies parked at "no acceptable release exists," quality-upgrade hunting,
  TV show support, and multi-user support are all explicitly out of scope for this feature and
  deferred per the project roadmap.
- The back-half of the pipeline (tracking a download to completion and importing it) was already
  fully automatic as of the prior phase; this feature's real gap and scope is specifically wiring
  the front half (automatic search/hand-off triggering) plus its retry/backoff behavior and the
  status dashboard.
