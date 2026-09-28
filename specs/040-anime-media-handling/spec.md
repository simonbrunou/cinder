# Feature Specification: Anime-Aware Media Handling

**Feature Branch**: `040-anime-media-handling`

**Created**: 2026-07-12

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-12-anime-media-handling-design.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Confirm a title as Anime without losing standard behavior (Priority: P1)

An administrator (or a requester proposing a new title) marks a movie or series as Anime. This
changes discovery, release matching, numbering, and preferences for that title only; the title
still lands in the existing movie/TV library layout and stays visible to Jellyfin/Plex exactly as
before.

**Why this priority**: The whole feature is worthless if turning Anime on for one title silently
changes the filesystem contract or affects other titles.

**Independent Test**: Set a series' profile to Anime, verify its files still land under
`Season NN/... - SxxEyy.ext`, and verify an unrelated Standard series is completely unaffected.

**Acceptance Scenarios**:

1. **Given** a series defaulting to `Auto`, **When** no explicit Anime confirmation exists,
   **Then** the series behaves exactly like Standard even if weak signals (Animation genre,
   Japanese origin) are present.
2. **Given** an administrator explicitly sets a series to Anime, **When** a later metadata refresh
   runs, **Then** the explicit choice survives and is never silently reverted.
3. **Given** a requester proposes Anime on a new title request, **When** an administrator approves
   it, **Then** the confirmed profile is applied; without household auto-approve trust, a proposal
   alone does not change acquisition.

### User Story 2 - Find and grab the correct anime release (Priority: P1)

Cinder searches using native/romaji/licensed/scene title aliases and anime indexer categories in
addition to normal season/episode queries, correctly parses absolute, scene, and split-cour
numbering, and scores/selects releases honoring audio/subtitle/release-group preferences.

**Why this priority**: Anime releases commonly use absolute numbering, batch ranges, and
dual-audio tags that the standard season/episode search and parsing pipeline does not handle.

**Independent Test**: Search a fixture anime title numbered absolutely (e.g. `One Piece 1122v2`,
CHANGELOG v1.1.0: "releases like `One Piece 1122v2` resolve without TMDB season math") and confirm
the correct episode coordinate and release are selected, while an unrelated standard TV search's
results are unchanged.

**Acceptance Scenarios**:

1. **Given** an Anime-profile series with only absolute-numbered releases available, **When**
   Cinder searches, **Then** it finds and correctly maps a release like `1122v2` to the right
   canonical episode without requiring `SxxEyy` in the title.
2. **Given** configured preferred release groups and a fallback delay, **When** only a non-preferred
   group's release is currently available, **Then** Cinder waits without spending a search attempt
   until the fallback delay passes, then grabs the next-best option.
3. **Given** a release whose actual downloaded audio/subtitles fail a hard configured requirement,
   **When** post-download verification runs, **Then** Cinder rejects and blocklists that exact
   release and re-searches instead of staging it.

### User Story 3 - Never file away an ambiguous anime batch (Priority: P1)

When a downloaded anime batch contains any video that is unidentified, ambiguously mapped, a
duplicate claim on the same episode, or outside the grab's reserved episodes, Cinder holds the
entire batch as `Needs mapping` instead of guessing, and lets an administrator resolve it.

**Why this priority**: This is the feature's defining safety rule (research.md): Cinder must not
stage, finalize, delete, or reinterpret a downloaded anime file until every video is uniquely
mapped or explicitly ignored as an extra.

**Independent Test**: Download a batch with one unrecognizable filename among otherwise-mapped
episodes and confirm the whole batch is held, not partially imported.

**Acceptance Scenarios**:

1. **Given** a batch where every video maps to exactly one reserved episode and every reserved
   episode is claimed exactly once, **When** import runs, **Then** staging proceeds normally.
2. **Given** a batch containing one unknown or duplicate-claimed video, **When** import runs,
   **Then** the entire batch enters `Needs mapping` with no partial filesystem write and no attempt
   counter incremented.
3. **Given** an administrator corrects the grab-local mapping for a held batch, **When** they retry
   import, **Then** the same full safety check reruns before anything is staged.

### Edge Cases

- A weak anime signal (Animation genre + Japanese language, or presence of an absolute episode
  group) without an explicit confirmation must not silently switch acquisition behavior.
- A positively identified non-story file (opening/ending credits, trailer, promo) may be ignored as
  an extra; an unrecognized file may never be assumed to be safely ignorable.
- A manual per-grab mapping correction is local to that grab by default and does not alter future
  downloads unless explicitly promoted to a durable per-series mapping.
- A release spanning multiple canonical seasons (cross-season batch) produces one destination per
  season group rather than one merged file.
- A fallback release with missing or invalid publication time is treated as manual-only rather than
  bypassing or waiting forever.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Movies and series MUST support an operator-owned profile of Auto, Standard, or Anime,
  defaulting to Auto and excluded from metadata/provider-refresh changesets.
- **FR-002**: `Auto` MUST resolve to Standard behavior unless a strong anime-provider identity or an
  explicit user/administrator confirmation is present; weak signals require confirmation, not
  silent switching.
- **FR-003**: The system MUST store native, romaji, licensed, and scene title aliases per movie/
  series, sourced and precedence-ranked (manual > curated provider > inferred provider), and use
  them during discovery and release search.
- **FR-004**: The system MUST resolve absolute, scene, cour-local, and provider-group episode
  numbering to the same canonical episode identity used by the standard TV pipeline, supporting
  many-to-many coordinate-to-episode mapping.
- **FR-005**: The system MUST classify episodes as regular, story special, recap, or extra, with
  story specials and recaps individually monitorable and extras excluded from completeness checks
  only when unambiguous.
- **FR-006**: Users MUST be able to configure anime release preferences: audio mode (original, dub,
  dual, any), desired subtitle languages and embedded-subtitle preference, trusted/blocked release
  groups, and a fallback delay before accepting a non-preferred group.
- **FR-007**: The system MUST verify a downloaded file's actual audio/subtitles against hard
  configured requirements before staging, and reject plus blocklist a release that fails
  verification instead of staging it.
- **FR-008**: The system MUST hold an entire downloaded batch as `Needs mapping` whenever any video
  is unidentified, ambiguous, duplicated, or outside the reserved episode set, and MUST NOT stage or
  delete anything until every video is uniquely resolved or explicitly ignored as an extra.
- **FR-009**: Administrators MUST be able to correct a held batch's grab-local mapping and re-run the
  same safety check before import proceeds.
- **FR-010**: A manual alias or mapping correction MUST survive later provider refreshes without
  being overwritten or deleted.
- **FR-011**: Anime movies MUST reuse the alias, query, parsing, and scoring behavior for search and
  selection but MUST NOT enter episode numbering or special handling, retaining the existing movie
  import pipeline.
- **FR-012**: The existing single unified discovery experience MUST remain; no separate anime
  discovery page, library root, or media-server plugin is introduced.

### Key Entities

- **Title alias**: a sourced, precedence-ranked alternate name (native/romaji/licensed/scene/
  alternative) attached to a movie or series.
- **Episode coordinate**: a source-scoped numbering value (standard, absolute, scene, provider
  group, typed special) that can map to one or more canonical episodes.
- **Episode classification**: the regular/story-special/recap/extra behavioral category of an
  episode, with its source and raw provider label.
- **Media profile**: the per-title Auto/Standard/Anime handling policy.
- **Mapping snapshot**: the immutable record of which release coordinates and episodes a
  reservation/grab was created against.
- **Mapping issue**: the persisted record of an unresolved batch (reasons, candidate files/
  episodes) awaiting administrator resolution.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An anime series confirmed via the profile setting is discoverable and searchable under
  its native, romaji, and licensed names without additional configuration.
- **SC-002**: Absolute, scene, and split-cour numbered releases for a confirmed anime title resolve
  to the correct canonical episode(s) without manual intervention for known corpus titles.
- **SC-003**: Zero downloaded anime batches are ever partially or incorrectly imported when any file
  in the batch is ambiguous, unknown, or outside the reserved target set — every such case produces
  an explicit, recoverable hold.
- **SC-004**: A release failing a hard audio/subtitle preference check is never staged and is
  blocklisted before any file write occurs.
- **SC-005**: Turning a title's profile off (back to Standard) preserves its previously collected
  aliases and episode coordinates without data loss.

## Assumptions

This is the umbrella spec for the Anime-aware media handling program (Part III of the roadmap,
milestones A0–A6). Each milestone slice has its own detailed spec covering milestone-specific
scenarios and requirements:

- `specs/041-a0-anime-corpus-contracts/` — A0: versioned corpus and provider-contract probe deciding
  whether TMDB alone (vs. TMDB+AniDB) satisfies discovery/mapping needs before any schema work.
- `specs/043-a1-anime-identity-foundation/` — A1: media profile, title aliases, and episode
  coordinate schema/foundation.
- `specs/044-a2-anime-acquisition/` — A2: anime-aware search, parsing, and release selection.
- `specs/045-a3-anime-safe-import/` — A3: safe import, mapping enforcement, and recovery workflow.
- `specs/046-a4-anime-specials-preferences/` — A4: specials monitoring, release preferences, and
  post-download verification.
- `specs/047-a6-anime-alternate-season-numbering/` — A6: alternate-season numbering via TMDB episode
  groups.

**A5 (live dogfood validation) has no separate design/plan document and therefore no numbered spec
slice.** Its only source material is two audit documents:
`docs/audits/2026-07-14-a5-corpus-rerun.md` and `docs/audits/2026-07-14-a5-live-dogfood.md`. Per
ROADMAP.md, A5 dogfooding against a real Plex library (no Jellyfin deployed — operator descope) ran
2/6 real-world cases cleanly and safe-stopped on 4/6 with documented root causes (zero wrong
automatic imports); those four blocked cases were attributed to ecosystem/provider gaps (missing
standalone releases, a TMDB episode-tree numbering divergence from scene numbering — the A6 trigger
evidence, an unrecognized CJK range separator, and untagged audio pending an operator decision)
rather than a defect in the shipped A0–A4.5 behavior, and none reopened those milestones.

Deliberate non-goals recorded in the design doc: no separate anime discovery page, no anime-only
library root, no Jellyfin/Plex plugin, no automatic franchise grouping, no watch-state sync, no
automatic quality upgrades at initial delivery, and AniDB/TheXEM were not mandatory first-release
dependencies (A0 determined TMDB alone was sufficient for A1–A4; A6 later closed the remaining
numbering gap using TMDB's own episode groups rather than adding a second provider).

CHANGELOG.md documents "Anime-aware handling" shipping under `## [1.1.0] - 2026-08-14`, which is the
version cited above.
