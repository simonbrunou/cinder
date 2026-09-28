# Feature Specification: Anime Safe Import and Mapping Recovery

**Feature Branch**: `045-a3-anime-safe-import-recovery`

**Created**: 2026-07-13

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-13-a3-safe-import-mapping-recovery-design.md`), plan.md (originally `docs/superpowers/plans/2026-07-13-a3-safe-import-mapping-recovery.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Import an anime batch only when every file is exactly accounted for (Priority: P1)

When an episodic anime download completes, every video file is matched to its authoritative target
episode(s) or explicitly identified as a non-story extra before anything is written into the library;
any ambiguity stops the import instead of guessing.

**Why this priority**: This is the core safety invariant that unblocks activating episodic anime
acquisition at all — a grab may enter the library only after every downloaded video is mapped
exactly to its authoritative episode targets or explicitly ignored as an extra, without guessing.

**Independent Test**: Complete a download whose files exactly match the reserved episodes and confirm
it imports; complete one with an unmatched or ambiguous file and confirm it holds instead of
importing anything.

**Acceptance Scenarios**:

1. **Given** a downloaded anime batch whose files map one-to-one (or many-to-one) onto every
   reserved episode with no leftover or ambiguity, **When** import runs, **Then** every file is
   staged into its correct canonical episode destination(s).
2. **Given** a downloaded batch containing a file that cannot be confidently mapped to a reserved
   episode, **When** import runs, **Then** no file from that batch is staged and the download is held
   in a needs-attention state.
3. **Given** a file that is positively identified as a non-story extra, **When** import runs,
   **Then** it is excluded from staging without blocking the rest of the batch.

### User Story 2 - Recover from an ambiguous batch without losing the download (Priority: P1)

An administrator can review a held anime download, see what the system understood about each file,
correct or confirm the mapping, and resume the import — or cancel and clean up the download entirely
— without needing to re-search or re-download.

**Why this priority**: A3 adds the smallest recovery path that lets a held batch resume or cancel
through one admin recovery page instead of leaving it stuck with no way to proceed.

**Independent Test**: Put a batch into a held state, assign its unmapped file to the correct episode,
resume, and confirm it then imports; separately, cancel a held batch and confirm its reservation and
remote content are cleaned up.

**Acceptance Scenarios**:

1. **Given** a held anime download with one unmapped file, **When** an administrator assigns it to
   the correct episode and resumes, **Then** the batch re-evaluates and imports successfully.
2. **Given** a held anime download, **When** an administrator cancels it, **Then** its episode
   reservations are released and its remote content is cleaned up through the existing cleanup path.
3. **Given** a correction changes which episodes a download is understood to cover, **When** it is
   saved, **Then** only episodes that are currently unclaimed and belong to the same series can be
   added, and removed episodes return to the wanted pool without losing search-attempt history.

### User Story 3 - Reuse a corrected mapping for future releases (Priority: P3)

An administrator who manually resolves a filename's episode mapping can promote that mapping so
future releases using the same naming convention resolve automatically.

**Why this priority**: Promotion lets a manually resolved naming convention resolve automatically
for a subsequent release of the same series, so the same manual correction is not required again.

**Independent Test**: Manually resolve a file to specific episodes, promote it, and confirm the same
naming pattern now resolves automatically for a subsequent release of that series.

**Acceptance Scenarios**:

1. **Given** a manually resolved file with a reusable parsed coordinate, **When** an administrator
   promotes it, **Then** a durable coordinate is stored for the series under the existing identity
   ownership rules.
2. **Given** a file decision with no reusable coordinate, **When** promotion is attempted, **Then** it
   is not offered as an option.

### Edge Cases

- A resolved mapping whose full membership includes an episode outside the currently reserved target
  set must be rejected, not silently truncated to the covered subset.
- The same target episode must never be claimed by two different files within one batch.
- A download's file inventory identity must be re-verified before staging and again after any
  recovery correction, so a filesystem change between passes cannot silently invalidate a stale
  decision.
- A mapping failure must never consume a search or import retry attempt, delete remote content, or
  fall back to the current (possibly changed) provider metadata instead of the frozen evidence used
  at selection time.
- An older reservation lacking the frozen title/alias context required for automatic resolution must
  stop safely for manual resolution rather than trusting mutable metadata that could have changed
  since selection.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST activate episodic anime acquisition (previously selection-only) end-to-end,
  including reservation, download, and import.
- **FR-002**: System MUST require every downloaded video in an episodic anime batch to be either
  mapped to one or more ordered target episodes or explicitly identified as a non-story extra with
  positive evidence before any library file is written.
- **FR-003**: System MUST reject a mapping whenever the union of mapped episodes does not exactly
  equal the batch's authoritative target set, or when a target is claimed by more than one file.
- **FR-004**: System MUST hold an ambiguous, unmatched, or incomplete batch in a durable
  needs-attention state that preserves the download, its evidence, and its search/import attempt
  counters rather than treating it as a failure.
- **FR-005**: Users MUST be able to review a held batch's understood file-to-episode mapping, manually
  assign or ignore individual files, and resume import without re-searching or re-downloading.
- **FR-006**: Users MUST be able to cancel a held batch, releasing its episode reservations and
  cleaning up its remote content through the existing cleanup mechanism.
- **FR-007**: System MUST allow a manual correction to add or remove target episodes only when every
  added episode is currently unclaimed and belongs to the same series, and MUST return removed
  episodes to the wanted pool without discarding existing attempt history.
- **FR-008**: System MUST re-verify file inventory identity immediately before staging and after every
  recovery correction, discarding a stale automatic decision if identity has changed.
- **FR-009**: Users MUST be able to promote a manually resolved, reusable filename mapping into a
  durable series-level coordinate so future releases with the same convention resolve automatically.
- **FR-010**: System MUST preserve the original immutable mapping evidence captured at selection time
  separately from any later manual override, so a correction never rewrites what was originally
  reserved.
- **FR-011**: System MUST support same-season and cross-season staged import for a single downloaded
  source spanning multiple canonical seasons, using the existing staged-import rollback guarantees.
- **FR-012**: System MUST leave standard (non-anime) movie and TV import behavior unchanged.

### Key Entities

- **Grab**: the durable record of a completed download, now carrying its immutable mapping snapshot,
  mapping status, and any recovery evidence.
- **File Inventory Entry**: one downloaded video's durable identity (path, size, modification
  signature) used to detect staleness.
- **Mapping Decision**: an automatic or manually overridden verdict (mapped/ignored) for one
  downloaded file.
- **Mapping Issue**: the recorded reason and candidates when a batch cannot be automatically resolved.
- **Promoted Coordinate**: a durable, series-scoped episode coordinate created from a manually
  confirmed file mapping.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: No episodic anime batch is ever imported with a file mapped outside its reserved target
  set or with a reserved episode left unclaimed.
- **SC-002**: Every ambiguous batch reaches a recoverable held state instead of silently failing,
  losing content, or consuming a retry/search attempt.
- **SC-003**: An administrator can resolve a held batch and see it import successfully without any
  re-search or re-download step.
- **SC-004**: A promoted mapping correctly resolves a subsequent release using the same naming
  convention without manual intervention.
- **SC-005**: Standard (non-anime) TV and movie import success/failure behavior is unaffected.

## Assumptions

- This is the third of six slices (A1–A6) of the umbrella Anime Media Handling feature
  (`040-anime-media-handling`); it activates the episodic anime acquisition held back by A2's explicit
  safety hold, and defers specials acquisition and hard release-preference enforcement to A4.
- The design's dedicated per-grab mapping-correction admin page (`/activity/grabs/:id/mapping`) was
  the originally built recovery surface, but per CHANGELOG (`v1.1.0`) it was subsequently removed
  during the same pre-1.0 dogfood cycle in favor of resolving a held batch through the existing
  `/activity` **Retry import** / **Discard** actions; the underlying safety guarantee (an ambiguous
  batch never stages a file) is unchanged. This spec's requirements describe the durable safety and
  recovery capability, not the specific superseded UI route.
- Anime remains a profile on the existing TV/movie pipelines; no new context, pipeline, or workflow
  table is introduced, per the source design's rejection of alternative approaches.
