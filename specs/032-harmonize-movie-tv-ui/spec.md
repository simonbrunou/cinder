# Feature Specification: Harmonize Movie & TV UI/UX

**Feature Branch**: `032-harmonize-movie-tv-ui`

**Created**: 2026-07-09

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-07-09-harmonize-movie-tv-ui-design.md`), plan.md (originally `docs/plans/2026-07-09-harmonize-movie-tv-ui.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A movie's detail page becomes a full management console, like a show's already is (Priority: P1)

A user managing a movie wants everything about that movie — editing, canceling, deleting, retrying,
finding a better match, and setting its language — available from the movie's own detail page,
exactly as a show's detail page already provides for a show.

**Why this priority**: This was the largest and most confusing inconsistency: clicking a series
poster opened a full management console, while clicking a movie poster opened a read-only
dead-end, with movie actions scattered across two other pages instead.

**Independent Test**: Open a movie's detail page and confirm every management action (edit, cancel,
delete, retry, find a better match, cancel an in-progress upgrade, set language) is available there
and functions correctly, with confirmation dialogs for destructive actions.

**Acceptance Scenarios**:

1. **Given** a movie in any pipeline state, **When** its detail page is opened, **Then** the
   appropriate action (Cancel if cancellable, otherwise Delete) is available directly on that page.
2. **Given** a movie's detail page, **When** the user chooses Edit, **Then** an inline edit form for
   title/year appears on the same page without navigating elsewhere.
3. **Given** a movie's detail page, **When** the user chooses Delete, **Then** a confirmation dialog
   appears offering the option to also delete the file from disk.
4. **Given** a parked movie's detail page, **When** the user chooses Retry, **Then** the movie
   re-enters search exactly as the previous Retry control did.
5. **Given** a movie's detail page, **When** the user opens "Find a better match" or cancels an
   in-progress upgrade, **Then** the same behavior previously available elsewhere now happens
   directly on this page.
6. **Given** a movie's detail page, **When** the user changes the movie's language preference,
   **Then** it is updated exactly as the previous language control did.

---

### User Story 2 - The library grid shows the same card shape for movies and shows (Priority: P2)

A user browsing the library grid wants movie and show cards to present the same information in the
same way — a poster, a status indicator, and quick actions — instead of shows lacking any status
indicator at all.

**Why this priority**: A visible inconsistency that undermines the sense of one coherent app, and
straightforward to fix once the console relocation (P1) is done.

**Independent Test**: View the library grid and confirm both a movie card and a series card show a
poster (linking to their detail page), a status badge, and Cancel/Delete controls, with no inline
edit form remaining on the movie card.

**Acceptance Scenarios**:

1. **Given** the library grid, **When** a movie card is viewed, **Then** it shows a poster (linking
   to the movie's detail page), a pipeline status badge, and Cancel/Delete controls, with no inline
   edit form present.
2. **Given** the library grid, **When** a series card is viewed, **Then** it shows a poster (linking
   to the series' detail page), a monitoring status badge, and Cancel/Delete controls, replacing the
   previous plain "Configure monitoring →" text link.

---

### User Story 3 - The activity board becomes a pure status view for both movies and shows (Priority: P2)

A user watching the in-flight activity board wants a live status view only — no management controls
mixed in — consistent between movies and shows.

**Why this priority**: Removing management controls from the activity board is what makes the
console relocation (P1) coherent; otherwise actions would exist in two places at once.

**Independent Test**: View the activity board while a movie is in-flight and confirm it shows only
title, status badge, and a link to the detail page — no retry, find-a-better-match, cancel-upgrade,
or language controls remain there.

**Acceptance Scenarios**:

1. **Given** the activity board, **When** a movie row is viewed, **Then** it shows only the title, a
   status badge, and a link to the movie's detail page.
2. **Given** the activity board, **When** an in-flight download (grab) row is viewed, **Then** its
   existing Delete (cancel-in-flight-download) control remains available, unchanged.

---

### User Story 4 - Discover shows per-title request state consistently for movies and TV (Priority: P3)

A user browsing the discover grid wants a TV show tile to reflect its current request state
(pending/approved/available), the same way a movie tile already does, instead of always showing a
generic "View seasons" regardless of state.

**Why this priority**: A cosmetic-but-informative parity gap; lower priority than the structural
console relocation but part of the same harmonization effort.

**Independent Test**: Request a season of a show, then view the discover grid and confirm the show's
tile now reflects that state using the same precedence rules movies already use.

**Acceptance Scenarios**:

1. **Given** a show with no requested seasons, **When** its discover tile is viewed, **Then** it
   falls back to "View seasons" as before.
2. **Given** a show with a requested, approved, available, or denied season, **When** its discover
   tile is viewed, **Then** it shows the corresponding state badge, using the same
   available-over-pending/approved-over-denied precedence movies already use.

---

### Edge Cases

- A movie's detail-page poster size now matches a series detail page's poster size, removing a
  previously visible inconsistency.
- An episode's file-info display remains a terse one-line chip on the season list — this feature
  does not add a full per-episode file panel.
- No pipeline, approval-gate, or underlying status-transition behavior changes as part of this
  feature — it is a relocation and consistency pass on the UI only.
- The "My Requests" view is unaffected, since it was already consistent between movies and shows
  before this feature.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to perform every movie management action (edit, cancel, delete,
  retry, find a better match, cancel an upgrade, set language) directly from the movie's own detail
  page.
- **FR-002**: The library grid MUST present movie and series cards with the same structure: poster
  linking to the item's detail page, a status badge, and quick Cancel/Delete controls.
- **FR-003**: The library grid MUST NOT retain an inline edit form on the movie card once editing
  has moved to the movie detail page.
- **FR-004**: The activity board MUST show only status information (title, status badge, link to
  detail page) for movies, with no management controls present.
- **FR-005**: The activity board's existing control for canceling an in-flight download (grab) MUST
  remain available and unchanged.
- **FR-006**: The discover grid MUST show a TV show's current per-title request state (using the
  same precedence as movies: available over pending/approved over denied), falling back to a
  generic browse prompt only when no state applies.
- **FR-007**: Movie and series detail pages MUST present their poster at the same size.
- **FR-008**: This feature MUST NOT alter any pipeline, approval-gate, or status-transition logic —
  only the location and presentation of existing controls.

### Key Entities

*(Not applicable — this feature relocates and restyles existing UI surfaces; it introduces no new
domain data.)*

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can perform every available movie management action from a single page (the
  movie's detail page), matching the number of pages required to manage a show.
- **SC-002**: The library grid's movie and series cards are visually and functionally identical in
  structure (poster, badge, quick actions).
- **SC-003**: The activity board no longer requires a user to distinguish "status view" from
  "management action" — every control it shows is either a status link or an in-flight-download
  cancel, with no residual management action left behind.
- **SC-004**: A user browsing Discover can identify a TV show's request state at a glance, matching
  the information already available for movies.

## Assumptions

- Moving Retry off the activity board to the movie detail page is an accepted, deliberate tradeoff:
  retrying a parked movie now takes one click into its detail page, mirroring how a parked episode
  is already retried on a show's detail page.
- No changes to the underlying pipeline, security invariants, or approval gate are made or intended
  by this feature — it is scoped purely to relocating and aligning existing UI controls and
  displays.
- Per-episode file-info display intentionally remains a compact list-row chip rather than gaining a
  full detail panel, since a season list is not the right surface for that much detail.
