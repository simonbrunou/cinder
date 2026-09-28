# Feature Specification: Source-aware import-time upgrade comparison

**Feature Branch**: `025-source-aware-upgrade`

**Created**: 2026-06-27

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-27-source-aware-upgrade-design.md`), plan.md (originally `docs/plans/2026-06-27-source-aware-upgrade.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Import-time replacement agrees with what selection chose (Priority: P1)

A user who has configured a preferred-sources list (e.g. Blu-ray over WEB-DL) wants the import-time
replace-or-keep decision to honor that same preference, so that when a new release collides with an
existing file at the same resolution, the release selection deliberately picked (a better source)
is not discarded in favor of the existing file just because file size is compared first.

**Why this priority**: This closes a known inconsistency between release selection (which already
ranks source) and import-time replacement (which previously ignored source entirely), preventing a
scorer-chosen Blu-ray from being silently thrown away on import.

**Independent Test**: Trigger a same-resolution collision where the incoming release has a
higher-ranked source than the existing imported file and confirm it replaces; reverse the source
ranking and confirm it does not.

**Acceptance Scenarios**:

1. **Given** an incoming release and an existing library file share the same resolution and the
   incoming release's source ranks higher in the user's preferred-sources list, **When** the import
   reaches the replace-or-keep decision, **Then** the existing file is replaced and the new source
   is recorded.
2. **Given** the same setup but the incoming release's source ranks lower (or the existing file's
   source ranks higher), **When** the decision is made, **Then** the existing file is kept.
3. **Given** a resolution difference also exists between the two files, **When** the decision is
   made, **Then** resolution still takes priority over source — a resolution downgrade is never
   accepted purely because the source is better.
4. **Given** a language difference is also present, **When** the decision is made, **Then**
   language still takes priority over both resolution and source, unchanged from the existing rule.

---

### User Story 2 - No preferred-sources setting means no behavior change (Priority: P2)

A user who has never configured a preferred-sources list wants the import-time comparison to behave
exactly as it did before this feature, falling straight through to the existing size tiebreak on a
resolution tie.

**Why this priority**: This feature must be strictly additive for the common case (no source
preference configured); regressing existing size-tiebreak behavior for those users would be an
unacceptable side effect.

**Independent Test**: With no preferred-sources setting configured, trigger a resolution-tied
collision between two releases of different (or unknown) sources and confirm the larger file still
wins, matching pre-feature behavior.

**Acceptance Scenarios**:

1. **Given** no preferred-sources list is configured, **When** two same-resolution releases collide
   at import, **Then** the decision falls through to the size comparison exactly as before this
   feature, regardless of either release's source.
2. **Given** an existing library file imported before this feature (with no recorded source),
   **When** a new same-resolution, same-size-or-smaller release is compared against it, **Then** the
   existing file's missing source ranks last on the source axis but the item is not automatically
   re-grabbed to fill in that gap.

---

### Edge Cases

- The library's clean final filename (e.g. `Title (Year).ext`) strips the source token, so source
  cannot be re-derived from the imported filename after the fact — it must be captured and stored
  at import time, not re-parsed later.
- A file imported before this feature has no recorded source; it ranks last on the source axis,
  identical to how a missing resolution already ranks last, with no automatic backfill or re-grab.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST include the release source as a ranked axis in the import-time
  replace-or-keep comparison, positioned between resolution and file size (language, then
  resolution, then source, then size).
- **FR-002**: System MUST persist the source of the file currently occupying a title's library
  destination at every successful import, so it remains available for future collision comparisons
  even though the source token is stripped from the final filename.
- **FR-003**: System MUST apply the source-aware comparison identically to movies and to TV
  episodes.
- **FR-004**: System MUST treat a file with no recorded source (including every file imported before
  this feature shipped) as ranking last on the source axis, without automatically re-grabbing it to
  acquire source information.
- **FR-005**: When no preferred-sources preference is configured, system MUST produce the exact same
  replace-or-keep outcome as it would have without this feature (source ties, falls through to
  size).
- **FR-006**: System MUST continue to prioritize language and resolution above source in every
  comparison — source only breaks a resolution tie, never overrides a resolution or language
  difference.

### Key Entities

- **Movie / Episode**: library items whose recorded file quality now includes the source (in
  addition to resolution, size, and language) of the file currently in the library.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A same-resolution collision where the new release has a preferred-list higher-ranked
  source than the existing file results in a replacement, matching what release selection would have
  chosen from scratch, in every exercised case.
- **SC-002**: With no source preference configured, collision outcomes are byte-for-byte identical to
  the prior (pre-feature) behavior in every exercised case.
- **SC-003**: A resolution or language difference always outranks a source difference in the final
  decision, with zero observed exceptions.

## Assumptions

- This feature does not add a mechanism to actively re-search for or re-grab a better-sourced
  release for an already-available item; it only makes the comparison used when a new import
  already lands at an occupied destination consistent with selection's source ranking. Active
  re-grabbing for quality upgrades remained a deferred "Quality upgrades & cutoffs" item at the time
  of this feature (a separate later feature — the manual "grab any release" / upgrade-swap
  capability visible in the shipped CHANGELOG — addresses active re-grabbing; it is not part of this
  spec).
- No data backfill runs for files imported before this feature; their source is simply nil going
  forward.
- This feature directly follows and depends on 023-release-source-preference (the source axis in
  release selection) to make the two comparisons consistent.
