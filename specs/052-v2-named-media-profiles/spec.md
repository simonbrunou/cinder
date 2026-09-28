# Feature Specification: Named Media Profiles

**Feature Branch**: `052-v2-named-media-profiles`

**Created**: 2026-08-15

**Status**: Shipped (v2.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-15-v2-named-media-profiles.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create and assign a named profile (Priority: P1)

An admin wants more than the fixed Standard/Anime choice for where titles land. The admin
creates a named movie or TV profile with a chosen handling engine (Standard or Anime) and an
optional dedicated library root, then assigns it to a request or a title.

**Why this priority**: This is the core value of the feature — replacing the fixed binary
destination choice with operator-named profiles is the entire point of the release.

**Independent Test**: Create a named profile for a media kind, assign it during a request or on a
title, and confirm the assignment is accepted and reflected on that request/title.

**Acceptance Scenarios**:

1. **Given** an admin viewing profile administration, **When** they create a named movie or TV
   profile with a name, kind, handling, and optional root, **Then** the profile is created and
   available for assignment within that kind.
2. **Given** a household member creating a request or an admin editing a title, **When** they
   select a named profile matching the item's kind, **Then** the assignment succeeds and the
   legacy Standard/Anime handling field stays synchronized with the profile's handling.
3. **Given** a household member or API caller submitting a profile id that does not match the
   target's kind, or that does not exist, **When** the assignment is attempted, **Then** it is
   rejected without changing the request's or title's existing state.

---

### User Story 2 - Existing installs migrate without behavior change (Priority: P1)

An operator upgrading from a pre-v2 install has existing titles and requests using the old
Standard/Anime handling and existing library roots. After upgrade, those titles and requests must
keep working exactly as before, now expressed through profile ids instead of a raw handling flag.

**Why this priority**: This is a core compatibility boundary of the release — existing titles and
requests must keep working through profile ids, without changing their handling.

**Independent Test**: Run the migration against a pre-v2 database snapshot and confirm every
explicit Standard/Anime title and request is backfilled to a matching seeded profile, with any
blank profile root falling back to the pre-existing Standard/Anime root.

**Acceptance Scenarios**:

1. **Given** an existing title or request with explicit Standard or Anime handling, **When** the
   v2 migration runs, **Then** it is deterministically backfilled to the matching seeded profile
   id.
2. **Given** an existing Auto title or a request with no proposed handling, **When** the v2
   migration runs, **Then** its profile id remains null rather than being guessed.
3. **Given** a profile with a blank root, **When** it is used for import or adoption, **Then** the
   existing matching Standard/Anime root is used, so paths are unchanged for existing installs.

---

### User Story 3 - Profiles stay safe to administer over time (Priority: P2)

An admin manages profiles after initial setup: renaming one, trying to delete one still in use, or
trying to change what a referenced profile points to. The system must prevent operations that
would silently break requests, titles, or root safety guarantees already relying on that profile.

**Why this priority**: A profile's kind, handling, and root cannot change once referenced, and a
referenced profile cannot be deleted; this protects already-placed roots and in-flight requests,
but it is secondary to the initial creation/assignment flow.

**Independent Test**: Attempt to delete a profile referenced by an existing request/title and
confirm it is rejected with a clear in-use error; attempt to change a referenced profile's kind,
handling, or root and confirm only the name can change.

**Acceptance Scenarios**:

1. **Given** a profile currently referenced by a request or title, **When** an admin attempts to
   delete it, **Then** the deletion is rejected with a clear in-use error.
2. **Given** a media kind with exactly one profile, **When** an admin attempts to delete that last
   profile for the kind, **Then** the deletion is rejected so each kind always retains at least one
   profile.
3. **Given** a referenced profile, **When** an admin renames it, **Then** the rename succeeds while
   its kind, handling, and root remain unchanged.

---

### Edge Cases

- Two profiles within the same media kind cannot share a name that is identical case-insensitively
  after trimming.
- A submitted profile root must be absolute, normalized, not `/`, and unique by expanded path
  within its kind; nested roots at different specificity are allowed and scanned most-specific
  first.
- A relative or non-normalized submitted root is rejected outright rather than silently rewritten.
- Concurrent admin writes that would both pass a root-uniqueness or last-profile check are
  serialized so only one succeeds.
- An API v1 payload supplying both a profile id and the legacy handling field is rejected.
- Adopting into a uniquely-matching named root assigns that exact profile; adopting into a root
  shared by legacy fallback paths cannot infer a blank profile and keeps existing Auto/handling
  behavior; an ambiguous explicit root fails closed rather than guessing.
- An unselected request in the approval UI continues to default to the seeded Standard profile.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Admins MUST be able to create a named movie or TV profile with a name, media kind,
  Standard-or-Anime handling, and an optional library root.
- **FR-002**: Users and admins MUST be able to reference a profile by id when creating a request or
  setting a title's destination.
- **FR-003**: System MUST reject a profile assignment whose kind does not match the target, or
  whose id does not exist, without altering the request's or title's current state.
- **FR-004**: System MUST keep the legacy Standard/Anime handling field synchronized with a
  profile's handling whenever a profile assignment is made, so background jobs and API v1 clients
  relying on the legacy field continue to work.
- **FR-005**: System MUST enforce that profile names are trimmed, non-empty, and unique
  case-insensitively within their media kind.
- **FR-006**: System MUST enforce that a nonblank profile root is absolute, normalized, not `/`,
  and unique by expanded path within its kind, rejecting relative or non-normalized submissions
  rather than rewriting them.
- **FR-007**: System MUST allow a referenced profile to be renamed but MUST prevent changing its
  kind, handling, or root once referenced.
- **FR-008**: System MUST prevent deleting a profile that is referenced by any existing request or
  title.
- **FR-009**: System MUST guarantee that each media kind retains at least one profile at all times.
- **FR-010**: System MUST fall back to the existing matching Standard/Anime root when a profile's
  root is blank, so existing installs keep the same import/adoption paths after migration.
- **FR-011**: System MUST deterministically backfill explicit Standard/Anime titles and requests to
  the matching seeded profile during migration, while leaving Auto titles and requests with no
  proposed handling at a null profile id.
- **FR-012**: System MUST default an unselected request in the approval UI to the seeded Standard
  profile.
- **FR-013**: API v1 MUST reject a payload that supplies both a profile id and the legacy
  handling field.
- **FR-014**: API v1 request output MUST include the profile's live association (id, name, kind,
  handling) so a subsequent rename is reflected, while continuing to accept legacy handling input.
- **FR-015**: System MUST revalidate a profile and confirm its root containment when committing an
  adoption, assigning the profile only when an explicit root match is unique and otherwise failing
  closed.
- **FR-016**: System MUST serialize root-uniqueness and last-profile-retention checks so concurrent
  admin writes cannot both pass the same check.
- **FR-017**: Admins MUST be able to manage profiles from the existing admin session with labelled
  form controls, inline validation errors, and confirmed deletion that surfaces in-use or
  last-profile errors clearly.

### Key Entities *(include if feature involves data)*

- **Media profile**: An operator-named destination choice with a media kind (movie or TV), a
  Standard-or-Anime handling engine, and an optional dedicated library root; referenced by id from
  requests and titles.
- **Request**: A per-title or per-season acquisition request that may carry a profile id
  determining its destination and handling.
- **Title**: A movie or series record that may carry a profile id, with its legacy Standard/Anime
  handling field kept synchronized with that profile.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A household can create a named movie or TV profile and successfully assign it during
  a request or on a title.
- **SC-002**: Every wrong-kind or unknown profile assignment attempt is rejected without changing
  request or title state.
- **SC-003**: Every existing explicit Standard/Anime title and request is deterministically
  backfilled to a matching profile on migration, while every Auto title and nil-handling request
  remains at a null profile id.
- **SC-004**: A named, non-blank profile root is used for import and adoption of matching titles;
  a blank root produces byte-identical destination paths to the pre-v2 behavior.
- **SC-005**: No referenced profile can be deleted, and every profile-managed destination remains
  fenced to its own root.
- **SC-006**: The full project automated test suite passes with the feature in place.

## Assumptions

- The feature keeps the existing Standard/Anime handling engine and global release scoring rules
  unchanged; a profile only chooses between the two proven engines rather than introducing a third
  handling mode or duplicating the scorer/Anime policy.
- Media-server scans remain per media kind (Jellyfin refreshes globally; Plex uses its configured
  movie/TV section), not per named profile.
- Rollback from v2 is explicitly association-lossy but handling-safe: legacy handling columns stay
  synchronized throughout v2, so a rollback drops profile names and custom destinations but never
  changes which handling engine (Standard vs Anime) a title or request used.
- Arbitrary named library destinations beyond the Standard/Anime engine choice were the deferred
  item this feature resolves (see the 051 spec's deferral list); this feature is the direct
  follow-through on that deferral, not new unscoped work.
