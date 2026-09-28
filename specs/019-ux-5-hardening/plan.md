# UX-5 — Hardening: a11y, motion, light theme, cross-device QA

**Track:** UX/identity overhaul, final phase (UX-5). **Date:** 2026-06-25.
**Design:** `docs/specs/2026-06-24-ux-identity-overhaul-design.md` (§ "UX-5").
**Status:** shipped — `mix test` green (673), cross-device QA passed live.

## Context

UX-5 is *final hardening*, not where responsiveness starts — UX-1…UX-4 already built the ember
theme (both light + dark tokens), the icon+text `<.status_badge>`, the `role`/`aria-live`
`<.confirm_action>`, the off-canvas drawer, and reflowing poster grids. A verified 5-dimension
audit (a11y, table semantics, motion, light theme, responsive/touch) over all 16 views + the
component/CSS layer confirmed most of the done-when was already met and surfaced a small,
concentrated gap list. This phase closes those gaps and runs the documented cross-device sweep.

## Changes shipped

**Motion — one global cascade fix.** `assets/css/app.css` gained a single
`@media (prefers-reduced-motion: reduce)` reset that neutralises every transition/animation
app-wide (theme-toggle slide, the JS `show/hide` flash transitions, hover effects, anything
future). This retires the whole motion gap at once instead of sprinkling `motion-safe:` on each
element. Stale stock theme comment ("Phoenix colors / Elixir colors") corrected to ember.

**a11y — accessible names on icon-only / ambiguous controls.**
- `theme_toggle` (layouts.ex): the 3 icon-only buttons got `type="button"` + `aria-label`
  ("Use system/light/dark theme"), a `focus-visible` outline, and a 44px min touch target
  (`min-h-11`).
- Nav drawer toggle checkbox (layouts.ex): `aria-label="Toggle navigation menu"`.
- Season "Monitor all / Unmonitor all" (series_detail_live.ex): `aria-label` carrying the season
  ("…all episodes in Season 1") — confirmed live.
- Role-toggle badge button (users_live.ex): `aria-label` naming the user + current role.
- Dashboard "Recheck" (dashboard_live.ex): `aria-label="Recheck service health"`.
- Flash close button (core_components.ex): `focus-visible` outline + `group-focus-visible`
  opacity (keyboard parity with hover).

**Table semantics.** The `<.table>` scaffold (core_components.ex) got `scope="col"` on its `<th>`s.
*Note:* `<.table>` has **zero callers** — every list view uses semantic `<ul>/<li>` cards now. The
component is a deletion candidate; left in place (not deleting pre-existing dead code unasked).

**Light theme.**
- `text-brand` (an **undefined** class that rendered the auth-page links unstyled) → `text-primary`
  on login.ex + registration.ex, plus `focus-visible:underline`. Guarded by a regression test.
- Theme-toggle indicator `brightness-200` gated to dark only
  (`[[data-theme=dark]_&]:brightness-200`) so it doesn't wash out on light — confirmed live
  (`filter: none` in light).

**Responsive (found live, fixed, re-verified).**
- **Dashboard 8px horizontal overflow @390px**: the `mt-8 grid gap-6 lg:grid-cols-2` had no base
  `grid-cols-*`, so the mobile implicit column sized to `auto` (min-content) and blew the track to
  382px past a 358px container. Added `grid-cols-1` (→ `minmax(0,1fr)`). Grep confirmed this was the
  **only** grid in the codebase missing a base column. Re-verified: 390 == 390, no overflow.
- **Discover search input** (the primary mobile requester control) was 35px tall → `input-lg
  min-h-11` → exactly 44px. Re-verified live.

## Cross-device QA sweep (live, against the running instance)

Driven with Playwright at **390 / 768 / 1440px**, both themes, logged in as a seeded admin with
sample movies + a series. Method: per page, `scrollWidth > clientWidth` overflow check + an
interactive-element tap-target scan + screenshots.

| Width | Result |
|---|---|
| **390** | Discover, Dashboard, Activity, Library, Series-detail, Calendar — **no horizontal overflow** (Dashboard fixed). Drawer opens over a scrim with the full role-grouped nav and is keyboard-operable. Poster grid reflows to 2 columns; posters load. Search input 44px. New aria-labels confirmed in the DOM. |
| **768** | Dashboard + Library — no overflow; sidebar still a drawer (persistent ≥ lg). |
| **1440** | Light-theme Dashboard — surfaces/text/badges all legible, no dark-only leaks, toggle indicator no longer over-bright. Persistent sidebar with active rail. |

**Touch targets — documented decision.** The design spec tiers surfaces: *requester-facing*
(Discover, My Requests, request flow) are mobile-first/strict; *admin* surfaces need only be
"fully usable on a phone with real touch targets." Accordingly the requester search now meets
44px, while admin-dense **secondary** controls (`btn-xs` Edit/Delete/Retry/Recheck/role,
`toggle-sm` episode toggles, inline "→" drill links) stay compact (~18–28px) by design — inflating
them would bloat a deliberately dense admin UI. No horizontal overflow anywhere; primary/requester
targets meet 44px. *If you'd rather enforce 44px on every admin control too, that's a follow-up
toggle.*

## Done-when verification

- Conventions pass — `mix test` green (673), credo `--strict` clean, format + warnings-as-errors. ✓
- Keyboard-only reaches every primary action; icon-only/ambiguous controls now have accessible
  names; `focus-visible` on the bespoke buttons. ✓
- Status never by colour alone — already true via `<.status_badge>` (icon+text), reconfirmed. ✓
- Light theme visually complete — no dark-only leaks, `text-brand` bug fixed, indicator fixed. ✓
- Motion fully gated under `prefers-reduced-motion` via the global reset. ✓
- Documented pass at 390 / 768 / 1440 — no horizontal overflow; drawer/grids/tables behave. ✓

## New test

`test/cinder_web/live/app_shell_test.exs` — UX-5 a11y describe: the theme toggle exposes an
accessible name per option, the drawer toggle is labelled, and the auth pages use `text-primary`
(not the undefined `text-brand`).
