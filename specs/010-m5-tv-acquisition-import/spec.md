# Feature Specification: TV Acquisition and Multi-File Import (M5)

**Feature Branch**: `010-m5-tv-acquisition-import`

**Created**: 2026-06-22

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-22-m5-design.md`), plan.md (originally `docs/plans/2026-06-22-m5a-tv-pipeline-data-model.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Monitored episodes are actually downloaded (Priority: P1)

A monitored, already-aired episode with no file yet is automatically found on indexers, downloaded
through the configured client, and tracked — whether the found release is a single episode or a
whole-season pack covering many episodes at once — without touching the existing, validated movie
pipeline in any way.

**Why this priority**: This is the milestone's entire purpose — turning the monitoring flags from
the prior milestone into actual downloads. Without it, TV monitoring is inert.

**Independent Test**: Mark an aired episode as monitored with no file, let the TV pipeline run a
search-and-grab pass, and confirm a download is started and linked to that episode, while the
movie pipeline's own tests remain unaffected.

**Acceptance Scenarios**:

1. **Given** an episode is monitored, has no file, and has already aired, **When** the TV pipeline
   searches, **Then** it is eligible for download; an unmonitored, unaired, or already-available
   episode is never swept up by this search.
2. **Given** a release search returns a season pack, **When** it is selected as the best release,
   **Then** one download is started that serves every episode the pack covers, linked through one
   shared record.
3. **Given** a release search returns only single-episode releases, **When** they are selected,
   **Then** each downloads and tracks independently.
4. **Given** the movie pipeline's full test suite, **When** TV acquisition is added, **Then** every
   movie-pipeline test and behavior remains exactly as before.

---

### User Story 2 - Downloaded episodes are imported into the correct location (Priority: P1)

Once a download completes, its file or files are matched to the correct episode(s) by parsing
season/episode markers out of the filenames, then placed into the library in the standard
`Show/Season NN/` naming layout — whether it was a single episode or a multi-file season pack.

**Why this priority**: A downloaded-but-unimported episode delivers no value to the user; this
closes the loop the roadmap calls the milestone's "Done when."

**Independent Test**: Complete a single-episode download and confirm it imports into the correctly
named library location and the episode is marked available; complete a season-pack download and
confirm every file is matched to its correct episode and imported.

**Acceptance Scenarios**:

1. **Given** a completed single-episode download, **When** the import pass runs, **Then** the file
   is placed into the library under the show's season folder with the standard naming pattern, and
   the episode is marked available.
2. **Given** a completed season-pack download containing files for several episodes, **When** the
   import pass runs, **Then** each file is matched to its correct episode by its season/episode
   marker and imported, and once every episode is accounted for the in-flight download record is
   cleaned up.
3. **Given** a file in a completed download that has no recognizable season/episode marker or no
   matching episode, **When** the import pass runs, **Then** that file is skipped gracefully
   (logged, not treated as a fatal error) rather than aborting the whole import.

---

### User Story 3 - Bounded, self-healing retries and crash recovery (Priority: P2)

If a download fails, stalls, or the process restarts mid-pipeline, the TV pipeline retries a
bounded number of times, eventually gives up gracefully rather than looping forever, and correctly
resumes exactly where it left off after a crash or restart.

**Why this priority**: Mirrors the movie pipeline's established reliability guarantee; without it,
a single bad release or a mid-download restart could leave episodes stuck indefinitely.

**Independent Test**: Simulate a search or download failure repeatedly past the retry bound and
confirm the episode is parked rather than retried forever; simulate a process restart mid-download
and confirm the pipeline correctly picks the in-flight download back up.

**Acceptance Scenarios**:

1. **Given** a download that repeatedly fails, **When** it exceeds the bounded retry limit,
   **Then** the associated episodes are released back to be searched again rather than left
   attached to a dead download forever.
2. **Given** a search that repeatedly finds nothing suitable, **When** it exceeds the bounded retry
   limit, **Then** the episode stops being retried every pass and is shown as unable to be found.
3. **Given** the application restarts while a download is in flight, **When** the TV pipeline
   resumes, **Then** it picks the in-flight download back up from persisted state rather than
   losing track of it or double-downloading.

---

### Edge Cases

- A season pack that becomes only partially downloadable/importable (some episode files missing or
  unmatched) still imports every file it can match, rather than failing the whole pack over one
  unmatched file.
- A monitoring toggle changing an episode's state mid-backoff can only delay its next retry
  attempt, never strand it permanently.
- Specially-numbered ("special"/season-zero) episodes are not given any special acquisition
  handling in this milestone — they park gracefully like any unmatched content, with any
  special-cased handling deferred.
- Every multi-row write (a season-pack download fanning out to several episodes) is applied as one
  atomic operation so a partial, inconsistent write is never observed.
- TV requests from non-admin users are explicitly not introduced in this milestone — TV addition
  remains admin-only and direct, as established previously; only the automated grabbing of
  already-monitored episodes is new.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automatically search for and download episodes that are monitored, have
  no file yet, and have already aired — and MUST NOT consider unmonitored, unaired, or
  already-available episodes for this automatic search.
- **FR-002**: System MUST support a single download serving multiple episodes at once (a
  season-pack release), tracked as one shared in-flight download record.
- **FR-003**: System MUST select the best release for wanted episodes using the same category of
  quality rules (size, resolution/source preference) established for movies, adapted for
  TV-specific release naming (single episode, episode range, or whole-season pack).
- **FR-004**: System MUST leave the existing movie search, scoring, download-start, and import
  behavior completely unaffected by the addition of TV acquisition.
- **FR-005**: System MUST, once a download completes, match each downloaded file to its correct
  episode by parsing season/episode information from the filename.
- **FR-006**: System MUST import a matched file into the library using a consistent, predictable
  naming layout organized by show and season.
- **FR-007**: System MUST mark an episode as available only once its file has actually been
  imported into the library.
- **FR-008**: System MUST gracefully skip (not fail the whole import for) any file in a completed
  download that cannot be matched to a known episode.
- **FR-009**: System MUST clean up an in-flight download's tracking record once every episode it
  covers has been successfully imported (or once it terminally fails).
- **FR-010**: System MUST bound the number of retry attempts for both the search phase and the
  download phase of an episode, and MUST stop retrying and surface a terminal state once that
  bound is exceeded.
- **FR-011**: System MUST correctly resume tracking of in-flight TV downloads after an application
  restart or crash, without losing or duplicating downloads.
- **FR-012**: System MUST apply any multi-episode write (such as linking a season pack's episodes
  to one download, or importing a pack's files) as a single atomic operation.

### Key Entities

- **Grab**: An in-flight download record serving one or more episodes at once, tracking the
  underlying download's identifier, protocol, retrieved content location, and retry count; removed
  once its episodes are fully imported or it terminally fails.
- **Episode** (extended): Gains pipeline-facing state — its imported file location, its linked
  in-flight grab (if any), and bounded search/import retry counters — layered onto the identity and
  monitoring data from the prior milestone. Episode state (available / downloading / wanted /
  unable-to-find) is inferred from these fields rather than stored as a separate status.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A monitored, aired, missing episode reaches an imported, available state entirely
  automatically, with no manual intervention, whether the winning release was a single episode or
  a season pack.
- **SC-002**: Every file in a completed season-pack download that has a recognizable episode marker
  ends up imported to the correct episode; any file that doesn't is skipped without aborting the
  rest of the pack.
- **SC-003**: The movie pipeline's existing behavior and reliability are unchanged and fully
  verified as still passing after TV acquisition is added.
- **SC-004**: A failing search or download for an episode never retries indefinitely — it reaches a
  visibly terminal, bounded state.
- **SC-005**: An application restart during an in-flight TV download does not lose track of, or
  duplicate, that download.

## Assumptions

- This milestone was executed as three internal sub-phases (data layer, acquisition logic, poller
  and multi-file import) across a single day per the roadmap; only the first sub-phase's
  implementation plan document was available as a source, so acquisition-logic and
  poller/import-phase requirements above are grounded in the shared design document's description
  of all three sub-phases rather than their own separate plan documents.
- Non-admin requesting of TV titles remains out of scope for this milestone — TV addition stays
  admin-only and direct, as established in the prior milestone; only automated acquisition of
  already-monitored content is new here.
- Special/season-zero episodes receive no bespoke acquisition treatment in this milestone; that is
  explicitly deferred.
- The TV download pipeline runs as its own independent process from the movie pipeline's, so a
  failure or slowdown in one cannot block or corrupt the other.
