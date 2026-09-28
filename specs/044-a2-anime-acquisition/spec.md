# Feature Specification: Anime Acquisition

**Feature Branch**: `044-a2-anime-acquisition`

**Created**: 2026-07-13

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-13-a2-anime-acquisition-design.md`), plan.md (originally `docs/superpowers/plans/2026-07-13-a2-anime-acquisition.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Find anime releases by alias, category, and absolute numbering (Priority: P1)

For an Anime-profile movie or series, the system additionally searches using stored title aliases,
the anime indexer category, and absolute/scene episode coordinates, on top of the existing
provider-ID search, so releases that don't use standard `SxxEyy` naming are still found.

**Why this priority**: Anime search must additively cover title aliases, category, and
absolute/scene coordinates so that releases which don't use standard `SxxEyy` naming can be found,
without altering existing Standard movie/TV search behavior.

**Independent Test**: Search for an Anime-profile series whose only available release uses an
absolute episode number and stored native alias; confirm it is found and correctly resolved to
canonical episode(s).

**Acceptance Scenarios**:

1. **Given** an Anime series with stored aliases, **When** a search runs, **Then** it queries the
   canonical title, each stored alias, and the anime category alongside the existing provider-ID
   query.
2. **Given** a release named with an absolute episode number, **When** it is parsed and resolved,
   **Then** it maps to the correct stable canonical episode ID(s) or is rejected as unmatched/
   ambiguous rather than guessed.
3. **Given** an Anime movie, **When** it is searched, **Then** the existing IMDb search runs plus a
   bounded set of category and alias queries, and any additive free-text match is verified against a
   title/year identity guard before automatic selection.

### User Story 2 - Select the best release across multiple wanted episodes (Priority: P1)

For an Anime series, the system evaluates candidate releases (including ones that batch or span
multiple episodes) and greedily assigns them to cover the wanted stable episode IDs.

**Why this priority**: Standard coordinates include cross-season `SxxEyy` batches, and absolute
values can span ranges; without stable-ID-aware selection, acquisition cannot correctly assign a
release spanning multiple wanted episodes.

**Independent Test**: Present a batch release covering several wanted episodes and a single-episode
release for a remaining one; confirm both are selected and no wanted episode is double-assigned.

**Acceptance Scenarios**:

1. **Given** two candidate releases that together disjointly cover all wanted episodes, **When**
   selection runs, **Then** both are chosen and no wanted ID is claimed by more than one release.
2. **Given** a candidate release resolving to an episode outside the current wanted set, **When**
   selection runs, **Then** the whole candidate is rejected rather than partially accepted.
3. **Given** a candidate resolves to no wanted episodes, **When** selection runs, **Then** it is not
   selected.

### User Story 3 - Wait for a preferred release group instead of settling for the first hit (Priority: P2)

Operators can configure preferred release groups and a fallback delay so acquisition waits for a
preferred-group release before falling back to any other eligible release, without burning retry
attempts while waiting.

**Why this priority**: Preferred-group waiting lets acquisition wait for a preferred-group release
before falling back to any other eligible release, without consuming a search attempt while waiting.

**Independent Test**: With a preferred group configured, present only a non-preferred candidate
before the fallback delay elapses; confirm the system reports it is waiting rather than grabbing or
consuming a search attempt.

**Acceptance Scenarios**:

1. **Given** only a non-preferred candidate exists and the fallback delay has not elapsed, **When**
   selection runs, **Then** the system reports it is waiting and does not consume a search attempt.
2. **Given** a preferred-group release becomes available, **When** selection runs, **Then** it is
   selected immediately regardless of the fallback delay.
3. **Given** a candidate has missing or invalid publication time, **When** selection runs, **Then**
   it is treated as manual-only and cannot bypass or extend the wait indefinitely.

### Edge Cases

- A release title that doesn't match any known canonical or alias title (after stripping bracketed
  groups and matching to a boundary) must fail the title-identity guard rather than being
  automatically selected.
- Malformed or partial provider/indexer metadata (bad category IDs, non-numeric size, unknown
  protocol, missing/invalid publish date) must degrade a single result safely without discarding
  valid sibling results or crashing the search pass.
- An anime coordinate range that is descending, overflowing, or unreasonably wide must be treated as
  unmatched rather than expanded.
- Episodic anime releases MUST NOT reach the existing importer in this phase; only anime-movie
  selection is activated end-to-end. Episodic selection and reservation logic ships fully tested but
  is not wired into live polling until the following phase.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST perform additive searches for Anime-profile titles using the canonical
  title, stored aliases, and the anime indexer category, alongside the existing provider-ID search,
  without altering Standard movie/TV search behavior.
- **FR-002**: System MUST parse anime release titles for explicit standard coordinates, bounded typed
  specials, and absolute episode numbers/ranges, distinguishing story content from extras (op/ed/
  trailer) and typed specials.
- **FR-003**: System MUST resolve every parsed coordinate value to stable canonical episode IDs
  through the existing precedence-aware resolver, rejecting the whole candidate on any unmatched or
  ambiguous value.
- **FR-004**: System MUST select releases via a greedy set-cover approach over wanted stable episode
  IDs, reusing existing hard filters (protocol, size, resolution, source), and MUST reject any
  candidate resolving to an episode outside the current wanted set.
- **FR-005**: System MUST support anime-movie acquisition through the existing movie pipeline,
  including an identity guard that requires an additive free-text candidate's title and year to
  match before automatic selection.
- **FR-006**: System MUST support optional preferred-release-group waiting with a configurable
  fallback delay, applied after hard filtering, such that waiting never consumes a search attempt and
  a release with missing/invalid publication time cannot be preferred.
- **FR-007**: System MUST persist an immutable snapshot of the mapping evidence used to select an
  episodic anime release, sufficient to survive a restart or later metadata refresh, without yet
  activating episodic import.
- **FR-008**: System MUST NOT allow an episodic anime release to reach the existing importer, grab,
  or any downloader/import side effect in this phase; only anime-movie selection is end-to-end
  active.
- **FR-009**: System MUST bound search fan-out (a fixed maximum number of aliases, wanted seasons,
  coordinate schemes, and total requests per pass) so anime search cannot become an unbounded
  Cartesian expansion.

### Key Entities

- **Release**: a candidate download carrying parsed coordinates, role, resolved episode IDs, and
  resolution evidence.
- **Anime Search Query Plan**: the bounded set of provider-ID, category, alias, and coordinate
  queries issued for a title's wanted episodes.
- **Mapping Snapshot**: the immutable evidence captured at selection time describing how a release's
  coordinates were resolved to stable episode IDs.
- **Preferred-Group Waiting State**: the transient eligibility/delay computation determining whether
  a release should be grabbed now or held for a preferred group.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An Anime-profile series with only an absolute-numbered or alias-titled release
  available is found and correctly grabbed, where it previously would not have matched any search
  query.
- **SC-002**: No episodic anime release reaches the existing importer or produces a downloader/grab/
  import side effect during this phase; only anime-movie grabs complete end-to-end.
- **SC-003**: Given overlapping candidate releases, the selected set together covers exactly the
  wanted episodes with no wanted episode claimed twice.
- **SC-004**: With a preferred group configured and unmet, acquisition never grabs a lesser candidate
  before the fallback delay and never depletes the retry/search budget while waiting.
- **SC-005**: Standard (non-anime) movie and TV search, scoring, and selection behavior remains
  byte-for-byte unchanged.

## Assumptions

- This is the second of six slices (A1–A6) of the umbrella Anime Media Handling feature
  (`040-anime-media-handling`); it builds on the A1 identity/resolver foundation and defers durable
  import/mapping-recovery behavior to A3, and persisted preference UI to A4, as explicitly scoped in
  the source design ("A2 does not include... episodic anime poller activation or any import
  behavior... persisted global or per-title group/audio/subtitle preferences").
- The repository-wide safety invariant that episodic anime content must not enter the existing
  importer until exact preflight exists (A3) is treated as a hard constraint of this phase, not a
  deferred nice-to-have.
- No new metadata provider, settings, migration column for preferences, or long-lived UI is added in
  this phase; preferred-group waiting exists only as call options.
