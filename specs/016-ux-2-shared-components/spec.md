# Feature Specification: UX-2 Shared Component Layer

**Feature Branch**: `016-ux-2-shared-components`

**Created**: 2026-06-24

**Status**: Shipped (v1.0.0)

**Input**: Normalized from historical docs — plan.md (originally `docs/plans/2026-06-24-ux-2-shared-components.md`)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One status vocabulary everywhere (Priority: P1)

Any user viewing a movie, TV request, episode, grab, or service-health state sees a badge that
always carries both an icon and a text label, using one consistent color/label mapping no matter
which page they're on — instead of six hand-rolled, already-drifted badge implementations (e.g.
Grabs previously rendered colorless badges).

**Why this priority**: The status→color mapping was duplicated and had already drifted across six
call sites; unifying it is the single highest-value fix and the direct source of the a11y baseline
(status is never conveyed by color alone).

**Independent Test**: Render the shared status badge for each kind/status combination (movie,
request, episode, grab, health) and confirm every one includes both an icon and a text label, and
that an unmapped status falls back to a neutral badge instead of crashing the page.

**Acceptance Scenarios**:

1. **Given** a movie in any pipeline status, **When** its badge renders, **Then** it shows an icon
   and a humanized text label (e.g. "No match", "Search failed") with a consistent color per state.
2. **Given** a service health check with a timeout error, **When** the health badge renders,
   **Then** it shows "Unreachable" in the error color with the underlying error reason as a hover
   title.
3. **Given** a status value the badge mapping does not recognize, **When** it renders, **Then** it
   falls back to a neutral badge with a humanized label rather than raising an error.

---

### User Story 2 - One confirmation pattern for destructive actions (Priority: P2)

Any user attempting a destructive action (delete a request, movie, series, grab, or user) sees the
same inline, accessible confirm step — instead of four incompatible shapes (two-step form, alert
box, inline div, bare span) scattered across the app.

**Why this priority**: Confirmation inconsistency was a top audit finding and directly touches
accidental-destructive-action risk; consolidating it after the badge (P1) is the next biggest
duplication removed.

**Independent Test**: Trigger a delete action on any of the five admin surfaces (requests, movies,
series, grabs, users) and confirm the same inline confirm affordance appears, announces itself to
assistive technology as an alert, and can be dismissed or confirmed.

**Acceptance Scenarios**:

1. **Given** an admin clicks "Delete" on any managed entity, **When** the confirm step renders,
   **Then** it is an inline alert-role confirm with consistent destructive copy, not a separate
   page, modal, or bare span.
2. **Given** the confirm step is open, **When** the admin clicks elsewhere or cancels, **Then** the
   confirm dismisses without performing the destructive action.

---

### User Story 3 - Meaningful empty and loading states (Priority: P3)

Any user who searches with no results, hits a failed search, or views a list with nothing in it
sees a distinct icon/title/message empty state (with a "no results" state visually distinguishable
from a "search failed" state) instead of one of fifteen bare gray sentences, and any mutating button
shows in-flight feedback instead of appearing to do nothing.

**Why this priority**: Lowest risk, highest polish; depends on nothing from P1/P2 and closes the
"thin states layer" and "near-absent loading feedback" audit findings.

**Independent Test**: Search with a query that returns zero results, then simulate a search
failure, and confirm the two empty states render differently; click any mutating button (save,
approve, deny, retry, recheck) and confirm it disables itself with in-flight text.

**Acceptance Scenarios**:

1. **Given** a search returns no matches, **When** the page renders, **Then** an empty state with
   an icon, title, and message appears, distinct from the failed-search variant.
2. **Given** a search request fails outright, **When** the page renders, **Then** a distinct
   failed-search empty-state variant appears instead of the no-results variant.
3. **Given** an admin clicks a mutating button (e.g. Save, Approve, Retry), **When** the request is
   in flight, **Then** the button disables itself and shows progress text while the action
   completes.

---

### Edge Cases

- What happens when a status value has no mapped badge spec? The badge falls back to a neutral
  colour and a humanized label instead of crashing the page.
- How does the system handle a service-health check that errors? The health badge shows
  "Unreachable" with the raw error reason surfaced only as a hover title, not in the label text.
- What happens to the three pages that previously rendered a bare, unstyled page heading? They are
  converted to the existing shared header component so no page skips it.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST render every movie, request, episode, grab, and service-health status as
  a badge carrying both an icon and a text label, never color alone.
- **FR-002**: System MUST use one shared status-badge mapping across every page that displays any
  of these statuses; no page may hand-roll its own status-to-color logic.
- **FR-003**: System MUST fall back to a neutral, humanized badge for any status value not in the
  known mapping, rather than crashing the page.
- **FR-004**: Users MUST see the same inline, accessible confirmation affordance before any
  destructive action (delete on requests, movies, series, grabs, users), replacing the four
  previously inconsistent confirm shapes.
- **FR-005**: System MUST distinguish a "no results" empty state from a "search failed" empty
  state with different icon/title/message content.
- **FR-006**: System MUST show progress feedback (disabled state + in-flight text) on every
  mutating admin button while its action is processing.
- **FR-007**: System MUST present every page with a consistent page header (icon/title/subtitle
  pattern), eliminating bare, unstyled page titles.
- **FR-008**: System MUST preserve every existing event name, value wiring, and underlying
  action/authorization behavior while replacing only the presentation markup — no approval-gate,
  role-gating, or pipeline behavior change.
- **FR-009**: System MUST keep every new shared component usable at a 390px mobile viewport with
  touch targets of at least 44 pixels.

### Key Entities

- **Status Badge**: A visual indicator of a state (movie pipeline, request, episode, grab, or
  service health) combining an icon, a text label, and a semantic color.
- **Confirm Action**: An inline, accessible confirmation step gating a destructive operation.
- **Empty State**: A placeholder shown for an empty or failed list/search result, distinguishing
  "nothing found" from "the operation failed."

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every status shown anywhere in the app is conveyed with both an icon and a text
  label, with zero instances of color-only status indication.
- **SC-002**: The number of distinct status-badge implementations in the codebase drops from six
  to one, and the number of distinct confirmation-dialog shapes drops from four to one.
- **SC-003**: Every page previously missing a header now displays one consistently, and the number
  of bare, unstyled empty-state sentences drops from fifteen to a small set of reusable
  variants (including a distinguishable no-results vs. search-error case).
- **SC-004**: Every shared component remains fully usable (no overflow, tap targets ≥44px) at a
  390px viewport width.

## Assumptions

- This feature is UX slice 2 of 5 under the umbrella feature `014-ux-identity-overhaul`, which
  also includes `015` (foundation/shell), `017-ux-3-unified-discover`, `018-ux-4-admin-home`, and
  `019-ux-5-hardening`.
- No backend, data-model, authentication, or approval-gate change is in scope; this is a
  presentation-layer consolidation only, per the umbrella design's hard constraints.
- The design's originally proposed page-scaffold component was deliberately dropped in favor of
  standardizing on the existing header component plus the UX-1 shell container, per an in-plan
  council decision; this is a resolved implementation detail, not an open question.
