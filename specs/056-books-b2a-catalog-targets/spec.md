# Feature Specification: Books B2a — Catalog Schemas, Identifiers, Credits, and Book Targets

**Feature Branch**: `056-books-b2a-catalog-targets`

**Created**: 2026-08-24

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-24-books-b2a-catalog-and-targets.md`)

Third of three sliced specs under the umbrella replacement of the household's Readarr/Bookshelf instances with native Cinder books support (`053-books-readarr-replacement`). B2a lands the durable books catalog (author, work, edition, identifier, credit, series membership) and the (work, media kind) monitoring target with its guarded transition. It ships as the first of two B2 slices — no network calls, no metadata provider, and no LiveView are part of this slice; those land in B2b.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Represent the four-layer catalog with real identity boundaries (Priority: P1)

Why this priority: the contract requires author, work, and edition to stay separate, referentially valid rows — real foreign keys rather than a collapsed or polymorphic `subject_type`/`subject_id` structure, since SQLite cannot enforce a polymorphic reference.

Independent Test: create an author, a work, and an edition and confirm each is a distinct row with its own identity, that an edition belongs to exactly one work, and that deleting a work cascades its editions, identifiers, credits, and series memberships.

**Acceptance Scenarios**:

1. **Given** a work and one of its editions, **When** both are inspected, **Then** they are separate rows and the edition references exactly one work.
2. **Given** a namespaced provider identifier for an author, work, or edition, **When** two identifiers are stored with the same provider, kind, and foreign identifier, **Then** the second insert returns a validation error rather than raising, and a stored identifier row references exactly one of author, work, or edition (never zero or two).
3. **Given** a work with credited contributors, **When** the same author holds two different roles on that work, **Then** both role rows persist with their recorded order, and the same author/role pair cannot be duplicated on the same subject.

### User Story 2 - Monitor a work per media kind with a guarded status transition (Priority: P1)

Why this priority: the parity contract locks monitoring at the (work, media kind) level, and the guarded `expect:` transition — modeled on `Catalog.transition/3` — is what keeps a status write from silently overwriting a concurrent change.

Independent Test: create a target in the unmonitored state, transition it with an expected-status guard, and confirm a stale expectation is rejected without any write or broadcast, while a correct expectation persists, returns the fresh row, and broadcasts exactly once.

**Acceptance Scenarios**:

1. **Given** a work with no existing target for a media kind, **When** the target is ensured, **Then** exactly one unmonitored target row is created, and a repeated call is a no-op (idempotent).
2. **Given** a target currently in one state, **When** a transition is attempted with a matching expected status, **Then** the write succeeds, the fresh row is returned, and a subscriber receives exactly one broadcast after commit.
3. **Given** a target's state has already changed since it was read, **When** a transition is attempted with a stale expected status, **Then** the call returns a stale-status error, no row is modified, and no broadcast occurs.
4. **Given** a target referencing a held status with a reason, **When** its status changes away from held, **Then** the hold reason is cleared automatically.

### User Story 3 - Keep book targets out of the video profile system (Priority: P2)

Why this priority: book targets must use the same profile-kind integrity guarantees as movies/TV without ever letting a request or a target cross into the wrong media kind's profile.

Independent Test: attempt to create a book target referencing a movies-kind profile and confirm it is rejected as a field-level error, and attempt to create a request referencing a book profile and confirm it still aborts.

**Acceptance Scenarios**:

1. **Given** a book target changeset references a profile whose kind is movies, **When** the changeset is validated, **Then** it fails with a field error on the profile reference, not a raw database error.
2. **Given** an existing request-profile integrity guard that only accepts a movie referencing a movies profile and a series/season/episode referencing a TV profile, **When** a request attempts to reference a book profile, **Then** it still aborts exactly as before.
3. **Given** a media-profile row is edited from e-book to audiobook kind while a book target references it, **When** the edit is attempted, **Then** the profile-integrity trigger blocks the mismatch so no target is stranded on a wrong-kind profile.

### Edge Cases

- A series position must round-trip losslessly as an integer-like string (`"1"`), a fractional string (`"1.5"`), or a textual position (`"Book Two"`) without coercion, and a work may belong to more than one series.
- The incomplete-contributors flag defaults to false and is castable to true, representing the twelve corpus cases (from B0) where an expected public contributor is known to be missing — the adapter must never invent a missing identity to clear this flag.
- The (work, media kind) uniqueness rule must allow a work to monitor e-book only, audiobook only, both, or neither, but never duplicate the same pair.
- Deleting a media-profile row that a book target references must be restricted (rejected), not cascaded, matching the existing referential policy for other profile consumers.
- A no-op transition (same status in and out) still updates the row's timestamp and still broadcasts, matching existing movie/TV transition behavior.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST store author, work, and edition as three distinct catalog layers, with each edition belonging to exactly one work.
- **FR-002**: The system MUST store provider identity as namespaced tuples of provider, kind, and foreign identifier, referencing exactly one of author, work, or edition, rejecting zero or multiple subjects and rejecting duplicate tuples as a validation error rather than a raise.
- **FR-003**: The system MUST store contributor credits as role-bearing, ordered rows on either a work or an edition (never both on the same row), allowing the same author to hold multiple distinct roles on the same subject.
- **FR-004**: The system MUST store series membership as a join separate from work identity, preserving a nullable, uncoerced position value, and allowing a work to belong to multiple series.
- **FR-005**: The system MUST track an incomplete-contributors flag on a work, defaulting to false, to represent known-incomplete public contributor data without inventing missing identities.
- **FR-006**: The system MUST support a monitoring target unique per (work, media kind), with status restricted to unmonitored, monitored, available, or held, and an optional profile reference restricted to a profile whose kind matches the target's media kind.
- **FR-007**: The system MUST provide an idempotent "ensure target" operation that creates an unmonitored target only if one does not already exist for that (work, media kind) pair.
- **FR-008**: The system MUST write target status changes only through a guarded transition that validates the changeset, applies the update conditioned on an expected prior status, and returns a stale-status error with no write and no broadcast when the expectation does not hold.
- **FR-009**: A successful target transition MUST broadcast exactly once, after the database commit, on a dedicated topic.
- **FR-010**: Leaving the held status MUST automatically clear the associated hold reason.
- **FR-011**: The system MUST continue to reject any request that references a book media profile, and any book target that references a profile of the wrong media kind, both as field-level validation errors.
- **FR-012**: Deleting a work MUST cascade to its editions, identifiers, credits, and series memberships; deleting a media profile that a book target references MUST be restricted rather than cascaded.
- **FR-013**: This slice MUST introduce no network calls, no metadata provider integration, and no LiveView surface — those are explicitly deferred to the next slice.

### Key Entities

- **Book author**: A credited person or organization, identified by name plus optional sort name and disambiguation.
- **Book work**: The abstract discoverable/requestable title, with optional original title, first-published date, overview, and an incompleteness flag.
- **Book edition**: A publication or recording manifestation of a work, carrying media kind, language, format, publisher, release date, and abridgement status.
- **Book identifier**: A namespaced provider identity tuple attached to exactly one author, work, or edition.
- **Book credit**: A role-bearing, ordered contributor relationship attached to exactly one work or edition.
- **Book series membership**: A named series association for a work, with an uncoerced position value.
- **Book target**: The (work, media kind) monitoring unit, carrying status, optional profile, and hold reason.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of provider-identity writes with zero or multiple subjects, or a duplicate provider/kind/foreign-identifier tuple, are rejected as validation errors rather than raises.
- **SC-002**: 100% of guarded target transitions with a stale expected status write nothing and broadcast nothing; 100% of successful transitions broadcast exactly once after commit.
- **SC-003**: A series position round-trips losslessly for all three tested forms (integer-like, fractional, textual) with zero coercion.
- **SC-004**: A book target referencing a wrong-kind profile is rejected as a field error in 100% of attempts, and an existing request-profile integrity guard continues to reject book profiles with no regression.
- **SC-005**: No file outside the books catalog module, the books context module, and this slice's migration changes any existing movie/TV behavior.

## Assumptions

- Metadata provider behavior, adapters, identity resolution against the B0 corpus, the refresher, and any LiveView surface are explicitly out of scope for this slice and land in B2b.
- Author aliases are deferred to B2b: nothing in this slice searches or refreshes authors, so a second provider-backed spelling of an author has no consumer yet.
- No legal state-transition map is enforced beyond status-value validity; all ordered state pairs are considered genuinely reachable, and the guarded expected-status check is the actual safety mechanism.
