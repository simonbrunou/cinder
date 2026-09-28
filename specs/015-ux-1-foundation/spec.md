# Feature Specification: UX-1 — Foundation: Identity + App Shell

**Feature Branch**: `015-ux-1-foundation`

**Created**: 2026-06-24

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-06-24-ux-1-foundation.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Every page renders with the new branded identity and no leftover default chrome (Priority: P1)

A user loading any existing page should see the "ember on charcoal" theme and a real navigation shell, with the previous default-framework navbar links, default page title, and default two-tone color scheme fully gone.

**Why this priority**: This is the phase's stated Done-when — it is the single most visible fix and the prerequisite for every later UX slice.

**Independent Test**: Load any route and confirm it renders inside the new shell/theme with no default-framework text or links present anywhere on the page.

**Acceptance Scenarios**:

1. **Given** any existing route, **When** a user loads it, **Then** the page uses the ember dark (default) or light theme instead of the previous default two-tone scheme.
2. **Given** any existing route, **When** a user loads it, **Then** no default-framework navbar links or generic marketing text are present.
3. **Given** a browser tab showing any page, **When** its title is inspected, **Then** it no longer shows the previous default framework suffix.

---

### User Story 2 - A role-aware sidebar replaces the flat unstyled navigation list (Priority: P1)

Navigation should be grouped and visually indicate which page is active, and should respect the same access rules the app already enforces — a non-admin sees only the links they're allowed to use.

**Why this priority**: The flat ungrouped list had no active-state indicator and mixed admin/non-admin links indiscriminately; this is the core shell rebuild the phase delivers.

**Independent Test**: Log in as a non-admin and confirm admin-only navigation links are absent; log in as an admin and confirm they appear, with the current page's link visually marked active.

**Acceptance Scenarios**:

1. **Given** a non-admin user, **When** they view the sidebar, **Then** admin-only links are not rendered, matching the routes they cannot access.
2. **Given** an admin user, **When** they view the sidebar, **Then** admin-only links are rendered.
3. **Given** a user on any page, **When** the sidebar renders, **Then** the link corresponding to the current page is visually marked as active.

---

### User Story 3 - Navigation works on a phone with a functioning drawer (Priority: P1)

A user on a narrow viewport should be able to open and close navigation via a hamburger control, with no horizontal overflow anywhere on the page.

**Why this priority**: Mobile is a first-class, non-deferred requirement of the whole track, and this phase is explicitly where the working drawer ships (not stubbed for later).

**Independent Test**: Load any page at a 390px viewport, confirm no horizontal overflow, tap the hamburger control, and confirm the navigation drawer opens and closes correctly.

**Acceptance Scenarios**:

1. **Given** a viewport narrower than the sidebar's persistent breakpoint, **When** a page loads, **Then** the sidebar is collapsed behind a hamburger control in a slim mobile top bar instead of being persistently shown.
2. **Given** the mobile top bar, **When** a user taps the hamburger control, **Then** the navigation drawer opens as an off-canvas panel; tapping again or navigating closes it.
3. **Given** a 390px-wide viewport, **When** any existing page renders inside the new shell, **Then** there is no horizontal overflow.

---

### Edge Cases

- No route's information architecture changes in this phase — every existing page must continue to render its own content unchanged, only wrapped in the new shell.
- No route's authorization (its access guard) changes — the new active-nav-tracking mechanism is additive and must not alter who can access what.
- A page that does not currently pass the two new shell assigns must be updated so it still renders correctly (mechanical migration of every call site).
- Content wider than the previous narrow container (e.g. a poster grid planned for a later phase) must fit the widened content area without this phase itself introducing a poster grid.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST present a single custom color theme (dark by default, plus a first-class light variant) replacing the prior default two-tone scheme, across every page.
- **FR-002**: The system MUST remove all default-framework navigation chrome (stock navbar links, generic marketing text) from every page.
- **FR-003**: The browser tab title MUST NOT display the prior default framework suffix on any page.
- **FR-004**: The system MUST replace the previous flat, unstyled, non-grouped navigation list with a structured, role-grouped navigation shell.
- **FR-005**: The navigation shell MUST show only the links a given user's role is permitted to access, matching existing route access rules exactly.
- **FR-006**: The navigation shell MUST visually indicate which page is currently active.
- **FR-007**: The navigation shell MUST collapse to an off-canvas drawer, opened via a hamburger control, below a defined viewport width, and MUST be persistently visible above it.
- **FR-008**: No page MUST exhibit horizontal overflow at a 390px viewport width after this phase.
- **FR-009**: This phase MUST NOT alter which routes any user role can access — only the navigation's grouping, labeling, and visual presentation may change.
- **FR-010**: This phase MUST NOT change the information architecture of any existing page — every current route MUST continue to render its existing content, now inside the new shell.
- **FR-011**: The page MUST provide a way for a keyboard/assistive-technology user to reach the main content directly (a skip-to-content mechanism) and the main content area MUST be identifiable as a landmark.

### Key Entities

*(Not applicable — this slice is presentation/navigation-shell only and introduces no domain data.)*

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A search of the rendered app for default-framework branding/navigation text returns no matches on any page.
- **SC-002**: The browser tab title no longer contains the prior default framework suffix on any page.
- **SC-003**: Every existing route renders successfully inside the new navigation shell with an active-state indicator on its own nav entry.
- **SC-004**: A non-admin user's rendered navigation never includes an admin-only link.
- **SC-005**: At a 390px viewport, every existing page shows a working navigation drawer and no horizontal overflow.
- **SC-006**: The application's full existing test suite continues to pass with this phase's changes in place.

## Assumptions

- This slice is the first of five in the `014-ux-identity-overhaul` umbrella track; `014` is its umbrella specification and this slice's design context is largely drawn from that umbrella's design doc, though its functional requirements here trace specifically to this slice's own implementation plan.
- No backend or data-model change is required by this phase; the only new server-side addition is a non-auth mechanism for tracking the current page to drive the active-nav indicator, which does not alter any access-control guard.
- Fonts and theme values are vendored as static assets, introducing no new external runtime dependency or service configuration.
- Later phases (016–019) are responsible for extracting shared status/confirmation/empty-state components, unifying discovery, building the admin dashboard, and final accessibility/motion/cross-device hardening — none of that is in scope for this slice.
