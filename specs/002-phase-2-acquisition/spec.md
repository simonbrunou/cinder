# Feature Specification: Acquisition — Finding the Best Release

**Feature Branch**: `002-phase-2-acquisition`

**Created**: 2026-06-18

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-18-phase-2-acquisition-design.md`), plan.md (originally `docs/superpowers/plans/2026-06-18-phase-2-acquisition.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Find the best available release for a requested movie (Priority: P1)

Given a movie's IMDb identifier, the system searches configured indexers for candidate releases
and automatically selects the single best one according to configurable rules (preferred
resolution, acceptable size range, and a blocked-release-group list), rather than surfacing a
raw list for a human to pick through.

**Why this priority**: This is the core value of the acquisition slice — turning "we want this
movie" into "here is the specific release to download" without manual triage, which every
downstream step (download, import) depends on.

**Independent Test**: Can be fully tested by calling the release-selection function with a mocked
indexer returning a fixed set of releases and asserting the correct one is chosen under a given
rule set.

**Acceptance Scenarios**:

1. **Given** an IMDb id and a set of candidate releases of mixed resolution and size, **When**
   the best release is requested, **Then** the system returns the release that best matches the
   preferred-resolution order, breaking ties by largest size within an acceptable size band.
2. **Given** every candidate release exceeds the configured maximum size, **When** the best
   release is requested, **Then** the system reports no match rather than selecting an
   oversized release.
3. **Given** a candidate release belongs to a blocked release group and would otherwise win on
   quality, **When** the best release is requested, **Then** that release is excluded and the
   next-best qualifying release is chosen instead.
4. **Given** no configured size limits, **When** the best release is requested, **Then** the size
   filter behaves as a no-op (does not reject anything on size grounds).

---

### User Story 2 - Extract structured attributes from a release's name (Priority: P1)

The system parses a release's file/torrent name to determine its resolution, video codec,
release group, and language, so the selection rules above have structured data to act on rather
than raw text.

**Why this priority**: Selection cannot happen without structured attributes; this is a
prerequisite building block for User Story 1.

**Independent Test**: Can be fully tested by feeding a table of real-world release names into the
parser and asserting the expected attribute map for each.

**Acceptance Scenarios**:

1. **Given** a well-formed scene release name (e.g. `Title.Year.1080p.BluRay.x264-GROUP`),
   **When** it is parsed, **Then** resolution, codec, and release group are all correctly
   extracted.
2. **Given** a movie title itself contains a hyphen (e.g. "Spider-Man"), **When** the name is
   parsed, **Then** the title fragment is never mistaken for a release group.
3. **Given** a release name with no identifiable group, resolution, codec, or language token,
   **When** it is parsed, **Then** each unrecognized field is reported as absent rather than
   guessed.
4. **Given** mixed-case tokens in the release name, **When** it is parsed, **Then** matching is
   case-insensitive and still succeeds.

---

### User Story 3 - Search an indexer for a movie by IMDb id (Priority: P2)

The system queries a configured indexer service using a movie's IMDb identifier and receives a
normalized list of candidate releases (title, size, download link, seeder count) for the
selection logic to evaluate.

**Why this priority**: This supplies the raw input to User Stories 1 and 2, but as an integration
concern behind a swappable interface it is lower-risk and more mechanical than the selection
logic itself.

**Independent Test**: Can be fully tested against a stubbed HTTP response asserting the indexer
query is built correctly and the response is normalized into the expected shape, with no real
network call.

**Acceptance Scenarios**:

1. **Given** an IMDb id, **When** the indexer is searched, **Then** the request is scoped to
   movie results for that identifier and returns a normalized list of releases with a usable
   download link, preferring a direct download link and falling back to a magnet link when
   necessary.
2. **Given** the indexer returns a non-success response, **When** the indexer is searched,
   **Then** the failure is reported as an error rather than raising or silently returning an
   empty list.

---

### Edge Cases

- A release name ending exactly on a source-hyphen token with no following field (e.g. ending on
  `WEB-DL`) is a known, accepted limitation that may parse a spurious short group token.
- A release name whose trailing group token is followed by a dotted suffix (e.g. `-GROUP.EXT`
  where `EXT` isn't a known container extension) yields no group rather than a wrong one.
- A release with no reported size is treated as zero bytes for size-band filtering.
- A release whose parsed group is unknown/absent can never match the blocklist.
- An unlisted or unrecognized resolution (including higher-than-preferred resolutions) is not
  rejected — it ranks last among survivors rather than being excluded.
- An empty candidate list from the indexer results in "no match," not an error or a crash.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST search a configured indexer service for release candidates matching a
  given movie's IMDb identifier.
- **FR-002**: System MUST normalize indexer results into a consistent shape (title, size,
  download link, seeder count) regardless of the underlying service's response format.
- **FR-003**: System MUST extract resolution, video codec, release group, and language from each
  candidate release's name, treating any field it cannot confidently identify as unknown.
- **FR-004**: System MUST reject candidate releases whose reported size falls outside a
  configurable acceptable size range, when such a range is configured.
- **FR-005**: System MUST exclude candidate releases whose release group appears on a
  configurable blocklist, evaluated case-insensitively.
- **FR-006**: System MUST select, among surviving candidates, the release that best matches a
  configurable ordered list of preferred resolutions, breaking ties by preferring the larger
  file.
- **FR-007**: System MUST report "no match" (not an error) when no candidate release survives
  filtering, and MUST report "no match" when the indexer returns zero candidates.
- **FR-008**: System MUST report indexer or network failures as errors distinct from "no match,"
  so callers can distinguish "nothing qualified" from "the search itself failed."
- **FR-009**: System MUST resolve a movie's IMDb identifier as part of enabling indexer search,
  carrying it through from the movie catalog lookup.

### Key Entities

- **Release**: A candidate download option for a movie, combining indexer-reported facts (title,
  size, download link, seeder count) with attributes parsed from its name (resolution, codec,
  release group, language).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Given a fixed set of candidate releases and a fixed rule configuration, release
  selection is fully deterministic — the same inputs always produce the same chosen release.
- **SC-002**: A blocklisted release group is never selected even when it would otherwise be the
  top-ranked candidate on quality alone.
- **SC-003**: No release outside a configured acceptable size range is ever selected.
- **SC-004**: An indexer outage or malformed response never crashes the selection process; it is
  always surfaced as a distinguishable error or "no match" outcome.

## Assumptions

- Scope is a pure library slice: indexer search, name parsing, and rule-based selection are built
  and unit-tested, but nothing yet triggers acquisition automatically from a requested movie, and
  no download or status-transition wiring exists — that is deferred to later phases.
- The indexer integration targets one specific indexer aggregation service (via its JSON API)
  rather than a generic protocol; swapping transports later is possible because the integration
  sits behind a swappable interface.
- Language is parsed from release names as a named field even though nothing yet scores or
  filters on it — parsing is in scope, language-based preference is deferred.
- Seeder count is carried through on each candidate for future use but is not part of the
  selection ranking in this phase.
- The live behavior of the real indexer service (per-indexer quirks, live field population) is
  validated only in a later phase's live smoke test; this phase's indexer client tests run fully
  offline against stubbed responses.
