# Feature Specification: Accounts, Roles, and Request/Approval (M2)

**Feature Branch**: `007-m2-accounts-roles-requests`

**Created**: 2026-06-21

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-21-m2-accounts-roles-requests-design.md`), plan.md (originally `docs/superpowers/plans/2026-06-21-m2-accounts-roles-requests.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Real local accounts replace the shared password (Priority: P1)

Instead of a single shared Basic-auth password for the whole household, each person registers
their own account with an email and password and logs in individually. The first person to
register automatically becomes an administrator.

**Why this priority**: This is the security foundation everything else in the milestone depends
on — without individual accounts, there is no way to distinguish who is allowed to add titles
directly versus who must request them.

**Independent Test**: Register a new account with no SMTP configured, confirm the account is
auto-confirmed and immediately logged in, and confirm the very first registrant on a fresh install
receives the admin role while subsequent registrants do not.

**Acceptance Scenarios**:

1. **Given** a fresh install with no users, **When** a person registers with email and password,
   **Then** their account is created, auto-confirmed (no email round-trip required), and they are
   granted the administrator role.
2. **Given** an install with an existing admin, **When** a second person registers, **Then** their
   account is created as a regular user, not an admin.
3. **Given** a registration form submission, **When** it includes a forged role field,
   **Then** the resulting account's role is still assigned server-side and the forged value is
   ignored.
4. **Given** a successful registration, **When** the form is submitted, **Then** the user is
   immediately logged in without a separate manual login step.

---

### User Story 2 - Non-admins request titles; admins approve or deny (Priority: P1)

A regular user who wants a movie added to the library submits a request instead of adding it
directly. No movie row — and therefore no download — is created until an admin approves that
request. Admins see a queue of pending requests and can approve or deny each one.

**Why this priority**: This is the actual security spine of the milestone — the entire point of
splitting roles is meaningless if a non-admin can still trigger a download without gatekeeping.

**Independent Test**: As a non-admin user, submit an "Add" for a title and confirm no movie is
created and no download starts; then, as an admin, approve the resulting pending request and
confirm the movie is created and the pipeline picks it up.

**Acceptance Scenarios**:

1. **Given** a signed-in non-admin user, **When** they add a title, **Then** a pending request is
   created and no movie row exists yet.
2. **Given** a pending request, **When** an admin approves it, **Then** a movie is created (or an
   existing movie for that title is reused at its current status, never reset), the request is
   marked approved, and the download pipeline picks it up.
3. **Given** a pending request, **When** an admin denies it with a reason, **Then** the request is
   marked denied with that reason and no movie is created.
4. **Given** a signed-in admin, **When** they add a title themselves, **Then** the request is
   auto-approved and the movie is created immediately, attributed to that admin.
5. **Given** the global auto-approve setting is enabled, **When** any user adds a title, **Then**
   the request is auto-approved without admin intervention.
6. **Given** a user submits a duplicate pending request for the same title, **When** the request is
   created, **Then** it is rejected as a duplicate rather than creating a second pending request.

---

### User Story 3 - Role-gated administrative areas (Priority: P2)

Administrative pages — the approval queue, system status, and settings — are only reachable by
users with the admin role. Anonymous visitors are redirected to log in, and signed-in non-admins
are redirected away with a message.

**Why this priority**: Without route-level gating, the role split would only be cosmetic; a
non-admin could reach admin functionality directly by URL.

**Independent Test**: As an anonymous visitor, request an admin page and confirm redirection to
login; as a signed-in non-admin, request the same page and confirm redirection with a flash
message.

**Acceptance Scenarios**:

1. **Given** an anonymous visitor, **When** they request any authenticated page, **Then** they are
   redirected to the login page.
2. **Given** a signed-in non-admin user, **When** they request an admin-only page (approval queue,
   status, settings, or development tools), **Then** they are redirected away with a flash message.
3. **Given** a signed-in admin, **When** they request an admin-only page, **Then** they are
   granted access.
4. **Given** the deployment has an optional outer password gate enabled, **When** any browser
   route is requested, **Then** that outer gate applies uniformly to every route — app pages, auth
   pages, admin pages, and development tools alike.

---

### Edge Cases

- Two admins approving the same request concurrently, or an admin approving while the background
  poller is also touching the same title, must not create two movie rows — the second write is
  caught and the existing row is reused.
- Approving a request for a title whose movie already exists at a further-along status (e.g.
  downloading or available) must reuse that movie unchanged rather than resetting it back to
  newly-requested.
- Denying an already-approved request, or approving an already-denied one, is guarded so a race
  between two admins cannot silently flip a request's outcome after the fact.
- A movie created via request approval must appear live on an already-open discovery page without
  requiring a reload.
- The magic-link/password-reset/email-confirmation machinery is kept dormant (present but unused
  in the UI) rather than removed, since a household could later configure outbound email.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow open self-registration with email and password, with no outbound
  email required for account confirmation.
- **FR-002**: System MUST automatically grant the administrator role to the first user to register
  on a fresh install, and the regular-user role to every subsequent registrant.
- **FR-003**: System MUST assign a user's role exclusively on the server, never accepting it as a
  submitted form value.
- **FR-004**: System MUST log a user in automatically immediately after successful registration.
- **FR-005**: System MUST require every non-admin request to create a title to go through a
  pending-approval step that produces no library entry until approved.
- **FR-006**: System MUST allow an admin to approve a pending request, causing the corresponding
  title to be created (or an existing title reused at its current state) and entered into the
  download pipeline.
- **FR-007**: System MUST allow an admin to deny a pending request with a reason, recording that
  reason without creating a library entry.
- **FR-008**: System MUST auto-approve requests made by admins themselves, and MUST auto-approve
  every user's requests when a global auto-approve setting is enabled.
- **FR-009**: System MUST prevent a user from submitting a second pending request for the same
  title while one is already pending.
- **FR-010**: System MUST restrict the approval queue, system status, and settings pages to
  admin-role users only, redirecting anonymous visitors to log in and non-admin users away with a
  message.
- **FR-011**: System MUST restrict development/diagnostic tooling routes to admin-role users only.
- **FR-012**: System MUST apply any optional outer household password gate uniformly across every
  browser-facing route, not just a subset.
- **FR-013**: System MUST ensure concurrent approval attempts (by two admins, or an admin and the
  background pipeline) on the same title result in exactly one library entry, never a duplicate.
- **FR-014**: System MUST notify any open discovery view in real time when a new title is created
  via approval, without requiring a manual reload.
- **FR-015**: System MUST NOT create a library entry for a non-admin's request under any code path
  outside the request/approval flow.

### Key Entities

- **User**: A registered account with an email, password, and role (administrator or regular
  user).
- **Request**: A record of a user asking for a specific title to be added, holding its target
  identity, a display snapshot (title/year/poster), status (pending/approved/denied), an optional
  denial reason, and which admin approved it (if any).
- **Movie**: A library entry created only once its corresponding request is approved (or created
  directly by an admin), entering the existing download pipeline.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: No non-admin action can result in a library entry being created without a prior
  admin approval — verified by an automated regression check that a non-admin's add path produces
  zero library rows.
- **SC-002**: A brand-new install requires no pre-configured credentials — the first person to
  register becomes the administrator automatically.
- **SC-003**: An admin can move a title from "pending request" to "downloading" through approval
  alone, without any direct database or configuration intervention.
- **SC-004**: Every admin-only page is unreachable by an anonymous or non-admin visitor, in every
  case, including non-LiveView diagnostic routes.
- **SC-005**: Concurrent approval of the same title never results in more than one library entry.

## Assumptions

- Real outbound email (SMTP) delivery and enforced email confirmation are explicitly out of scope
  for this milestone; the underlying context code is kept dormant rather than deleted.
- Each request is modeled with a general-purpose target-type-and-identifier pair up front (rather
  than a movie-specific reference), anticipating that a future TV-episode request will need
  additional identifying detail the current data model doesn't yet carry.
- The optional outer Basic-auth gate is treated as a deployment-level convenience (e.g. behind a
  reverse proxy), not the primary security boundary — the primary boundary is the
  request/approval data model itself.
- Per-title request-status indicators on the discovery grid (showing a user their own pending
  status inline) are explicitly deferred to a later milestone, not included here.
