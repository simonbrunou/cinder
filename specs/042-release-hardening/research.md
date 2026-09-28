# Release Hardening Design

## Goal

Make the current Cinder release safe and dependable for a small group of invited household users,
while preserving its single-container, SQLite, self-hosted design and its existing private/LAN
integration support.

The work lands as one pull request composed of independently testable commits. Each commit closes
one audited boundary, adds regression coverage, and keeps the project gate green before the next
boundary is changed.

## Compatibility and trust model

Cinder continues to support administrator-configured services on private, loopback, Docker DNS,
and LAN addresses. Those configured origins are trusted operator input.

URLs returned by an indexer or remote provider are untrusted. They may use HTTP or HTTPS only when
the workflow already supports both, may not resolve to loopback, link-local, multicast, reserved,
or private addresses, may not downgrade an HTTPS request to HTTP, and may not redirect credentials
or request bodies to a different origin. DNS is resolved and checked before each initial request
and redirect. The implementation must use the vetted address for the connection when the Req
transport permits it; otherwise the remaining DNS time-of-check/time-of-use limitation is recorded
explicitly rather than claiming complete rebinding protection.

Existing external-service behaviours remain the context boundary. Contexts must not call concrete
clients directly, and tests continue to use Mox or local deterministic HTTP stubs rather than real
services.

## Dependency and release gates

Upgrade Plug to 1.20.3 or newer within the existing compatible requirement, resolving both known
Plug advisories. Keep multipart parsing enabled because Phoenix forms depend on it.

CI gains explicit dependency advisory, production release build, Dockerfile validation, and
HIGH/CRITICAL image vulnerability gates. The production image gains a bounded health check against
a lightweight unauthenticated endpoint. The endpoint reports process readiness without exposing
configuration, account, or integration details.

## Authorization, sessions, and bootstrap

Privileged actions must authorize the current actor at the moment of the state change. A shared
Accounts authorization function reloads the actor from the database inside the operation and
requires the administrator role before invoking existing context writers. LiveViews may keep a
scope for presentation, but cached socket assigns are never the final authority for admin writes.

Role changes, password resets, account deletion, and session replacement return the affected
session tokens and broadcast disconnects for their LiveView topics. Session reissue atomically
creates the replacement and deletes the superseded token so the old credential cannot remain valid
until its natural expiry. Production remember-me cookies are always `Secure`; development and test
retain HTTP support through explicit environment configuration.

Fresh production installations require a one-time `CINDER_BOOTSTRAP_TOKEN` while no user exists.
The registration form accepts it without retaining or logging it. Existing installations with an
account are unaffected, and registration continues to create later users without administrator
authority. Docker Compose requires the token for a fresh deployment and documents removing it
after the administrator is claimed.

The login limiter keeps its current household-scale ETS design, generic error response, and fixed
window, but records failures with an atomic ETS update. Concurrent failures cannot be lost. A
successful login still clears the exact `{IP, email}` key.

## Filesystem boundary

Add a Settings registry entry for one or more permitted download/import roots. Existing
installations receive a conservative inferred root only when the configured movie and TV roots
share a non-filesystem-root ancestor; otherwise Settings requires the administrator to select an
import root before new imports run. No new service environment variable is introduced.

Add a focused library path-policy module used by every import read, recursive walk, placement, and
delete operation. It provides these invariants:

- Source paths must be canonically contained within configured download roots and resolve to
  regular files of an allowed media type.
- Directory traversal uses `lstat`, never follows symlinked entries, tracks visited device/inode
  pairs, and enforces bounded depth and entry counts.
- Every existing destination component is checked with `lstat`; symlinked parents are rejected.
- The canonical destination remains within the configured movie or TV library root before any
  mkdir, temporary write, hardlink, copy, rename, or unlink.
- Deletion is allowed only for canonically contained regular library files. A poisoned or stale
  downloader path is reported as unsafe and left untouched.

Configured roots and legitimate hardlink/cross-device-copy behavior remain supported. Unsafe paths
produce explicit, sanitized errors and park the existing workflow through its normal import-failure
handling rather than crashing a poller.

## Outbound HTTP boundary

Introduce a small HTTP-policy module and use it consistently in Prowlarr, qBittorrent, Jellyfin,
Plex, OpenSubtitles, LibreTranslate, Discord, and other audited Req clients.

Configured service calls may reach their configured LAN origin. Redirects are disabled for calls
that contain API keys, cookies, credentials, webhook payloads, or subtitle content unless the next
location is same-origin and preserves the original scheme. Custom headers and request bodies are
never replayed cross-origin.

Provider-returned download URLs use the untrusted-destination policy described above. Torrent,
subtitle, translation, and service-response bodies have explicit byte limits, bounded redirect
counts, and total/request timeouts. Oversized bodies return existing-style error tuples and are
never parsed or written. SABnzbd continues to use its protocol-required `apikey` query parameter,
but Cinder redacts URLs from logs and telemetry; if the deployed API supports header authentication,
the implementation prefers it without dropping compatibility.

Remote release titles, content paths, and error strings are emitted as structured log metadata or
have CR/LF removed so external data cannot forge log records.

## Durable background work

External download creation uses durable intent records with deterministic operation keys. The
database records the intent before calling qBittorrent or SABnzbd, and retries reconcile the same
intent rather than creating an independent job. Successful remote identifiers are attached through
the existing guarded Catalog transition path.

Import and upgrade replacement are staged before the final database compare-and-swap. A stale or
cancelled transition removes newly staged files; replacing an existing live file retains rollback
material until the database transition succeeds. TV finalization verifies that every episode still
belongs to the active grab.

Cancelling a series also clears its series-level monitored policy so a later metadata refresh cannot
silently re-enable newly announced seasons. Scheduled worker serialization, supervision, and
per-item failure isolation remain unchanged.

## UI and accessibility

Every routed LiveView assigns a localized, route-specific page title while keeping the existing
`· Cinder` suffix. Auth and error pages receive equivalent titles.

The application sidebar becomes a labelled `nav` landmark. Interactive controls satisfy at least
the WCAG 2.2 24-by-24 CSS-pixel target minimum with spacing, and primary mobile actions use a
44-pixel target where practical. The flash dismiss button, locale controls, compact admin actions,
and Settings test buttons are included.

Settings keeps one persistence model and save flow but groups integrations into semantic,
keyboard-operable disclosure sections. The active/error-containing section opens automatically,
desktop users may keep multiple groups open, and mobile users avoid one uninterrupted wall of
configuration. Dark/light themes, English/French copy, reduced-motion behavior, and the existing
visual language are preserved.

## Error handling and observability

Security-policy rejections use stable tagged errors rather than raising. User-facing messages stay
generic where detail would leak a path, credential, or network target; structured logs retain a
sanitized reason for operators.

Expected failure-path tests capture their own logs so the full suite does not bury unexpected
errors in known warning output. Production logging behavior is unchanged except for structured or
sanitized remote-controlled values.

## Testing and verification

Each boundary starts with a focused regression that fails against the vulnerable behavior and a
positive control proving supported behavior remains intact. Coverage includes:

- multipart advisory resolution and dependency audit;
- stale mounted-admin actions, role/password/account revocation, token rotation, secure cookies,
  bootstrap token enforcement, and concurrent rate-limiter increments;
- source and destination symlinks, sibling-prefix paths, recursive cycles, out-of-root reads,
  writes and deletes, regular imports, and cross-device copy fallback;
- cross-origin 301/302/307/308 behavior, HTTPS downgrade, DNS/private-address rejection, same-origin
  redirects, configured LAN services, response-size limits, and log sanitization;
- process death at every external-add/import/upgrade ordering boundary, retry reconciliation,
  cancellation races, and monitored-series refresh;
- route titles, landmarks, disclosure keyboard behavior, target sizes, mobile/desktop overflow,
  themes, locales, reduced motion, and authorization redirects.

After focused tests, run the repository `mix test` gate repeatedly, update Graphify, build the
production release and image, validate Compose, run dependency and image scans, and exercise the
admin and requester browser matrices at desktop and mobile widths.

## Pull request and merge process

The branch starts from current `origin/main`. Commits follow the implementation sequence and remain
reviewable on their own. Before opening the PR, review the complete diff for security bypasses,
over-engineering, accessibility regressions, and unrelated changes.

After opening the PR, wait for CI, inspect all review comments and checks, reproduce every actionable
finding, fix it with regression coverage, and rerun the full verification set. Squash-merge only
when all required checks and review threads are resolved. Confirm the merge commit on `main` and
leave the local repository clean.

## Deliberate limits

This release remains a single-instance household application backed by SQLite. It does not add
multi-node rate limiting, a service mesh, tenant isolation, sandbox untrusted executable content,
or a general-purpose network proxy. It does not redesign Settings storage or change the supported
external-service APIs beyond enforcing the boundaries above.
