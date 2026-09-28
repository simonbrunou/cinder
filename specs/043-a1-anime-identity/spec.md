# Feature Specification: Anime Identity Foundation

**Feature Branch**: `043-a1-anime-identity`

**Created**: 2026-07-13

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/superpowers/plans/2026-07-13-a1-anime-identity-foundation.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Confirm a title as Anime without a new pipeline (Priority: P1)

An admin approving a request, or editing an existing movie/series, can explicitly set its handling
profile to Standard or Anime; leaving it on Auto never silently changes existing behavior.

**Why this priority**: Every later anime capability (A2–A6) depends on a persisted, explicit
per-title profile that never activates itself.

**Independent Test**: Set a series' profile to Anime and confirm search/scoring/import behavior is
otherwise identical to a Standard series until later phases add anime-aware logic.

**Acceptance Scenarios**:

1. **Given** a movie or series with no profile set, **When** no one confirms a profile, **Then** it
   remains effectively Standard even if provider evidence weakly suggests Anime.
2. **Given** a requester proposes a profile on their request, **When** an admin approves it, **Then**
   the confirmed profile is applied to the created/matched title.
3. **Given** auto-approve-all is enabled and a request carries an explicit proposed profile,
   **When** the request auto-approves, **Then** the proposal is applied; a request with no proposal
   preserves Auto.

### User Story 2 - Track alternative titles and episode coordinates per source (Priority: P1)

The system stores movie/series title aliases and series episode coordinates (absolute, scene, or
other provider numbering) scoped by source and namespace, with manual entries always outranking
provider-supplied ones.

**Why this priority**: Alias- and coordinate-aware search (A2) and mapping (A3) cannot exist without
a durable, precedence-ordered identity store.

**Independent Test**: Insert a manual alias/coordinate, then run a provider refresh, and confirm the
manual entry survives untouched while provider-owned rows in the same namespace are replaced.

**Acceptance Scenarios**:

1. **Given** a series with a provider-supplied episode coordinate, **When** the provider is
   refreshed, **Then** only that provider's own namespace rows are replaced.
2. **Given** a manually added alias or coordinate, **When** any provider refresh runs, **Then** the
   manual entry, media profile, and manual classification are never overwritten.
3. **Given** a coordinate value with both curated and inferred provider evidence, **When** it is
   resolved, **Then** manual precedence beats curated, and curated beats inferred.

### User Story 3 - Classify episodes without changing acquisition (Priority: P2)

Episodes gain a classification (regular, story special, recap, extra) sourced from providers or
operators, visible on the title but with no effect yet on search, scoring, or import.

**Why this priority**: Later phases (A4) own monitoring and acquisition policy built on top of
classification data, so it needs to already be flowing before they can act on it.

**Independent Test**: Classify an episode as a story special and confirm it has no observable effect
on wanted-episode queries or existing acquisition behavior.

**Acceptance Scenarios**:

1. **Given** a newly synced episode, **When** no explicit classification is provided, **Then** it
   defaults to regular.
2. **Given** an episode already manually classified, **When** a provider refresh runs, **Then** the
   manual classification is preserved.

### Edge Cases

- A title alias or coordinate row must belong to exactly one owner (movie or series), never both or
  neither.
- Coordinate membership (which stable episodes a coordinate resolves to) is ordered and cannot
  contain duplicate positions or duplicate episode membership for the same coordinate.
- A resolver call given ambiguous or unmatched coordinate evidence must report that outcome rather
  than guessing an episode.
- TMDB remains the only metadata provider; no second provider is introduced by this phase.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST support a per-title handling profile of Auto, Standard, or Anime on both
  movies and series, defaulting to Auto.
- **FR-002**: System MUST treat Auto as effectively Standard unless a profile is explicitly
  confirmed as Anime, even when provider evidence weakly suggests Anime.
- **FR-003**: Users MUST be able to propose Standard or Anime on a request; an admin approval (manual
  or auto-approve-all with an explicit proposal) MUST apply that confirmed profile.
- **FR-004**: System MUST store source-scoped title aliases for movies and series with a kind
  (alternative, licensed, romaji, native, scene) and a precedence (manual, curated, inferred).
- **FR-005**: System MUST store source-scoped episode coordinates for series (e.g. absolute
  numbering) and their ordered membership against stable canonical episodes.
- **FR-006**: System MUST apply manual-over-curated-over-inferred precedence whenever an alias or
  coordinate is resolved or refreshed.
- **FR-007**: A provider refresh MUST replace only rows it owns (matching source and namespace) and
  MUST NOT overwrite manual aliases, manual classifications, media profile, or previously returned
  resolver evidence.
- **FR-008**: System MUST provide a pure resolver that maps a candidate episode coordinate to an
  ordered set of stable canonical episode IDs, reporting unmatched or ambiguous evidence rather than
  guessing.
- **FR-009**: System MUST record an episode classification (regular, story special, recap, extra)
  sourced from a provider or an operator, defaulting to regular, with no effect on acquisition,
  search, or import behavior in this phase.
- **FR-010**: System MUST leave existing movie and episodic TV search, scoring, and import behavior
  unchanged for this phase; no acquisition, parser, or scorer work is introduced.

### Key Entities

- **Media Profile**: the confirmed or default handling mode (Auto/Standard/Anime) for a movie or
  series.
- **Title Alias**: an alternative title for a movie or series, scoped by source/namespace with a
  kind and precedence.
- **Episode Coordinate**: a source-scoped numbering scheme value for a series (e.g. an absolute
  episode number) with a precedence.
- **Episode Coordinate Membership**: the ordered link from an episode coordinate to one or more
  stable canonical episodes.
- **Episode Classification**: the narrative role (regular/story special/recap/extra) assigned to a
  canonical episode.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Confirming a title's profile as Anime or Standard never alters existing movie/TV
  search, scoring, or import outcomes for that title in this phase.
- **SC-002**: A provider metadata refresh never removes or overwrites a manually entered alias,
  coordinate, classification, or media profile.
- **SC-003**: Given any set of persisted aliases/coordinates for a value, the resolver always returns
  either one unambiguous, precedence-consistent set of stable episode IDs or an explicit
  unmatched/ambiguous result — never a silent partial or incorrect mapping.
- **SC-004**: A request's proposed profile is honored on both manual approval and auto-approve-all,
  and Auto is preserved whenever no proposal is present.

## Assumptions

- This is the first of six slices (A1–A6) of the umbrella Anime Media Handling feature
  (`040-anime-media-handling`); A1 delivers only the identity/profile/classification/resolver
  foundation with zero acquisition, download, or import behavior change, as explicitly scoped in the
  source plan ("No A2 acquisition/search/parser/scorer work and no A3 durable mapping/import state
  lands in A1").
- TMDB remains the sole metadata provider for this and subsequent anime phases per the plan; adding a
  second provider is explicitly out of scope.
- Anime is treated as a handling profile on the existing Movie/Series pipelines, not a third media
  type or a new pipeline.
