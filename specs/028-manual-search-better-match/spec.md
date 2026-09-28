# Feature Specification: Manual Search + Find-a-Better-Match

**Feature Branch**: `028-manual-search-better-match`

**Created**: 2026-06-29

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-29-better-match-manual-search-design.md`), plan.md (originally `docs/plans/2026-06-29-better-match-manual-search.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Manually search and grab a specific release for a stuck title (Priority: P1)

An operator with a movie or show stuck at "no match" or otherwise parked wants to see every
release the indexer actually returned, understand why the automatic picker rejected each one, and
choose exactly which one to grab.

**Why this priority**: This is the primary user-requested capability — an interactive override for
when the automatic pipeline can't or won't proceed on its own.

**Independent Test**: Open the manual-search panel for a parked movie, confirm every parsed release
appears with a verdict, pick a rejected one, and confirm it is grabbed and the title starts
downloading.

**Acceptance Scenarios**:

1. **Given** a parked movie, **When** the operator opens "Find a better match" and the indexer
   returns several releases, **Then** the panel lists every release with its score and the reason
   the automatic pick would reject it (out of band, blocklisted, wrong resolution, wrong source,
   wrong protocol, or a soft language-mismatch note).
2. **Given** the panel is open, **When** the operator picks a release the automatic picker would
   have rejected, **Then** that release is grabbed anyway and the title transitions to downloading.
3. **Given** the indexer returns no results or errors, **When** the panel loads, **Then** it shows
   an explicit empty-results or error state rather than an empty table or a crash.

---

### User Story 2 - Replace an already-available movie's file with a better release (Priority: P1)

An operator who already has a movie file wants to manually pick a different release (e.g. higher
quality) and have it atomically replace the existing file, without ever losing the working file if
the replacement fails.

**Why this priority**: This is the feature's most novel and risk-bearing capability — automatic
re-search never targets an already-available title (there's no stopping rule for it), so a human
picking a specific release is the only sanctioned way to upgrade a file already in the library.

**Independent Test**: Trigger a manual replace on an available movie, let the mocked download
complete, and confirm the library file is atomically swapped and the movie ends available with the
new file's quality info; then repeat with a failing import and confirm the original file and
availability are untouched.

**Acceptance Scenarios**:

1. **Given** an available movie, **When** the operator picks a replacement release and confirms
   "replace," **Then** the movie enters an upgrading state while its currently-playable file stays
   in place and untouched.
2. **Given** an upgrade download completes successfully, **When** it is imported, **Then** the new
   file atomically replaces the old one (including when the new file uses a different container
   extension, in which case the old file is removed afterward) and the movie returns to available
   with the new file's information.
3. **Given** an upgrade download or import fails for any reason, **When** the failure is detected,
   **Then** the movie reverts to available with its original file completely untouched, and the
   failed release is recorded so it is not re-grabbed.
4. **Given** an upgrade is in progress, **When** the operator cancels it or deletes the title,
   **Then** the in-flight replacement download is removed with no orphaned downloads, and a
   cancelled upgrade reverts the movie to available rather than to a cancelled state.

---

### User Story 3 - Re-queue missing TV episodes on demand (Priority: P2)

An operator wants to force an immediate re-search for one missing episode or every missing episode
of a show, without waiting for the normal automatic sweep to reconsider them.

**Why this priority**: A useful but lower-risk convenience relative to the interactive
release-picking and file-replace capabilities — it reuses the existing automatic sweep rather than
introducing new grab logic.

**Independent Test**: Trigger "search all missing" on a show with several wanted episodes and
confirm they are picked up and grabbed by the existing sweep on its next pass.

**Acceptance Scenarios**:

1. **Given** a show with wanted (missing) episodes, **When** the operator triggers "search all
   missing" for the show, **Then** every still-wanted episode of that show is re-queued for search
   on the next sweep.
2. **Given** a single wanted episode, **When** the operator triggers "search" for just that
   episode, **Then** only that episode is re-queued; the action is a harmless no-op on an episode
   that isn't currently wanted.

---

### User Story 4 - Manually search and grab a season's still-wanted episodes for a show (Priority: P2)

An operator wants the same interactive release-listing and manual-grab experience for a TV
season's missing episodes as exists for movies.

**Why this priority**: Extends the P1 capability to TV, but deliberately scoped down: replacing an
already-imported episode's file is out of scope, so this story only covers filling in gaps.

**Independent Test**: Open the manual-search panel on a season with some wanted episodes, grab a
listed release, and confirm only the still-wanted episodes are covered by the resulting grab.

**Acceptance Scenarios**:

1. **Given** a season with some episodes still wanted, **When** the operator picks a release from
   the season's manual-search panel, **Then** the grab covers exactly the still-wanted episode
   numbers, recomputed at the moment of grabbing (not a stale snapshot).
2. **Given** a season where every episode is already present, **When** the operator opens the
   panel, **Then** it explicitly states that replacing existing TV files isn't supported yet,
   rather than showing an empty or misleading results table.

---

### Edge Cases

- A movie is deleted by another process between opening the manual-search panel and confirming a
  grab; the grab action fails gracefully rather than crashing.
- A manual grab is attempted on a title that is currently in-flight (searching, downloading,
  downloaded) or already upgrading or cancelled; the action is rejected and the operator is told
  to cancel first.
- A manual grab succeeds in selection but the resulting download later fails; the attempted
  release is still recorded as blocked even though the pick was manually overridden.
- A same-filesystem crash-recovery scenario where the replacement file is already hardlinked in
  place records the new file's quality information, not the stale old one.
- A season's wanted-episode set changes between when the panel was opened and when the operator
  confirms a grab (e.g. the automatic sweep grabbed one mid-action); the grab recomputes the
  current wanted set at confirm time so nothing is double-grabbed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to view every parsed release the indexer returns for a title
  (movie or a TV season), each annotated with the reason it would or wouldn't be automatically
  picked.
- **FR-002**: Users MUST be able to manually select any listed release and grab it, overriding the
  automatic size, language, and blocklist rules for that selection.
- **FR-003**: System MUST allow a manual grab to replace an already-available movie's file only
  through this interactive flow — automatic re-search MUST NOT act on already-available titles.
- **FR-004**: System MUST perform a movie file replacement atomically: the live file is never left
  in an unplayable or duplicated state, including when the replacement uses a different file
  extension than the original.
- **FR-005**: System MUST leave the original file and availability fully intact when a manual
  replacement download or import fails, and MUST record the failed release so it is not offered
  again automatically.
- **FR-006**: Users MUST be able to cancel or delete a title that is in the middle of a manual
  file-replacement, with no leftover in-flight downloads.
- **FR-007**: System MUST reject a manual grab attempt on a title that is not in an eligible state
  (in-flight, already upgrading, or cancelled), returning a clear rejection rather than acting on
  it.
- **FR-008**: Users MUST be able to re-queue a search for one missing TV episode or for every
  missing episode of a show, on demand, separate from the automatic sweep's own schedule.
- **FR-009**: Users MUST be able to manually search and grab a release covering a TV season's
  still-wanted episodes, computed at the moment of the grab rather than from a stale snapshot.
- **FR-010**: System MUST NOT support replacing an already-imported TV episode's file through this
  feature; a season with no wanted episodes MUST clearly communicate that limitation rather than
  present an empty or misleading interface.
- **FR-011**: System MUST show an explicit loading, empty-results, or error state whenever a
  manual search query is in flight, returns nothing, or fails.

### Key Entities

- **Release**: A single candidate download the indexer returns, with attributes such as title,
  resolution, source, size, and language, plus a verdict describing why the automatic picker would
  accept or reject it.
- **Movie Upgrade**: The state of an already-available movie while its user-chosen replacement
  release downloads; the original file remains intact and playable until the replacement succeeds.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can find and grab a specific release for any title within one interactive
  session, without needing external tools or manual database edits.
- **SC-002**: A failed manual file-replacement never results in a lost or corrupted movie file —
  100% of failed upgrades leave the original file playable.
- **SC-003**: A manual replacement using a different file container never leaves two copies of the
  same movie's file on disk.
- **SC-004**: Re-queuing missing TV episodes reduces the wait for a fresh search from "next
  scheduled sweep" to "at most one poll interval."

## Assumptions

- Automatic re-search never targets already-available titles because there is no quality-target or
  cutoff concept to bound it; that capability is a separate, deferred effort and out of scope here.
- Replacing an already-imported TV episode's file is deferred; this feature intentionally limits TV
  manual-grab to still-wanted episodes only.
- There is no global "search all wanted" control across the whole library; re-queuing is scoped to
  one episode or one show at a time.
- Restoring a movie's original release identity or torrent handle after a failed or aborted upgrade
  is not supported — the original download's in-flight state is considered lost once an upgrade
  begins, matching the behavior of any other re-grab.
- A release's name-derived language tag is treated as an unreliable hint in the manual-search
  panel, not a hard rejection, because the only reliable signal is a post-download audio check.
