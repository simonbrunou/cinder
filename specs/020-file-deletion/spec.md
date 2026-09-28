# Feature Specification: Delete-File Option on Movie / Show / Season / Episode Deletion

**Feature Branch**: `020-file-deletion`

**Created**: 2026-06-25

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-25-file-deletion-design.md`), plan.md (originally `docs/plans/2026-06-25-file-deletion.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Delete a movie and optionally its file (Priority: P1)

An admin deleting a movie from the library can opt in to also delete the underlying media file
from disk, mirroring Sonarr/Radarr behavior — instead of the file silently being left behind with
no way to remove it.

**Why this priority**: This closes the gap the acquisition pipeline was explicitly built
anticipating (movie deletion already carried a comment pointing at this "deferred unlink
feature"), and is the most common deletion path.

**Independent Test**: As an admin, delete a movie with the "Delete file(s) from disk" checkbox
checked and confirm both the database row and the on-disk file are gone; delete another movie with
the checkbox unchecked and confirm the row is removed but the file remains.

**Acceptance Scenarios**:

1. **Given** an admin deletes a movie with "Delete file(s) from disk" checked, **When** the
   deletion completes, **Then** the movie row is removed and its media file is unlinked from disk.
2. **Given** an admin deletes a movie without checking "Delete file(s) from disk", **When** the
   deletion completes, **Then** the movie row is removed and the media file is left on disk,
   exactly as before this feature.
3. **Given** an admin deletes a movie with the checkbox checked but the file removal fails,
   **When** the deletion completes, **Then** the movie row is still removed (file deletion is
   best-effort and does not block the row delete).

---

### User Story 2 - Delete a TV show and optionally its files (Priority: P1)

An admin deleting an entire TV show can opt in to also delete every episode's media file from
disk, at the same priority as the movie case since it uses the identical opt-in pattern.

**Why this priority**: Directly parallels User Story 1 for the show-level cascade delete, closing
the same anticipated gap for TV.

**Independent Test**: As an admin, delete a TV show with "Delete file(s) from disk" checked and
confirm the show/season/episode rows and every downloaded episode file are gone.

**Acceptance Scenarios**:

1. **Given** an admin deletes a TV show with "Delete file(s) from disk" checked, **When** the
   deletion completes, **Then** the show and its season/episode tree are removed and every
   episode's media file is unlinked from disk.
2. **Given** an admin deletes a TV show without checking the option, **When** the deletion
   completes, **Then** the show tree is removed and every episode's media file is left on disk.

---

### User Story 3 - Delete a single episode's or season's file without removing tracking (Priority: P2)

An admin can delete the media file for one episode, or for every episode in a season, without
deleting the episode/season records themselves — since episodes and seasons are TMDB-synced and
get re-added automatically, deleting the row is not a meaningful operation at that level.

**Why this priority**: This is new functionality (no prior "delete" existed at episode/season
level at all), but is a secondary, more targeted action than the entity-level deletes above.

**Independent Test**: As an admin, delete an episode's file (leaving it monitored) and confirm the
episode's file reference clears and it becomes eligible to be re-grabbed; delete a season's files
and confirm every episode in the season loses its file reference in one update.

**Acceptance Scenarios**:

1. **Given** an admin deletes an episode's file with "also stop monitoring" left unchecked,
   **When** the deletion completes, **Then** the episode's file reference is cleared, the episode
   remains monitored, and it becomes eligible for automatic re-acquisition.
2. **Given** an admin deletes an episode's file with "also stop monitoring" checked, **When** the
   deletion completes, **Then** the episode's file reference is cleared and it is no longer
   monitored.
3. **Given** an admin attempts to delete the file for an episode that has no file, **When** the
   action runs, **Then** the system reports there is no file to delete rather than silently
   succeeding.
4. **Given** an admin deletes a season's files, **When** the deletion completes, **Then** every
   episode in the season that had a file loses its file reference, episodes without a file are
   left untouched, and the change is applied as one update rather than one per episode.
5. **Given** a file-only deletion (episode or season) fails to unlink the file, **When** the action
   completes, **Then** the failure is surfaced to the admin rather than silently succeeding, unlike
   the best-effort behavior of the entity-level deletes.

---

### Edge Cases

- What happens when the file being deleted is already missing from disk? The deletion is treated
  as successful (idempotent) rather than reported as an error.
- What happens to the folder a deleted file leaves behind? Empty parent folders are removed up to,
  but never including, the library root.
- What happens when a folder still contains another file after the deletion? Pruning stops at that
  folder; nothing above it is touched.
- What happens when a file's recorded path does not fall strictly inside any configured library
  root (e.g. a stale or misconfigured path)? The file is still unlinked, but no folder pruning is
  attempted at all, so deletion never reaches outside a library root.
- How does deleting a library file interact with the download client's own copy? Because library
  files are hardlinks, disk space is reclaimed only once the download client also drops its copy;
  this feature does not touch or remove anything from the download client.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to optionally delete a movie's media file from disk at the same
  time they delete the movie, via an opt-in control that defaults to off.
- **FR-002**: Users MUST be able to optionally delete every episode's media file from disk at the
  same time they delete an entire TV show, via an opt-in control that defaults to off.
- **FR-003**: Users MUST be able to delete a single episode's media file without deleting the
  episode's tracking record.
- **FR-004**: Users MUST be able to delete every media file in a season without deleting the
  season's or its episodes' tracking records.
- **FR-005**: Users MUST be able to choose, when deleting an episode's or season's file(s),
  whether that item also stops being monitored (default: remains monitored).
- **FR-006**: System MUST treat deletion of an already-missing file as a successful, idempotent
  outcome rather than an error.
- **FR-007**: System MUST remove empty parent folders left behind by a file deletion, walking
  upward, and MUST NOT remove the library root itself or any folder that is not empty.
- **FR-008**: System MUST NOT prune any folder for a file whose path does not fall strictly inside
  a configured library root, even though the file itself is still unlinked.
- **FR-009**: System MUST continue removing the underlying database row when an entity-level
  delete (movie or show) is requested with file deletion enabled, even if the file deletion itself
  fails.
- **FR-010**: System MUST surface an error to the admin when a file-only deletion (episode or
  season) fails to unlink a file, rather than failing silently.
- **FR-011**: System MUST record, for every deletion that includes file removal, whether the
  file(s) were in fact deleted, as part of the existing audit trail for that action.
- **FR-012**: System MUST restrict every delete-file action to admin-gated surfaces, consistent
  with existing entity-delete authorization.

### Key Entities

- **Movie**: A tracked film with an associated media file path once downloaded; deletable with or
  without its file.
- **TV Show / Series**: A tracked show with a season/episode tree, each episode potentially having
  its own media file; deletable with or without its files.
- **Season**: A group of episodes within a show; supports a bulk file-only deletion across all its
  episodes.
- **Episode**: A single trackable unit within a season, with an optional media file reference and
  a monitored flag controlling future re-acquisition.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An admin can remove a movie's or show's on-disk media alongside its record in a
  single delete action, with zero cases of the file being left behind when the option was chosen.
- **SC-002**: An admin can remove a single episode's or an entire season's on-disk media without
  losing tracking of the show, and the item remains eligible for automatic re-acquisition unless
  the admin explicitly also stops monitoring it.
- **SC-003**: Deleting an already-missing file never produces a visible error to the admin.
- **SC-004**: File deletion never removes a non-empty folder or a library root, and never prunes
  any folder for a file located outside every configured library root.
- **SC-005**: A file-only deletion failure is always visible to the admin, while an entity-level
  deletion always completes its record removal regardless of file-deletion outcome.

## Assumptions

- This feature is unrelated to the UX/identity overhaul track (`014-ux-identity-overhaul` and its
  slices `015`–`019`); it is a standalone media-management feature for removing files from disk.
- Bulk multi-select deletion and a "delete file but keep the record" action for movies (as a
  separate action from delete-movie) were explicitly out of scope for this feature.
- Removing the download client's own copy of a file as part of "delete file" is explicitly out of
  scope; only the library's own copy is affected.
- Authorization for all four delete actions relies on the existing admin-gated routes; no new
  authorization mechanism was introduced.
