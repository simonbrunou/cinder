# Feature Specification: Book requests, approval, and target creation

**Feature Branch**: `058-books-b3a-requests-approval`

**Created**: 2026-08-25

**Status**: Shipped (v3.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-08-25-books-b3a-requests-and-approval.md`)

Part of the umbrella books/Readarr-replacement effort (see `053-books-readarr-replacement`); this
slice is the first half of B3 (data model, approval, and API), with Discover and the work-detail
page delivered in the companion slice `059-books-b3b-discovery-request-ui`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A household member requests a book (Priority: P1)

Why this priority: this is the entry point of the whole books workflow — without a requestable
book, nothing downstream (approval, acquisition) has anything to act on.

Independent Test: create a book request through the context API for an existing work and verify it
lands as pending with no managed acquisition target created.

**Acceptance Scenarios**:

1. **Given** a known work and a media kind of e-book or audiobook, **When** a household member
   requests it, **Then** a pending request row is created and no acquisition target exists yet.
2. **Given** a work id that does not exist locally, **When** a request is submitted for it, **Then**
   the request is rejected with an explicit "unknown work" error rather than creating a title-less
   request.
3. **Given** one work, **When** a household member requests it as both an e-book and an audiobook,
   **Then** both requests succeed independently and do not collide.

### User Story 2 - Admin approval creates a monitored target (Priority: P1)

Why this priority: approval is the choke-point that turns a request into something the acquisition
pipeline will act on; it must enforce the same profile and hold-state guarantees as movies/TV.

Independent Test: approve a pending book request with a valid e-book profile and confirm exactly one
monitored target is created, idempotently across re-approval.

**Acceptance Scenarios**:

1. **Given** a pending e-book request and a configured e-book profile, **When** an admin approves it,
   **Then** a target for that (work, media kind) becomes monitored, carrying the approved profile.
2. **Given** a target that is already available, **When** a new request for the same
   (work, media kind) is approved, **Then** the target's status is left available and only its
   profile is updated — never downgraded.
3. **Given** a target that is held, **When** an approval is attempted against it, **Then** the
   approval fails explicitly rather than silently succeeding or leaving an unexplained pending row.

### User Story 3 - Approval fails closed without a matching profile (Priority: P2)

Why this priority: creating a target the acquisition pipeline cannot score would produce a silently
broken managed target.

Independent Test: attempt to approve a book request with no e-book profile configured, or with a
mismatched-kind profile, and confirm no target is created either way.

**Acceptance Scenarios**:

1. **Given** no e-book profile configured, **When** an admin attempts to approve an e-book request,
   **Then** approval fails with an explicit invalid-profile error and no target is created.
2. **Given** a movie/TV profile, **When** it is supplied for a book approval, **Then** the approval
   is rejected at both the application and database-integrity level.

### Edge Cases

- Under an "auto-approve all" household policy, a request against a held target fails before any
  request row is written, rather than being silently parked as pending with no path to resolution.
- A book request without a media kind is rejected at the changeset level; a non-book request
  carrying a media kind is likewise rejected.
- Re-kinding a media profile that a book request currently references is blocked by the same
  integrity mechanism that protects movie/TV profile references.
- `/api/v1` and personal export projections round-trip the requested media kind for books exactly as
  they do the existing target-type fields for movies/TV.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to request a locally-known book work as either an e-book or an
  audiobook, tracked as an independent monitoring axis per (work, media kind).
- **FR-002**: System MUST reject a book request that does not specify a media kind, and reject a
  media kind on any non-book request.
- **FR-003**: System MUST allow one work to carry independent, non-colliding pending requests for
  e-book and audiobook simultaneously.
- **FR-004**: System MUST reject a request referencing a work id that does not exist locally, with an
  explicit error, rather than creating an incomplete request record.
- **FR-005**: System MUST NOT create an acquisition target when a book request is created; a target
  is created only on approval.
- **FR-006**: System MUST, on approval, create the (work, media kind) target if it does not exist and
  transition it to monitored, carrying the approved profile.
- **FR-007**: System MUST NOT downgrade a target that is already monitored or available when a new
  request for the same (work, media kind) is approved — an already-monitored or already-available
  target keeps its status and only takes the new profile.
- **FR-008**: System MUST refuse approval outright against a target in a held state, with an explicit
  error distinguishing it from a generic failure, and MUST create no request or target as a result.
- **FR-009**: System MUST require a book-kind media profile for approval and MUST fail approval
  closed, creating no target, when no such profile is configured or an incompatible profile is
  supplied.
- **FR-010**: System MUST reject, at the database-integrity level, a book request or target carrying
  a profile whose kind does not match its media kind, independent of application-level validation.
- **FR-011**: System MUST prevent an operator from re-kinding a media profile that a book request or
  target currently references.
- **FR-012**: System MUST allow an admin's own book request to auto-approve under existing
  auto-approval rules, subject to the same held-target refusal as any other approval.
- **FR-013**: System MUST project the requested media kind in the request API representation and in
  a user's personal request export, matching existing movie/TV projection conventions.
- **FR-014**: System MUST derive a book request's display title and year from the local catalog
  record rather than an external provider at request time, and MUST reject the request if that
  local record is missing.

### Key Entities

- **Request**: a household member's ask to acquire a work, now carrying an optional media kind for
  book requests, distinguishing e-book from audiobook asks on the same work.
- **Book target**: the independently monitored acquisition target for one (work, media kind) pair,
  transitioning through unmonitored, monitored, available, and held states.
- **Media profile**: a named quality/handling configuration, now including book-kind profiles
  alongside movie/TV profiles, matched to a request's media kind at approval.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A household member can request a work as an e-book with no acquisition target created
  before an admin approves it.
- **SC-002**: An admin's own book request auto-approves under existing auto-approval rules and
  results in exactly one monitored target.
- **SC-003**: One work supports an independent e-book request/target and audiobook request/target at
  the same time without either interfering with the other.
- **SC-004**: Approval never silently downgrades an available target, and refuses outright — rather
  than silently succeeding — against a held target.
- **SC-005**: A book request can never carry a movie or TV profile, enforced at both the request
  validation layer and the database-integrity layer.

## Assumptions

- Discover, the book work-detail route, and shared request UI components are explicitly out of scope
  for this slice; they are delivered in `059-books-b3b-discovery-request-ui`.
- Local author search and author aliases are deferred to the discovery slice, since they belong to
  the search surface rather than the request/approval data path.
- Operator metadata overrides remain out of scope: no UI exists yet to create one, so there is
  nothing for this slice to preserve.
- Cover art for book requests is deferred; no rendering path consumes it until the discovery slice.
- Deleting an approved book request/target, and fanning out availability/failure notifications for
  it, are deferred to later acquisition-related milestones — no acquisition or deletion path exists
  yet for books.
- Edition-specific requests are out of scope; the request boundary is the work, with edition
  selection deferred to later acquisition milestones.
