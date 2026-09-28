# Feature Specification: Release Hardening

**Feature Branch**: `042-release-hardening`

**Created**: 2026-07-12

**Status**: Shipped (v1.1.0)

**Input**: Normalized from historical docs — research.md (originally `docs/superpowers/specs/2026-07-12-release-hardening-design.md`), plan.md (originally `docs/superpowers/plans/2026-07-12-release-hardening.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Trust boundary holds between operator-configured services and untrusted provider data (Priority: P1)

Cinder continues to reach administrator-configured services (indexers, download clients, media
servers) on private/LAN/loopback addresses, while URLs and data returned *by* those services (an
indexer's release download link, a redirect target) are treated as untrusted and validated before
any request is made.

**Why this priority**: Per research.md, "Cinder continues to support administrator-configured
services on private, loopback, Docker DNS, and LAN addresses. Those configured origins are
trusted operator input. URLs returned by an indexer or remote provider are untrusted."

**Independent Test**: Point a fixture provider response at a loopback/private/link-local address or
an HTTP downgrade and confirm the request is rejected, while a normal configured-service call still
succeeds.

**Acceptance Scenarios**:

1. **Given** a provider-returned download URL, **When** it resolves to a loopback, link-local,
   multicast, reserved, or private address, **Then** Cinder rejects the request instead of following
   it.
2. **Given** a provider-returned redirect, **When** it would downgrade HTTPS to HTTP or cross to a
   different origin carrying credentials/cookies/webhook payloads/subtitle content, **Then** Cinder
   refuses to replay the sensitive request.
3. **Given** an administrator-configured LAN service (Prowlarr, qBittorrent, Jellyfin, Plex, etc.),
   **When** Cinder calls it normally, **Then** the call succeeds exactly as before hardening.

### User Story 2 - Privileged actions re-authorize the current actor and revoke stale sessions (Priority: P1)

Every privileged write (role change, password reset, account deletion, session replacement)
re-checks the acting administrator's role at the moment of the change rather than trusting a cached
socket assignment, and affected session tokens are atomically revoked and disconnected.

**Why this priority**: A demoted or removed administrator whose LiveView socket is still mounted
must not be able to perform further privileged writes, and a superseded session token must not
remain valid.

**Independent Test**: Demote an administrator's role via a second admin while their session is
mounted, then attempt a privileged action from the stale session and confirm it is rejected and the
underlying data is unchanged.

**Acceptance Scenarios**:

1. **Given** an administrator whose role was revoked after their session mounted, **When** they
   attempt a role/password/deletion mutation, **Then** the action is rejected with no data change.
2. **Given** a role change, password reset, or account deletion, **When** it completes, **Then** the
   affected session tokens are revoked and their LiveView topics are disconnected.
3. **Given** a session token replacement, **When** it completes, **Then** the old token stops
   authenticating immediately while the new token works normally.

### User Story 3 - Filesystem writes stay inside configured library/download roots (Priority: P1)

Every import read, recursive directory walk, file placement, and delete operation verifies that the
source and destination paths are canonically contained within configured roots, using `lstat`-based
checks that reject symlinks at every path component.

**Why this priority**: A poisoned or symlinked downloader path must never let Cinder read, write, or
delete a file outside its configured library/download roots.

**Independent Test**: Construct a symlinked source, a symlinked destination parent, and a directory
symlink cycle, and confirm each is rejected while a normal regular-file import still succeeds.

**Acceptance Scenarios**:

1. **Given** a source path containing a symlinked component, **When** Cinder attempts to read it for
   import, **Then** it is rejected as unsafe rather than followed.
2. **Given** a destination path whose parent has been replaced with a symlink, **When** Cinder
   attempts to write there, **Then** it is rejected before any mkdir, write, hardlink, copy, or
   rename.
3. **Given** a legitimate regular file fully contained within a configured root, **When** Cinder
   imports or deletes it, **Then** the operation succeeds exactly as before hardening, including the
   existing cross-device copy fallback.

### Edge Cases

- Fresh production installations with no existing user require a one-time bootstrap token before
  the first registration is allowed; installations with an existing account are unaffected.
- Concurrent login failures against the rate limiter must all be recorded — none may be lost to a
  read-then-write race — while a successful login still clears exactly its own key.
- A process death between staging an import/upgrade and the final database transition must not
  leave orphaned staged files or a live file replaced without its rollback material.
- Cancelling a monitored series must also clear its series-level monitored policy so a later
  metadata refresh cannot silently re-enable it.
- Oversized or malformed remote response bodies must be rejected with an existing-style error rather
  than parsed or written to disk.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST validate that provider-returned URLs do not resolve to loopback,
  link-local, multicast, reserved, or private addresses before connecting.
- **FR-002**: The system MUST refuse to downgrade an HTTPS request to HTTP and MUST NOT replay
  credentials, cookies, custom headers, or request bodies across an origin change on redirect.
- **FR-003**: The system MUST continue to support administrator-configured services on private,
  loopback, Docker DNS, and LAN addresses without additional restriction.
- **FR-004**: Privileged administrator actions MUST re-authorize the current actor's role at the
  moment of the state change rather than trusting a previously cached value.
- **FR-005**: Role changes, password resets, account deletion, and session replacement MUST
  atomically revoke the affected session token(s) and disconnect their live sessions.
- **FR-006**: Users MUST be required to supply a one-time bootstrap token to complete the first
  registration on a fresh production installation with no existing account.
- **FR-007**: The login rate limiter MUST record concurrent failures without loss and MUST clear
  exactly the successful `{IP, email}` key on a successful login.
- **FR-008**: Every import read, recursive walk, placement, and delete operation MUST verify that
  the involved path is canonically contained within a configured root and rejects any path
  component that is a symlink.
- **FR-009**: Directory traversal MUST track visited device/inode pairs and enforce a bounded depth
  and entry count to prevent cycles or unbounded walks.
- **FR-010**: External download creation (qBittorrent/SABnzbd) MUST record a durable intent before
  the remote call so a retry reconciles the same operation rather than creating a duplicate.
- **FR-011**: Import and upgrade replacement MUST stage files before the final database
  compare-and-swap and MUST clean up staged files on a stale or cancelled transition.
- **FR-012**: The production deployment MUST expose a lightweight, unauthenticated readiness
  endpoint that reports process health without leaking configuration, account, or integration
  details, and it MUST be wired into the container health check.
- **FR-013**: CI MUST run a dependency advisory check, a production release/image build, a
  Dockerfile validation, and a HIGH/CRITICAL image vulnerability scan as release gates.
- **FR-014**: Every routed page MUST expose a localized, route-specific page title, and interactive
  controls MUST meet at least the WCAG 2.2 24-by-24 CSS-pixel minimum target size.
- **FR-015**: Security-policy rejections MUST surface as stable tagged errors with generic
  user-facing messages, while structured logs retain a sanitized reason for operators.

### Key Entities

- **Import root / library root**: the configured filesystem boundaries within which reads, writes,
  and deletes are permitted.
- **Download intent**: the durable, deterministic record of a pending or submitted external
  download-client operation.
- **Session token**: the credential representing an authenticated session, subject to atomic
  replacement and revocation.
- **Bootstrap token**: the one-time credential gating the first registration on a fresh install.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: No provider-returned URL can cause Cinder to connect to a loopback, private, or
  link-local address, or to silently downgrade HTTPS to HTTP.
- **SC-002**: A demoted or deleted administrator's stale session can no longer perform any
  privileged write, verified across role change, password reset, and deletion flows.
- **SC-003**: No symlink-based path (source, destination parent, or traversal cycle) can cause a
  read, write, or delete outside a configured root.
- **SC-004**: The production container reports a bounded, content-free health check usable by
  orchestration tooling.
- **SC-005**: CI blocks a release when a HIGH/CRITICAL image vulnerability or an unresolved
  dependency advisory is present.
- **SC-006**: The full regression suite (security, filesystem, HTTP, session, accessibility) passes
  before merge, and the reviewed diff introduces no unrelated changes.

## Assumptions

- Scope is a single-instance, household-scale, SQLite-backed application; the hardening pass
  explicitly does not add multi-node rate limiting, a service mesh, tenant isolation, sandboxing of
  untrusted executable content, or a general-purpose network proxy.
- Settings storage and the supported set of external-service APIs are not redesigned beyond
  enforcing the described boundaries.
- SABnzbd continues using its protocol-required `apikey` query parameter (URLs are redacted from
  logs/telemetry) since the protocol does not universally support header authentication; the
  implementation prefers header auth where the deployed API supports it without dropping
  compatibility.
- The full DNS rebinding time-of-check/time-of-use gap is explicitly not claimed as completely
  closed where the underlying HTTP transport cannot pin the vetted address to the connection; this
  residual limitation is documented rather than silently assumed away.
- CHANGELOG.md places the `/healthz` readiness endpoint, database-volume monitoring, bootstrap/
  session hardening items, and related entries under `## [1.1.0] - 2026-08-14`, the version cited
  above; there is no dedicated "release hardening" changelog heading because the work landed as many
  individual boundary-scoped entries across that release rather than one named feature.
