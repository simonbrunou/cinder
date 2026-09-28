# Feature Specification: Season Disclosures

**Feature Branch**: `034-season-disclosures`

**Created**: 2026-07-10

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-07-10-season-disclosures-design.md`), plan.md (originally `docs/plans/2026-07-10-season-disclosures.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Collapsed seasons on series detail (Priority: P1)

**Why this priority**: The entire feature is this one change — every season on a TV series detail
page renders collapsed by default so the page is not cluttered with every episode of every season
at once.

**Independent Test**: Open a series detail page for a show with multiple seasons and confirm each
season's episode list is hidden until that season is opened.

**Acceptance Scenarios**:

1. **Given** a series with multiple seasons, **When** a viewer opens the series detail page,
   **Then** every season, including any specials season, renders collapsed with only its name and
   monitored-episode count visible.
2. **Given** a collapsed season, **When** the viewer opens it, **Then** the season's actions,
   manual-search panel, confirmation panel, and episode list become visible.
3. **Given** an opened season, **When** the viewer navigates away and returns to the series detail
   page, **Then** the season renders collapsed again (state is not persisted).

### Edge Cases

- A specials season (Season 0) starts collapsed the same as every numbered season.
- Reloading or revisiting the page does not remember which seasons were previously opened.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The series detail page MUST render each season's episode content inside a
  collapsible disclosure that is closed by default whenever the page renders.
- **FR-002**: Each season's collapsed summary MUST show the season name and its monitored-episode
  count.
- **FR-003**: Users MUST be able to open and close a season's disclosure using standard keyboard
  and pointer interaction, without triggering a page reload or server round trip.
- **FR-004**: The existing season actions, manual-search panel, confirmation panel, and episode
  list MUST remain fully available inside the expanded disclosure content.
- **FR-005**: The system MUST NOT persist a season's open/closed state across page renders; every
  season starts collapsed on each fresh render, including the specials season.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On first render of any series detail page, 100% of seasons (including specials)
  display collapsed, showing only name and monitored-episode count.
- **SC-002**: A viewer can open any individual season without affecting the collapsed/expanded
  state of any other season on the page.
- **SC-003**: All existing season and episode controls remain reachable and functional after a
  season is opened, with no loss of prior functionality.

## Assumptions

- No new user preference, setting, or persisted state is introduced; open/closed state is
  browser-native and resets on every render.
- No JavaScript or LiveView event handling is added — the browser alone owns disclosure state.
- Scope is limited to the TV series detail page; no other page's layout changes.
