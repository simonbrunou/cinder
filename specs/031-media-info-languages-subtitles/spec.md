# Feature Specification: Media-Info Audio Languages + Subtitles Display

**Feature Branch**: `031-media-info-languages-subtitles`

**Created**: 2026-07-07

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-07-07-media-info-languages-subtitles-design.md`), plan.md (originally `docs/plans/2026-07-07-media-info-languages-subtitles.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See the true audio and subtitle languages of an acquired file (Priority: P1)

A user viewing a movie or episode's detail page wants to know which audio languages the actual file
contains and which subtitle languages are available, distinguishing subtitles embedded in the
video file from separate sidecar subtitle files.

**Why this priority**: The existing detail page only shows a single name-derived guess at language,
which says nothing about the actual file contents or subtitle availability — this is the entire
reason the feature exists.

**Independent Test**: Import a movie whose file has multiple audio tracks and both an embedded and
a sidecar subtitle, then view its detail page and confirm both audio languages and both subtitle
languages appear, correctly labeled as embedded or sidecar.

**Acceptance Scenarios**:

1. **Given** a movie has finished importing, **When** its detail page is viewed, **Then** it shows
   every audio language actually present in the file and every subtitle language available,
   labeled as either embedded (in-container) or sidecar (separate file).
2. **Given** an episode has finished importing, **When** its show's detail page is viewed, **Then**
   the imported episode's row shows compact audio and subtitle language indicators.
3. **Given** a file has no detectable subtitles at all, **When** its detail page is viewed, **Then**
   the subtitle information is simply omitted rather than shown as empty or broken.

---

### User Story 2 - Sidecar subtitles shipped with a release are preserved on import (Priority: P1)

A user whose downloaded release included loose subtitle files alongside the video wants those
files carried into the library next to the imported video, so the media server can serve them.

**Why this priority**: Without this, sidecar subtitles that came bundled with a release would be
silently discarded during import, which is a real loss of already-available content.

**Independent Test**: Import a release whose source folder contains a video plus one or more
subtitle files with language tags in their names, and confirm each subtitle file is copied
alongside the imported video with its language and any forced/SDH flag preserved in the filename.

**Acceptance Scenarios**:

1. **Given** a downloaded release folder contains a video and one or more subtitle files matching
   the video by name, **When** the video is imported, **Then** each matching subtitle file is
   placed next to the imported video, renamed to preserve its language and any forced/SDH flag.
2. **Given** a single-video release folder contains exactly one subtitle file that doesn't match
   the video's name by stem, **When** the video is imported, **Then** that lone subtitle file is
   still imported, with an unresolved language recorded rather than being skipped.
3. **Given** a subtitle file's language token is unrecognized or absent, **When** it is imported,
   **Then** it is still imported and recorded as an undetermined language, not dropped.

---

### User Story 3 - Existing library files get language and subtitle info backfilled (Priority: P2)

An operator with movies and episodes imported before this feature existed wants their existing
library entries to gain the same audio/subtitle language information without re-downloading
anything.

**Why this priority**: Without a backfill, only new imports would benefit, leaving the majority of
an existing library's detail pages blank — a lower-priority follow-up to the core capture, but
necessary for the value to reach existing libraries.

**Independent Test**: Run the backfill command against a library containing already-available
movies and episodes, and confirm audio/embedded-subtitle/sidecar-subtitle fields are populated from
the actual files, and that running it again is a no-op that doesn't corrupt existing data.

**Acceptance Scenarios**:

1. **Given** an existing library of already-available movies and imported episodes, **When** the
   backfill is run, **Then** each item's audio languages, embedded subtitle languages, and
   currently-present sidecar subtitle languages are recorded from the real files.
2. **Given** the backfill has already been run once, **When** it is run again, **Then** the result
   is unchanged and no errors occur (it is safe to re-run).
3. **Given** an import predating this feature discarded a shipped sidecar subtitle that is no
   longer present in the library folder, **When** the backfill runs, **Then** it can only record
   what currently exists — a previously-discarded sidecar cannot be resurrected by the backfill.

---

### Edge Cases

- A file with an audio or subtitle track that declares no resolvable language records that track
  as an undetermined language code rather than being omitted or causing an error.
- A missing or failing media-probe tool still allows the import to proceed; audio and subtitle
  language fields are simply recorded as empty for that file, and the existing language-mismatch
  check is treated as "can't verify, import anyway."
- Capturing audio/subtitle language information happens regardless of whether the household has
  set a preferred audio language — this is unconditional on-import behavior, separate from the
  audio-language-mismatch park check that only runs when a preference is actually set.
- The manual-search release picker is unaffected by this feature — it continues to show only the
  name-parsed language guess, since embedded/sidecar language truth can't be known before a file is
  downloaded.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST record the true audio languages present in an imported movie or episode
  file, read from the actual file rather than from the release's name.
- **FR-002**: System MUST record the embedded (in-container) subtitle languages present in an
  imported movie or episode file.
- **FR-003**: System MUST record the languages of any sidecar (separate-file) subtitles shipped
  alongside the video in the downloaded release, and MUST import those subtitle files into the
  library next to the video.
- **FR-004**: System MUST preserve a sidecar subtitle's forced/SDH designation in its imported
  filename so the media server can recognize it, without needing to model those flags separately.
- **FR-005**: Users MUST be able to view a movie's audio languages and subtitle languages (labeled
  embedded or sidecar) on its detail page.
- **FR-006**: Users MUST be able to view compact audio and subtitle language indicators for each
  imported episode on a show's detail page.
- **FR-007**: System MUST omit the audio/subtitle display entirely for an item that has no
  detectable languages or subtitles, rather than showing an empty or malformed section.
- **FR-008**: System MUST capture audio and subtitle language information for every import
  unconditionally, independent of whether a preferred-audio-language setting is configured.
- **FR-009**: A lone sidecar subtitle file in a single-video release whose name doesn't match the
  video by filename stem MUST still be imported, with its language recorded as undetermined if
  unresolvable.
- **FR-010**: Operators MUST be able to run a one-time backfill that populates audio and subtitle
  language information for every already-imported movie and episode in the library, and this
  backfill MUST be safe to run more than once.
- **FR-011**: The backfill MUST NOT be able to resurrect a subtitle file that was discarded by an
  import predating this feature and is no longer present in the library folder — it only records
  currently-present files.
- **FR-012**: System MUST NOT change the manual-search release picker's display of language, which
  continues to show only the name-derived guess.

### Key Entities

- **Imported Audio Languages**: The set of true audio-track languages detected in an imported
  file, distinct from the name-derived guess shown elsewhere in the app.
- **Imported Embedded Subtitles**: The set of subtitle languages detected inside the video
  container itself.
- **Imported Sidecar Subtitles**: The set of subtitle languages present as separate files
  alongside the imported video, carried over from the original release download.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user viewing any newly-imported title's detail page can see its true audio
  languages and available subtitle languages without consulting an external tool.
- **SC-002**: No sidecar subtitle files shipped with a release are lost during import after this
  feature ships — every matching subtitle file that was present in the download is present next to
  the imported video.
- **SC-003**: An operator can bring an entire pre-existing library up to date with audio/subtitle
  information in a single backfill run, with no risk of data corruption on repeat runs.
- **SC-004**: The existing audio-language-mismatch park behavior is unaffected in outcome — it
  produces the exact same results as before this feature, just sourced from a single combined
  probe.

## Assumptions

- Subtitle *content* inspection, per-language scoring, and any change to the separate
  OpenSubtitles-fetch subtitle engine are explicitly out of scope for this feature.
- The manual-search release picker is a stated non-goal for enhancement — embedded/sidecar
  subtitle truth is only knowable after a file is actually downloaded.
- Forced/SDH subtitle flags are preserved cosmetically in filenames for the media server's benefit
  but are not modeled or displayed as distinct fields in the application itself.
- A single combined media-probe call captures both audio and subtitle information per file,
  replacing a previous audio-only probe, with no behavioral change to the existing
  language-mismatch check that consumes it.
