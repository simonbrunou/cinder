# Feature Specification: Subtitles Engine

**Feature Branch**: `030-subtitles-engine`

**Created**: 2026-07-07

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-07-07-subtitles-engine-design.md`), plan.md (originally `docs/plans/2026-07-07-subtitles-engine.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Subtitles are fetched automatically for newly imported media (Priority: P1)

A household with a subtitle language preference set wants imported movies and TV episodes to
automatically get subtitle files in their chosen languages, without running a separate service.

**Why this priority**: This is the primary value proposition — playback with subtitles, owned
entirely by the system, with zero manual effort per title.

**Independent Test**: Import a movie with subtitle languages configured, and confirm a subtitle
file for each configured language is fetched and placed alongside the video without affecting the
import itself.

**Acceptance Scenarios**:

1. **Given** the household has configured one or more subtitle languages, **When** a movie or
   episode finishes importing, **Then** the system searches for and downloads a subtitle file for
   each configured language that doesn't already have one, placed next to the video file.
2. **Given** no subtitle languages are configured, **When** media is imported, **Then** no
   subtitle search or download occurs — the feature is entirely inert.
3. **Given** the subtitle provider is unreachable or returns an error during import, **When** the
   import proceeds, **Then** the video import still completes successfully and the title becomes
   available; the subtitle fetch failure never blocks or fails the import.

---

### User Story 2 - Subtitles uploaded after the fact are backfilled (Priority: P2)

A household wants titles that didn't have a subtitle available at import time to automatically
pick one up later, once it's been uploaded to the provider.

**Why this priority**: Subtitle availability on the provider changes over time; a one-shot
at-import search alone would permanently miss subtitles uploaded afterward.

**Independent Test**: Simulate an available movie missing a subtitle for a configured language, run
the periodic sweep, and confirm the missing subtitle is fetched; confirm a movie that already has
its subtitle is skipped.

**Acceptance Scenarios**:

1. **Given** an available movie or an imported episode is missing a subtitle file for a configured
   language, **When** the periodic sweep runs, **Then** the system searches for and fetches that
   subtitle.
2. **Given** a movie already has a subtitle file for every configured language, **When** the sweep
   runs, **Then** no search or fetch happens for that title.
3. **Given** no subtitle languages are configured, **When** the sweep runs, **Then** it takes no
   action at all.

---

### Edge Cases

- A configured language whose subtitle file already exists on disk is skipped without a provider
  call.
- Deleting an existing subtitle file causes it to be re-fetched on the next sweep; adding a new
  configured language causes it to be backfilled on the next sweep — no manual re-trigger needed.
- The provider's daily download quota is exhausted mid-sweep; fetching stops for that tick without
  erroring, and unaffected titles are unaffected (re-searching for a still-missing subtitle does
  not itself consume quota).
- A candidate subtitle result marked hearing-impaired or machine-translated is never selected, even
  if it otherwise would rank highest.
- A still-missing subtitle is retried on every sweep with no permanent give-up marker, since
  repeated searches are inexpensive.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to configure a global list of desired subtitle languages,
  independent of any per-title audio-language preference.
- **FR-002**: System MUST treat a blank subtitle-language configuration as the feature being fully
  off — no searches or fetches occur.
- **FR-003**: System MUST attempt to fetch a subtitle for each configured language for a movie or
  episode at the time it is imported.
- **FR-004**: System MUST periodically re-check the library and fetch any subtitle that is still
  missing for a configured language, so subtitles uploaded to the provider after import are
  eventually picked up.
- **FR-005**: System MUST determine whether a subtitle is needed by checking for the sidecar file's
  presence on disk, not by tracking a separate completion record — so removing or adding a sidecar
  file changes future fetch behavior automatically.
- **FR-006**: A subtitle fetch failure, at import time or during the periodic sweep, MUST NOT
  block, delay, or fail the underlying video import or any other pipeline action.
- **FR-007**: System MUST exclude hearing-impaired and machine-translated subtitle candidates when
  selecting which one to download.
- **FR-008**: When multiple subtitle candidates exist for a language, System MUST select the one
  with the most downloads on the provider.
- **FR-009**: System MUST respect the subtitle provider's daily download quota, stopping further
  downloads for the remainder of that period once exhausted, without treating that as an error
  condition.
- **FR-010**: Users MUST be able to configure their subtitle-provider credentials from the in-app
  settings page, with a way to verify the connection is working.

### Key Entities

- **Subtitle Sidecar**: A per-language subtitle file placed alongside an imported video's file,
  whose mere presence or absence on disk determines whether a fetch is needed for that language.
- **Subtitle Candidate**: A single subtitle result returned by the provider for a search, carrying
  attributes such as language, download count, and hearing-impaired/machine-translated flags, used
  to pick the best match.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A household with subtitle languages configured has subtitles present for newly
  imported titles without any manual per-title action.
- **SC-002**: A title missing a subtitle at import time acquires one automatically within one
  sweep interval once it becomes available on the provider.
- **SC-003**: Zero video imports are ever blocked, delayed, or failed due to a subtitle-provider
  outage or error.
- **SC-004**: A household with the feature turned off (blank language list) observes zero
  additional network calls or processing related to subtitles.

## Assumptions

- Only one subtitle provider (OpenSubtitles.com) is integrated; a multi-provider registry is
  explicitly deferred as unnecessary until a second provider is actually wanted.
- Subtitle matching is done by the title's known identifiers (not by fuzzy title text or file-hash
  matching); this can occasionally produce a subtitle timed to a slightly different release than
  the one imported — an accepted sync-accuracy ceiling, with file-hash-based matching noted as the
  future upgrade path (see the follow-on moviehash feature).
- Only plain, non-forced, non-hearing-impaired subtitle variants are fetched; forced and SDH
  variants are out of scope.
- No database table tracks subtitle state; the filesystem itself is the source of truth for what
  still needs fetching, consistent with the project's existing derived-state approach.
