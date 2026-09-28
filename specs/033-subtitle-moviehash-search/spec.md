# Feature Specification: Subtitle Search by Moviehash

**Feature Branch**: `033-subtitle-moviehash-search`

**Created**: 2026-07-09

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-07-09-subtitle-moviehash-design.md`), plan.md (originally `docs/plans/2026-07-09-subtitle-moviehash.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Subtitles chosen for a file are synced to that exact release (Priority: P1)

A user who has a movie or episode file wants the subtitle the system fetches for it to actually be
timed correctly to their specific release, not just any subtitle for the right title.

**Why this priority**: This is the entire value of the feature — the previous identifier-only
search could return a subtitle timed to a different release of the same title, leading to
out-of-sync subtitles that require manual adjustment; a file-derived hash lets the provider return
subtitles proven to be synced to this exact rip.

**Independent Test**: Fetch a subtitle for a file where the provider has both an identifier-matched
candidate and a hash-matched candidate available, and confirm the hash-matched one is chosen even
if it has fewer downloads than the alternative.

**Acceptance Scenarios**:

1. **Given** an imported movie or episode file is at least 128 KiB in size, **When** the system
   searches for a subtitle for it (at import time or during the periodic sweep), **Then** it
   computes a fingerprint of the file and includes it in the subtitle search alongside the existing
   title/episode identifiers.
2. **Given** the subtitle search returns both a candidate confirmed to match the file's exact
   fingerprint and a candidate that doesn't but has more downloads, **When** the best candidate is
   selected, **Then** the fingerprint-matched candidate is chosen.
3. **Given** no fingerprint-matched candidate exists among the results, **When** the best candidate
   is selected, **Then** selection falls back to the existing most-downloaded rule exactly as
   before this feature.

---

### User Story 2 - A file too small or unreadable to fingerprint still gets subtitles the old way (Priority: P2)

A user whose file can't be fingerprinted for any reason should not lose subtitle-fetching
capability entirely — the system should fall back cleanly to identifier-only search.

**Why this priority**: Ensures this feature is a strict improvement with no regression path; a file
that can't be hashed must not end up worse off than before the feature existed.

**Independent Test**: Attempt a subtitle fetch for a file too small to fingerprint (or one that
can't be read), and confirm the subtitle search still proceeds using only the title/episode
identifiers, exactly as it did before this feature.

**Acceptance Scenarios**:

1. **Given** a video file is smaller than the minimum size needed to compute a fingerprint,
   **When** a subtitle fetch is attempted for it, **Then** the search proceeds using only the
   existing identifier-based criteria, with no fingerprint included.
2. **Given** a video file cannot be read for any reason during fingerprinting, **When** a subtitle
   fetch is attempted for it, **Then** the failure is silently absorbed and the search proceeds
   using only the existing identifier-based criteria — a fingerprinting problem never blocks or
   fails a subtitle fetch.

---

### Edge Cases

- A subtitle candidate whose fingerprint-match flag is malformed or missing in the provider's
  response is treated as not matched, so it is never incorrectly preferred.
- Neither an identifier match nor a fingerprint match exists for a file — behavior is identical to
  before this feature (no subtitle found).
- The fingerprint computation is applied automatically to every fetch attempt (both at import and
  during the periodic sweep) with no per-household setting to turn it on or off.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST compute a fingerprint of an imported video file's content and include it
  in every subtitle search, alongside the existing title/episode-based search criteria.
- **FR-002**: When multiple subtitle candidates are available for a language, System MUST prefer
  one confirmed to be synced to the file's exact fingerprint over one that is not, even if the
  non-matched candidate has more downloads.
- **FR-003**: System MUST fall back to the existing most-downloaded-candidate selection when no
  fingerprint-matched candidate is available among the results.
- **FR-004**: System MUST continue to search using the existing title/episode identifiers even when
  a fingerprint is available — fingerprint search MUST supplement, not replace, identifier search.
- **FR-005**: System MUST omit the fingerprint from a search when the file is too small or cannot
  be read, and MUST still proceed with the identifier-based search in that case rather than
  skipping the fetch entirely.
- **FR-006**: This feature MUST require no new user-facing setting, environment variable, or
  configuration — fingerprinting happens automatically whenever a file exists to fingerprint.
- **FR-007**: System MUST NOT drop or replace the existing identifier-based subtitle search with
  free-text title matching — identifier search plus the new fingerprint remain the only search
  strategies.

### Key Entities

- **File Fingerprint**: A value derived from a video file's size and portions of its content, used
  to identify subtitles proven to be synced to that exact file rather than merely the same title.
- **Subtitle Candidate Match Flag**: An indicator on each subtitle search result denoting whether
  that candidate is confirmed synced to the searched file's fingerprint.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user's fetched subtitles are measurably more often correctly synced to their exact
  file than under the previous identifier-only search, whenever a fingerprint-matched candidate
  exists.
- **SC-002**: Zero regressions in subtitle-fetch coverage — every file that could get a subtitle
  before this feature can still get one, since fingerprinting only adds a preference layer on top
  of the existing search.
- **SC-003**: A file that cannot be fingerprinted (too small or unreadable) experiences no
  difference in subtitle-fetch behavior compared to before this feature existed.

## Assumptions

- Free-text title-based subtitle search is explicitly out of scope — every title already has a
  reliable identifier, so a fuzzier title-match path would never fire or improve results.
- Fingerprint computation is not cached between fetch attempts; it is recomputed each time a
  fetch is attempted, accepted as inexpensive at household scale.
- Only one subtitle provider is supported (unchanged from the underlying subtitles engine); this
  feature does not introduce provider-agnostic fingerprinting or a second provider.
- This feature supersedes only the identifier-only search limitation of the prior subtitles engine
  feature; all other behavior of that engine (language configuration, best-effort import handling,
  periodic sweep, hearing-impaired/machine-translated exclusion) is unchanged.
