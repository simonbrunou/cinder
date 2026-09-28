# Feature Specification: Alternate-Season Numbering for Anime

**Feature Branch**: `047-a6-alt-season-numbering`

**Created**: 2026-07-17

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-17-a6-alt-season-numbering-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Find releases when TMDB and release-naming disagree on season boundaries (Priority: P1)

For an anime series where TMDB collapses multiple broadcast seasons into one (or otherwise splits
seasons differently than the way releases are actually named), an operator can choose the correct
alternate season grouping so wanted episodes become findable again.

**Why this priority**: Without this, an entire back half of a series (e.g. episodes 29–38 of a
38-episode single-TMDB-season anime) is permanently unfindable because no query Cinder emits matches
how indexers and release names describe it.

**Independent Test**: For a series whose TMDB season numbering doesn't match how releases are
actually numbered, select the matching alternate grouping and confirm a previously unmatchable
release for the missing episodes is now found and correctly selected.

**Acceptance Scenarios**:

1. **Given** a series with no alternate numbering chosen, **When** search runs, **Then** behavior is
   completely unchanged from today (the feature is off by default).
2. **Given** an operator selects an alternate season grouping for a series, **When** the choice is
   saved, **Then** the system derives and previews the resulting episode-to-alternate-season mapping
   before persisting it.
3. **Given** an alternate grouping is active and covers still-wanted episodes, **When** search runs,
   **Then** it additionally emits a season-scoped query using the alternate season number and accepts
   releases named with that alternate coordinate.

### User Story 2 - Never guess the correct alternate grouping automatically (Priority: P1)

The system never automatically selects or applies an alternate numbering grouping for a series; a
human always makes and can see the exact choice before it takes effect.

**Why this priority**: Per the A0 finding — no metadata signal is safe to auto-trust — the group
choice is always an explicit operator action; Cinder never auto-picks a grouping.

**Independent Test**: Confirm that with several distinct groupings available for a series, none is
applied without an explicit selection, and the derived mapping is visible before saving.

**Acceptance Scenarios**:

1. **Given** a series has multiple candidate groupings, **When** no operator has chosen one, **Then**
   no alternate numbering is active and search behavior is unchanged.
2. **Given** an operator is choosing a grouping, **When** they select a candidate, **Then** they see
   the derived season/episode mapping preview before saving it.
3. **Given** an operator clears the selection, **When** saved, **Then** the alternate mapping for that
   series is removed and search reverts to today's behavior.

### User Story 3 - Keep alternate numbering resilient to metadata drift (Priority: P2)

If the chosen grouping later fails to refresh (a fetch error, or the group being deleted upstream),
the previously synced alternate mapping stays in place rather than disappearing and breaking search.

**Why this priority**: A fetch failure or the upstream group becoming unavailable must not
silently strip search ability mid-course, so the previously synced alternate mapping is kept and
the failure is logged.

**Independent Test**: Simulate a refresh failure for a series with an active alternate grouping and
confirm the previously synced alternate coordinates and search ability are retained.

**Acceptance Scenarios**:

1. **Given** an active alternate grouping, **When** a refresh fetch fails or the group is no longer
   available upstream, **Then** the last-synced alternate coordinates are kept and the failure is
   logged.
2. **Given** an episode was manually corrected to a specific coordinate, **When** the alternate
   grouping is refreshed, **Then** the manual correction survives the refresh.
3. **Given** an episode is absent from the chosen group on refresh, **When** coordinates are synced,
   **Then** that episode simply has no alternate coordinate and falls back to today's behavior for it.

### Edge Cases

- A canonical coordinate value that both the standard numbering and the alternate numbering agree on
  must resolve using the standard (manual-precedence) mapping, never the alternate one.
- A release named with the alternate season/episode coordinate must resolve to the correct canonical
  episode and be selectable, matching a case that previously failed to match at all.
- A batch containing files named with the alternate coordinate must still be held entirely if any file
  in it is unmatched, exactly as the existing import safety invariant already requires.
- This capability is scoped to anime series only; movies are unaffected (they are queried by
  provider-ID only), and standard (non-anime) TV numbering ambiguity is explicitly out of scope for
  this phase.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow an operator to choose one alternate episode grouping per anime series
  from that series' available metadata-provided groupings, with no grouping chosen being the default
  (today's behavior).
- **FR-002**: System MUST show a preview of the derived alternate season/episode mapping before the
  operator's choice is saved, and MUST NOT apply any grouping without that explicit save.
- **FR-003**: Users MUST be able to clear a previously chosen grouping, which removes the derived
  alternate mapping for that series and reverts search to today's behavior.
- **FR-004**: System MUST derive an alternate season number and episode number for each episode in the
  chosen grouping and persist it as searchable alternate-numbering evidence for that series.
- **FR-005**: System MUST additionally search using the alternate season number for any still-wanted
  episode covered by an active alternate grouping, alongside the existing search queries.
- **FR-006**: System MUST resolve a release named with the alternate coordinate to the correct
  canonical episode, while a value known under both standard and alternate numbering MUST resolve via
  the higher-precedence standard mapping.
- **FR-007**: System MUST preserve the last successfully synced alternate mapping when a later refresh
  fails or the upstream grouping becomes unavailable, rather than discarding search ability.
- **FR-008**: System MUST preserve any manually corrected coordinate for an episode across an alternate
  grouping refresh.
- **FR-009**: System MUST NOT change import behavior: a batch resolved through alternate-numbering
  evidence is still subject to the existing exact-mapping safety invariant (any unmatched file holds
  the whole batch).
- **FR-010**: System MUST leave movie acquisition and standard (non-anime) TV search behavior
  unchanged.

### Key Entities

- **Alternate Season Grouping**: an operator-selected metadata grouping for a series that expresses a
  different season/episode split than the series' primary numbering.
- **Alternate Episode Coordinate**: the derived alternate season/episode value persisted per episode
  from the chosen grouping, used for search and resolution.
- **Grouping Mapping Preview**: the derived season-to-episode-range mapping shown to the operator
  before a grouping choice is saved.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a series whose broadcast seasons TMDB collapses but whose releases follow a
  different split, choosing the matching alternate grouping makes a release that previously resolved
  to no match now resolve to the correct episodes and get selected.
- **SC-002**: No alternate grouping is ever applied to a series without an explicit, visible operator
  choice.
- **SC-003**: A transient refresh failure or an upstream grouping disappearing never removes existing
  search ability for a series with an already-active alternate grouping.
- **SC-004**: A manual episode coordinate correction is never lost by an alternate-grouping refresh.
- **SC-005**: Standard (non-anime) TV search and all movie search behavior remain unaffected.

## Assumptions

- This is the sixth of six slices (A1–A6, with A5 being a non-code live-dogfood audit) of the umbrella
  Anime Media Handling feature (`040-anime-media-handling`); per ROADMAP.md, it closes the
  provider-numbering gap triggered by A5 live evidence via the Frieren and Re:Zero titles
  referenced in the source design and the A5 audit.
- Per ROADMAP.md (`[done 2026-07-19 — realized TMDB-internally, no second provider]`), this shipped as
  a **TMDB-internal** mechanism using TMDB's own episode groups (`series.scene_numbering_group_id`,
  an operator-only "Alternate numbering" picker on the series detail page). The source design
  document's speculative framing — that if TMDB's episode groups proved insufficient, an external
  provider (TheXEM / AniDB / anime-lists) might be added — did **not** occur: live evidence against
  the two triggering titles (Frieren, Re:Zero) showed TMDB's own groups already modeled the needed
  split, so no second metadata provider was ever introduced. This spec grounds its requirements on
  that as-shipped, TMDB-only outcome, and treats the design's external-provider option as an explicitly
  parked (not built) alternative.
- The capability is deliberately scoped to anime series only; extending equivalent alternate-numbering
  support to standard (non-anime) TV is tracked as separate, later, out-of-scope work per the source
  design.
