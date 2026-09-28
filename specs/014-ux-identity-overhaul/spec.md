# Feature Specification: UX & Identity Overhaul

**Feature Branch**: `014-ux-identity-overhaul`

**Created**: 2026-06-24

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — research.md (originally `docs/specs/2026-06-24-ux-identity-overhaul-design.md`)

## User Scenarios & Testing *(mandatory)*

This is an umbrella track delivered as five independently-shippable slices, each with its own spec: **015-ux-1-foundation** (identity theme + app shell), **016-ux-2-shared-components** (shared component layer), **017-ux-3-unified-discover** (merged movie+TV discovery), **018-ux-4-admin-home** (Dashboard/Activity/Library), and **019-ux-5-hardening** (accessibility, motion, light theme, cross-device QA). User stories below are summarized at track level; see each slice's spec for detailed acceptance criteria.

### User Story 1 - The product has one consistent, branded visual identity (Priority: P1)

Every page currently reads as built by accretion: leftover Phoenix-generator chrome, two clashing stock theme colors, and duplicated ad-hoc styling logic across pages. A user visiting any page should instead see one intentional "ember on charcoal" visual language, on a real app shell, not scaffold.

**Why this priority**: This is the foundation every later slice builds on (015, 016) — without it the product doesn't feel finished, and it was called out as the most severe, most visible problem in the design's audit.

**Independent Test**: Load any existing route and confirm it renders inside the new branded sidebar shell with the ember theme, with no residual default-framework chrome visible.

**Acceptance Scenarios**:

1. **Given** any authenticated route, **When** a user loads it, **Then** it renders inside a role-aware sidebar shell using the ember-on-charcoal theme, with no Phoenix-default navbar or generic page title.
2. **Given** the same status/confirmation concept (e.g. a pending badge) appearing on different pages, **When** rendered, **Then** it uses one shared component rather than page-specific duplicated logic.

---

### User Story 2 - Discovery is a single, unified movies+TV surface (Priority: P1)

A user currently searches movies and TV on two separate pages with two separate flows. They should be able to search once and see both movies and TV results together, requesting either directly from the same grid.

**Why this priority**: This is the most substantial information-architecture change and the one most directly affecting the core request workflow that must not regress the approval gate.

**Independent Test**: Search a mixed query from one entry point and confirm both movie and TV results render together with correct, working request affordances for each.

**Acceptance Scenarios**:

1. **Given** a user on the unified Discover page, **When** they search, **Then** movies and TV results render together in one grid, each showing correct per-user request state.
2. **Given** a user requests a movie or a TV season from Discover, **When** they submit the request, **Then** it flows through the exact same approval gate as before — no request bypasses approval.

---

### User Story 3 - Admins get a consolidated operations home (Priority: P2)

Admins currently piece together pipeline status from several separate pages. They should land on one Dashboard showing pending approvals, service health, and recent activity at a glance, with the former separate pipeline/grabs views consolidated into one Activity feed and movies/series management consolidated into one Library.

**Why this priority**: Delivers the reimagined admin IA, but depends on the foundation and shared components landing first.

**Independent Test**: Log in as an admin and confirm the landing page shows live pending-request count, health, and recent activity, with drill-downs to Requests/Activity/Library all working.

**Acceptance Scenarios**:

1. **Given** an admin logs in, **When** the app loads, **Then** they land on a Dashboard showing pending-approval count, service health, and recent activity.
2. **Given** the admin wants to browse the full managed catalog, **When** they open Library, **Then** movies and TV series are listed together with drill-down to detail/monitoring.

---

### User Story 4 - The whole app is genuinely usable on a phone (Priority: P1)

A household member requesting media from their phone should get a fully functional, non-overflowing, touch-friendly experience — not a desktop layout shrunk down.

**Why this priority**: Called out as a cross-cutting, first-class requirement in every phase of the design, not deferred polish — household members request from phones.

**Independent Test**: Load Discover and My Requests at a 390px viewport and confirm no horizontal overflow, a working navigation drawer, and reachable (non-hover-only) request actions.

**Acceptance Scenarios**:

1. **Given** a 390px-wide viewport, **When** a user opens any page, **Then** navigation is available via a working off-canvas drawer and no content overflows horizontally.
2. **Given** a touch device, **When** a user views a media card, **Then** its request affordance is always visible (not hover-revealed) and meets a minimum touch-target size.

---

### Edge Cases

- A page exists that predates this track and was never updated with the new shared components — it must still render correctly inside the new shell (015 requires every existing route to work with no IA change).
- The approval gate or any route's authorization guard must never be altered by a purely visual/IA change in any slice.
- A status value must never be conveyed by color alone (accessibility finding from the audit).
- A confirmation dialog for a destructive action must be tap-friendly, not a tiny inline link, on mobile.
- Old, now-consolidated routes (e.g. former `/status`, `/movies`) must still work via redirect for any existing bookmark.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST present one consistent visual identity (a single custom theme, replacing the prior default two-tone scheme) across every page, in both dark and light modes.
- **FR-002**: The system MUST replace default-framework chrome (navbar, generic page title, ungrouped navigation list) with a purpose-built, role-aware navigation shell.
- **FR-003**: The system MUST consolidate duplicated status-badge, confirmation, and empty-state presentation logic into shared, reusable components used everywhere that concept appears.
- **FR-004**: Users MUST be able to search and browse movies and TV together in one unified discovery surface, requesting either without leaving that surface.
- **FR-005**: The request/approval security gate MUST NOT change behavior as a result of any visual or navigational change in this track — no user action must be able to create a library item without going through existing approval.
- **FR-006**: No route's authorization/role guard MUST change as a result of this track — only grouping, labeling, and visual presentation may change.
- **FR-007**: Admins MUST be presented with a consolidated operational home showing pending approvals, service health, and recent activity, with drill-down to full detail.
- **FR-008**: The system MUST consolidate the former separate pipeline-status and grabs views into one combined activity feed.
- **FR-009**: The system MUST consolidate movie and TV series management into one unified library view with drill-down to per-title detail and monitoring controls.
- **FR-010**: The application MUST be fully usable at a mobile viewport width (390px) on every page, with no horizontal overflow and a working collapsible navigation.
- **FR-011**: Request-facing surfaces (discovery, personal requests view, the season-picker flow) MUST be designed mobile-first and MUST NOT rely on hover-only interaction for any action.
- **FR-012**: Tabular/columnar data views MUST degrade to a stacked, non-scrolling layout on narrow viewports.
- **FR-013**: Status information MUST be conveyed through more than color alone (e.g. icon plus text label).
- **FR-014**: A former route made obsolete by consolidation MUST continue to work via redirect for any existing bookmark.
- **FR-015**: Each slice of this track MUST be independently shippable, leaving the application in a fully working, fully tested state at every slice boundary.

### Key Entities

- **Movie / Series (+ Season, Episode)**: The media entities users discover, request, and admins manage — unaffected in data shape by this track; only their presentation and navigation change.
- **Request**: A user's approval-gated ask for media; its data/lifecycle is unchanged, only its display consolidates into shared components.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: No page in the application displays default-framework branding, chrome, or page titles after the track completes.
- **SC-002**: A single search from the unified Discover surface returns and correctly renders both movie and TV results with accurate per-user request state.
- **SC-003**: An admin can determine, from one landing page, the current pending-approval count, service health, and recent activity without navigating elsewhere.
- **SC-004**: Every page in the application renders without horizontal overflow and with all primary actions reachable and tappable at a 390px viewport.
- **SC-005**: A full regression check confirms that no user action anywhere in the app can create a library item (movie or TV season) without passing through the existing approval gate.
- **SC-006**: A duplicated presentation pattern identified in the originating audit (status badges, confirmations, empty states) appears exactly once as a shared component, used everywhere that concept is shown.

## Assumptions

- This is an umbrella specification; detailed, independently-verifiable requirements for each slice live in its own spec: `015-ux-1-foundation`, `016-ux-2-shared-components`, `017-ux-3-unified-discover`, `018-ux-4-admin-home`, and `019-ux-5-hardening`.
- The track explicitly does not change the pipeline, the approval gate, or any route's authorization guard — it is scoped to presentation, information architecture, and theming only.
- No new external service configuration/env vars are introduced; the identity is expressed purely through static theme assets and components already in the existing Tailwind/daisyUI stack.
- No backend or data-model change is required by this track; any new read used by a consolidated view is an additive query against existing data, never a new writer.
- The design's mockup assets are a visual reference only, not code ported directly into the
  implementation.
