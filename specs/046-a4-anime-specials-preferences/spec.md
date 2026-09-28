# Feature Specification: Anime Specials Acquisition and Release Preferences

**Feature Branch**: `046-a4-anime-specials-preferences`

**Created**: 2026-07-13

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-13-a4-anime-specials-preferences-design.md`), plan.md (originally `docs/superpowers/plans/2026-07-13-a4-anime-specials-preferences.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Acquire a monitored story special or recap individually (Priority: P1)

A specific story special or recap episode that an operator explicitly monitors is searched for and
acquired the same way a regular episode is, while unmonitored specials and true extras never enter
the wanted pool.

**Why this priority**: The A3 handoff leaves `Catalog.wanted_episodes/0` still excluding Season 00,
so a story special or recap could not be individually acquired even when explicitly monitored.

**Independent Test**: Explicitly monitor an aired story special with no file and confirm it appears
in the wanted/search pool; leave a recap unmonitored and confirm it never does.

**Acceptance Scenarios**:

1. **Given** an Anime series episode classified as a story special that is explicitly monitored, has
   aired, has no file, and has search budget remaining, **When** the wanted set is computed, **Then**
   it is included.
2. **Given** the same episode is not explicitly monitored, **When** the wanted set is computed,
   **Then** it is excluded.
3. **Given** an episode classified as extra, **When** the wanted set is computed, **Then** it is
   never included regardless of monitoring.

### User Story 2 - Set global release preferences for audio, subtitles, and release groups (Priority: P1)

Operators can configure global Anime release preferences (audio language handling, subtitle
handling, preferred/blocked release groups, and fallback delay), and each Anime-profile movie/series
can choose its own audio preference, so acquisition and post-download verification honor them
consistently.

**Why this priority**: The A3 handoff leaves no preference settings feeding the A2 selection
options, so acquisition and post-download verification could not yet honor per-title or global
Anime audio, subtitle, and release-group expectations.

**Independent Test**: Configure a hard subtitle requirement and a blocked release group; confirm a
release from the blocked group is never selected, and a downloaded file lacking the required
embedded subtitle is rejected before import.

**Acceptance Scenarios**:

1. **Given** a blocked release group is configured, **When** a release from that group is
   considered, **Then** it is never selected.
2. **Given** a required embedded subtitle policy and preferred-language list, **When** a downloaded
   file lacks any desired embedded subtitle stream, **Then** the release is rejected before import,
   the exact release is blocklisted, and its targets are requeued without losing search history.
3. **Given** a soft (non-required) preference is unmet, **When** the file is otherwise valid,
   **Then** it still imports and existing subtitle fallback continues.

### User Story 3 - Trust the policy that was active when a release was reserved (Priority: P2)

Once a release is selected, its hard audio/subtitle requirements are frozen so a later preference
change cannot retroactively reject or misjudge an in-flight download.

**Why this priority**: Changing preferences while a release downloads must not change what that
reservation means.

**Independent Test**: Start a download under one policy, change the global preference before it
completes, and confirm verification still uses the frozen policy captured at selection time.

**Acceptance Scenarios**:

1. **Given** a release is reserved under a given hard policy, **When** the global or per-title
   preference changes before the download completes, **Then** verification still uses the policy
   captured at reservation time.
2. **Given** MediaInfo probing is unavailable or errors while a hard policy exists, **When**
   verification runs, **Then** the download is preserved and retried up to the existing bound rather
   than being rejected or blocklisted outright.

### Edge Cases

- A provider-classified new story special or recap defaults to unmonitored; a provider refresh never
  un-monitors an episode an operator already chose to monitor.
- An audio mode requiring a target dub language is invalid when no target language is configured; the
  UI must surface this rather than silently producing an unsatisfiable requirement.
- A release-name trait (audio/subtitle marker) is advisory only: a missing marker never proves absence
  of a stream and cannot by itself cause rejection; only an explicit contradiction rejects a release
  before download.
- A confirmed hard-policy mismatch after download blocks only the exact release (not the whole
  release group) and never blocks a mapping-ambiguous or unknown-role file, which continues to use
  the existing needs-attention path instead.
- Season 00/typed specials never become wholesale monitored; only classification + explicit
  monitoring together with the existing air-date and search-budget rules govern inclusion.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST include in the wanted set any Anime-profile episode classified as a
  story special or recap that is explicitly monitored, has aired, has no file or active grab, and
  has remaining search budget; regular episodes keep their existing wanted-query behavior unchanged.
- **FR-002**: System MUST exclude episodes classified as extra from the wanted set under all
  conditions.
- **FR-003**: System MUST default newly provider-classified story specials and recaps to unmonitored,
  and MUST NOT let a provider refresh change an operator's existing monitoring choice.
- **FR-004**: Users MUST be able to configure global Anime release preferences: subtitle handling
  (allow/prefer/require), preferred release groups, blocked release groups, and a group fallback
  delay.
- **FR-005**: Users MUST be able to choose an Anime title's audio preference (original / target
  language dub / target language plus original / any) per movie or series.
- **FR-006**: System MUST reject a candidate release before download when it belongs to a blocked
  group, or when its release-name traits explicitly contradict the configured hard audio/subtitle
  requirement.
- **FR-007**: System MUST apply preferred-group eligibility and fallback-delay waiting to anime
  selection, consistent with the existing waiting semantics, without consuming a search attempt while
  waiting.
- **FR-008**: System MUST freeze the hard portion of the applicable release policy at the moment a
  release is reserved, and MUST use that frozen policy — not the currently configured preferences —
  for post-download verification of that specific download.
- **FR-009**: System MUST verify every unique downloaded source video against its frozen hard policy
  before staging, confirming required audio languages are present and, when subtitles are required,
  that at least one desired language exists as an embedded stream.
- **FR-010**: System MUST, on a confirmed hard-policy mismatch, block only the exact release, requeue
  only the targets it owned without losing search-attempt history, and clean up the download through
  the existing durable cleanup mechanism, without creating any library file.
- **FR-011**: System MUST preserve (not reject or blocklist) a download when MediaInfo verification is
  unavailable or errors, retrying up to the existing bound before reaching a durable
  needs-verification hold that an operator can clear.
- **FR-012**: System MUST leave standard (non-anime) movie/TV acquisition, scoring, and import
  behavior unchanged.

### Key Entities

- **Anime Release Preferences**: the resolved global (and, for audio, per-title) policy governing
  subtitle handling, groups, fallback delay, and audio language expectations for Anime content.
- **Frozen Release Policy Snapshot**: the immutable hard-requirement evidence captured when a release
  is reserved, used later for verification instead of live settings.
- **Wanted Special/Recap Episode**: a story special or recap episode that qualifies for acquisition
  because it is classified, monitored, aired, and unfulfilled.
- **Verification Hold**: a durable state reached when a downloaded file cannot be confirmed against
  its frozen hard policy due to a probing failure rather than a confirmed mismatch.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An explicitly monitored, aired story special or recap is found and acquired without any
  other manual step; an unmonitored one is never searched for.
- **SC-002**: No release from a blocked group, and no downloaded file provably missing a required hard
  audio/subtitle stream, ever reaches the library.
- **SC-003**: Changing global or per-title preferences never changes the outcome of a download already
  reserved under the previous policy.
- **SC-004**: A MediaInfo probing failure never results in a false rejection or blocklisting of an
  otherwise valid release.
- **SC-005**: Standard (non-anime) acquisition, scoring, and import outcomes are unaffected.

## Assumptions

- This is the fourth of six slices (A1–A6) of the umbrella Anime Media Handling feature
  (`040-anime-media-handling`); it builds on A3's exact preflight/import safety and adds the
  remaining behavioral and preference gaps the design identifies (Season 00 exclusion, no preference
  settings, best-effort-only MediaInfo language handling).
- Per CHANGELOG (`v1.1.0`), the design's originally proposed **per-title** overrides for subtitle
  languages, embedded-subtitle mode, preferred/blocked groups, and fallback delay were dropped before
  release in favor of **global-only** `/settings` values for those axes (a dogfood-only breaking
  change that never affected a tagged release); separately, the design's global Audio mode setting and
  its single-axis per-title override were merged into the pre-existing per-title Audio pick
  (`preferred_language`, extended with a French-plus-original option), which remains per-title with no
  global fallback. This spec's FRs describe that final shipped shape (global preferences for
  subtitles/groups/delay; per-title choice for audio) rather than the design's earlier bidirectional
  global-plus-per-title model for every axis.
- Anime movie policy uses only the group/audio/subtitle/verification subset; specials and stable
  episode coordinates remain TV-only concepts, per the source design.
