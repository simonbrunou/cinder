# Feature Specification: TVDB/TMDB Episode Cardinality Handling

**Feature Branch**: `049-tvdb-tmdb-cardinality-decision`

**Created**: 2026-07-22

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-07-22-159-tvdb-tmdb-cardinality-decision.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Adopting a library with TVDB-split episodes doesn't lose content (Priority: P1)

An operator adopting an existing TV library encounters source files that TVDB numbers as two
episodes but TMDB folds into one combined episode, leaving those files with nowhere to attach.

**Why this priority**: this was the evidenced, real-world pain — multiple titles in a real
library adoption had files TVDB counts as two episodes (a "supersized" episode or a two-part
finale) that TMDB folds into one, leaving those files with nowhere to go.

**Independent Test**: adopt a folder containing a TVDB-numbered file for an episode that TMDB
represents as a single combined episode, and confirm the file is attached to that episode
instead of being dropped or left unmatched.

**Acceptance Scenarios**:

1. **Given** a season file numbered per TVDB with no matching TMDB episode slot, **When** the
   operator confirms it during adoption, **Then** it is recorded as an additional part of the
   corresponding combined TMDB episode.
2. **Given** an operator adopts a season containing several such split files, **When** each is
   resolved, **Then** each is explicitly assigned by the operator — none is auto-guessed.

### User Story 2 - Live pack imports are not newly put at risk (Priority: P2)

A live season-pack import contains most files matching TMDB episodes and one file that does not
match any TMDB episode slot.

**Why this priority**: the decision explicitly rejected any live-import guard that could hold or
block a whole pack over one out-of-range file, since that would newly block good episodes on
season packs that legitimately contain a recap, special, or absolute-numbered file.

**Independent Test**: import a season pack where most files match TMDB episodes but one does
not, and confirm the matched episodes still import while the unmatched one is only logged.

**Acceptance Scenarios**:

1. **Given** a season pack import where most files match TMDB episodes but one does not,
   **When** imported, **Then** the matched episodes still import and finalize.
2. **Given** the same scenario, **When** the unmatched file is skipped, **Then** it is skipped
   with only a server-log warning — a known limitation this decision accepted rather than fixed.

### Edge Cases

- A genuine two-part finale (TVDB counts two episodes, TMDB counts one) is resolved by
  operator review during adoption rather than an automatic largest-file-wins deletion.
- A file that only numerically coincides with a TMDB slot because an earlier fold shifted
  later numbering is a known limitation left open beyond this decision.
- Movies are unaffected — movie identity uses only an IMDb id.
- Anime titles are unaffected — they use their own alternate-season coordinate mechanism.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow a single combined TMDB episode to reference more than one
  on-disk source file when TVDB physically splits what TMDB treats as one episode.
- **FR-002**: System MUST require explicit operator confirmation before attaching an
  unmatched file as an additional part of an episode; the system MUST NOT auto-guess this
  association.
- **FR-003**: System MUST keep the combined TMDB episode as the single catalog artifact — it
  MUST NOT create duplicate episode rows for a TVDB-split pair during adoption.
- **FR-004**: System MUST NOT hold or block an entire season pack import solely because it
  contains one file with no matching TMDB episode slot.
- **FR-005**: System MUST NOT change the live standard import path in this decision: an
  unmatched file in a pack is skipped (recorded only as a server-log warning) while matched
  episodes import — an accepted, known limitation.
- **FR-006**: System MUST leave movie identity and anime identity/coordinate handling
  unaffected by this decision.

### Key Entities

- **Episode**: The catalog row for a single TV episode, identified by its TMDB season/episode
  numbering.
- **TVDB coordinate**: An episode's TheTVDB season/episode numbering, which can split what TMDB
  treats as one combined episode.
- **TMDB coordinate**: An episode's TMDB season/episode numbering, the catalog's canonical
  numbering scheme.
- **Part file**: An on-disk source file attached to an episode as one of possibly several
  physical parts when TVDB splits it.
- **Series**: The show record that owns the season/episode hierarchy a cardinality mismatch
  affects.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every TVDB-split source file encountered during library adoption can be
  attached to its correct combined episode without content loss.
- **SC-002**: Adoption never silently discards a TVDB-numbered file — every unmatched file is
  either resolved by the operator or explicitly surfaced.
- **SC-003**: A completed-season pack import on the live path is not newly blocked by the
  presence of an out-of-TMDB-range file.
- **SC-004**: No duplicate episode rows are created for a title affected by a TVDB/TMDB
  cardinality mismatch.

## Assumptions

- This decision record explicitly deferred any live-import-pipeline code change; at decision
  time the live standard path's silent-drop-on-unmatched-file behavior was accepted as a known,
  open limitation rather than fixed here.
- The original decision rejected any "stacked part-files" schema outright. The
  later-shipped implementation (recorded in a 2026-07-27 addendum to the same source document)
  superseded that specific wording by introducing a part-files list per episode, while
  preserving the decision's intent that one combined TMDB episode remains the single catalog
  artifact.
- A wrong-content file that numerically coincides with a TMDB slot after an offset fold
  elsewhere remains a known limitation, explicitly left open beyond this decision.
- Scope is standard TV only; movies and anime titles are explicitly out of scope for this
  cardinality problem.
