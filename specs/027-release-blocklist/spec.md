# Feature Specification: Release Blocklist + Search-Exclusion

**Feature Branch**: `027-release-blocklist`

**Created**: 2026-06-28

**Status**: Shipped

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-06-28-release-blocklist.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A rejected release is never re-grabbed (Priority: P1)

When a grabbed release fails for a permanent reason (wrong audio language, no usable video file,
no importable content, or exhausted download retries), the household should never see that same
release chosen again on the next automatic search for the same movie or show.

**Why this priority**: This is the headline bug the project's own roadmap named as its top deferred
item — a release that parks for a deterministic or exhausted-download reason was re-searched and
re-grabbed every tick because nothing recorded which release had failed.

**Independent Test**: Pre-seed a failed release record for a movie, run an automatic search where
the indexer returns both the previously-failed release and a valid alternative, and confirm the
system downloads the alternative, never the failed one.

**Acceptance Scenarios**:

1. **Given** a movie parked for a permanent import failure (e.g. wrong audio language) on a
   specific release, **When** the household's periodic search runs again, **Then** that exact
   release is excluded from selection and a different release is chosen if one is available.
2. **Given** a TV download that exhausts all download-retry attempts on a specific release,
   **When** the next search for that show runs, **Then** the exhausted release is excluded and the
   search proceeds to the next-best candidate.
3. **Given** no releases have ever been blocked for a title, **When** the automatic search runs,
   **Then** selection behaves exactly as it did before this feature existed.

---

### User Story 2 - Human-initiated retry still respects the blocklist scope (Priority: P2)

An operator retrying a parked title should not accidentally clear the record of the known-bad
release, but should be able to have the title try again with fresh search state.

**Why this priority**: Without this, a manual Retry could either reintroduce the re-download loop
(if it cleared the block) or leave stale state that misrepresents the title's condition.

**Independent Test**: Retry a parked movie whose release was previously blocked, and confirm the
blocklist record for that release still exists while the movie's own stale release-state is
cleared.

**Acceptance Scenarios**:

1. **Given** a parked movie with a blocked release recorded, **When** an operator presses Retry,
   **Then** the blocklist record persists (the release stays excluded) while the movie's tracked
   release identity is cleared so a fresh search can proceed.

---

### Edge Cases

- A title whose only available release is blocklisted ends up with no match; retrying re-parks it
  the same way, and the only recovery is deleting and re-adding the title.
- A wrong-audio-language block does not get un-blocked just because the household's language
  preference is later changed — the release genuinely was wrong-language for the old preference.
- A TV season pack that imports some episodes correctly and rejects others on audio is not
  blocked, since the grab as a whole did not fail; the wrong-audio episodes continue to search
  independently, bounded by their own retry count.
- A transient (non-exhausted) download hiccup does not block a release — only search failures that
  are deterministic, or download failures that have exhausted all retries, are recorded.
- Two different indexers returning slightly different names for what is effectively the same
  release are treated as distinct entries; an exact-name match is what the blocklist recognizes.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST record which specific release was chosen for a title whenever a grab is
  made, so it can later be identified if that grab fails.
- **FR-002**: System MUST exclude a previously blocked release from consideration on every
  subsequent automatic search for the same title, for both movies and TV shows.
- **FR-003**: System MUST record a release as blocked when its import fails for a permanent,
  non-retryable reason (e.g. wrong audio language, unusable video file, no importable file).
- **FR-004**: System MUST record a release as blocked when its download fails and all
  download-retry attempts have been exhausted, but MUST NOT block it on a single transient
  failure.
- **FR-005**: System MUST scope a blocked release to the specific title (movie or show) it was
  grabbed for, and MUST NOT apply it globally across the household's library.
- **FR-006**: The blocklist MUST have no expiration — once a release is blocked for a title, it
  stays blocked for that title indefinitely.
- **FR-007**: Users MUST be able to retry a parked title without clearing that title's recorded
  blocklist entries.
- **FR-008**: System MUST behave identically to pre-feature behavior for any title that has no
  blocked releases recorded.
- **FR-009**: System MUST record a blocked release without ever causing the surrounding park
  operation itself to fail or abort — recording the block is a best-effort side effect.

### Key Entities

- **Blocked Release**: A record of a specific release name that failed permanently for a specific
  movie or show, including the reason it failed; used to exclude that release from future
  automatic selection for that title.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A title whose only failing release keeps getting offered by the indexer is never
  re-downloaded a second time; the household stops seeing a repeating grab/fail loop on the same
  release.
- **SC-002**: Households with an empty blocklist see no behavior change from before the feature
  existed — every existing automatic search and park outcome remains identical.
- **SC-003**: An operator can distinguish "genuinely no good release exists" (title parks at no
  match) from "the system keeps trying the same bad release" (title no longer possible after this
  feature).

## Assumptions

- The identifying signature for a release is its exact release name as returned by the indexer;
  a differently-worded release for the same underlying file from a second indexer is treated as a
  distinct, unblocked release (an accepted, documented limitation).
- Pre-grab search-time failures (e.g. unparseable release, missing metadata id, no scoreable
  match) never had a specific release name recorded, so they are unaffected by this feature.
- A per-item (movie/show) scope, not a global or per-infohash scope, is sufficient for the
  target household-scale usage; a broader scope is a deferred future enhancement.
- No user-facing "clear blocklist" control exists yet; the only stated recovery for a fully
  blocked title is delete-and-re-add.
