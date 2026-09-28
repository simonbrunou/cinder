# Feature Specification: Stalled Download Reaper

**Feature Branch**: `048-stalled-download-reaper`

**Created**: 2026-07-21

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-21-stalled-download-reaper-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dead downloads free themselves automatically (Priority: P1)

Why this priority: a dead torrent swarm or frozen job otherwise sits forever with no forward
progress and no automatic recovery — this is the core value of the feature.

**Independent Test**: simulate a torrent download reporting zero speed past the configured
threshold and confirm it is removed, blocklisted, and the item re-searches for a different
release.

**Acceptance Scenarios**:

1. **Given** a movie download with zero connected seeders and no speed for the no-seeders
   window, **When** the next check runs, **Then** the download is removed from the client, its
   release is blocklisted, and the movie returns to searching for a different release.
2. **Given** a torrent stalled with some or unknown seeders past the longer stall window,
   **When** checked, **Then** the same reap occurs.
3. **Given** a usenet download reporting no speed, **When** checked, **Then** it is never
   reaped — stall detection applies to torrents only.

### User Story 2 - Reaped releases are recoverable, not banned forever (Priority: P2)

Why this priority: a slow-but-alive release wrongly reaped must not be permanently forbidden;
recoverability keeps the feature safe to run automatically.

**Independent Test**: manually retry a movie that has a stall-caused blocklist entry and
confirm that specific entry clears while other blocklist reasons remain.

**Acceptance Scenarios**:

1. **Given** a movie whose only blocklisted release was blocklisted for stalling, **When**
   the operator performs a manual Retry, **Then** that stall-caused entry is cleared while any
   entries blocked for other reasons stay in place.
2. **Given** a TV episode or season with a stall-caused blocklist entry, **When** the operator
   uses manual "search now," **Then** the series' stall-caused entries are cleared.
3. **Given** the automatic search sweep runs (no manual action), **When** it encounters a
   stall-caused blocklist entry, **Then** it continues to respect it so recovery converges
   instead of thrashing.

### User Story 3 - Upgrades and TV grabs are covered too (Priority: P3)

Why this priority: the feature's scope explicitly includes stalled upgrade replacements and
stalled TV grabs, not only first-time movie downloads.

**Independent Test**: simulate a stalled upgrade replacement download and confirm the movie
reverts to its previous state keeping its existing file.

**Acceptance Scenarios**:

1. **Given** a movie mid-upgrade whose replacement download stalls, **When** reaped, **Then**
   the movie reverts to its prior available state, its existing playable file is untouched,
   and the stalled replacement is removed from the client and blocklisted.
2. **Given** a TV grab (episode or season) stalls, **When** reaped, **Then** the grab and its
   client download are torn down, affected episodes return to wanted for re-search, and the
   release is blocklisted recoverably.

### Edge Cases

- Stall detection is fully disabled by configuration → nothing is ever reaped.
- A user cancels the same item at the same moment a reap would occur → the reap
  safely does nothing rather than clobbering the user's action.
- A title with many slow-but-genuinely-downloading releases exhausts its candidates over
  repeated reaps and parks at "no match," recoverable via Retry as above.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST detect a torrent download making no forward progress (zero speed)
  for a configurable time window and treat it as stalled.
- **FR-002**: System MUST use a shorter stall window when a torrent has no connected peers,
  and a longer window otherwise.
- **FR-003**: System MUST NOT apply stall detection to usenet downloads.
- **FR-004**: On detecting a stalled movie download, system MUST remove the download (and its
  data) from the client, blocklist the stalled release, and reset the movie to search for a
  different release.
- **FR-005**: On detecting a stalled upgrade replacement download, system MUST revert the
  movie to its prior available state, leave its existing playable file untouched, remove the
  stalled replacement from the client, and blocklist the stalled release.
- **FR-006**: On detecting a stalled TV grab, system MUST remove the grab and its client
  download, return affected episodes to wanted for re-search, and blocklist the stalled
  release.
- **FR-007**: System MUST treat a stall-caused blocklist entry as recoverable, distinct from a
  permanently blocklisted release.
- **FR-008**: Users MUST be able to clear a movie's stall-caused blocklist entries via a
  manual Retry action.
- **FR-009**: Users MUST be able to clear a series' stall-caused blocklist entries via a
  manual search-now action on an episode or season.
- **FR-010**: System MUST NOT clear stall-caused blocklist entries during the automatic
  search sweep.
- **FR-011**: System MUST allow stalled-download detection to be enabled or disabled.
- **FR-012**: System MUST log each reap so an operator can observe when and why it happened.

### Key Entities

- Download / grab
- Release
- Blocklist entry
- Movie
- TV episode / season

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A dead torrent swarm is detected and reaped within its configured window with
  no user interaction required.
- **SC-002**: A stalled item's next automatic search selects a different release than the one
  just reaped.
- **SC-003**: An operator can restore eligibility of a previously reaped release with a
  single manual action (Retry or search-now).
- **SC-004**: Usenet downloads are never affected by stall detection.
- **SC-005**: An upgrading movie that stalls never loses its existing playable file.

## Assumptions

- The feature is opt-in by design (a single enable/disable setting); the shipped default
  configuration turns it on, an operator decision distinct from the feature's own off-by-default
  design.
- The specific no-seeders and general stall time windows are operator-configurable; the
  shipped default values are an implementation detail, not a fixed user-facing contract.
- No dedicated UI was added for this feature in v1 — visibility rides the existing
  activity/notification surfaces already shown for other state transitions.
- The original design proposed a dedicated stall-start timestamp; the shipped implementation
  derives staleness a different way — an internal detail with no user-visible difference.
