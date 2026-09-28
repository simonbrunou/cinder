# Feature Specification: Catalog — Movie Discovery and Watchlist

**Feature Branch**: `001-phase-1-catalog`

**Created**: 2026-06-18

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-18-phase-1-catalog-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Search for a movie (Priority: P1)

A user visiting the app's home page types a movie title into a live search box and sees matching
results (title, year, poster) as they type, without needing to click a submit button.

**Why this priority**: Search is the entry point to every other capability in the app — without it
a user has no way to find a movie to request.

**Independent Test**: Can be fully tested by typing a query into the home page search box and
observing debounced results render without a page reload.

**Acceptance Scenarios**:

1. **Given** the home page is loaded, **When** the user types a movie title, **Then** matching
   results appear after a short debounce with no explicit submit action.
2. **Given** the user clears the search box, **When** the query becomes blank, **Then** the
   results list disappears (no stale results remain) and no external search call is made.
3. **Given** a valid query with no matches, **When** results return empty, **Then** a "no
   matches" message is shown instead of a blank gap.
4. **Given** the movie catalog service is unavailable, **When** a search is attempted, **Then**
   an error is flashed to the user, prior results are kept, and the page does not crash.

---

### User Story 2 - Add a movie to the watchlist (Priority: P1)

From search results, a user adds a movie to their watchlist with one click; it then appears in
the watchlist below the search box, marked as requested.

**Why this priority**: Adding to the watchlist is the action that turns a discovered movie into a
tracked request — the foundational step the rest of the system (acquisition, download, library)
builds on.

**Independent Test**: Can be fully tested by searching for a movie, clicking Add, and confirming
it appears in the rendered watchlist in a "requested" state.

**Acceptance Scenarios**:

1. **Given** search results are shown, **When** the user clicks Add on a result, **Then** the
   movie is persisted with a "requested" status and prepended to the visible watchlist.
2. **Given** a movie is already on the watchlist, **When** the user attempts to add it again,
   **Then** the system rejects the duplicate and flashes "already on your watchlist" instead of
   creating a second entry.
3. **Given** the user double-clicks Add quickly, **When** both clicks reach the server, **Then**
   only one watchlist entry is created (no duplicate row).

---

### User Story 3 - View the watchlist on first run (Priority: P2)

On a fresh install with an empty watchlist, the home page shows helpful empty-state copy instead
of a blank area.

**Why this priority**: First-run experience matters for a self-hosted app with no seed data, but
it is secondary to search and add working at all.

**Independent Test**: Can be fully tested by loading the home page with zero watchlist entries and
observing empty-state copy below the search box.

**Acceptance Scenarios**:

1. **Given** no movies have been added yet, **When** the home page loads, **Then** empty-state
   copy is rendered instead of an empty list.

---

### Edge Cases

- Movie posters that TMDB doesn't provide render a text placeholder instead of a broken image.
- Movies with no known release year render just the title, without a "(year)" suffix.
- Clicking Add on a result that is no longer in the current in-memory result set (e.g. results
  were cleared or replaced mid-click) is a no-op rather than an error.
- A blank/whitespace-only query never triggers an external search call.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST let users search for movies by title via a live, debounced search box
  with no explicit submit action.
- **FR-002**: System MUST short-circuit a blank or whitespace-only query to an empty result set
  without calling the external movie catalog service.
- **FR-003**: System MUST render a distinct "no matches" state for a valid query that returns zero
  results.
- **FR-004**: Users MUST be able to add a search result to a persistent watchlist with one action.
- **FR-005**: System MUST prevent the same movie from being added to the watchlist twice,
  informing the user instead of creating a duplicate entry.
- **FR-006**: System MUST display the watchlist, most recently added first, on the home page.
- **FR-007**: System MUST show a distinct empty-state message when the watchlist has no entries.
- **FR-008**: System MUST surface a non-crashing error message when the movie search service is
  unavailable or errors, while preserving the previously displayed results.
- **FR-009**: System MUST track each watchlisted movie's status, starting at "requested," using a
  known, extensible set of statuses so later phases can advance it without redefining the field.
- **FR-010**: System MUST render a placeholder in place of a poster image when no poster is
  available, and omit the release year from the title display when the year is unknown.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can go from typing a movie title to having it appear in their watchlist in
  under three interactions (type, wait for results, click Add).
- **SC-002**: Search results reflect the user's typed query within roughly 300ms of the user
  pausing input, without requiring a manual submit.
- **SC-003**: No duplicate watchlist entries are ever created for the same movie, including under
  rapid repeated add attempts.
- **SC-004**: A movie catalog service outage never crashes the search page; the user always sees
  either results or an explicit error state.

## Assumptions

- Scope is movies-only; TV, multi-user support, and search pagination are explicitly deferred.
- The external movie catalog integration (TMDB) is not live-credentialed at this stage; live
  connectivity is validated in a later phase (Phase 5). Tests for this phase run fully mocked.
- IMDb identifier carry-through for indexer search is deliberately deferred to the next phase
  (Acquisition), which needs it.
- No cross-referencing between search results and the existing watchlist is provided in this
  phase (Add is always shown, even for already-watchlisted movies) — acceptable for a
  single-household deployment.
- No live PubSub updates to the watchlist in this phase; one process owns reads and writes until
  a later phase introduces background pollers.
