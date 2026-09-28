# Dashboard Discord Notifications Design

## Goal

Notify operators in Discord when a maintenance action started from the admin Dashboard completes
or fails, using Cinder's existing configurable, best-effort notification seam.

## Scope

Cover all six actions in the Dashboard's **Run maintenance** section:

- Movie pipeline
- TV pipeline
- Monitored series refresh
- Subtitle backfill
- Movie library scan
- TV library scan

Send no notification when an action starts, when a duplicate click is rejected, or when the same
worker runs on its normal schedule. Do not add settings, database state, dashboard controls,
notification history, or a second transport.

## Events and data flow

`CinderWeb.DashboardLive` already receives the definitive result of each maintenance task through
`handle_async/3`. At that boundary, emit one of two typed events through `Cinder.Notifier` before
recording the result in the socket:

- `{:maintenance_completed, action_key}` for `{:ok, :ok}`
- `{:maintenance_failed, action_key, reason}` for a returned `{:error, reason}` or task exit

The action key is one of the six stable atoms already used by the Dashboard. Keeping notification
dispatch in the LiveView limits the feature to manually requested Dashboard operations; emitting
inside the workers would also alert for scheduled passes.

`Cinder.Notifier.notify/1` remains the only dispatch entry point. The Dashboard must not call the
Discord implementation directly. A notifier raise, exit, HTTP failure, or timeout remains
best-effort and cannot change the maintenance result shown in the Dashboard.

## Message rendering

Extend `Cinder.Notifier.Discord` with embeds for the two events. Map each action key to a canonical,
human-readable English operation name in the notifier:

- A completed event posts a green embed titled **Maintenance completed**, with the operation name
  as its description.
- A failed event posts a red embed titled **Maintenance failed**, with the operation name and a
  concise inspected error reason in its description.

Extend `Cinder.Notifier.Log` with explicit messages for the two event types. This preserves useful
operational output when no Discord webhook is configured and avoids relying on the generic event
formatter.

Unknown maintenance keys should still render safely using their inspected value rather than
raising or suppressing an otherwise useful failure notification. The Dashboard itself continues
to validate incoming action identifiers against its six known actions.

## Failure behavior

Only the maintenance task's outcome determines whether the event is completed or failed. A
notification delivery failure is logged and swallowed by the existing notifier layers. It must
not convert a completed Dashboard operation into a failure, hide a real operation failure, or
leave an action marked as running.

Returned errors and async exits share the same failure event and retain the original reason. The
Dashboard continues to show its existing generic **Failed** result while Discord and logs include
the technical reason for diagnosis.

## Testing

Add focused tests at both boundaries:

- Discord notifier tests assert that completed and failed events post the expected title, color,
  readable operation name, and inspected failure reason.
- Dashboard LiveView tests subscribe to the configured test notifier and prove one completion event
  for a successful action, one failure event for a returned error, and one failure event for an
  async exit.
- A running-action test proves no notification is sent at start, and the existing duplicate-event
  test proves the rejected second click emits no additional notification.

Run the focused notifier and Dashboard tests first, then run `mix test`, the repository's
source-of-truth compile, format, Credo, and test gate.

## Deliberate limits

This change does not announce scheduled maintenance, persist notification delivery status, retry
Discord posts, localize Discord operation names, or include the triggering administrator's
identity. Those require broader product decisions and are unnecessary for completion/failure
alerts from the current single-household admin Dashboard.
