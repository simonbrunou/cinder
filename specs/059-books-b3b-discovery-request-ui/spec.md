# Feature Specification: Book discovery, work page, and the request UI

**Feature Branch**: `059-books-b3b-discovery-request-ui`

**Created**: 2026-08-25

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-25-books-b3b-discovery-and-request-ui.md`)

Part of the umbrella books/Readarr-replacement effort (see `053-books-readarr-replacement`); this
slice is the second half of B3, giving a household member a way to reach the request path built in
`058-books-b3a-requests-approval`: search books from Discover, open a work, and request it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Search and discover a book (Priority: P1)

Why this priority: without a search entry point, a household member has no way to find a book to
request at all.

Independent Test: search Discover for a book title and confirm book results render in their own
section without disturbing movie/TV results.

**Acceptance Scenarios**:

1. **Given** a search query of three or more characters, **When** Discover runs the search, **Then**
   a books section renders results distinct from the movie/TV grid.
2. **Given** the book metadata provider is unavailable, **When** a search is run, **Then** the books
   section shows an inline outage note while movie and TV results remain fully usable.
3. **Given** a user filters to books only, **When** the filter is applied, **Then** movie/TV results
   are hidden and only book results show, and vice versa.

### User Story 2 - Open a book and request it (Priority: P1)

Why this priority: this is the actual conversion point — reaching the request path built in the
prior slice.

Independent Test: open a book's discovery page and press its "Request eBook"/"Request audiobook"
button, confirming the outcome matches the underlying request/approval rules.

**Acceptance Scenarios**:

1. **Given** a household member opens a book's discovery page, **When** they press "Request eBook",
   **Then** a pending request is created and no acquisition target exists until an admin approves.
2. **Given** an admin opens a book's discovery page, **When** they press "Request eBook", **Then**
   the request auto-approves under existing auto-approval rules and exactly one monitored target is
   created.
3. **Given** a work with both e-book and audiobook available, **When** a user requests one, **Then**
   the other kind's request button remains independently usable.

### User Story 3 - See live request/availability status (Priority: P2)

Why this priority: a requester or admin needs to see approval and availability progress without
reloading, consistent with the rest of the app's live-update behavior.

Independent Test: approve a pending request from another session and confirm the open discovery page
updates its badge without a manual reload.

**Acceptance Scenarios**:

1. **Given** an open book discovery page with a pending request, **When** an admin approves it
   elsewhere, **Then** the page's badge updates to reflect the monitored state without a reload.
2. **Given** a book media kind with no configured profile, **When** the discovery page renders,
   **Then** that kind's request button is absent, and an admin sees a link to configure one while a
   non-admin sees a plain "not available yet" message.

### Edge Cases

- An unknown provider segment in the book discovery route renders a 404.
- A metadata resolution failure for a specific book renders an inline retry state with a normal page
  load, never a 404 — the system cannot distinguish "unknown book" from "provider down" at this
  layer.
- A second request press on an already-pending kind shows an "already requested" message and creates
  nothing new.
- A stale, slow search response for a query the user has since retyped is discarded rather than
  overwriting the current results.
- A query under three characters does not trigger a book search.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to search for a book by title/author from the same Discover surface
  used for movies and TV.
- **FR-002**: System MUST render book search results as their own distinct section, separate from
  the movie/TV results grid.
- **FR-003**: System MUST provide a books filter that, when applied, shows only book results and
  hides movie/TV results, and MUST allow returning to the combined view.
- **FR-004**: System MUST perform book searches asynchronously so a slow provider lookup never blocks
  the rest of the page from rendering or updating.
- **FR-005**: System MUST discard a book search result whose query no longer matches the user's
  current search input.
- **FR-006**: System MUST NOT trigger a book search for a query shorter than three characters.
- **FR-007**: System MUST degrade gracefully when the book metadata provider is unavailable: the
  books section shows an inline outage indicator while movie, TV, and any other Discover content
  remain fully functional.
- **FR-008**: Users MUST be able to open a dedicated page for a specific book showing its title,
  contributors with roles, first published year, overview, series memberships, and a summary of
  available digital editions.
- **FR-009**: System MUST return a not-found response for a book page referencing an unrecognized
  metadata provider, and MUST instead show an inline retry state (not a not-found response) when a
  known provider fails to resolve the book.
- **FR-010**: Users MUST be able to request a book as an e-book or audiobook directly from its
  discovery page, one button per media kind that has a configured profile.
- **FR-011**: System MUST omit the request button for a media kind that has no configured profile,
  and MUST show an admin a path to configure one while showing a non-admin a plain unavailable
  message instead.
- **FR-012**: System MUST prevent a duplicate request for a kind that already has a pending request
  from the same user, surfacing an explicit "already requested" outcome instead of creating a second
  request.
- **FR-013**: System MUST allow a work's e-book and audiobook requests to be created and tracked
  independently — requesting one MUST NOT disable or otherwise affect the other's request control.
- **FR-014**: System MUST update a book's live request/availability badge automatically when its
  underlying request or target state changes, without requiring a manual page reload.
- **FR-015**: System MUST NOT expose indexer, download-format, ISBN, or profile-selection controls on
  any requester-facing book surface.
- **FR-016**: System MUST present all book discovery and request UI text through the application's
  localization mechanism, in every supported locale.

### Key Entities

- **Book work**: the logical title a household member discovers, identified through a metadata
  provider reference before it necessarily has a local acquisition target.
- **Book candidate**: a provider-supplied search result carrying no local acquisition state, overlaid
  with local request/target status for display.
- **Discover result section**: a distinct grouping of book results alongside the existing movie/TV
  results within the shared discovery surface.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A household member can find a book from the home/discover surface, open it, and request
  it as an e-book or audiobook, with no managed acquisition target created before an admin approves.
- **SC-002**: An admin's own book request auto-approves under existing auto-approval rules and
  results in exactly one monitored target.
- **SC-003**: A book-provider outage degrades only the books section of Discover — movie and TV
  results remain fully usable throughout.
- **SC-004**: No requester-facing book surface exposes indexer, format, ISBN, or profile-handling
  controls.
- **SC-005**: All book discovery and request UI copy is fully localized in every supported locale.

## Assumptions

- Local author search and author aliases remain deferred to a later author-monitoring milestone;
  this slice's search operates purely against external metadata providers.
- Operator metadata overrides are out of scope: the book discovery page is read-only, with no edit
  control anywhere in this slice.
- Listing books in the general library view is deferred until an acquisition/import milestone gives
  the library something to list; until then there are no book files to show there.
- No cover art is shown for book candidates or the book discovery page, since the metadata providers
  used in this slice supply none.
- No client-side search result caching is implemented; a debounced input plus the three-character
  minimum query length is treated as sufficient for this slice.
- No edition picker is offered on the book discovery page; edition selection is deferred to a later
  acquisition milestone.
