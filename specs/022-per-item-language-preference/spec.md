# Feature Specification: Per-item preferred audio language

**Feature Branch**: `022-per-item-language-preference`

**Created**: 2026-06-25

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-25-per-item-language-preference-design.md`), plan.md (originally `docs/plans/2026-06-25-per-item-language-preference.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pick a language per title, independent of global format settings (Priority: P1)

A bilingual (French/English) household wants to choose, for each movie or series individually,
which audio language the acquisition pipeline should search for — some titles in the original
language, some dubbed in French — separate from the global preferred-resolution setting.

**Why this priority**: This is the foundational capability; every other behavior (strict parking,
escape hatch, parser support) exists to make this per-item choice safe and usable.

**Independent Test**: Add a movie with the language picker set to French, confirm only
French-satisfying releases are grabbed; add another set to Original, confirm original-language
releases are grabbed for it independently.

**Acceptance Scenarios**:

1. **Given** a movie is added with preference "French," **When** the acquisition pipeline searches
   for releases, **Then** only releases whose audio the pipeline can confirm as French (explicitly
   tagged, or a multi-audio release) are eligible for grabbing.
2. **Given** a movie is added with preference "Original" and its original language is known,
   **When** the pipeline searches, **Then** only releases that are untagged (interpreted as
   original audio), explicitly tagged in that language, or multi-audio are eligible.
3. **Given** a movie is added with preference "Any," **When** the pipeline searches, **Then** the
   language filter is disabled and selection behaves exactly as it did before this feature existed.
4. **Given** a series is added with a language preference, **When** the pipeline searches for any
   season/episode of that series, **Then** the same single per-series preference governs the whole
   show (no per-season language).

---

### User Story 2 - Never silently grab the wrong language (Priority: P1)

A user who deliberately picked a language for a title wants a firm guarantee: if no release
satisfies that choice, the item is visibly parked rather than grabbed in the wrong language and
discovered only at playback.

**Why this priority**: The value of a per-item preference collapses if it can be silently
overridden; this strict/visible behavior is what makes the choice trustworthy, and the design
explicitly rejects a silent fallback for this reason (no upgrade path exists to correct a wrong
grab later).

**Independent Test**: Set an explicit language (e.g. French) on a title where no candidate release
satisfies it, and confirm the item parks with a distinguishable reason rather than grabbing an
unsatisfying release.

**Acceptance Scenarios**:

1. **Given** a title has an explicit language pick (not Original/Any) and no candidate release
   satisfies it, **When** the pipeline finishes searching, **Then** the item is parked with a
   reason distinguishable from "nothing found at all," and no release is grabbed.
2. **Given** a title's pick resolves to no target (Any, or Original with an unknown original
   language), **When** no release would satisfy a would-be filter, **Then** the item falls back to
   scoring the unfiltered candidate set instead of parking — an unopted-in default must never
   strand a title over a coincidental title-word collision.
3. **Given** a TV season where only some episodes have a satisfying release, **When** the pipeline
   searches, **Then** the satisfying episodes are grabbed and the rest remain wanted for a future
   search pass (partial coverage), rather than the whole pack being blocked.

---

### User Story 3 - Change a title's language after the fact (Priority: P2)

A user who parked on the wrong language pick, or changes their mind, wants to edit the preference
on an existing movie or series and have it re-searched with the new preference, including for TV
episodes which have no other manual retry mechanism.

**Why this priority**: Without this escape hatch, a strict park would be a dead end for any title
that doesn't already have a Retry button (all TV episodes), making the strict behavior punitive
rather than recoverable.

**Independent Test**: Change the language preference on a parked movie and confirm it re-enters the
search queue; change a series' preference and confirm its still-wanted episodes re-enter search.

**Acceptance Scenarios**:

1. **Given** a movie is parked (no-match or search-failed) or currently set to Any, **When** its
   language preference is edited, **Then** it resets to the requested/searching state with its
   search-attempt count cleared so it re-searches with the new preference.
2. **Given** a movie is already available or in-flight, **When** its language preference is edited,
   **Then** only the preference field updates — no automatic re-grab occurs (no upgrade path in
   this feature).
3. **Given** a series' language preference is edited, **When** the change is saved, **Then**
   search-attempt counts are cleared only for episodes that are still wanted (no file, no grab);
   already-available or in-flight episodes are untouched.

---

### Edge Cases

- A release name that happens to contain a language word unrelated to its audio track (e.g. a
  title containing "French" or "Italian") must not falsely satisfy or falsely block a soft
  (Original/Any) pick.
- Subtitle-only markers (original audio with French subtitles) must not be treated as French audio
  — they satisfy an Original pick, not an explicit French pick.
- A pre-existing row with no recorded original language and the default "Original" preference must
  keep behaving exactly as it did before the feature shipped, until the user re-requests it.
- A non-admin request carrying a language pick must propagate that pick and the discovered original
  language onto the created movie/series at approval time.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to choose a preferred audio language — Original, French, or Any —
  independently for each movie and each series, separate from the global preferred-resolution
  setting.
- **FR-002**: System MUST default every new item's preference to Original.
- **FR-003**: System MUST resolve "Original" to the title's own original-language, sourced from the
  catalog metadata at add time.
- **FR-004**: System MUST only grab a release for an explicit language pick when that release can be
  confirmed as satisfying the pick (explicitly tagged in that language, multi-audio, or, for the
  original language, untagged-and-that-language-is-original).
- **FR-005**: System MUST park an item visibly, with a reason distinguishable from "no releases
  found," when an explicit language pick cannot be satisfied by any candidate release.
- **FR-006**: System MUST NOT park an item purely because of a soft (Original/Any) pick that happens
  to be unsatisfiable due to a parsing false-positive; it MUST fall back to unfiltered selection in
  that case.
- **FR-007**: Users MUST be able to edit a title's language preference after creation, and the
  system MUST re-queue it (or, for a series, its still-wanted episodes) for a fresh search using the
  new preference.
- **FR-008**: System MUST NOT automatically re-grab an item that is already available or in-flight
  when its language preference changes.
- **FR-009**: For a TV series, the system MUST apply one preference to the whole show; it MUST NOT
  offer or honor a per-season language.
- **FR-010**: System MUST recognize common French audio-dub markers in release names as French
  audio, distinct from subtitle-only markers which MUST remain interpreted as original audio.
- **FR-011**: System MUST partially satisfy a TV season: episodes with a language-satisfying release
  are grabbed while the rest remain wanted, rather than blocking the whole season on one unmet
  episode.
- **FR-012**: When a non-admin user requests a title with a language pick, the system MUST carry
  that pick and the title's original language through approval onto the created library item.

### Key Entities

- **Movie / Series**: library items that each carry an original language (catalog-sourced) and a
  user-set preferred-language pick.
- **Request**: a pending household request that carries a proposed language pick and original
  language through to approval.
- **Release**: a candidate download whose parsed audio-language tag is tested against a title's
  resolved target language.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A household with mixed-language taste can set French on some titles and Original on
  others and observe each acquiring audio matching its own individual pick, with no global setting
  change required.
- **SC-002**: Titles with an explicit language pick that cannot be satisfied are visibly
  distinguishable in the UI from titles that simply found no release at all, in 100% of observed
  park cases.
- **SC-003**: Existing library items present before the feature shipped continue to search and grab
  exactly as before until a user deliberately re-requests or edits them.
- **SC-004**: A parked title can be recovered without deleting and re-adding it — editing its
  language preference alone is sufficient to restart its search.

## Assumptions

- English has no separate menu option; choosing Original on an English-original title covers it.
- Only French, in addition to Original/Any, is offered as an explicit pick in the menu, even though
  the underlying parser also recognizes German/Spanish/Italian tags.
- Re-grabbing an already-available item because its language preference changed is out of scope;
  there is no upgrade path in this feature (later delivered separately by the score-gated
  reimport/replace and source-aware upgrade features).
- Backfilling original-language data onto pre-existing rows added before this feature is not done;
  such rows behave as "Any" until the user re-requests them.
