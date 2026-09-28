# Feature Specification: TV Data Model and Discovery (M4)

**Feature Branch**: `009-m4-tv-data-model-discovery`

**Created**: 2026-06-22

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-22-m4-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Series/season/episode data model (Priority: P1)

The system can represent a TV series as a tree of seasons and episodes, each with its own
monitoring state, without disturbing the existing movie pipeline in any way. Adding a series
persists its whole season/episode tree in one operation.

**Why this priority**: This is the foundational break from the movie pipeline's one-row-per-title
assumption — every later TV capability (acquisition, import) depends on this schema existing
first, landed safely behind monitoring flags with no active downloader yet.

**Independent Test**: Add a series and confirm its seasons and episodes are all persisted
together, each episode correctly flagged as monitored or not according to the chosen monitoring
strategy, while the existing movie test suite remains fully green.

**Acceptance Scenarios**:

1. **Given** an admin adds a series, **When** the add completes, **Then** the series along with
   every one of its seasons and episodes is persisted in a single consistent write.
2. **Given** a series is added with the default monitoring strategy, **When** its tree is
   persisted, **Then** only future (not-yet-aired) episodes are flagged as monitored, avoiding a
   flood of back-catalogue downloads.
3. **Given** a series is added with an "all" or "none" monitoring strategy, **When** its tree is
   persisted, **Then** every episode (including specials) is flagged accordingly, uniformly across
   every season.
4. **Given** the movie pipeline's full existing test suite, **When** this feature is added,
   **Then** every movie-pipeline test continues to pass unchanged.

---

### User Story 2 - TV discovery and per-episode monitoring control (Priority: P2)

An admin can search TMDB for TV shows, add one to the library, view its season/episode tree, and
toggle monitoring on or off for an individual episode or an entire season.

**Why this priority**: Without a way to search for and inspect series content, the data model
alone has no way for an admin to actually use TV support; this is the minimum UI needed to make
the schema from User Story 1 operable.

**Independent Test**: Search for a known TV show, add it, open its detail view, and toggle
monitoring on a single episode and confirm the change is reflected live.

**Acceptance Scenarios**:

1. **Given** an admin on the TV discovery page, **When** they search for a show title, **Then**
   matching results are returned from TMDB.
2. **Given** a search result, **When** the admin adds it, **Then** the series becomes visible in
   the library with its season/episode tree.
3. **Given** a series detail view, **When** the admin toggles monitoring on a single episode,
   **Then** only that episode's monitored flag changes.
4. **Given** a series detail view, **When** the admin toggles monitoring on an entire season,
   **Then** the change cascades to every episode in that season in one consistent write.

---

### Edge Cases

- A newly added series with the default strategy does not flood the download client, since only
  future episodes are monitored by default.
- Episode identity is tied to a TMDB-stable episode identifier where available so that later
  reconciliation against TMDB's renumbering is possible, but this identifier may legitimately be
  absent for a malformed or placeholder episode without failing the whole series add.
- TMDB's missing or empty air-date values are normalized to an absent date rather than treated as
  a "released" date, so future-only monitoring logic never depends on a malformed date string.
- Adding a series is admin-only and direct (no request/approval step) in this milestone, because no
  automated TV downloader exists yet to act on monitored flags — there is nothing an
  unauthorized-add could trigger.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST represent a TV series as its own entity distinct from a movie, composed
  of seasons, which are in turn composed of episodes.
- **FR-002**: System MUST persist an entire series' season/episode tree as a single consistent
  operation when the series is added.
- **FR-003**: System MUST support at least three monitoring strategies when adding a series:
  monitor only future episodes (the default), monitor all episodes, or monitor none.
- **FR-004**: System MUST apply the chosen monitoring strategy uniformly across every season of a
  series, including special/bonus seasons.
- **FR-005**: System MUST leave the existing movie pipeline's behavior and data completely
  unaffected by the introduction of TV data.
- **FR-006**: System MUST allow an admin to search for TV shows and add one to the library.
- **FR-007**: System MUST allow an admin to view a series' full season/episode tree after adding
  it.
- **FR-008**: System MUST allow an admin to toggle monitoring for an individual episode.
- **FR-009**: System MUST allow an admin to toggle monitoring for an entire season, applying that
  change to every episode within it in one consistent write.
- **FR-010**: System MUST restrict adding and monitoring TV series to admin users, since no
  automated download pathway consumes TV data yet in this milestone.
- **FR-011**: Users MUST be able to see live updates to a series' detail view when its monitoring
  state changes.

### Key Entities

- **Series**: A TV show tracked in the library, with a title, year, monitoring toggle, and default
  monitoring strategy for newly discovered content.
- **Season**: A numbered season belonging to a series, with its own monitoring toggle.
- **Episode**: A numbered episode belonging to a season, with a title, air date, and monitoring
  toggle; deliberately carries only identity and monitoring information at this stage, not
  download/pipeline state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A newly added series never results in monitoring the show's entire back catalogue by
  default — only future episodes are monitored unless the admin explicitly chooses otherwise.
- **SC-002**: Adding TV support introduces zero regressions to the movie pipeline, verified by the
  full pre-existing movie test suite continuing to pass unchanged.
- **SC-003**: An admin can go from searching for a show to viewing its per-episode monitoring state
  entirely within the app, with no manual database intervention.
- **SC-004**: Toggling monitoring at the season level always leaves every episode in that season
  consistent with the toggle — never a partial application.

## Assumptions

- This milestone intentionally ships the data layer and discovery UI without any TV
  acquisition/download logic — monitoring flags exist but nothing acts on them yet; that arrives
  in a later milestone (010).
- TV series creation is deliberately admin-only and direct (no request/approval gate), because
  without an active TV downloader there is no pipeline-entry risk to gate; the request-based flow
  for TV is deferred alongside acquisition.
- Per the roadmap, this milestone was executed in two parts — a data-layer session and a
  discovery-UI session — both completed on the same date and treated as one shipped feature here.
- Episode-level pipeline fields (file path, download linkage, search/import attempt counters) are
  explicitly deferred to the next milestone as a clean additive change, not included here.
