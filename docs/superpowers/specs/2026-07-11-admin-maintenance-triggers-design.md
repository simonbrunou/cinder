# Admin Maintenance Triggers Design

## Goal

Let an authenticated administrator manually run Cinder's operator-relevant media automation
without adding a second scheduler or exposing infrastructure-only maintenance.

## Scope

Add six actions to the existing admin Dashboard:

- Run the movie pipeline once.
- Run the TV pipeline once.
- Refresh every monitored series from TMDB once.
- Run the subtitle backfill once.
- Ask the configured media server to scan the movie library.
- Ask the configured media server to scan the TV library.

Do not expose login-rate-limit cleanup, telemetry sampling, notification replay, post-import
download removal, job history, scheduler configuration, or global pause controls. The existing
per-title retry, search, monitoring, cancellation, and deletion controls remain unchanged.

## Interface

Add a compact **Run maintenance** section to `/dashboard`. Each action has its own labelled button
and short description. While an action is running, only its button is disabled and shows a
progress label. Completion or failure is retained beside that action for the life of the Dashboard
session, so concurrent results cannot overwrite one another.

The Dashboard is already inside the admin-only LiveView session, so no new route, navigation item,
or authorization mechanism is needed.

## Execution

Use the Dashboard's existing `start_async/3` pattern. Give each action a distinct async name so
different actions may run concurrently and their results cannot overwrite one another.

The four worker buttons call the workers' existing public `poll/0` functions:

- `Cinder.Download.Poller.poll/0`
- `Cinder.Download.TvPoller.poll/0`
- `Cinder.Catalog.Refresher.poll/0`
- `Cinder.Subtitles.Sweeper.poll/0`

Those calls execute through the already-supervised GenServers. A manual call therefore serializes
with the worker's scheduled tick and cannot overlap another pass in that worker.

Add `Cinder.Library.scan/1` as the single new domain entry point for manual media-server scans. It
accepts `:movies | :tv` and returns the configured media server's real `:ok | {:error, reason}`
result. Keep automatic post-import scans best-effort by having the existing `refresh/2` call
`scan/1` and retain its current rescue, logging, and always-success behavior.

## Results and failures

The LiveView treats `:ok` as a completed pass and `{:error, reason}` or an async exit as a failure.
Worker passes deliberately isolate and log individual item failures, so a successful worker result
means the pass finished, not that every item advanced. The success message should use "completed"
rather than promise that work was found or changed.

An action remains runnable after either outcome. Returned and raised failures are logged with the
action key and reason while the UI keeps the reason generic. Leaving the page may discard its UI result, but a
worker pass already accepted by its GenServer continues. Button disabling is local to one Dashboard
session; the GenServer provides the cross-session serialization for worker actions. Two sessions
can still request the same worker and will produce two sequential passes rather than deduplicate.
Direct movie
and TV scan requests may overlap across browser sessions, which is acceptable at single-household
scale because the configured media-server scan endpoints are idempotent triggers.

## Testing

Use LiveView tests on the existing Dashboard test module:

- The six controls render for an admin.
- Each control dispatches the intended worker or library scan.
- A running action disables only its own button.
- Concurrent actions retain independent completion/failure results.
- A forged duplicate event does not start an already-running action twice in one session.
- A returned scan error and an async exit produce a failure result, and the reason is logged.
- The existing non-admin Dashboard redirect remains the authorization regression check.

Add a focused `Cinder.Library` test proving `scan/1` returns the media-server result while
`refresh/2` continues swallowing failures. Run the affected tests first, then `mix test` as the
source-of-truth gate.

## Deliberate limits

No database-backed job records, progress percentages, run history, cross-session button state, or
new dependency. Add persistent operations tracking only if operators later need to diagnose runs
after leaving the page or across application restarts.

Like every existing admin LiveView, authorization is checked when the LiveView mounts. Demoting an
admin does not currently disconnect their already-open LiveView sessions; event-time role
revalidation or session revocation is a system-wide authentication hardening task, not part of this
maintenance surface.
