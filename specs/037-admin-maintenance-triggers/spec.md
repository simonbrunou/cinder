# Feature Specification: Admin Maintenance Triggers

**Feature Branch**: `037-admin-maintenance-triggers`

**Created**: 2026-07-11

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-11-admin-maintenance-triggers-design.md`), plan.md (originally `docs/superpowers/plans/2026-07-11-admin-maintenance-triggers.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run a background worker on demand (Priority: P1)

An administrator wants to run the movie pipeline, TV pipeline, monitored-series refresh, or
subtitle backfill immediately, without waiting for the worker's next scheduled tick, to confirm a
fix or unblock a household member.

**Why this priority**: This is the core value of the feature — replacing "wait for the schedule"
with an on-demand trigger for the four existing recurring passes.

**Independent Test**: From the admin Dashboard, click a worker action button and observe it
complete or fail independently of the others.

**Acceptance Scenarios**:

1. **Given** an admin is on the Dashboard, **When** they click the movie pipeline action, **Then**
   the button shows a progress label and, when the pass finishes, an independent "Completed"
   result appears beside that action.
2. **Given** a worker action is already running, **When** the admin sends a duplicate request for
   the same action, **Then** the action does not start twice in that session.
3. **Given** a worker pass raises or returns an error, **When** the pass ends, **Then** the action
   shows a generic "Failed" result and remains runnable again.

### User Story 2 - Trigger a media-server library scan (Priority: P2)

An administrator wants to ask the configured media server to rescan the movie or TV library right
away, for example after manually placing files, instead of waiting for the server's own scan
schedule.

**Why this priority**: Distinct from the four worker passes — it calls the media server directly
and surfaces a real success/failure result rather than the workers' best-effort logging.

**Independent Test**: Click the movie (or TV) scan action and observe a genuine
success/failure result reflecting the media server's response.

**Acceptance Scenarios**:

1. **Given** the media server is reachable, **When** the admin triggers a movie library scan,
   **Then** the action reports "Completed".
2. **Given** the media server returns an error, **When** the admin triggers a scan, **Then** the
   action reports "Failed" and the technical reason is logged (not shown to the admin).
3. **Given** a movie scan and a TV scan are triggered concurrently, **When** both finish, **Then**
   each retains its own independent result.

### Edge Cases

- Leaving the Dashboard page discards its displayed action result, but an already-accepted worker
  pass keeps running to completion.
- Two admin sessions can request the same worker action; the two passes queue and run
  sequentially rather than being deduplicated across sessions.
- Two sessions can request movie/TV scans concurrently; requests may overlap since the scan
  endpoint is an idempotent trigger.
- A successful worker pass result means the pass finished, not that every item inside it
  necessarily succeeded — per-item failures are isolated and logged separately by the worker.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST offer six maintenance actions from the existing admin-only
  Dashboard: run the movie pipeline once, run the TV pipeline once, refresh every monitored
  series from TMDB once, run the subtitle backfill once, scan the movie library, and scan the TV
  library.
- **FR-002**: Users MUST be able to trigger each action independently, with its own button,
  description, running indicator, and result, so no action's outcome can overwrite another's.
- **FR-003**: The system MUST disable only the button of a currently running action; all other
  actions remain available.
- **FR-004**: The system MUST prevent a duplicate request for an action that is already running
  in the same Dashboard session from starting a second concurrent run.
- **FR-005**: The four worker actions MUST run through the same supervised worker used for the
  scheduled pass, so a manual run serializes with (and cannot overlap) that worker's own tick.
- **FR-006**: The two scan actions MUST report the media server's real outcome (success or the
  specific failure), distinct from the workers' best-effort behavior.
- **FR-007**: The system MUST keep the existing automatic post-import media-server scan
  best-effort (log-and-continue), unaffected by making manual scans report real failures.
- **FR-008**: A completed action MUST be labeled as "completed" rather than implying a change or
  discovery was made.
- **FR-009**: A failed action MUST show a generic failure result to the admin while logging the
  specific reason.
- **FR-010**: The system MUST NOT expose this maintenance surface to non-admin users; the
  existing admin-only authorization boundary applies unchanged.
- **FR-011**: The system MUST NOT add a new route, navigation item, scheduler, persistent job
  record, run history, progress percentage, or global pause control as part of this feature.

### Key Entities

- **Maintenance action**: one of the six operator-triggerable operations, each with a stable
  identifier, a running state, and an independent result.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An administrator can start any of the six maintenance actions and see a completion
  or failure result without leaving the Dashboard or waiting for a scheduled pass.
- **SC-002**: Two or more maintenance actions can run at the same time within one session and
  each shows its own correct result with no cross-contamination.
- **SC-003**: A duplicate click on an already-running action never produces a second concurrent
  run in that session.
- **SC-004**: Non-admin users cannot reach or trigger any maintenance action.

## Assumptions

- No database-backed job records, run history, or cross-session running-state sharing are
  provided; operators needing to diagnose a run after leaving the page or across a restart are
  out of scope for this feature.
- Demoting an admin does not disconnect their already-open Dashboard session; revoking access
  mid-session is a separate, system-wide authentication concern.
- Concurrent scan requests across browser sessions are accepted as safe because the underlying
  media-server scan trigger is idempotent, at the single-household scale this feature targets.
