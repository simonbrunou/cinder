# Feature Specification: Score-gated replace on re-import

**Feature Branch**: `024-reimport-replace-score-gated`

**Created**: 2026-06-26

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-26-cinder-reimport-replace-design.md`), plan.md (originally `docs/superpowers/plans/2026-06-26-import-upgrade-replace.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Re-adding an already-present title no longer parks forever (Priority: P1)

A user who deletes a movie/series row without removing its on-disk file, then re-adds the same
title, or who retries an import that previously parked, wants the re-import to either replace the
existing library file with a genuinely better one or keep the existing file and succeed —
never get stuck parked at an import-failure state indefinitely.

**Why this priority**: This is the entire feature. The pre-existing behavior — a different-inode
collision at the destination path unconditionally fails and retries until it permanently parks —
is the concrete, observed incident ("Open Season") this feature fixes.

**Independent Test**: Delete a movie row while leaving its file on disk, re-add the same title, and
confirm the re-import either replaces the file (when the new release is better) or keeps the
existing file and marks the item available — in neither case does it park.

**Acceptance Scenarios**:

1. **Given** a movie/episode already has a file at its library destination (a different physical
   file than the incoming import), **When** the incoming release is judged better by the upgrade
   rule, **Then** the existing file is atomically replaced and the item becomes available with the
   new file's recorded quality.
2. **Given** the same collision, **When** the incoming release is judged not better (or worse),
   **Then** the existing file is left untouched, the item still becomes available, and the event is
   logged — no failure, no park.
3. **Given** a parked import-failed item is retried, **When** the retry reaches the same
   destination, **Then** it resolves via the same replace-or-keep decision rather than parking again
   on a different-inode error.

---

### User Story 2 - The replace decision is genuinely an upgrade, not a coin flip (Priority: P1)

A user wants the system to only replace an existing library file when the new release is
meaningfully better — matching their configured language preference first, then higher resolution,
then larger file size — so an accidental downgrade never silently overwrites a good file.

**Why this priority**: A replace mechanism that could regress quality would be worse than the
parking bug it fixes; ordering the comparison correctly (language first, since it's a deliberate
per-item choice with no other correction path) is what makes replacement safe to automate.

**Independent Test**: Present a same-resolution release in the user's preferred language against an
existing file in a different language and confirm it replaces; present a lower-resolution release
regardless of language parity and confirm it does not replace a higher-resolution existing file
without a countervailing language upgrade.

**Acceptance Scenarios**:

1. **Given** the existing file has no recorded quality information at all, **When** any new release
   imports to that destination, **Then** it is treated as an upgrade and replaces (a "first known
   quality wins" baseline, relevant mainly right after this feature ships).
2. **Given** a language target is set for the item, **When** the incoming release satisfies the
   target language and the existing file does not, **Then** it is treated as an upgrade regardless
   of resolution; the reverse (existing satisfies, incoming doesn't) is never an upgrade.
3. **Given** language is not discriminating (both satisfy, neither satisfies, or no target is set),
   **When** comparing quality, **Then** a strictly better resolution wins, and on a resolution tie a
   strictly larger file size wins.
4. **Given** the incoming release has an unrecognized (nil) resolution, **When** compared against an
   existing file with a known resolution, **Then** it never outranks the existing file on the
   resolution axis.

---

### User Story 3 - Two different titles can never collide with each other's files (Priority: P2)

A user with two different titles that happen to sanitize to the same folder name (or who
distinguishes titles primarily by TMDB identity) wants a guarantee that this replace-or-keep
mechanism only ever applies to re-imports of the *same* title, never accidentally overwrites an
unrelated title's file.

**Why this priority**: The whole replace mechanism is only safe because library folders are made
provably unique per title; without that, "different inode at the same path" could mean two
unrelated titles collided, not a re-import of the same one.

**Independent Test**: Import two different titles whose sanitized names would previously have
collided and confirm each lands in its own distinctly-identified folder with no cross-contamination.

**Acceptance Scenarios**:

1. **Given** two different titles are imported, **When** their sanitized display names would
   otherwise match, **Then** each is placed under an identity-qualified folder unique to that title,
   so they never share a destination path.
2. **Given** a library folder created before this feature (without the identity qualifier), **When**
   this feature is active, **Then** no automatic migration touches that folder — new imports use the
   qualified naming, and the old folder remains until an operator cleans it up manually.

---

### Edge Cases

- The comparison uses name-parsed resolution and language (not a probed/verified audio track), so a
  release whose true quality differs from what its filename claims is compared on the filename's
  claim — accepted as a known limitation.
- File size alone is a weak quality proxy (a larger re-encode could theoretically outrank a smaller,
  genuinely better file at the same resolution) — accepted, mitigated by resolution taking priority
  and nil-resolution always ranking last.
- A wrong-audio release that fails an independent audio verification step still parks as it did
  before this feature; that check runs ahead of the replace-or-keep decision and is unaffected by it.
- A replace that fails partway (e.g. a filesystem error) leaves the existing file untouched and the
  item retries normally, rather than losing the existing file.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST resolve a re-import that lands on a destination already occupied by a
  different physical file of the same title by replacing or keeping — it MUST NOT fail/park solely
  because the destination is occupied by a different file.
- **FR-002**: System MUST replace the existing library file only when the incoming release is
  judged an upgrade under the configured comparison rule; otherwise it MUST keep the existing file
  unchanged and still mark the item available.
- **FR-003**: System MUST prioritize the user's configured language preference above resolution and
  file size when both the incoming and existing files differ in language-target satisfaction.
- **FR-004**: When language does not discriminate between the two files, system MUST prefer higher
  resolution, and on a resolution tie, prefer larger file size.
- **FR-005**: System MUST treat an incoming release with no known quality information as always
  better than an existing file with no recorded quality information at all.
- **FR-006**: System MUST guarantee that this replace-or-keep mechanism only ever applies to a
  re-import of the same title/item, never to an unrelated title, by giving every imported item a
  uniquely-identified library destination.
- **FR-007**: System MUST perform any replacement atomically — a media library scan must never
  observe a missing or partially-written file during the swap.
- **FR-008**: System MUST apply this replace-or-keep behavior symmetrically to movies and to TV
  episodes.
- **FR-009**: System MUST NOT introduce an automatic re-search/re-grab of an already-available item
  purely because a better release might exist; this feature only resolves collisions that occur
  when a new import already lands at an occupied destination (via re-add or retry).

### Key Entities

- **Movie / Episode**: library items that each now record the resolution, file size, and language
  of the physical file currently occupying their library destination.
- **Release**: an incoming candidate download whose parsed resolution/language and measured size are
  compared against the existing file's recorded quality.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Re-adding a title whose file remains on disk (after a delete-without-file-removal) no
  longer results in a permanently parked import-failure state; it resolves to either "replaced" or
  "kept," both ending in an available item.
- **SC-002**: A retried previously-parked import resolves the same way, with zero cases reverting to
  the old park-forever behavior in the covered scenarios.
- **SC-003**: A deliberate language upgrade is always honored (replaces) even when it does not
  improve resolution, in every exercised case.
- **SC-004**: Two distinct titles that would have collided on a shared sanitized name never overwrite
  each other's files after this feature ships.

## Assumptions

- Quality comparison uses name-parsed resolution and a byte-size measurement, not codec/bitrate/HDR
  analysis or probed audio — explicitly accepted as a known limitation, not a defect to fix here.
- Existing library folders created before this feature (without the identity qualifier) are not
  migrated automatically; they persist as orphaned/transitional until manually cleaned up.
- Adding an automatic "re-search an already-available item for a better release" trigger is
  explicitly out of scope; this feature only resolves collisions triggered by re-add or retry
  (that capability arrives with 025-source-aware-upgrade's sibling upgrade-grab feature and later
  work, not this one).
- Source (Blu-ray vs. WEB-DL vs. …) is not yet part of the comparison rule in this feature; it is
  added afterward by 025-source-aware-upgrade to keep import-time replacement consistent with
  release selection.
