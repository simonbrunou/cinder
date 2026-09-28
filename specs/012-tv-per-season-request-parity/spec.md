# Feature Specification: TV Per-Season Request/Approval Parity

**Feature Branch**: `012-tv-per-season-request-parity`

**Created**: 2026-06-23

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-23-tv-per-season-request-parity-design.md`), plan.md (originally `docs/plans/2026-06-23-tv-per-season-request-parity.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A household member requests a season of a show (Priority: P1)

A non-admin household member searches for a TV show and requests a specific season, exactly as they already can for a movie. The request enters a pending state until an admin approves it; only then does the show/season materialize in the library and begin downloading.

**Why this priority**: This closes TV's second-class status — TV was previously admin-only/admin-direct with no request, approval, quota, or requester visibility, unlike movies. Bringing TV to parity with the existing movie request loop is the entire goal of this feature.

**Independent Test**: As a non-admin user, request a season of a show not yet in the local library; verify only a pending request is created and no series or monitored season exists until an admin approves.

**Acceptance Scenarios**:

1. **Given** a non-admin user browsing a show not yet added locally, **When** they request a specific season, **Then** a pending request is created referencing that show and season, and no series/season is created or monitored yet.
2. **Given** a pending season request, **When** an admin approves it, **Then** the series (and its season tree) is created if absent, and only the requested season is set to monitored — other seasons are left as they were.
3. **Given** an admin requests a season themselves, **When** the request is submitted, **Then** it is auto-approved and the season is monitored immediately, just as an admin's own movie request auto-approves.

---

### User Story 2 - Per-season granularity, not whole-series or per-episode (Priority: P1)

A user requests "Show, Season 2" as a single natural unit — not the whole series and not an individual episode.

**Why this priority**: The design explicitly locks season as the request granularity as the natural unit; this shapes every other requirement (uniqueness, monitoring scope, UI).

**Independent Test**: Request two different seasons of the same show as two separate actions; verify they produce two distinct request records, each independently approvable, and each approval only monitors its own season.

**Acceptance Scenarios**:

1. **Given** a show with multiple seasons, **When** a user requests season 1 and later season 2, **Then** these are two distinct, independently tracked requests.
2. **Given** season 1 is approved and monitored, **When** season 2 is later approved, **Then** season 2 becomes monitored while season 1's monitoring state is unaffected.
3. **Given** a user re-requests a season they already requested, **When** they submit it again, **Then** the duplicate is deduplicated against the existing request (movie request deduplication is unaffected).

---

### User Story 3 - Requesters and admins can see and manage season requests (Priority: P2)

A requester can see the status of their season requests (Pending/Approved/Denied) in their personal requests view; an admin sees season requests in the approval queue alongside movie requests, and per-title state badges reflect a season's request status.

**Why this priority**: Visibility of request state is core to the parity goal — a request flow without visible status feedback is not usable end-to-end.

**Independent Test**: Submit a season request, then check it appears correctly labeled ("Show — Season N") with its status in the requester's personal view and in the admin approval queue.

**Acceptance Scenarios**:

1. **Given** a pending season request, **When** the requesting user views their personal requests list, **Then** it shows "Show — Season N" with a Pending badge.
2. **Given** a pending season request, **When** an admin views the approval queue, **Then** the season number is shown alongside the show's title/poster like any other pending request.
3. **Given** a show a user is browsing, **When** they view its seasons, **Then** each season shows the current user's own request state (Pending/Approved/Denied) or a Request action if none exists.

---

### User Story 4 - Discovery works for shows not yet in the local library (Priority: P2)

A user wants to request a season of a show that has never been added locally — its season list is only known from the external metadata source.

**Why this priority**: Without this, only already-added shows could receive season requests, defeating the purpose of a request-driven (not admin-direct) TV flow.

**Independent Test**: Search for a show never added locally; open its discovery page keyed by its external id; verify its season list renders with request actions, and requesting a season works without the show existing locally beforehand.

**Acceptance Scenarios**:

1. **Given** a show not yet in the local library, **When** a user opens its discovery page, **Then** the season list (fetched from the external metadata source) renders with a Request action per season.
2. **Given** a season request on a not-yet-added show is approved, **When** approval completes, **Then** the series and season tree are created from the external source and the requested season is monitored.

---

### Edge Cases

- A season request targeting a show whose series already exists locally: approval must not re-create it, only flip the requested season's monitoring on.
- Creating a series from an external source involves network calls; this must not block the admin's approve action from completing promptly, nor happen inside a database transaction alongside monitoring writes.
- A user hitting their request quota is rejected the same way for a season request as for a movie request; each season counts as one request toward quota.
- Per-episode requests are explicitly out of scope — season is the smallest requestable unit.
- A "request the whole series" convenience (fanning out to every season) is out of scope for this feature.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Users MUST be able to request a specific season of a TV show, whether or not that show already exists in the local library.
- **FR-002**: A season request from a non-admin user MUST enter a pending state and MUST NOT create or monitor any series/season data until an admin approves it.
- **FR-003**: An admin's own season request, or an admin approving another user's request, MUST result in the season being created (if needed) and monitored immediately.
- **FR-004**: System MUST treat each season of a show as an independently requestable, independently trackable unit — not the whole series, not a single episode.
- **FR-005**: Approving a season request MUST monitor only that requested season, leaving all other seasons of the same series unaffected.
- **FR-006**: System MUST prevent duplicate active requests for the same season by the same user, while still allowing different seasons of the same show, or the same season by different users, to be requested independently.
- **FR-007**: Each season request MUST count toward the requesting user's request quota, exactly as a movie request does.
- **FR-008**: Users MUST be able to view the status (Pending/Approved/Denied) of their own season requests in their personal requests view, labeled with the show title and season number.
- **FR-009**: Admins MUST be able to see pending season requests in the same approval queue used for movie requests, with the season number visible.
- **FR-010**: Users MUST be able to discover and browse the season list of a show that is not yet in the local library, and request from that view.
- **FR-011**: TV discovery/request surfaces MUST be reachable by any authenticated household member, not admin-only; per-episode/per-season monitoring management on the local series detail view MUST remain admin-only.
- **FR-012**: The existing movie request/approval/quota behavior MUST remain completely unchanged by this feature.

### Key Entities

- **Request**: A user's ask for a piece of media, now generalized to also represent "this show, this season," carrying status (Pending/Approved/Denied), the requesting user, and quota accounting.
- **Series**: A TV show tracked in the local library, containing seasons.
- **Season**: A numbered season of a series that can be individually monitored and, via this feature, individually requested.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A non-admin user can request a season and see it reflected as Pending in their personal view, with zero library changes occurring before admin approval.
- **SC-002**: After admin approval of a season request, the show appears in the library with exactly the requested season monitored (verified: other seasons untouched) and its episodes begin being searched/grabbed automatically.
- **SC-003**: Two different seasons of the same show can be requested and approved independently without interfering with each other's monitoring state.
- **SC-004**: A user attempting to exceed their request quota with season requests is blocked the same way a movie-quota violation is blocked.
- **SC-005**: A show never before added locally can be discovered, and a season of it requested, entirely from its external-source season list.
- **SC-006**: All pre-existing movie request/approval behavior continues to pass its existing verification unchanged.

## Assumptions

- Per-episode requests remain out of scope; season is the smallest unit a user can request.
- A unified movie+TV discovery grid is out of scope for this feature (movies and TV keep parallel, separate discovery pages).
- Surfacing TV pipeline state on the admin movie-pipeline dashboard is out of scope; TV management continues to live on the series detail and calendar views.
- A "request the entire series" convenience action is deferred to a later feature.
- The existing single polymorphic request/approval gate is extended to dispatch on season-vs-movie targets rather than introducing a parallel TV-specific request path.
