# Feature Specification: Library — Importing Completed Downloads

**Feature Branch**: `004-phase-4-library`

**Created**: 2026-06-19

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-19-phase-4-library-design.md`), plan.md (originally `docs/superpowers/plans/2026-06-19-phase-4-library.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Import a completed download into the media library (Priority: P1)

Once a movie's download finishes, the system locates its downloaded video file, links it into
the media library under a clean "Title (Year)" folder and filename, triggers the media server to
rescan, and marks the movie as available.

**Why this priority**: This is the payoff step of the whole pipeline — turning a completed
download into a movie the user can actually watch through their media server.

**Independent Test**: Can be fully tested by giving the import function a downloaded movie with a
known file path against mocked filesystem and media-server operations, and asserting the correct
link, folder naming, and scan-trigger calls occur.

**Acceptance Scenarios**:

1. **Given** a downloaded movie whose completed download is a single video file, **When** import
   runs, **Then** the file is linked into the library under a `Title (Year)/Title (Year).ext`
   path and the media server is told to rescan.
2. **Given** a downloaded movie whose completed download is a folder containing multiple files
   (e.g. a sample and the main feature), **When** import runs, **Then** the largest video file in
   the folder is selected as the source, ignoring samples/extras.
3. **Given** a downloaded movie whose folder contains no recognizable video file, **When** import
   runs, **Then** import fails with a distinct "no video file" outcome and the media server is not
   scanned.
4. **Given** an import that already succeeded once for a movie (e.g. retried after a later
   failure elsewhere), **When** import runs again, **Then** it recognizes the existing link as
   already done and reports success without erroring.

---

### User Story 2 - Recover from a crash between download and import (Priority: P1)

If the application crashes or an import step fails after a download completes but before the
movie is marked available, a later background pass automatically retries the import using the
persisted download location, with no manual intervention.

**Why this priority**: Long-running background pipelines must survive restarts; without this, a
completed download could get permanently stranded.

**Independent Test**: Can be fully tested by constructing a movie already at "downloaded" status
with a persisted file path (simulating a crash after download, before import), running a
background pass, and asserting it reaches "available."

**Acceptance Scenarios**:

1. **Given** a movie stuck at "downloaded" status with a known file path, **When** a background
   pass runs, **Then** the movie is imported and advances to "available."
2. **Given** an import attempt fails (e.g. the media server scan fails), **When** the pass
   completes, **Then** the movie remains at "downloaded" status (not silently marked failed or
   available) so a later pass retries it.

---

### User Story 3 - Isolate import failures per movie (Priority: P2)

If importing one movie raises an unexpected error, it does not prevent other movies in the same
background pass from being processed.

**Why this priority**: Protects overall pipeline throughput and reliability, but is secondary to
the core import and recovery behavior working at all.

**Independent Test**: Can be fully tested by running a background pass over multiple downloaded
movies where one import raises unexpectedly, and asserting the other movies are still processed.

**Acceptance Scenarios**:

1. **Given** multiple movies ready for import in one pass, **When** one movie's import raises an
   unexpected error, **Then** that movie is logged and skipped while the remaining movies in the
   same pass are still processed.

---

### Edge Cases

- A completed download reported by the download client while still being relocated internally
  (a transient "moving" state) is not treated as ready for import, avoiding import from a
  location that hasn't settled yet.
- A movie's downloaded-file path is only ever captured once the download client reports it at
  rest, so the persisted path used for import is stable across retries.
- A movie with no persisted file path (e.g. an older row predating this capability) fails import
  immediately with a distinct outcome rather than crashing.
- Full-disc rips, RAR-packed releases, and multi-part (CD1/CD2) releases are not supported by the
  largest-video-file heuristic and are not imported.
- There is no distinct "import failed" status in this phase; permanent import failures surface
  only as a movie stuck at "downloaded" plus a log entry, not a separate labelled state.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST, once a movie's download is reported complete and at rest, locate its
  downloaded video content on disk using a persisted path rather than re-querying the download
  client.
- **FR-002**: System MUST, when the downloaded content is a folder, select the largest file with
  a recognized video extension as the file to import, ignoring non-video and smaller files.
- **FR-003**: System MUST fail import with a distinct, identifiable outcome when no recognizable
  video file can be found, without attempting to link or scan.
- **FR-004**: System MUST link the selected video file into the media library under a
  deterministic `Title (Year)/Title (Year).ext` folder and filename derived from the movie's
  title, year, and the source file's extension.
- **FR-005**: System MUST trigger a media server library rescan after a successful link so newly
  imported content becomes visible.
- **FR-006**: System MUST mark a movie as available only after both the file link and the media
  server rescan trigger succeed.
- **FR-007**: System MUST treat an import that finds its destination already linked as an
  idempotent success rather than an error, so retries are safe.
- **FR-008**: System MUST automatically retry importing any movie left at "downloaded" status on
  a later background pass, without requiring manual intervention, so a crash or transient failure
  between download completion and import does not strand the movie.
- **FR-009**: System MUST isolate an unexpected failure importing one movie so it does not
  prevent other movies in the same background pass from being processed.
- **FR-010**: System MUST NOT treat a download reported as still being relocated by the download
  client as ready for import.

### Key Entities

- **Movie**: Now also carries a persisted file path pointing to its completed download's location
  on disk, used as the source for import.
- **Library entry**: The imported, renamed file placed under the media library root, named after
  the movie's title and year.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A movie whose download completes and whose content is a supported single-file or
  standard folder release always ends up marked available in the library, with no manual steps.
- **SC-002**: A movie stranded at "downloaded" by a crash or transient import failure is
  automatically retried and eventually reaches "available" once the underlying issue clears, with
  no manual intervention.
- **SC-003**: Retrying an import that already succeeded never produces a duplicate or corrupted
  library entry.
- **SC-004**: An import failure for one movie never blocks or delays import for any other movie
  being processed in the same pass.

## Assumptions

- The application process and the download client are assumed to see the downloaded file at the
  same filesystem path, and the media library is assumed to be on the same filesystem as
  downloads (so a hardlink, not a copy, can be used); validating this assumption against a real
  deployment is deferred to a later phase's live smoke test.
- No distinct "import failed" terminal status exists in this phase; the accepted trade-off is that
  permanent failures surface only as "stuck at downloaded" plus a log line, not an explicit
  failure state visible in the UI — revisited only if it proves insufficient.
- A full library rescan is triggered on every successful import rather than a targeted/incremental
  scan.
- Import runs synchronously within the same background pass that detects a downloaded movie,
  accepted as sufficient at single-household volume.
