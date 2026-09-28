# Feature Specification: M6 — TV Monitoring Sweep, TMDB Refresh & Calendar

**Feature Branch**: `011-m6-tv-monitoring-sweep`

**Created**: 2026-06-22

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-22-m6-design.md`), plan.md (originally `docs/plans/2026-06-22-m6-tv-monitoring-sweep-calendar.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A monitored episode that just aired becomes searchable automatically (Priority: P1)

A household added a show while an episode's air date was still unknown or in the future. Once that date passes, the system should recognize the episode as eligible for search and grab it without any manual action.

**Why this priority**: This is the milestone's stated Done-when — closing the Sonarr-style monitoring loop is the entire reason the milestone exists.

**Independent Test**: Add a series with an episode whose air date is unknown; simulate a TMDB refresh that fills in a past air date; verify the episode appears in the wanted-episodes set and the search sweep grabs it.

**Acceptance Scenarios**:

1. **Given** an episode monitored under a future-air-date strategy with no air date, **When** a periodic TMDB refresh fills in a past air date, **Then** the episode becomes visible to the wanted-episodes query and is grabbed on the next search pass.
2. **Given** an episode that already has a correct past air date at add time, **When** time passes that date, **Then** it becomes search-eligible automatically with no flag to flip.

---

### User Story 2 - Series and episode metadata stays current with TMDB (Priority: P2)

As TMDB adds new seasons/episodes to a show or renumbers existing ones, the local catalog should reflect those changes without losing locally-tracked state (monitoring, file, grab status).

**Why this priority**: Without periodic reconciliation, air dates go stale and newly-announced seasons never appear locally, defeating the wanted-episode sweep.

**Independent Test**: Run a refresh against a mocked TMDB response containing an updated episode, a new episode, and a new season; verify existing rows update in place, new rows are inserted with the series' monitor strategy applied, and vanished rows are left untouched.

**Acceptance Scenarios**:

1. **Given** a stored episode matched by its TMDB episode id, **When** the refresh runs, **Then** its air date, episode number, title, and season are updated in place while its monitored/file/grab state is preserved.
2. **Given** a TMDB episode with no matching stored row, **When** the refresh runs, **Then** it is inserted under its season with monitoring applied per the series' strategy.
3. **Given** a new season announced on TMDB, **When** the refresh runs, **Then** the season and its episodes are inserted, monitored per the strategy.
4. **Given** a stored episode absent from the TMDB response, **When** the refresh runs, **Then** the row is left untouched (never deleted).
5. **Given** TMDB renumbers/reorders episodes mid-season, **When** the refresh runs, **Then** all displaced rows are moved to their new numbers in one pass without collisions or orphaned/duplicate rows.

---

### User Story 3 - Household sees upcoming and current episode availability at a glance (Priority: P3)

A household member wants a single place to see which episodes are already available, downloading, wanted, or upcoming, ordered by air date.

**Why this priority**: Completes the loop's visibility — the sweep and refresh are invisible without a surfaced view, and this was the milestone's third explicit deliverable.

**Independent Test**: Seed episodes across the four derived states within the calendar's date window; open the calendar view and verify each renders with the correct state badge in air-date order.

**Acceptance Scenarios**:

1. **Given** monitored episodes with air dates within a recent-to-near-future window, **When** a user opens the calendar view, **Then** they are listed in ascending air-date order with a badge reflecting Available, Downloading, Wanted, or Upcoming state.
2. **Given** a series update is broadcast (e.g. a refresh just ran), **When** the calendar view is open, **Then** it re-queries and its badges stay live without a manual reload.

---

### Edge Cases

- An episode's air date collides with another episode during renumbering because the target slot is still held by a vanished (untracked-by-TMDB) row — this collision is logged and skipped, not fatal.
- Specials (season number 0) are excluded from the wanted-episode search sweep (the release parser/scorer cannot address season 0), though refresh still keeps their tree data current.
- A TMDB fetch failure for one series during a refresh tick does not prevent other series from being refreshed.
- The wanted-episodes query must not degrade to scanning the full episode table as the catalog grows.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST treat a monitored episode as search-eligible automatically once its air date is in the past, with no manual state transition required.
- **FR-002**: System MUST periodically re-fetch each monitored series' season/episode data from the external metadata source and reconcile it against stored records.
- **FR-003**: System MUST update an existing episode's air date, episode number, title, and season assignment when metadata changes, while preserving its monitored, file, grab, and search-attempt state.
- **FR-004**: System MUST insert newly-announced episodes and seasons discovered during a refresh, applying the series' configured monitoring strategy to them.
- **FR-005**: System MUST NOT delete or modify a locally-tracked episode/season that is no longer present in the external metadata source.
- **FR-006**: System MUST correctly reconcile a mid-season episode renumbering or reorder in a single pass, without leaving stale numbering, orphaned rows, or duplicate rows.
- **FR-007**: The search sweep MUST query only the wanted subset of episodes (monitored, missing, not already grabbing, aired), not scan every episode.
- **FR-008**: Users MUST be able to view an upcoming/calendar list of monitored episodes within a bounded recent-to-future date window, ordered by air date.
- **FR-009**: The calendar view MUST show each episode's derived availability state (available, downloading, wanted, or upcoming) and MUST refresh live when underlying series data changes.
- **FR-010**: System MUST leave the existing movie pipeline behavior completely unaffected by this feature.

### Key Entities

- **Series**: A monitored show tracked from the external metadata source, with an overall monitoring strategy.
- **Season**: A numbered season belonging to a series, itself individually monitorable.
- **Episode**: A numbered episode belonging to a season, carrying identity (title, air date), monitoring flag, and pipeline state (file/grab linkage).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An episode that transitions from "air date unknown" to "aired" via a routine metadata refresh is grabbed automatically without any user action, verified end-to-end.
- **SC-002**: The query that selects wanted episodes for the search sweep executes via an index lookup rather than a full table scan, regardless of catalog size.
- **SC-003**: A show's mid-season episode reorder is fully reconciled (correct numbers, no duplicates/orphans) in a single reconciliation pass.
- **SC-004**: Household members can see all currently airing/near-term episodes and their availability state in one place, always reflecting the latest known data.
- **SC-005**: The existing movie pipeline test suite remains fully passing after this feature ships (no regression).

## Assumptions

- Metadata freshness is achieved by polling the external metadata source on a long interval (not per-tracker RSS), matching the "leanest cut" decision in the design doc.
- Specials (season 0) grabbing remains out of scope; only their tree data is kept current.
- Per-episode TV size-band configuration and vanished-row deletion/un-monitoring are explicitly deferred to later milestones.
- Re-syncing an already-added series' metadata is handled solely by the periodic refresh, not by re-running the add flow.
