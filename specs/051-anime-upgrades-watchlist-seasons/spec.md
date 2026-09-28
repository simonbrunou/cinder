# Feature Specification: Anime TV Auto-Upgrades and Plex Watchlist Season Sync

**Feature Branch**: `051-anime-upgrades-watchlist-seasons`

**Created**: 2026-08-14

**Status**: Shipped (v2.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-14-next-session-feature-gaps.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Automatic Anime series upgrades (Priority: P1)

A household member holds an Anime series where a better release becomes available after the
original episode files were imported. Cinder should find and adopt those better releases the same
way it already does for Standard TV, without the household member doing anything.

**Why this priority**: This closes the one gap between Anime and Standard TV handling that left
Anime episodes permanently stuck at whatever quality was first grabbed.

**Independent Test**: Configure an Anime series below its upgrade cutoff, let a better release
appear, and confirm the episode file is replaced automatically while a series already at cutoff is
left untouched.

**Acceptance Scenarios**:

1. **Given** an Anime series with episodes below its configured upgrade cutoff, **When** the
   upgrade hunter runs, **Then** it searches, reserves, verifies, and imports a better release
   through the existing Anime search/reservation/verification/import paths.
2. **Given** an Anime series already at its configured cutoff, **When** the upgrade hunter runs,
   **Then** the series is skipped and no search is performed.
3. **Given** an upgrade search that returns a failed or ambiguous replacement, **When** the import
   attempt cannot be completed cleanly, **Then** the existing episode files remain available and
   untouched.

---

### User Story 2 - Plex watchlist expands a show into per-season requests (Priority: P2)

A Plex user with watchlist sync enabled adds a TV show to their Plex watchlist. Cinder should turn
that into requests for every season of the show currently known, respecting Cinder's per-season
request model, rather than ignoring TV watchlist entries entirely.

**Why this priority**: Watchlist sync previously handled only movies; shows on a watchlist were
skipped entirely, so the feature's TV coverage was missing.

**Independent Test**: Add a show to a synced Plex user's watchlist and confirm one request per
currently known numbered TMDB season is created under that user, each subject to their quota and
the household approval gate independently.

**Acceptance Scenarios**:

1. **Given** a Plex user with watchlist sync enabled adds a show to their watchlist, **When** the
   next watchlist sweep runs, **Then** Cinder submits one request per currently known numbered TMDB
   season for that show, attributed to that Plex user.
2. **Given** a submitted per-season request, **When** it is created, **Then** it passes through the
   same per-user quota and household approval path as a manually created season request.
3. **Given** a watchlisted show whose specials (Season 0) carry no season-level intent from Plex,
   **When** the watchlist expands into season requests, **Then** specials are not requested
   automatically and remain a manual choice.

---

### Edge Cases

- A series at its configured upgrade cutoff is skipped rather than searched.
- A failed or ambiguous upgrade replacement leaves existing episode files available rather than
  removing or replacing them speculatively.
- Standard (non-Anime) TV upgrade behavior is unchanged by the Anime upgrade addition.
- A season that could not be requested during watchlist expansion is retried, per the CHANGELOG
  v2.0.0 entry's "seasons that could not be requested are retried."
- Each expanded season request is still made as the watchlisting Plex user, so a per-user quota
  limit can independently block some of a show's seasons while approving others.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automatically search for upgrade candidates for an eligible Anime series
  using the existing Anime search, reservation, verification, and import paths.
- **FR-002**: System MUST respect each series' configured TV upgrade cutoff and skip searching once
  a series has reached it.
- **FR-003**: System MUST never downgrade an existing episode file during an automatic Anime
  upgrade attempt.
- **FR-004**: System MUST retain the current episode file until a replacement has been verified and
  committed.
- **FR-005**: System MUST leave existing episode files available when an upgrade search or import
  fails or is ambiguous.
- **FR-006**: System MUST leave Standard (non-Anime) TV upgrade behavior unchanged by this feature.
- **FR-007**: System MUST expand a watchlisted show into one request per currently known numbered
  TMDB season when Plex watchlist sync processes a TV title.
- **FR-008**: System MUST submit each expanded season request through the existing per-user
  request, quota, and approval path.
- **FR-009**: System MUST attribute each expanded season request to the Plex user whose watchlist
  produced it.
- **FR-010**: System MUST exclude specials (Season 0) from automatic watchlist expansion, since the
  watchlist entry carries no season-level intent.
- **FR-011**: System MUST retry a season that could not be requested during a watchlist expansion
  attempt (CHANGELOG v2.0.0: "seasons that could not be requested are retried").

### Key Entities *(include if feature involves data)*

- **Anime series**: A TV title using Anime handling, with a configured upgrade cutoff and episode
  mappings used by the search/reservation/verification/import pipeline.
- **Plex watchlist entry**: A title a Plex user has added to their watchlist, driving automatic
  request creation for that user.
- **Season request**: A per-season TV request submitted under a specific household member, subject
  to that member's quota and the household approval gate.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An eligible Anime series below its cutoff is searched and upgraded automatically
  without manual intervention.
- **SC-002**: A series at its configured cutoff produces zero automatic upgrade search attempts.
- **SC-003**: A failed or ambiguous automatic Anime upgrade never results in a lost or downgraded
  episode file.
- **SC-004**: Adding a show to a synced Plex user's watchlist results in a season request for every
  currently known numbered TMDB season, attributed to that user.
- **SC-005**: Specials are never auto-requested via Plex watchlist expansion.

## Assumptions

- Anime upgrades and Plex watchlist season sync are two small, independently shipped additions
  reusing existing pipelines (Anime search/reservation/verification/import for upgrades;
  per-user request/quota/approval for watchlist expansion) rather than introducing new mechanisms;
  they were not shipped in the same release (see the version note below).
- The following items were explicitly deferred at the time of this doc and are NOT part of this
  feature and NOT implemented here: arbitrary named library destinations beyond Standard and Anime
  (later addressed by named media profiles, v2.0.0); built-in backup scheduling and restore
  verification (the operating guide documents manual SQLite backups instead); additional download
  clients beyond qBittorrent, Transmission, SABnzbd, and NZBGet; and tracker-specific/RSS
  automation beyond Prowlarr's existing normalization.
- Anime upgrades shipped 2026-08-14 (changelog v1.1.0, "Automatic Anime TV upgrades"); Plex
  watchlist TV-season sync followed 2026-08-15 (changelog v2.0.0, "Plex watchlist TV-season sync").
