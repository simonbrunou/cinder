# Feature Specification: Discord Notifications

**Feature Branch**: `029-discord-notifications`

**Created**: 2026-07-05

**Status**: Shipped

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-07-05-discord-notifications-design.md`), plan.md (originally `docs/plans/2026-07-05-discord-notifications.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See pipeline activity in a Discord channel (Priority: P1)

An operator wants their household's Discord server to receive a notification whenever something
important happens in the pipeline — a request approved, a movie or episodes becoming available, or
a failure — without having to check the app.

**Why this priority**: This is the entire point of the feature and the first real external
notification transport the project ships; without it the feature delivers no value.

**Independent Test**: Configure a webhook URL in settings, trigger each of the six pipeline events,
and confirm each posts a distinct, correctly formatted embed to the stubbed webhook endpoint.

**Acceptance Scenarios**:

1. **Given** a Discord webhook URL is configured, **When** a request is approved, a movie becomes
   available, a movie fails, a movie upgrade fails, TV episodes become available, or a TV grab
   fails, **Then** a rich embed is posted to the webhook with a title, description, and a color
   indicating success (green) or failure (red).
2. **Given** an available movie or a request has a poster image, **When** its notification embed
   is built, **Then** the embed includes a thumbnail pointing at that poster image.
3. **Given** an event has no associated poster image, **When** its embed is built, **Then** the
   embed omits the thumbnail entirely rather than showing a broken image.

---

### User Story 2 - Notifications are opt-in and safe by default (Priority: P1)

An operator who has not configured a webhook should see absolutely no change in behavior, and an
operator whose Discord webhook is slow, broken, or misconfigured should never have that affect the
running pipeline.

**Why this priority**: Safety and non-intrusiveness are as load-bearing as the notification itself
— a synchronous external call sits directly in poller ticks and the admin approval action, so an
unbounded or crashing call would be a regression, not a feature.

**Independent Test**: Leave the webhook unset and confirm no HTTP call is made and the app behaves
identically to before the feature existed; then stub a failing/slow/erroring webhook and confirm
the pipeline is unaffected.

**Acceptance Scenarios**:

1. **Given** no webhook URL is configured, **When** any pipeline event fires, **Then** the event is
   still logged as before but no HTTP request is made.
2. **Given** a webhook URL is configured but the endpoint returns an error status or a transport
   error, **When** an event fires, **Then** the failure is logged and swallowed — the pipeline
   action that triggered the event completes normally.
3. **Given** a webhook URL is configured but the endpoint hangs, **When** an event fires, **Then**
   the outbound request is bounded by a timeout so it cannot stall the poller tick or the approval
   action indefinitely.

---

### User Story 3 - Configure and verify the webhook without touching server config (Priority: P2)

An operator wants to set up Discord notifications entirely from the in-app settings page, and be
able to confirm the webhook is valid before relying on it.

**Why this priority**: Consistent with the project's existing settings-driven configuration
convention; a webhook set only via server environment variables would break that pattern and be
harder for non-technical operators to use.

**Independent Test**: Enter a webhook URL in the settings page, click "Test connection," and
confirm it reports success or failure without posting a visible message to the channel.

**Acceptance Scenarios**:

1. **Given** the operator is on the settings page, **When** they enter a Discord webhook URL and
   save, **Then** the value is stored securely (never displayed back in plaintext) and used for
   future notifications.
2. **Given** a webhook URL is saved, **When** the operator clicks "Test connection," **Then** the
   system verifies the webhook is valid without posting a visible message into the Discord channel.
3. **Given** no webhook URL is configured, **When** the operator clicks "Test connection," **Then**
   the result clearly indicates notifications are not configured.

---

### Edge Cases

- An event type the notifier doesn't recognize is still logged, but no Discord post is attempted.
- A webhook that returns a non-2xx status or times out never raises out of the pipeline action that
  triggered the notification.
- The "Test connection" check does not send a visible test message into the channel — it validates
  the webhook's existence and authorization only.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST deliver a Discord notification for each of the pipeline's existing
  events: request approved, movie available, movie failed, movie upgrade failed, episodes
  available, and TV grab failed.
- **FR-002**: Each notification MUST be rendered as a rich embed with a title, description, and a
  color that distinguishes success from failure.
- **FR-003**: A notification for an event with an associated poster image MUST include that image
  as a thumbnail; an event without one MUST omit the thumbnail.
- **FR-004**: System MUST NOT send any Discord notification unless an operator has explicitly
  configured a webhook URL — the feature is opt-in per household.
- **FR-005**: System MUST continue logging every event exactly as before, independent of whether a
  webhook is configured.
- **FR-006**: A failure to deliver a Discord notification (error response or transport failure)
  MUST be logged and MUST NOT interrupt or fail the pipeline action that triggered it.
- **FR-007**: A Discord notification attempt MUST be bounded by a timeout so a hung webhook cannot
  stall the synchronous pipeline action that triggered it.
- **FR-008**: Users MUST be able to configure the Discord webhook URL from the in-app settings
  page, without needing server-level configuration or environment variables.
- **FR-009**: The stored webhook URL MUST be treated as a secret — encrypted at rest and never
  echoed back to the operator in plaintext.
- **FR-010**: Users MUST be able to verify the configured webhook is valid via a "Test connection"
  action, and that verification MUST NOT post a visible message into the Discord channel.

### Key Entities

- **Notification Event**: A typed pipeline occurrence (e.g. request approved, movie available,
  movie failed) carrying the data needed to describe it, such as a title and optional poster image.
- **Webhook Configuration**: The household's Discord webhook URL, stored securely and used to
  deliver notifications when present.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator with Discord configured receives a notification for every pipeline event
  type within moments of it occurring, with no missed event types.
- **SC-002**: An operator with no webhook configured observes zero change in application behavior
  or performance compared to before the feature existed.
- **SC-003**: A broken or slow Discord webhook never causes a delay or failure visible in the
  application's own pipeline processing.
- **SC-004**: An operator can fully set up and validate Discord notifications using only the
  in-app settings page, with no server access required.

## Assumptions

- Only one notification transport (Discord) is supported; a generic multi-transport
  fan-out/routing system is explicitly deferred as unnecessary at this scale.
- There is no per-event or per-user notification customization, muting, or message templating.
- A failed notification delivery is not retried — it is best-effort, and the underlying event
  remains visible in-app and in logs regardless.
- No new environment variable is introduced; the webhook is configured exclusively through the
  in-app settings registry, consistent with the project's existing service-configuration
  convention.
