# Feature Specification: Admin CRUD on Entities

**Feature Branch**: `013-admin-crud`

**Created**: 2026-06-23

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-06-23-admin-crud-design.md`), plan.md (originally `docs/superpowers/plans/2026-06-23-admin-crud.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Admin manages user accounts fully (Priority: P1)

An admin can create new user accounts, edit a member's email, change their role, reset their password, adjust their request quota, and delete an account — while the system prevents removing or demoting the last remaining admin, and prevents an admin from deleting themselves.

**Why this priority**: Users were previously list-only with quota adjustment; full account lifecycle management is foundational admin capability and the only entity needing true create.

**Independent Test**: As an admin, create a user, edit their email, toggle their role, reset their password, then delete them; verify each action succeeds and a self-delete or last-admin-removal attempt is refused.

**Acceptance Scenarios**:

1. **Given** an admin on the users management screen, **When** they create a new user, **Then** the account is created with the assigned role and is usable.
2. **Given** an existing user, **When** an admin edits their email or resets their password, **Then** the change takes effect and the user's existing sessions are invalidated by a password reset.
3. **Given** there is only one admin account, **When** that admin tries to demote or delete themselves or the last admin, **Then** the action is refused with a clear message.
4. **Given** a user with request history, **When** an admin deletes that user, **Then** the user and their related request rows are removed together.

---

### User Story 2 - Admin manages Movies and Series, including safe cancel/delete (Priority: P1)

An admin can view, edit metadata for, cancel, or delete movies and TV series from dedicated management screens. Cancelling or deleting an item with an active download removes the orphaned download from the download client rather than leaving it running unmanaged.

**Why this priority**: Prior to this feature there were no admin pages for Movies at all, and no delete/cancel capability for either Movies or Series — items in progress could not be safely stopped.

**Independent Test**: As an admin, cancel a movie mid-download and verify its download is removed from the client and its status becomes cancelled; delete a series with in-flight episode downloads and verify all its downloads are removed from the client before the series and its seasons/episodes are removed.

**Acceptance Scenarios**:

1. **Given** a movie actively downloading, **When** an admin cancels it, **Then** its download is removed from the download client and its status becomes a terminal cancelled state.
2. **Given** a movie or series with no active download, **When** an admin deletes it, **Then** its database record is removed without attempting a client-side download removal.
3. **Given** a series with episodes at various pipeline stages (including a downloaded-but-not-yet-imported episode), **When** an admin cancels or deletes the series, **Then** every associated download is removed from the client and the series stops being re-grabbed by the search sweep.
4. **Given** an item with an active download, **When** an admin attempts a bare delete instead of cancel, **Then** the system still safely removes the client download rather than orphaning it.
5. **Given** an admin edits a series' metadata, **When** the edit is saved, **Then** existing per-season/per-episode monitoring settings are left untouched.

---

### User Story 3 - Admin manages Requests and Grabs (Priority: P2)

An admin can view all requests (not just pending) and delete a request row; an admin can view all grabs and delete a grab row.

**Why this priority**: Rounds out full visibility/cleanup over the remaining pipeline-adjacent entities, completing the "curated CRUD across all core entities" goal, lower priority than the destructive-action-heavy Users/Catalog work.

**Independent Test**: As an admin, view the full requests list (including non-pending), delete one, and confirm a warning about its side effects is shown; view the grabs list and delete one.

**Acceptance Scenarios**:

1. **Given** the requests management screen, **When** an admin views it, **Then** all requests (any status) are listed with their approve/deny actions still available for pending ones.
2. **Given** a request that already produced a library item, **When** an admin deletes that request row, **Then** they are warned that deleting it does not remove the item it spawned and may allow the title to be requested again.
3. **Given** the grabs management screen, **When** an admin views and deletes a grab, **Then** the grab row is removed from the list.

---

### Edge Cases

- An admin attempts to demote or delete the last remaining admin account — refused.
- An admin attempts to delete their own account — refused.
- A cancel/delete is attempted on an item whose tracked download id is unknown to (or already gone from) the download client — treated as already-removed, not an error.
- A cancel/delete is attempted on an item with no tracked download id at all — the download-client removal step is skipped entirely.
- Deleting a series must reap all of its episodes' grabs (removing their client downloads) before the season/episode rows are cascade-deleted, so no download is orphaned by the cascade itself.
- A destructive action is interrupted or its safety guard fails partway — the guard and its audit record must not leave a partial (rolled-back write but recorded audit, or vice versa) state.
- A status value newly introduced by this feature (cancelled) must render correctly everywhere status is displayed, not crash the page.
- Non-admin users attempting to reach any of these new/extended management screens.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Admins MUST be able to create, view, edit, and delete user accounts.
- **FR-002**: System MUST refuse any action that would leave zero admin accounts (demotion or deletion of the last admin).
- **FR-003**: System MUST refuse an admin's attempt to delete their own account.
- **FR-004**: Deleting a user MUST also remove that user's own request history.
- **FR-005**: Resetting a user's password MUST invalidate that user's existing sessions.
- **FR-006**: Admins MUST be able to view and edit metadata for movies and series from dedicated management screens.
- **FR-007**: Admins MUST be able to cancel an in-progress movie or series item, which MUST remove its associated download(s) from the download client and MUST NOT leave it re-grabbable by the automated search sweep.
- **FR-008**: Admins MUST be able to delete a movie or series record; if the item has an active download, deletion MUST first remove that download from the download client rather than leaving it orphaned.
- **FR-009**: Deleting a series MUST remove its seasons and episodes together with it, and MUST first remove every associated grab's download from the download client.
- **FR-010**: Editing a series' metadata MUST NOT alter existing per-season or per-episode monitoring settings.
- **FR-011**: A removal of a download from the download client MUST succeed (treated as a no-op) even if the download is already gone from the client, and MUST be skipped entirely when there is no tracked download for the item.
- **FR-012**: Admins MUST be able to view all requests regardless of status and delete a request row; the system MUST warn that deleting a request does not remove any library item it already produced.
- **FR-013**: Admins MUST be able to view all grabs and delete a grab row.
- **FR-014**: Every destructive admin action (delete, cancel, role change, password reset, quota change) MUST be recorded in an audit trail identifying who performed it, what it targeted, and when — and a rolled-back action MUST NOT leave an audit record.
- **FR-015**: Non-admin users MUST be blocked from reaching any of these management screens.
- **FR-016**: Any view currently open and showing a movie or series that gets deleted or updated by an admin elsewhere MUST reflect that change (removal or update) without requiring a manual reload.
- **FR-017**: On-disk media file removal MUST NOT occur as part of any delete in this feature — deletion is limited to database records.

### Key Entities

- **User**: A household account with a role (admin/member), a request quota, and request history.
- **Movie**: A tracked film with a pipeline status, optionally an active download.
- **Series / Season / Episode**: A tracked TV show and its structure, with per-season/episode monitoring and, at the episode level, an optional active download.
- **Request**: A user's approval-gated ask for a movie or season.
- **Grab**: A record of an acquired release tied to a movie or episode, with a tracked download.
- **Audit record**: An immutable log entry of a destructive admin action (actor, action, target, detail, timestamp).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An admin can complete the full lifecycle (create, edit, role change, password reset, delete) for a user account without leaving the admin surface.
- **SC-002**: Cancelling or deleting a movie or series with an active download never leaves that download running unmanaged in the download client (verified for every entity type covered).
- **SC-003**: Deleting the last admin account, or an admin deleting themselves, is impossible through any of the new controls.
- **SC-004**: Every destructive action taken through the new admin screens produces a corresponding audit entry, with no audit entry ever recorded for an action that was rolled back.
- **SC-005**: Introducing the new cancelled state does not cause any existing status display to fail to render.
- **SC-006**: A non-admin account cannot reach any of the new or extended management screens.

## Assumptions

- On-disk library file removal on delete is explicitly deferred to a separate, future feature; deletes in this feature affect only database records, and an already-imported item's file is left on disk (recoverable/reaped later).
- Create is only meaningful for Users; Movies/Series are created solely via the existing discovery/request flow, and Grabs are created solely by the acquisition pipeline — so this feature adds only read/update/delete for those entities.
- This feature is a curated, hand-rolled set of admin screens purpose-built to the app's existing conventions, not a generic data-console or third-party admin framework.
- Status changes continue to route exclusively through the existing pipeline state-transition mechanism; only non-status edits and deletes required new write paths.
