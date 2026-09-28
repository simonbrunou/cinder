# Feature Specification: Local Subtitle Extraction and Translation Fallback

**Feature Branch**: `036-subtitle-local-translation`

**Created**: 2026-07-10

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-10-subtitle-local-translation-fallback-design.md`), plan.md (originally `docs/superpowers/plans/2026-07-10-subtitle-local-translation-fallback.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Fill a missing subtitle language locally (Priority: P1)

**Why this priority**: The core value is that every configured subtitle language ends up filled
even when OpenSubtitles has nothing usable for that language, instead of leaving the viewer with
no subtitles in their language.

**Independent Test**: Import a movie or episode whose media file has embedded subtitles, configure
a target language OpenSubtitles cannot supply, and confirm a subtitle file for that language
appears, sourced from the embedded track or a translation of it.

**Acceptance Scenarios**:

1. **Given** an imported movie or episode with no usable OpenSubtitles result for a configured
   target language, **When** the media file has an embedded text track in that exact language,
   **Then** that track is extracted directly as the subtitle for that language.
2. **Given** no exact-language embedded track, **When** the media file has a default, non-forced
   embedded text track, **Then** that track is extracted once and translated into each remaining
   missing configured language.
3. **Given** no usable embedded text track at all, **When** an existing `.srt` sidecar is present,
   **Then** it is used directly for an exact-language match or as a translation source for
   remaining missing languages.

### User Story 2 - Never overwrite a better or user-owned subtitle (Priority: P2)

**Why this priority**: Subtitle quality and user trust depend on never silently replacing a good
OpenSubtitles hash match or a subtitle the user placed themselves.

**Independent Test**: Place a manually-added `.srt` file next to an imported video with no Cinder
provenance, then run subtitle fetching, and confirm the file is left untouched.

**Acceptance Scenarios**:

1. **Given** a sidecar subtitle file with no Cinder-recorded provenance, **When** subtitle
   fetching runs for that video, **Then** the file is never overwritten, though it may still be
   read as a translation source when no usable embedded source exists.
2. **Given** a Cinder-managed local or ID-matched subtitle, **When** a later search finds an exact
   OpenSubtitles moviehash match for that language, **Then** the local or ID-matched file is
   superseded by the moviehash match.
3. **Given** a Cinder-managed subtitle with a stable moviehash match, **When** subtitle fetching
   runs again, **Then** that language is left untouched.

### User Story 3 - Provider errors never break import or destroy subtitles (Priority: P3)

**Why this priority**: Subtitle fetching must stay strictly best-effort; a flaky provider, a
translation-service outage, or an extraction failure must never affect whether an import succeeds
or whether an existing subtitle disappears.

**Independent Test**: Simulate an OpenSubtitles provider error or quota response and a
LibreTranslate outage during subtitle fetching for a newly imported title, and confirm the import
completes normally and no existing subtitle is altered.

**Acceptance Scenarios**:

1. **Given** an OpenSubtitles provider error, authentication failure, timeout, or daily-quota
   response, **When** subtitle fetching runs, **Then** it is not treated as a subtitle miss and
   does not trigger local extraction, translation, or any file replacement.
2. **Given** a LibreTranslate failure or an unconfigured translation service, **When** local
   fallback would otherwise translate a track, **Then** the affected language is left missing or
   provisional for a later retry, and the current subtitle for that language (if any) is left
   intact.
3. **Given** any subtitle-fetching failure (extraction, translation, filesystem, or media-server
   refresh), **When** it occurs during or after import, **Then** the video import itself is
   unaffected.

### Edge Cases

- Image-based subtitle formats (PGS, VobSub) and forced-only tracks are never used as translation
  sources.
- A video quality upgrade that changes the file's moviehash invalidates a subtitle's prior
  "stable" classification, since that classification was tied to the old file.
- A subtitle selection decision is made independently per requested target language; an
  OpenSubtitles hit for one language never blocks local fallback for another.
- A periodic sweep rechecks missing and provisional subtitles but skips languages already stably
  matched by moviehash.
- Concurrent import and sweep work for the same video cannot both write a replacement subtitle at
  once.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: For each configured subtitle language, the system MUST search OpenSubtitles first,
  preferring an exact moviehash match and accepting an ID match as a lower-quality, provisional
  fallback.
- **FR-002**: The system MUST attempt local extraction or translation for a target language only
  after a successful OpenSubtitles search returns no usable candidate for that language.
- **FR-003**: The system MUST prefer an embedded text track in the exact requested language over
  any other local source.
- **FR-004**: When no exact-language embedded track exists, the system MUST extract the default,
  non-forced embedded text track once and translate it into each remaining missing target
  language.
- **FR-005**: When no usable embedded track exists, the system MUST use an existing `.srt` sidecar
  as an exact-language subtitle or as a translation source for remaining missing languages.
- **FR-006**: The system MUST NOT treat an OpenSubtitles provider error, authentication failure,
  timeout, or daily-quota response as a subtitle miss, and MUST NOT trigger local fallback from
  such a response.
- **FR-007**: The system MUST NOT overwrite a sidecar subtitle file that carries no Cinder-recorded
  provenance.
- **FR-008**: The system MUST record, for every Cinder-managed subtitle, whether its origin is a
  stable moviehash match or a provisional (ID match, embedded, translated, or release-sidecar)
  source.
- **FR-009**: The system MUST allow a provisional or local subtitle to be superseded by a later
  exact moviehash match, and MUST leave a stable moviehash-matched subtitle untouched on
  subsequent checks.
- **FR-010**: The system MUST invalidate a subtitle's stable classification when the video file it
  was matched against changes (for example, after a quality upgrade).
- **FR-011**: The system MUST make every subtitle-language decision independently; a successful
  result for one target language must never prevent fetching, extraction, or translation for
  another target language.
- **FR-012**: The system MUST NOT use image-based subtitle formats or forced-only tracks as a
  translation or direct-use source.
- **FR-013**: The system MUST produce translated output as a valid `.srt` file, preserving cue
  numbers, timestamps, blank-line separators, and inline markup, translating only the dialogue
  text.
- **FR-014**: The system MUST leave the current subtitle for a language unchanged whenever
  extraction, translation, or the translation service is unavailable or fails, and MUST leave
  that language missing or provisional for a later retry.
- **FR-015**: The system MUST NOT allow any subtitle-fetching failure to affect video import
  success or state.
- **FR-016**: The system MUST periodically re-check missing and provisional subtitle languages for
  already-imported media, while skipping languages already stably matched.
- **FR-017**: The system MUST prevent import-time and periodic-sweep subtitle work for the same
  video from concurrently producing conflicting subtitle writes.
- **FR-018**: The system MUST refresh the relevant media-server library after a successful new or
  replaced Cinder-managed subtitle is committed.
- **FR-019**: Administrators MUST be able to configure the local-translation service independently
  of whether OpenSubtitles is configured, and the system MUST leave local translation unavailable
  (logging a best-effort miss) when it is not configured.

### Key Entities *(include if feature involves data)*

- **Subtitle language target**: one configured language a video should have a subtitle for,
  tracked and resolved independently of every other target language.
- **Subtitle provenance record**: per-video, per-language record of how a Cinder-managed subtitle
  was obtained (moviehash match, ID match, embedded extraction, translation, or release sidecar)
  and whether that origin is stable or provisional.
- **Embedded text track**: a subtitle track carried inside the imported media file, distinguished
  by language, default/forced disposition, and whether it is extractable text (not image-based).
- **Translation source**: the dialogue text of an extracted embedded track or an existing sidecar
  used as input to produce a translated subtitle for a missing language.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every configured subtitle language for an imported title ends up filled whenever any
  usable OpenSubtitles, embedded, or sidecar source exists for it, rather than being left empty
  after only an OpenSubtitles miss.
- **SC-002**: No user-owned sidecar subtitle (one without Cinder provenance) is ever altered by
  automatic subtitle fetching.
- **SC-003**: A provider error, quota response, or translation-service failure never changes video
  import outcome and never removes or corrupts an existing subtitle.
- **SC-004**: A subtitle later found via an exact moviehash match replaces any lower-confidence
  local or ID-matched subtitle for that language within one periodic sweep cycle.
- **SC-005**: Translated subtitle output remains correctly timed and structured — cue count,
  order, timestamps, and formatting match the source track — for every produced translation.

## Assumptions

- OCR or conversion of image-based subtitle formats is explicitly out of scope.
- Translating `.ass`, `.ssa`, `.sub`, or `.vtt` content is explicitly out of scope; only SRT
  sources and output are supported.
- No subtitle database table, retry-counter mechanism, or per-item UI override is introduced;
  provenance is tracked in a hidden per-video manifest instead.
- Additional translation providers or automatic hosting of a translation model are out of scope;
  only a single self-hosted LibreTranslate integration is supported.
- Deleting an old sidecar when no replacement can be produced is explicitly out of scope — a
  failed fallback simply leaves the language missing or provisional.
- Applies only to already-imported movies and TV episodes; it is not applied to unimported or
  in-flight downloads.
