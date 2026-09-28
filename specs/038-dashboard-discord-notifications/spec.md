# Feature Specification: Dashboard Maintenance Discord Notifications

**Feature Branch**: `038-dashboard-discord-notifications`

**Created**: 2026-07-11

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-11-dashboard-discord-notifications-design.md`), plan.md (originally `docs/superpowers/plans/2026-07-11-dashboard-discord-notifications.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Get notified when a manual maintenance action finishes (Priority: P1)

An administrator who triggers a maintenance action from the Dashboard and then leaves the page
wants to learn in Discord whether it completed or failed, instead of having to return to the
Dashboard to check.

**Why this priority**: This is the entire value of the feature — closing the loop on an action the
admin is no longer watching, using the notification channel Cinder already supports.

**Independent Test**: Trigger a maintenance action from the Dashboard, let it finish, and observe
a Discord message describing the outcome.

**Acceptance Scenarios**:

1. **Given** an admin triggers the movie pipeline action and it completes successfully, **When**
   the action finishes, **Then** a Discord message announces the completed operation by name.
2. **Given** an admin triggers a movie library scan and the media server returns an error, **When**
   the action finishes, **Then** a Discord message announces the failed operation with the
   technical reason.
3. **Given** a maintenance task exits unexpectedly (a crash rather than a returned error), **When**
   the task ends, **Then** a Discord message reports it as a failure with the exit reason.

### User Story 2 - No noise for actions the admin didn't ask about (Priority: P2)

An administrator does not want a Discord message every time a background worker runs on its
normal schedule, only for the maintenance actions they personally triggered from the Dashboard.

**Why this priority**: Notification dispatch stays in the Dashboard LiveView so only manually
requested actions produce a notification; emitting from inside the workers would also alert for
scheduled passes.

**Independent Test**: Let a worker's normal scheduled pass run, and separately let a Dashboard
click be rejected as a duplicate; confirm neither produces a Discord message.

**Acceptance Scenarios**:

1. **Given** a worker runs on its normal schedule (not triggered from the Dashboard), **When** it
   finishes, **Then** no Discord message is sent for it.
2. **Given** a maintenance action is already running, **When** a duplicate click is rejected,
   **Then** no additional Discord message is sent.
3. **Given** a maintenance action starts, **When** it begins running, **Then** no "started" message
   is sent — only the eventual completion or failure produces a message.

### Edge Cases

- An unrecognized/unknown maintenance action key must still render a safe, readable Discord
  message (using its raw identifier) rather than raising or silently dropping the notification.
- If the Discord delivery itself fails (webhook down, HTTP error, timeout), the failure is logged
  and swallowed; it must never change the maintenance action's own completed/failed result shown
  in the Dashboard, and must never leave an action stuck showing as running.
- When no Discord webhook is configured, the equivalent outcome is still recorded in the
  application log with an explicit, readable message.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST send a notification when a Dashboard-triggered maintenance action
  (movie pipeline, TV pipeline, monitored-series refresh, subtitle backfill, movie library scan,
  or TV library scan) completes successfully.
- **FR-002**: The system MUST send a notification when a Dashboard-triggered maintenance action
  fails, whether the failure is a returned error or an unexpected task exit, and the notification
  MUST include the technical failure reason.
- **FR-003**: The system MUST NOT send a notification when an action starts, when a duplicate
  click on an already-running action is rejected, or when the corresponding worker runs on its
  normal schedule rather than from the Dashboard.
- **FR-004**: The system MUST dispatch every maintenance notification only through the existing
  general-purpose notifier entry point, not by calling the Discord implementation directly.
- **FR-005**: The system MUST render a completed maintenance notification distinctly from a
  failed one (e.g. by title/color) and MUST label each with a human-readable operation name.
- **FR-006**: The system MUST render the equivalent maintenance outcome as an explicit log message
  when Discord is not the active notifier.
- **FR-007**: The system MUST render a maintenance notification for an unrecognized action
  identifier safely, without raising and without suppressing the notification.
- **FR-008**: A notification delivery failure MUST be logged and MUST NOT alter the maintenance
  action's completed/failed result already determined by its own outcome.
- **FR-009**: The system MUST NOT add new settings, database-backed notification history, retry
  logic for notification delivery, or a second notification transport as part of this feature.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every Dashboard-triggered maintenance action that completes or fails produces
  exactly one corresponding notification.
- **SC-002**: No notification is produced for an action start, a rejected duplicate click, or a
  worker's normal scheduled run.
- **SC-003**: A notification delivery failure never changes what the Dashboard shows for that
  action's outcome.
- **SC-004**: An unrecognized maintenance action still produces a readable, non-crashing
  notification.

## Assumptions

- The feature does not announce scheduled (non-Dashboard) maintenance runs; that is an explicit
  non-goal.
- Notification delivery status is not persisted, and failed Discord posts are not retried.
- Discord operation names are not localized.
- The notification does not include the identity of the triggering administrator; these are
  deferred as broader product decisions not needed for a single-household admin Dashboard.
