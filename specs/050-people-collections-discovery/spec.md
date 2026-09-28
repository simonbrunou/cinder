# Feature Specification: People & Collections Discovery

**Feature Branch**: `050-people-collections-discovery`

**Created**: 2026-07-23

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-07-23-people-collections-discovery-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Landing page shows trending content instead of a blank search box (Priority: P1)

Why this priority: replaces a previously parked idea for a trending/discover landing page
beyond search (ROADMAP: "replaces the formerly parked 'trending/discover landing pages
beyond search'").

**Independent Test**: load the app's root page with no search query and confirm a populated,
actionable trending grid appears.

**Acceptance Scenarios**:

1. **Given** a household member visits the empty landing page, **When** the page loads,
   **Then** a trending-this-week grid of movies and TV appears with the same request/add
   actions available on search result cards.
2. **Given** the trending data fails to load, **When** the page loads, **Then** it degrades
   gracefully to the prior search-only landing page instead of erroring.

### User Story 2 - Searching finds people and franchises, not just titles (Priority: P1)

Why this priority: this is the core capability gap being closed — search previously had no
way to surface an actor, director, or franchise.

**Independent Test**: search a well-known actor's name and a well-known franchise name and
confirm both appear as distinct result types alongside movies and TV.

**Acceptance Scenarios**:

1. **Given** a search term matching an actor or director, **When** search runs, **Then** a
   person result appears among the results.
2. **Given** a search term matching a franchise, **When** search runs, **Then** a collection
   result appears among the results.
3. **Given** a search returns multiple result types, **When** shown, **Then** results are
   interleaved across types and can be narrowed with filter chips (All / Movies / TV / People
   / Collections).

### User Story 3 - Drilling into a person or franchise shows a focused browsing page (Priority: P2)

Why this priority: completes the discovery loop for the two new result types by letting a
household member explore everything tied to a person or franchise.

**Independent Test**: click through from a person or collection result and confirm a
dedicated page listing related titles with working request/add actions.

**Acceptance Scenarios**:

1. **Given** a household member opens a person's page, **When** it loads, **Then** it shows
   that person's combined movie and TV credits with request/add actions.
2. **Given** a person has more than 60 credits, **When** their page loads, **Then** only the
   top 60 are shown along with a visible caption of the total credit count.
3. **Given** a household member opens a collection's page, **When** it loads, **Then** its
   movies are shown in chronological release order with request/add actions.

### Edge Cases

- Movie and TV search both fail → the search is reported as failed, regardless of whether
  people/collections succeeded.
- Only the people and/or collections side fails while movies/TV succeed → those results are
  simply omitted, not treated as a failed search.
- A search term dominated by one result type (e.g. a common name) yields fewer movie/TV
  results on screen once interleaved with people/collections — recoverable via filter chips.
- A person or collection id that does not exist is a distinct case from that service being
  unreachable.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST show a trending grid of movies and TV on the landing page when no
  search has been entered.
- **FR-002**: System MUST fall back to the prior search-only landing page when trending data
  cannot be fetched.
- **FR-003**: Users MUST be able to search for people (actors, directors, and similar roles)
  in addition to movies and TV.
- **FR-004**: Users MUST be able to search for collections/franchises in addition to movies
  and TV.
- **FR-005**: System MUST present movie, TV, person, and collection results interleaved
  rather than grouped in separate fixed blocks.
- **FR-006**: Users MUST be able to filter combined search results by result type (movies,
  TV, people, collections, or all).
- **FR-007**: Users MUST be able to open a dedicated page for a person showing their combined
  movie and TV credits.
- **FR-008**: Users MUST be able to open a dedicated page for a collection showing its
  movies in chronological order.
- **FR-009**: System MUST cap a person's displayed credits at 60 and show a visible
  indicator when more exist beyond the cap.
- **FR-010**: Users MUST be able to request/add a title directly from a person's or
  collection's page, using the same flow used elsewhere in discovery.
- **FR-011**: System MUST report a search as failed only when both the movie and TV sides
  fail, regardless of the person/collection sides' outcome.
- **FR-012**: System MUST keep existing movie/TV search and trending behavior unaffected by
  the addition of people and collections.

### Key Entities

- Person
- Collection (franchise)
- Search result
- Credit
- Trending grid

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A household member with no query sees a populated, actionable landing page
  instead of a blank search box.
- **SC-002**: Searching a known actor or franchise name surfaces that person or franchise as
  a result, not only titles whose text happens to match.
- **SC-003**: A household member can go from a search result to a focused browsing page for a
  person or franchise in one click, and from there request a title in one more.
- **SC-004**: A person with a long filmography is never shown an unbounded list — it is
  capped with a visible caption of the total credit count.
- **SC-005**: A failure fetching people or collections never prevents a household member from
  seeing movie/TV search results.

## Assumptions

- Separate per-type search endpoints were used instead of a combined multi-search endpoint,
  as an additive-rollout choice; this is a scope boundary, not a user-facing requirement — the
  existing movie/TV search and trending pipelines were deliberately left untouched.
- Round-robin interleaving of result types was accepted with the known, named tradeoff that a
  query dominated by one type shows fewer movie/TV results per screen, recoverable via filter
  chips — a deliberate tradeoff for a household-scale tool, not a defect.
- The exact shipping CHANGELOG version could not be confidently matched by name/keyword
  search; shipped status is grounded in ROADMAP.md's dated shipped entry and the design
  document's own 2026-07-23 date.
- An existing, unrelated series-discovery page's duplicated flash-message copy was
  deliberately left as-is and is out of scope for this feature.
