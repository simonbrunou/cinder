# Feature Specification: UX-3 Unified Discover

**Feature Branch**: `017-ux-3-unified-discover`

**Created**: 2026-06-24

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-06-24-ux-3-unified-discover.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One search for movies and TV (Priority: P1)

A household member searching for something to watch types one query and sees both matching movies
and matching TV shows together in a single mixed poster grid, instead of having to know in advance
whether to search the movie page or the separate TV page.

**Why this priority**: This is the core reimagining goal of the phase — merging three fragmented
surfaces (movie search, TV search, season request) into one Discover surface — and every other
story depends on this merged search existing.

**Independent Test**: Enter a query that matches both a known movie title and a known TV show
title; confirm both appear in one interleaved grid, each tagged with its type.

**Acceptance Scenarios**:

1. **Given** a search query that matches a movie and a TV show, **When** the search runs, **Then**
   both results render in one grid, each carrying a poster, title, year, and a film/TV type chip.
2. **Given** a search query with no whitespace-only content, **When** it is submitted blank,
   **Then** no external search call is made and an empty result set is returned.
3. **Given** one of the two underlying search sources fails while the other succeeds, **When** the
   search completes, **Then** the succeeding source's results still render (partial results beat
   none).
4. **Given** both underlying search sources fail, **When** the search completes, **Then** the page
   shows a distinct search-failed state rather than an empty-results state.

---

### User Story 2 - Requesting a movie or a TV season from Discover (Priority: P1)

A household member finds a movie or TV show in Discover and requests it — a movie is requested
inline on its card; a TV show links to the existing season picker — without either path bypassing
the approval gate.

**Why this priority**: Preserving the request/approval-gate behavior while unifying the entry
point is the hard non-negotiable constraint of this phase; it is equally foundational to the merge
itself.

**Independent Test**: As a non-admin household member, request a movie inline and request a TV
season via the season picker; confirm both create a request row exactly as they did before the
merge and neither auto-approves.

**Acceptance Scenarios**:

1. **Given** a household member viewing a movie card in Discover, **When** they use the inline
   request affordance, **Then** a request is created through the same approval-gated path as
   before, with no row available before admin approval.
2. **Given** a household member viewing a TV show card in Discover, **When** they follow it to the
   season picker, **Then** they can request a season through the unchanged season-request flow.
3. **Given** a non-admin user, **When** they submit either kind of request, **Then** no route's
   authorization/role-gating differs from before the merge.

---

### User Story 3 - Old bookmarks still work (Priority: P3)

A user who bookmarked the old separate TV search page is redirected to the new unified Discover
page instead of hitting a dead page.

**Why this priority**: Low-risk cleanup that preserves continuity for existing bookmarks/links;
independent of the search-merge mechanics themselves.

**Independent Test**: Navigate to the old TV search route and confirm it redirects to the new
Discover route.

**Acceptance Scenarios**:

1. **Given** a user navigates to the old TV search URL, **When** the request is handled, **Then**
   they are redirected to the unified Discover page.

---

### Edge Cases

- What happens when a query is blank or only whitespace? No external search call happens; the
  result is an empty list rather than an error.
- How does the system handle one search source failing while the other succeeds? The failing
  side's error is logged and omitted; the succeeding side's results are still shown.
- How does the system handle both search sources failing? A distinct search-failed state is shown
  rather than a plain empty-results message.
- What happens when the same title appears in more than one discovery listing/rail context? It is
  shown once, associated with the context it was first encountered in, never duplicated.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to search movies and TV shows from a single search box on one
  page and see both kinds of results in one mixed grid.
- **FR-002**: System MUST tag and visually distinguish each result as a movie or a TV show (e.g. a
  film/TV chip) within the mixed grid.
- **FR-003**: System MUST interleave movie and TV results rather than grouping all of one kind
  before the other, so both kinds surface near the top on a small screen.
- **FR-004**: Users MUST be able to request a movie inline, directly on its card, without leaving
  the Discover surface.
- **FR-005**: Users MUST be able to reach a season picker from a TV result to request a specific
  season.
- **FR-006**: System MUST create every request (movie or TV season) through the single existing
  approval-gated request-creation path; no new path may create a request row.
- **FR-007**: System MUST NOT change any route's authorization/role-gating as part of unifying the
  search surfaces.
- **FR-008**: System MUST redirect the old, separate TV search route to the unified Discover route
  so existing links keep working.
- **FR-009**: System MUST return the results of one search source even when the other source
  errors, and only show a search-failure state when both sources fail.
- **FR-010**: System MUST keep the Discover surface, its request affordances, and the season
  picker fully operable by touch, reflowing to a 2-column grid on a 390px-wide screen, with
  request/season affordances always visible rather than revealed only on hover.

### Key Entities

- **Discover Result**: A movie or TV search result normalized to a common shape (title, year,
  poster, type) for display in the mixed grid.
- **Request**: A household member's ask to acquire a movie or a specific TV season, gated by
  admin approval before acquisition proceeds.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A single search on the Discover page returns and displays both movie and TV results
  together, replacing the three previously separate search/request surfaces.
- **SC-002**: Requesting a movie or a TV season from Discover produces the identical
  approval-gated outcome as the pre-merge flows, with zero requests bypassing approval.
- **SC-003**: Navigating to the old, separate TV search URL always lands the user on the unified
  Discover page.
- **SC-004**: The Discover grid and its request affordances remain fully usable with no horizontal
  overflow at a 390px screen width, reflowing to at least two columns.

## Assumptions

- This feature is UX slice 3 of 5 under the umbrella feature `014-ux-identity-overhaul`, which
  also includes `015` (foundation/shell), `016-ux-2-shared-components`, `018-ux-4-admin-home`, and
  `019-ux-5-hardening`.
- The admin-only "Added series" management block was relocated onto the Discover page for this
  phase only, as an explicit interim decision; the umbrella design notes it moves again to the
  Library surface in the next phase (UX-4).
- Whether the TV season picker is a dedicated route or a modal was left open by the umbrella
  design and settled in this phase's own plan as a dedicated route, not a modal.
- No backend approval-gate, pipeline, or role-gating change is in scope; only the search/request
  entry-point presentation is unified.
