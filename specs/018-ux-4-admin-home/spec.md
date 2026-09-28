# Feature Specification: UX-4 Admin Home — Dashboard, Activity, Library

**Feature Branch**: `018-ux-4-admin-home`

**Created**: 2026-06-24

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-06-24-ux-4-admin-home.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Admins land on an operations dashboard (Priority: P1)

An admin who logs in is taken to a Dashboard showing at a glance what needs attention: pending
approvals, service health, and recent activity — instead of landing on the same movie-search page
household members see.

**Why this priority**: This is the core reimagined information architecture the phase exists to
deliver, and every other consolidation (Activity, Library) is reached from or alongside it.

**Independent Test**: Log in as an admin and confirm the landing page is the Dashboard, showing a
live pending-approval count, service health, and a recent-activity slice, with drill-downs into
Requests / Activity / Library.

**Acceptance Scenarios**:

1. **Given** an admin logs in, **When** they land, **Then** they see the Dashboard, not the
   household Discover page.
2. **Given** the Dashboard is open, **When** a request is approved or denied directly from it,
   **Then** the outcome is identical to approving/denying from the dedicated Requests page.
3. **Given** a household member (non-admin) logs in, **When** they land, **Then** they land on
   Discover, not the Dashboard.

---

### User Story 2 - One Activity feed for pipeline and downloads (Priority: P2)

An admin checking what's happening right now sees one consolidated Activity feed combining the
movie pipeline and in-flight TV downloads, as reflowing cards rather than a table, instead of two
separate pages.

**Why this priority**: Removes a fragmented admin surface and is a direct prerequisite for the
Dashboard's "recent activity" and for old bookmarks continuing to work.

**Independent Test**: As an admin, visit the old separate pipeline and downloads URLs and confirm
each redirects to the merged Activity page, which shows both movie pipeline entries and TV grabs.

**Acceptance Scenarios**:

1. **Given** an admin visits the old movie-pipeline URL, **When** the request is handled, **Then**
   they are redirected to the merged Activity page.
2. **Given** an admin visits the old downloads URL, **When** the request is handled, **Then** they
   are redirected to the merged Activity page.
3. **Given** a movie is in a parked/failed state, **When** viewing Activity, **Then** a Retry
   action is available that re-queues it; an in-flight movie shows no Retry action.
4. **Given** an admin deletes a grab from Activity, **When** they confirm the deletion, **Then**
   the grab is removed and no longer listed.

---

### User Story 3 - One Library for movies and TV (Priority: P2)

An admin managing the collection sees movies and added TV shows together in one Library page and
can drill into series detail from there, instead of switching between a movies page and a TV
detail flow reached only through Discover.

**Why this priority**: Completes the consolidation map alongside Activity, at the same priority
tier, and is what the Discover admin-only series block moves into.

**Independent Test**: As an admin, visit the old movies-list URL and confirm it redirects to
Library; confirm Library lists both movies and added series and drilling into a series reaches
its unchanged detail/monitoring page.

**Acceptance Scenarios**:

1. **Given** an admin visits the old movies-list URL, **When** the request is handled, **Then**
   they are redirected to the Library page.
2. **Given** the Library page is open, **When** the admin views it, **Then** both movies and added
   TV series are listed together.
3. **Given** the admin selects a series in Library, **When** they drill in, **Then** they reach the
   unchanged per-episode monitoring detail page.

---

### Edge Cases

- What happens when a non-admin tries to reach an admin-only consolidated page (Activity,
  Library, Dashboard)? They are redirected away, identically to the pre-existing route guards.
- How does the system handle the old bookmarked URLs for the pages being merged? Each redirects to
  its new consolidated destination rather than 404ing.
- What happens to the pipeline/grab-list table layout on a narrow screen? It degrades to a stacked
  card list instead of overflowing horizontally.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST route an admin to a Dashboard landing page on login, while a
  non-admin continues to land on Discover.
- **FR-002**: System MUST show live pending-approval count, service health, and a recent-activity
  summary on the Dashboard.
- **FR-003**: Users MUST be able to approve or deny a pending request directly from the Dashboard
  with the identical outcome as the dedicated Requests page.
- **FR-004**: System MUST consolidate the previously separate movie-pipeline view and TV-downloads
  view into one Activity feed.
- **FR-005**: Users MUST be able to retry a parked/failed movie from Activity, and the retry action
  MUST NOT be available for a movie that is already in flight.
- **FR-006**: Users MUST be able to delete a TV download (grab) from Activity through a
  confirmation step.
- **FR-007**: System MUST consolidate the previously separate movies list and the added-series
  list into one Library view.
- **FR-008**: Users MUST be able to drill from a series in Library into its existing per-episode
  monitoring detail page.
- **FR-009**: System MUST redirect every old route being merged (movie-pipeline page, downloads
  page, movies list) to its new consolidated destination.
- **FR-010**: System MUST NOT change any route's authorization/role-gating as part of this
  consolidation — only grouping, labeling, and visuals change.
- **FR-011**: System MUST keep Dashboard, Activity, and Library fully usable at a 390px screen
  width, with tabular data degrading to stacked cards and no horizontal overflow.

### Key Entities

- **Dashboard**: The admin's role-aware landing page summarizing pending approvals, service
  health, and recent activity with drill-downs.
- **Activity**: The consolidated live feed of the movie acquisition pipeline and in-flight TV
  downloads.
- **Library**: The consolidated, browsable view of the household's managed movies and added TV
  series, with drill-down to series detail.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An admin logging in always lands on the Dashboard; a non-admin always lands on
  Discover.
- **SC-002**: The number of separate admin pages for pipeline/downloads/movies drops from three
  fragmented pages to two consolidated pages (Activity, Library), each reachable via redirect from
  every corresponding old URL.
- **SC-003**: Approving or denying a request from the Dashboard produces the same result as doing
  so from the dedicated Requests page, with zero behavioral divergence.
- **SC-004**: Dashboard, Activity, and Library all render with no horizontal overflow at a 390px
  screen width.

## Assumptions

- This feature is UX slice 4 of 5 under the umbrella feature `014-ux-identity-overhaul`, which
  also includes `015` (foundation/shell), `016-ux-2-shared-components`, `017-ux-3-unified-discover`,
  and `019-ux-5-hardening`.
- No backend, data-model, authentication, or approval-gate/pipeline change is in scope; this phase
  is presentation and information-architecture only, reusing existing read/mutate functions.
- The admin-only "Added series" block that UX-3 temporarily placed on Discover is relocated to
  Library in this phase, per the umbrella design's stated plan.
