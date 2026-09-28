# Feature Specification: Onboarding Wizard and Requester UX (M3)

**Feature Branch**: `008-m3-onboarding-requester-ux`

**Created**: 2026-06-22

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-22-m3-design.md`), plan.md (originally `docs/plans/2026-06-22-m3-onboarding-requester-ux.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - First-run setup wizard (Priority: P1)

A stranger installs Cinder with no prior configuration and no environment variables set. After
registering as the first (admin) user, they are guided through a setup wizard that requires every
essential service — TMDB, an indexer, at least one download client, a media server, and a library
path — to be configured and verified working before the app becomes usable.

**Why this priority**: This is the milestone's stated goal — making the multi-user movies product
installable-and-operable by a stranger, not just a developer who already knows the required
environment variables.

**Independent Test**: On a fresh install with no configuration, register the first user and
confirm they land on the setup wizard; attempt to finish before all services test successfully and
confirm it's blocked; configure and successfully test all five, then confirm setup completes and
the app becomes reachable.

**Acceptance Scenarios**:

1. **Given** a fresh install with no completed setup, **When** the first (admin) user registers,
   **Then** they are routed to the setup wizard instead of the normal discovery page.
2. **Given** the setup wizard, **When** not every required service has been tested successfully,
   **Then** the finish action is disabled.
3. **Given** every required service (TMDB, indexer, a download client, a media server, and the
   library path) tests successfully, **When** the admin finishes the wizard, **Then** setup is
   marked complete and the admin is taken to the normal discovery page.
4. **Given** setup is already complete, **When** any user visits the setup wizard URL, **Then**
   they are redirected away rather than shown the wizard again.
5. **Given** setup is incomplete, **When** a non-admin user tries to sign in, **Then** they are
   redirected to the login page with a message rather than let into an unconfigured app.

---

### User Story 2 - Per-user request quotas (Priority: P2)

An admin can cap how many requests a given non-admin user may have pending at once, preventing one
user from flooding the approval queue.

**Why this priority**: Necessary for a self-hosted multi-user household where quotas are the
lightweight abuse-prevention control admins need, but secondary to simply making the app runnable
at all.

**Independent Test**: Set a user's quota to 1, submit a request as that user, then submit a second
request for a different title and confirm it is rejected until the first is resolved.

**Acceptance Scenarios**:

1. **Given** a user has a concurrent-pending request quota, **When** they already have that many
   pending requests, **Then** a further request is rejected rather than queued.
2. **Given** a user has no quota set, **When** they submit requests, **Then** there is no limit on
   how many may be pending at once.
3. **Given** an admin, or the global auto-approve setting is on, **When** a request is submitted,
   **Then** the quota check is bypassed since the request never sits in a pending state.
4. **Given** an admin viewing the user list, **When** they edit a user's quota inline, **Then** the
   new quota takes effect immediately for that user's future requests.

---

### User Story 3 - Requester visibility into their own requests (Priority: P2)

A non-admin user can see the status of everything they've requested — pending, approved, or denied
with a reason — in one place, and see an at-a-glance status badge on each title in the discovery
grid reflecting their own relationship to it, instead of always seeing a generic "Add" button.

**Why this priority**: Completes the requester experience — without this, a user who requested a
title has no way to know if it was approved, denied, or is still waiting, short of asking an
admin.

**Independent Test**: As a non-admin, submit a request, then visit the personal requests page and
confirm it shows as pending; have it denied and confirm the reason is visible; confirm the
discovery grid shows the corresponding badge instead of "Add" for that title.

**Acceptance Scenarios**:

1. **Given** a user has pending, approved, and denied requests, **When** they visit their personal
   requests page, **Then** each is shown with its current status (and denial reason, if denied).
2. **Given** an approved request whose movie is still downloading, **When** the user views their
   requests, **Then** the live pipeline state of that movie is reflected, updating through to
   available.
3. **Given** a title the user has already requested, **When** they view the discovery grid,
   **Then** the title shows a status badge (Pending/Approved/Available/Denied) in place of the
   default Add button.
4. **Given** a denied request, **When** the user views that title again, **Then** the Add button is
   re-enabled so they may request it again.

---

### Edge Cases

- A non-admin who visits the app while setup is still incomplete is redirected to login with a
  message rather than shown a partially-configured app.
- A denied request does not permanently block re-requesting the same title — only an existing
  pending request blocks a duplicate.
- Approving a request or a movie becoming available or failing must trigger a notification event
  even though the default notification channel is log-only, keeping the seam ready for a real
  transport later.
- The wizard's service tests validate the just-saved configuration, not unsaved form values in the
  browser, matching the existing settings page's save-then-test behavior.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST detect whether first-run setup has been completed and route the admin to
  a setup wizard whenever it has not.
- **FR-002**: System MUST require TMDB, an indexer, at least one download client, a media server,
  and a library path to each be successfully tested before setup can be marked complete.
- **FR-003**: System MUST prevent completing setup while any required service has not yet tested
  successfully.
- **FR-004**: System MUST make the library path configurable through the same settings mechanism
  as other services, rather than requiring an environment variable, while still allowing an
  environment-provided default to seed it.
- **FR-005**: System MUST redirect a non-admin user away from the app (to login, with a message)
  whenever setup has not yet been completed.
- **FR-006**: System MUST redirect any user away from the setup wizard once setup is already
  complete.
- **FR-007**: System MUST allow an admin to set a per-user cap on how many requests that user may
  have pending simultaneously, including removing the cap entirely.
- **FR-008**: System MUST reject a new request from a user who is already at their pending-request
  quota, without creating the request.
- **FR-009**: System MUST exempt admins and requests made while the global auto-approve setting is
  on from the pending-request quota, since those requests never remain pending.
- **FR-010**: System MUST provide a page where a user can see all of their own requests along with
  each one's current status and, for approved requests, the underlying title's live pipeline
  progress.
- **FR-011**: System MUST show a denial reason to the requesting user when their request is denied.
- **FR-012**: System MUST show a per-title status indicator on the discovery grid reflecting the
  signed-in user's own relationship to that title (no relationship, pending, approved, denied, or
  available) in place of a plain Add action.
- **FR-013**: System MUST re-enable requesting a title whose prior request was denied.
- **FR-014**: System MUST emit a notification event when a request is approved, when a requested
  title becomes available, and when it fails — dispatched through a single seam so a real delivery
  channel can be added later without touching the call sites.
- **FR-015**: System MUST provide an admin-only page listing all users where their role and request
  quota can be viewed and edited.

### Key Entities

- **User**: Gains a per-user concurrent-pending request quota (unlimited if unset), in addition to
  its existing role.
- **Request**: The existing pending/approved/denied request, now also visible to its owning user
  with live status and denial-reason detail.
- **Setup state**: A flag tracking whether the installation's first-run configuration has been
  completed.
- **Notification event**: A typed event (request approved, title available, title failed) sent
  through the notifier seam.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A brand-new installation with zero prior configuration can be taken from first
  registration to a fully working, request-capable app using only the in-app wizard — no manually
  edited environment variables required for any of the five gated services.
- **SC-002**: An admin can prevent a single user from monopolizing the approval queue by capping
  their concurrent pending requests, verified by that user's next over-quota request being
  rejected.
- **SC-003**: A user can determine the status of anything they've requested — including why it was
  denied — without needing to ask an admin or inspect the approval queue directly.
- **SC-004**: The discovery grid never shows a plain "Add" button for a title the signed-in user
  already has an active (pending or approved) or fulfilled (available) relationship with.

## Assumptions

- Real outbound notification delivery (Discord, email, etc.) is out of scope for this milestone;
  only the log-only default implementation and the seam for future transports are delivered.
- Email confirmation remains off (no SMTP requirement), consistent with the prior milestone's
  auto-confirm registration.
- Attribution of a created title to the requesting user is tracked only on the request record, not
  duplicated onto the title itself.
- TV/series requests are out of scope; this milestone's requester UX and quotas apply to the
  existing movies-only request flow.
