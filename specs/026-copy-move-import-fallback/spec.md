# Feature Specification: Copy/move import fallback (cross-filesystem)

**Feature Branch**: `026-copy-move-import-fallback`

**Created**: 2026-06-28

**Status**: Shipped

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-06-28-copy-move-import-fallback.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Import works when downloads and library are on different filesystems (Priority: P1)

An operator whose download directory and library root live on separate filesystems — a common
self-hosted layout — wants imports to succeed automatically, instead of every import permanently
failing because a hardlink cannot cross filesystem boundaries.

**Why this priority**: This is the entire feature. Without it, an extremely common deployment
topology results in every import parking as a failure, with no fallback and no configuration
option to fix it.

**Independent Test**: Configure downloads and library on different filesystems, complete a movie
import, and confirm it succeeds via a fallback copy rather than parking on the cross-filesystem
error.

**Acceptance Scenarios**:

1. **Given** the download and library directories are on different filesystems, **When** an import
   attempts to hardlink and receives a cross-filesystem error, **Then** the system automatically
   falls back to copying the file into the library and the import completes successfully.
2. **Given** the download and library directories are on the same filesystem, **When** an import
   runs, **Then** it hardlinks exactly as before this feature — instant, no copy, byte-identical
   behavior.
3. **Given** a TV episode import is attempted across filesystems, **When** the hardlink fails with
   the same cross-filesystem error, **Then** the episode import also falls back to a copy and
   completes, symmetric to the movie path.
4. **Given** no configuration exists for hardlink-vs-copy mode, **When** any import runs, **Then**
   the choice is made automatically per-attempt based on whether the hardlink succeeds — no setting
   is required or exposed.

---

### User Story 2 - The fallback copy is crash-safe (Priority: P1)

An operator wants the cross-filesystem copy to never leave a half-written or truncated file visible
to their media server, even if Cinder crashes or the host has an I/O stall mid-copy.

**Why this priority**: A copy is not atomic the way a hardlink is; without an atomic write pattern,
a crash mid-copy could hand the media server a broken, truncated file to scan and serve.

**Independent Test**: Simulate a copy failure partway through and confirm no partially-written file
appears at the final library path, and any leftover temporary file is cleaned up.

**Acceptance Scenarios**:

1. **Given** a cross-filesystem import is falling back to copy, **When** the copy completes
   successfully, **Then** the file is first written to a uniquely-named temporary location in the
   destination directory and only then atomically renamed into its final path — the final path
   never shows a partially-written file.
2. **Given** the copy step itself fails (e.g. disk full), **When** the failure occurs, **Then** the
   temporary file is removed, the import returns a failure for normal retry handling, and no file
   appears at the final destination.
3. **Given** a prior crash left a stale temporary file behind, **When** a later import runs at that
   destination, **Then** the stale temporary file is swept up as part of the normal import attempt.

---

### User Story 3 - A cross-filesystem re-import still applies the correct upgrade/keep decision (Priority: P2)

An operator whose collision/upgrade comparison already governs same-filesystem re-imports wants
that same correctness to hold across filesystems, so that inode numbers — which are only unique
within a single filesystem — never cause a genuine quality upgrade to be silently skipped.

**Why this priority**: Once cross-filesystem imports are possible, the existing idempotency
short-circuit (comparing inode numbers to detect "this is already the same file") becomes unsafe,
because two different files on two different filesystems can coincidentally share the same inode
number — a correctness regression that must be closed before the feature is safe to ship.

**Independent Test**: Construct a cross-filesystem re-import where the source and destination
coincidentally report the same inode number but different filesystem devices, and confirm the
system reaches the normal upgrade/keep comparison instead of incorrectly treating it as already
identical.

**Acceptance Scenarios**:

1. **Given** a source file and an existing destination file report the same inode number but
   different filesystem device identifiers, **When** the import evaluates whether the destination
   already holds this exact file, **Then** it does not take the "already identical, skip" shortcut
   and instead proceeds to the normal upgrade-or-keep comparison.
2. **Given** that comparison finds the incoming file is a genuine upgrade, **When** the decision is
   made, **Then** the existing file is replaced; if not an upgrade, it is kept — matching the
   existing same-filesystem replace/keep behavior.
3. **Given** a genuinely identical file on the same filesystem (same inode and same device), **When**
   the import evaluates it, **Then** the existing "already identical, skip" shortcut still fires as
   before this feature.

---

### Edge Cases

- A non-cross-filesystem hardlink failure (e.g. a permissions error, missing source, or a full disk)
  MUST propagate as a real failure and MUST NOT be masked by an attempted copy, since a copy would
  fail the same way and only obscure the root cause.
- Deletion of the source download is not part of this feature; the copy leaves the source download
  in place (consuming double the disk space) unless a separate move-on-import setting is enabled.
- A cross-filesystem collision at an already-occupied destination still surfaces through the same
  existing-file error path and resolves through the ordinary upgrade/keep decision, not a special
  cross-filesystem-only path.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automatically detect a cross-filesystem hardlink failure and fall back to
  copying the file into the library, without requiring any operator configuration.
- **FR-002**: System MUST leave same-filesystem imports completely unchanged — hardlink remains the
  only mechanism used when it succeeds.
- **FR-003**: System MUST apply the cross-filesystem fallback symmetrically to movie imports and TV
  episode imports.
- **FR-004**: System MUST perform the fallback copy atomically with respect to any concurrent media
  library scan — the final library path must never be observable in a partially-written state.
- **FR-005**: System MUST clean up any temporary file left behind by a failed or interrupted copy,
  including one left by a prior crash, without operator intervention.
- **FR-006**: System MUST NOT attempt a copy fallback for hardlink failures other than the
  cross-filesystem case (e.g. permission errors, missing source, out of disk space) — those MUST
  propagate as real failures.
- **FR-007**: System MUST correctly distinguish "this exact file is already at the destination" from
  "a coincidentally-numbered but different file is at the destination" when source and destination
  reside on different filesystems, so a genuine quality upgrade is never silently skipped due to
  inode-number reuse across filesystems.
- **FR-008**: System MUST NOT delete the source download as part of the copy fallback; deletion
  remains governed entirely by the separate move-on-import setting.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator with downloads and library on separate filesystems observes imports
  completing successfully with no manual intervention, where they previously failed on every
  attempt.
- **SC-002**: An operator with downloads and library on the same filesystem observes zero change in
  import speed or behavior after this feature ships.
- **SC-003**: No partially-written file is ever observed at a final library path during or after a
  cross-filesystem import, including under simulated failure conditions.
- **SC-004**: A cross-filesystem re-import with a coincidental cross-device inode match correctly
  reaches the upgrade/keep decision rather than being silently skipped, in every exercised case.

## Assumptions

- Remote or containerized path mappings — where the Cinder host cannot directly check for the
  existence of a path a download client reports — are explicitly out of scope; this feature only
  addresses two directories both directly visible to the Cinder host on different local
  filesystems.
- An explicit hardlink-vs-copy configuration mode was considered and rejected in favor of automatic
  per-attempt detection, to avoid a foot-gun where an operator could misconfigure "hardlink" on a
  cross-filesystem box and reintroduce the original failure.
- A cross-filesystem import without move-on-import enabled permanently consumes roughly double the
  disk space (source download plus library copy) and copy time scales with file size, briefly
  extending a single import cycle — both are accepted, documented trade-offs rather than defects.
- This feature builds directly on the atomic replace mechanism and the tmdb-tagged unique library
  folders introduced by 024-reimport-replace-score-gated, reusing the same temp-then-rename pattern
  and per-title uniqueness guarantee.
