# Feature Specification: UX-5 Hardening — Accessibility, Motion, Light Theme, Cross-Device QA

**Feature Branch**: `019-ux-5-hardening`

**Created**: 2026-06-25

**Status**: Shipped

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-06-25-ux-5-hardening.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Every control is operable and named without a mouse (Priority: P1)

A user relying on keyboard navigation or a screen reader can reach and operate every primary
action in the app, and every icon-only control (theme toggle, nav drawer toggle, season monitor
toggles, role-toggle badges, recheck, flash close) announces what it does instead of being an
unlabeled icon.

**Why this priority**: This closes the audit's thinnest area (accessible names present on only
3 of 17 views) and is the direct completion of the "status/controls never conveyed by
appearance alone" commitment made across the whole UX track.

**Independent Test**: Tab through the app using only the keyboard and confirm every primary
action is reachable and has a visible focus indicator; inspect each icon-only control and confirm
it carries an accessible name describing its current action/state.

**Acceptance Scenarios**:

1. **Given** a user navigates using only the keyboard, **When** they tab through the interface,
   **Then** every primary action is reachable and shows a visible focus indicator.
2. **Given** the theme toggle, nav drawer toggle, per-season monitor toggle, role-toggle badge,
   dashboard recheck, and flash close controls, **When** inspected, **Then** each carries an
   accessible name describing its action or current state.

---

### User Story 2 - Motion respects the user's reduced-motion preference (Priority: P2)

A user with a system-level reduced-motion preference sees no transitions or animations anywhere in
the app — theme toggle slide, flash transitions, hover effects — instead of only some elements
respecting it.

**Why this priority**: A single global fix retires the entire motion gap at once; it is
independent of the a11y-labeling work and lower risk than the light-theme/responsive fixes.

**Independent Test**: Enable a reduced-motion system preference, then trigger the theme toggle,
a flash message, and a hover-affected element, and confirm none of them animate.

**Acceptance Scenarios**:

1. **Given** a user's system is set to prefer reduced motion, **When** any transition or animation
   would normally play anywhere in the app, **Then** it is suppressed.

---

### User Story 3 - The light theme is complete and correct (Priority: P2)

A user who switches to light mode sees every page fully and correctly styled — no unstyled links,
no dark-theme-only visual effects leaking into light mode — instead of a partially-finished light
theme.

**Why this priority**: The light theme was a first-class commitment from the original design (ember
in both themes) and this phase is where its remaining defects are found and fixed.

**Independent Test**: Switch to light theme and visit the login/registration pages and the theme
toggle indicator, confirming links are visibly styled and no dark-only visual effect (e.g.
over-brightening) appears.

**Acceptance Scenarios**:

1. **Given** light theme is active, **When** viewing the login or registration page, **Then** links
   render with visible, on-brand styling rather than unstyled text.
2. **Given** light theme is active, **When** viewing the theme-toggle indicator, **Then** it does
   not display the dark-only over-brightening effect.

---

### User Story 4 - No horizontal overflow at phone, tablet, or desktop width (Priority: P3)

A user on a phone, tablet, or desktop browses every major page and never encounters horizontal
scrolling or content spilling past the viewport edge.

**Why this priority**: This is the closing verification pass across the whole mobile-first
commitment made in UX-1 through UX-4, confirming the built-in responsiveness actually holds under
a documented sweep — lowest priority because it's largely already built, not net-new.

**Independent Test**: Load Discover, Dashboard, Activity, Library, Series-detail, and Calendar at
390px, 768px, and 1440px widths in both themes and confirm no page's scrollable width exceeds its
visible width.

**Acceptance Scenarios**:

1. **Given** any major page is loaded at a 390px viewport, **When** measured, **Then** its
   scrollable width does not exceed its visible width.
2. **Given** the Dashboard specifically, **When** loaded at 390px, **Then** its panel grid does not
   overflow (a previously found 8px overflow is fixed).
3. **Given** the Discover search input, **When** measured on a touch viewport, **Then** it meets a
   44px minimum touch-target height.

---

### Edge Cases

- What happens to admin-dense secondary controls (edit/delete/retry/recheck row actions, episode
  toggles, drill-in links) under the 44px touch-target rule? They deliberately stay compact by
  design — only requester-facing primary controls are held to the strict 44px minimum, to avoid
  bloating a dense admin UI.
- How does the system handle a pre-existing, uncalled table-rendering component discovered to have
  zero remaining callers? It is left in place rather than deleted, since removing unrelated dead
  code was not part of this phase's scope.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide an accessible name on every icon-only or otherwise ambiguous
  interactive control, including theme toggle options, the navigation drawer toggle, per-season
  monitor toggles, role-toggle controls, and the dashboard health-recheck control.
- **FR-002**: Users MUST be able to reach and operate every primary action using only the
  keyboard, with a visible focus indicator on custom interactive elements.
- **FR-003**: System MUST suppress all transitions and animations application-wide when the user's
  system indicates a reduced-motion preference.
- **FR-004**: System MUST render every page correctly and completely in the light theme, with no
  unstyled text and no dark-theme-only visual effect appearing in light mode.
- **FR-005**: System MUST render every major page with no horizontal overflow at 390px, 768px, and
  1440px viewport widths, in both themes.
- **FR-006**: System MUST meet a minimum 44-pixel touch-target size on requester-facing primary
  controls (e.g. the Discover search input).
- **FR-007**: System MUST continue conveying status through icon-and-text (never color alone),
  reconfirmed across the hardening pass.

### Key Entities

*(Not applicable — this phase is a cross-cutting quality pass with no new domain data.)*

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A full keyboard-only pass reaches every primary action across the audited surfaces
  with zero unreachable actions.
- **SC-002**: Zero icon-only or ambiguous controls remain without an accessible name across the
  audited views.
- **SC-003**: A documented sweep at 390px, 768px, and 1440px, in both themes, across all major
  pages (Discover, Dashboard, Activity, Library, Series-detail, Calendar) shows zero instances of
  horizontal overflow.
- **SC-004**: Zero remaining dark-theme-only visual leaks or unstyled elements are observed when
  browsing the full app in light theme.
- **SC-005**: All triggerable transitions/animations are suppressed under a reduced-motion system
  preference, verified across theme toggle, flash messages, and hover effects.

## Assumptions

- This feature is UX slice 5 of 5 (final hardening) under the umbrella feature
  `014-ux-identity-overhaul`, which also includes `015` (foundation/shell), `016-ux-2-shared-components`,
  `017-ux-3-unified-discover`, and `018-ux-4-admin-home`.
- This phase assumes UX-1 through UX-4 already built the majority of responsive/mobile behavior;
  it is a verification-and-gap-closure pass, not where mobile-first design originates.
- The touch-target tiering (44px strict on requester-facing primary controls, compact by design on
  dense admin secondary controls) is treated as a deliberate, documented decision rather than an
  unresolved gap.
