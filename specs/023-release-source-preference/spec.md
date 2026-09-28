# Feature Specification: Release source preference (Blu-ray / WEB-DL / …)

**Feature Branch**: `023-release-source-preference`

**Created**: 2026-06-26

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-26-release-source-preference-design.md`), plan.md (originally `docs/plans/2026-06-26-release-source-preference.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Express a preferred release source per library kind (Priority: P1)

A user who cares about disc-sourced quality (or wants to avoid cam rips/HDTV) wants a way to tell
Cinder which release sources (Blu-ray, WEB-DL, HDTV, etc.) are acceptable for movies and for TV,
mirroring how they already restrict preferred resolutions.

**Why this priority**: This is the entire feature — without a source preference, source is an
unaddressable selection axis even though resolution and size bands already exist.

**Independent Test**: Set a preferred-sources list containing only "bluray" for movies, run
selection against a mixed candidate list, and confirm only Blu-ray (and untagged) releases are
eligible.

**Acceptance Scenarios**:

1. **Given** a preferred-sources list is set for a kind (movies or TV), **When** the selection
   scorer evaluates candidate releases, **Then** only releases whose parsed source is in the list
   (or unparseable) remain eligible.
2. **Given** no preferred-sources list is set (the default), **When** selection runs, **Then**
   every source is accepted, identical to pre-feature behavior.
3. **Given** a preferred-sources list is set, **When** a release's source cannot be parsed from its
   name, **Then** that release still passes the filter (untagged releases are never rejected outright).
4. **Given** a preferred-sources list is set, **When** a release's source is recognized but not in
   the list, **Then** that release is rejected.

---

### User Story 2 - Rank source as a secondary tiebreaker (Priority: P2)

A user with several acceptable sources listed wants the better-ranked source (per their listed
order) to win selection when resolution is tied, so a 1080p WEB-DL still loses to a 1080p Blu-ray
if Blu-ray ranks higher in their list, while resolution always takes priority over source.

**Why this priority**: Filtering alone does not express relative preference among multiple accepted
sources; ranking makes the preference meaningful when several acceptable options are simultaneously
available.

**Independent Test**: Provide two same-resolution releases with different acceptable sources and
confirm the higher-ranked source is selected; confirm a higher-resolution release with a
lower-ranked source still wins over a lower-resolution release with a higher-ranked source.

**Acceptance Scenarios**:

1. **Given** two candidate releases at the same resolution with different sources both present in
   the preferred list, **When** selection runs, **Then** the release whose source appears earlier in
   the preferred list is chosen.
2. **Given** a candidate release at a higher resolution but a lower-ranked (or untagged) source and
   another at a lower resolution but higher-ranked source, **When** selection runs, **Then** the
   higher-resolution release wins — resolution outranks source.
3. **Given** two candidates tie on resolution and source, **When** selection runs, **Then** the
   existing size-based tiebreak decides between them, unchanged from before this feature.

---

### Edge Cases

- Ambiguous 2-letter source abbreviations (e.g. "ts," "bd") are deliberately excluded from parsing
  to avoid false-positive matches inside unrelated title words.
- A release name containing multiple source-like tokens (e.g. both "remux" and "bluray") resolves
  to the most specific match (remux wins over plain Blu-ray).
- TV season-pack selection applies the same source filter and tiebreak per the existing
  greedy-coverage selection, not as part of the per-episode size band.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to set a preferred-sources list separately for movies and for TV,
  from a fixed vocabulary of recognized source tokens.
- **FR-002**: System MUST leave the preferred-sources setting empty by default, accepting every
  source until a user opts in — an empty/unset list MUST never silently filter existing installs.
- **FR-003**: System MUST reject a candidate release whose source is recognized but not present in
  a non-empty preferred-sources list.
- **FR-004**: System MUST NOT reject a candidate release whose source cannot be determined from its
  name, even when a non-empty preferred-sources list is set.
- **FR-005**: System MUST rank resolution above source above size when choosing among multiple
  eligible releases — source functions purely as a secondary tiebreaker, never overriding
  resolution.
- **FR-006**: System MUST apply the same source filtering and ranking behavior to both movie
  selection and TV season/episode selection.

### Key Entities

- **Release**: a candidate download whose name is parsed for a source token (e.g. Blu-ray, WEB-DL,
  HDTV, remux, DVD, cam) in addition to its existing resolution/size/language attributes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user who sets "bluray" as their only preferred source for movies observes no
  non-Blu-ray-tagged release grabbed for a new request, except when no source could be determined
  from the release name.
- **SC-002**: An install that never touches the new setting exhibits selection results identical to
  before the feature shipped.
- **SC-003**: Given a same-resolution choice between two acceptable sources, the source listed
  first by the user is the one grabbed, observably every time.

## Assumptions

- This feature is pure selection preference; it does not add quality "tiers," upgrade cutoffs, or
  any mechanism to re-grab an already-imported file because a better source later appears (that
  capability is explicitly deferred and later delivered separately — see
  025-source-aware-upgrade).
- No populated default source list is offered, since there is no universally-desired source the way
  there is a universally-desired minimum resolution.
