# UX & Identity Overhaul — Design

**Track:** UX/identity overhaul (Part II, pre-v1.0). Size L (split into 5 phases UX-1…UX-5).
**Date:** 2026-06-24.
**Status:** design approved (brainstorm). Per-phase implementation plans follow, one per session.

## Goal

Cinder works, but its UI reads as *built by accretion*: the movie pages set a vocabulary in
Phases 1–3 and every later wave (TV, settings, auth, admin CRUD) re-invented it slightly. The
shell is still half Phoenix-generator scaffold. There is no Cinder identity. This track makes the
product feel **intentional, distinctive, and finished** — a cinematic, poster-forward media app —
**without touching the proven pipeline, the approval gate, or role-gating.** It lands *before the
v1.0 tag* so the single public launch shows the real product.

**Done when (whole track):** the dead Phoenix chrome is gone; every page speaks one visual
language (the ember-on-charcoal daisyUI theme) through a shared component layer; discovery is a
single movies+TV surface; the admin lands on a consolidated Dashboard; **the whole app is
genuinely usable on a phone**; and `mix test` (the alias) is green at every phase boundary. Each
phase below carries its own Done-when, including a mobile criterion.

## Grounding — the audit

This design is built on a full code-level UI/UX audit (6-agent sweep, 2026-06-24). Key findings,
all concrete and re-checkable:

- **Good bones, fragmented surface.** daisyUI-on-Tailwind everywhere, consistent theme tokens,
  live PubSub updates, clean `:authenticated`/`:admin`/`:setup` route gating, *existing* shared
  components (two status-badge components, `.header`, card-list idiom, search-grid idiom). The
  problem is the surface, not the foundation.
- **The shell is half-scaffold.** `Layouts.app/1` (`layouts.ex:36-73`) still renders the stock
  Phoenix navbar — "Website / GitHub / Get Started →" linking to `phoenixframework.org` &
  `hexdocs`, and a version badge showing *Phoenix's* version — on every page, above the *real*
  nav, which is a flat ungrouped `<ul class="menu">` in `root.html.heex:32-74` with no active
  state and no mobile menu. The tab title is still "· Phoenix Framework" (`root.html.heex:7`).
  Content is capped at `max-w-2xl` (`layouts.ex:66`) — wrong for a poster grid.
- **No identity.** The two stock daisyUI theme blocks (`app.css:24-92`) make the brand color
  *Phoenix orange in light* and *Elixir purple in dark*.
- **Same logic duplicated.** The status→color badge mapping is hand-rewritten in **6** places
  (`watchlist_live.ex:238`, `series_discovery_live.ex:190`, `calendar_live.ex:36`,
  `status_live.ex:78`, `grabs_live.ex:50`, vs the canonical `core_components.ex:525`) and has
  already drifted (Grabs renders colorless badges).
- **Confirmations have 4 incompatible shapes** (two-step form, alert box, inline div, bare
  `<span>`) across requests/movies/series/grabs/users.
- **3 pages skip `.header`** (calendar, series_detail, series_discovery); record lists are shown
  as cards on some pages, a zebra table or a *nav-menu* on others.
- **States layer is thin** — 8 ad-hoc empty-state sentences; loading feedback near-absent.
- **a11y is thin** — `aria-label` in 3/17 views, status by color alone, captionless tables.

The full synthesis (consistent patterns, per-theme inconsistencies with severities, opportunities,
quick wins) was produced by the audit workflow and informs every phase below.

## Locked decisions (from the brainstorm)

1. **Ambition: reimagine** — re-draw the information architecture, not just unify components.
2. **Visual identity: cinematic media-server** — dark-first, poster-forward, content is the hero.
3. **Navigation: left sidebar** — role-grouped, active rail, collapses to a mobile drawer.
4. **Home: role-aware** — admins land on an ops **Dashboard**; household members land on
   **Discover**. Both pages exist; both roles can reach Discover.
5. **Timing: before v1.0** — land UX-1…UX-5 ahead of the v1.0 tag.
6. **Brand hook: "ember on charcoal"** — Cinder = a glowing ember in the dark; the single brand
   accent is a warm ember-amber across *both* themes (fixes the orange/purple split).
7. **Mobile-friendly is first-class** — the household requests from phones, so mobile UX is a
   cross-cutting requirement designed into *every* phase, not deferred to polish. Requester-facing
   surfaces (Discover, My Requests, the request/season-picker flow) are **mobile-first**; admin
   surfaces are at minimum fully usable on a phone (no horizontal overflow, real touch targets).

## Constraints & non-goals (hard)

- **Do not touch the approval gate, role-gating, or pipeline logic.** This is a presentation,
  IA, and theming change only. `Cinder.Requests.create_request/2` stays the only user-action
  path that can create a `:requested` row; the poller pickup is unchanged; the
  `:authenticated`/`:admin`/`:setup` live_sessions keep their `on_mount` guards. The roadmap's
  top risk — "a non-admin who can write a `:requested` row is an approve-by-default leak" — is
  honored: **no route's auth changes**, only its grouping/label/visuals.
- **Stay in-stack.** Tailwind v4 + daisyUI + HEEx. No React, no CSS framework swap. The identity
  is expressed as a custom daisyUI theme + a small set of function components.
- **Every phase is independently shippable and green.** `mix test` (compile-warnings-as-errors,
  format, credo --strict, suite) passes at each boundary; commit per phase, like every milestone.
- **Mobile is built in, not bolted on.** Each phase ships its surfaces responsive (mobile-first
  for requester pages); a phase is not "done" if it introduces a screen that overflows or is
  unusable at 390px. UX-5 is *final hardening + cross-device QA*, not where mobile starts.
- **No new external service env vars** (CLAUDE.md config rule). Theme/identity is static assets.
- **No backend/data-model change** is required by this track. (Dashboard/Activity read existing
  context functions; if a read helper is missing it's an additive query, never a writer.)

## Information architecture

Two front doors, one app. Same routes' auth; the change is grouping, labels, and merges.

### Sidebar (the new shell)

```
EVERYONE                 ADMIN (hidden for non-admins)        (bottom, pinned)
  Discover   /             Dashboard   /dashboard               theme toggle
  My Requests /my-requests Requests    /requests  (pending #)   user menu → Account / Log out
                           Library     /library
                           Activity    /activity  (active #)
                           Calendar    /calendar
                           Settings    /settings
                           Users       /users
```

- Active item gets the ember rail + soft glow. Counts (pending approvals, in-pipeline) are live
  badges. Persistent ≥ `lg`; collapses to a `☰` off-canvas drawer below `lg` (so tablets get the
  drawer too). Replaces *both* the dead Phoenix navbar and the `root.html.heex` `<ul>`.

### Role-aware home

`/` is **Discover** for everyone (both roles browse + request). Admins are routed to
`/dashboard` as their landing (post-login redirect + the logo/home affordance is role-aware); a
household member's home stays `/`. Implementation: a small role check at the landing; **no change
to who may access what** — `/dashboard` lives in the existing `:admin` live_session.

### Consolidation map (the reimagining)

| Today (fragmented) | Becomes | Routes |
|---|---|---|
| `/` movie search+add **+** `/series` TV search **+** `/series/tmdb/:id` season request | **Discover** — one search, movies **and** TV in a single mixed poster grid, per-card request state; movie → request inline, TV → season picker | `/` (+ a TV season-picker view, route TBD in UX-3: keep `/discover/tv/:tmdb_id` or a modal) |
| `/movies` admin list **+** added-series list inside `/series` | **Library** — unified managed catalog, movies + TV, filter by type/status, drill to detail | `/library`, detail `/library/...` (reuse `SeriesDetailLive` content) |
| `/series/:id` monitor detail | **Library → Series detail** (kept; per-episode monitoring lives here) | `/series/:id` (kept; reached from Library) |
| `/status` movie-pipeline table **+** `/grabs` | **Activity** — one live "what's happening now" feed (pipeline + grabs) | `/activity` |
| *(new)* | **Dashboard** — admin home: pipeline at a glance, pending approvals inline, service health, recent activity, with drill-downs into Requests / Activity / Library | `/dashboard` |
| `/requests`, `/my-requests`, `/calendar`, `/users`, `/settings`, `/setup`, auth | kept in purpose; restyled into the new shell + components | unchanged |

Route renames are cosmetic and done with redirects from old paths where a bookmark might exist.
Exact route choices for the unified Discover TV season-picker and the Library detail are settled
in the UX-3/UX-4 plans (a route vs a modal/drawer is an implementation call, not an IA one).

## Visual system — "ember on charcoal"

Expressed as a **custom daisyUI theme** replacing the two stock blocks in `app.css`, plus
self-hosted fonts and a few component classes. Values below are the design target; exact tokens
are tuned for **WCAG AA contrast** during UX-1.

### Color

**Dark (default / hero):** deep cool charcoal, layered surfaces, hairline borders over heavy
shadows.

| Token | Hex (target) | ~OKLCH | Role |
|---|---|---|---|
| base-100 | `#0d0f13` | `oklch(15.5% .008 265)` | page background |
| base-200 | `#15181f` | `oklch(19.5% .009 265)` | sidebar / cards |
| base-300 | `#1b1f27` | `oklch(23% .010 262)` | raised surface / hairline border |
| base-content | `#eaecef` | `oklch(93% .003 265)` | text (dim `#9aa2ad`, faint `#646c77`) |
| **primary (ember)** | `#ff7a3c` | `oklch(72% .16 47)` | brand accent, CTAs, active nav |
| primary-content | `#1a0d06` | `oklch(20% .04 50)` | text on ember |
| info | `#5aa9ff` | `oklch(72% .13 250)` | downloading/approved |
| success | `#3fc78a` | `oklch(74% .14 165)` | available/reachable |
| warning | `#f5b23d` | `oklch(80% .13 75)` | pending/attention |
| error | `#ff5f5f` | `oklch(68% .20 22)` | failed/denied/down |

**Light (first-class, same ember):** warm near-white surfaces (`#fbfbfa` / `#f3f2f0` /
`#e7e5e2`), text `#1b1d22`, **primary = a slightly deeper ember** `#e8612a`
(`oklch(64% .17 45)`) for AA contrast on light. Semantics analogous. The brand color stays ember
in both themes — the single most important fix.

One accent only: `accent` maps to ember (no separate hue). Ember CTAs use a subtle gradient
(`#ff8a4c → #f2542d`) for the "glow."

### Type, shape, depth, motion

- **Type:** `Inter` (UI/body) + `Inter Tight` (headings + wordmark), **self-hosted** (vendored
  `@font-face`, no runtime CDN). Headings carry slight negative tracking.
- **Shape:** `--radius-box ≈ 0.875rem` (14px cards), `--radius-field ≈ 0.5rem`, pill
  badges/chips. `--border: 1px` hairline.
- **Depth:** layered surfaces + hairlines; restrained glass (`backdrop-blur`) only on the sticky
  topbar and sidebar.
- **Content-forward:** Discover/Library cards are edge-to-edge poster with a gradient scrim;
  title + state badge sit on the artwork. Detail pages + Dashboard use the TMDB **backdrop** as
  an ambient hero wash (the ember glow). `poster_path` is already fetched; backdrop is an
  additive TMDB field where needed.
- **Motion:** poster hover-lift, sliding active rail, smooth badge transitions — all gated behind
  `prefers-reduced-motion`.

### Responsive & mobile (first-class)

The household requests from phones; this is not an afterthought. The system is **mobile-first on
requester surfaces** and fully usable on a phone everywhere.

- **One breakpoint story.** Single column < `sm`, scaling up via Tailwind's responsive utilities.
  The sidebar is persistent ≥ `lg` and becomes an off-canvas **drawer** (hamburger in a slim
  mobile top bar) below it — the drawer ships working in UX-1, not stubbed.
- **Poster grids reflow:** `grid-cols-2` on phones → `3/4/5/6` as width grows. Cards stay
  poster-forward and tappable; the request affordance is always reachable (not hover-only — hover
  doesn't exist on touch, so state badges / request buttons are always rendered, not revealed).
- **Touch targets ≥ 44×44px**; primary actions sit within thumb reach; confirmations are
  tap-friendly (no tiny inline links).
- **Tables degrade to cards on mobile.** Activity/Calendar's columnar data becomes stacked cards
  below `md` — no horizontal scroll. (This is also why the audit's "card vs table" inconsistency
  is resolved toward cards as the default record container.)
- **Mobile-first requester flow:** Discover search, the per-card request, the TV season-picker,
  and My Requests are designed at 390px first, then enhanced upward.
- The topbar search collapses to an icon that expands on tap; the user/account menu lives in the
  drawer on mobile.

The approved direction is captured as throwaway HTML/CSS mockups in
`docs/specs/assets/2026-06-24-ux-overhaul/` (`discover.html`, `dashboard.html`, `_shared.css`) —
open in a browser or render at any width. The Discover mockup is responsive: persistent sidebar
≥ `lg`, hamburger drawer + 2-column grid on mobile. These are a visual target for UX-1/UX-3, not
code to port.

## Component layer (extracted once, adopted everywhere)

| Component | API sketch | Replaces |
|---|---|---|
| **App shell** (`Layouts.app` rewrite + `root.html.heex`) | sidebar with role-grouped nav slots, active detection (`@current_path`), live count badges, mobile drawer, theme toggle, user menu, `<main>` landmark + skip link | dead Phoenix navbar (`layouts.ex:48-63`) + flat `<ul>` (`root.html.heex:32-74`) |
| **`<.status_badge>`** | `kind={:movie\|:request\|:grab\|:health\|:episode} status={..}` → `{label, semantic-color, icon}`; icon **and** text (not color-only) | the 6 hand-rolled helpers; single source of truth |
| **`<.confirm_action>`** | inline confirm: `id`, `phx-*` confirm/cancel, `:caveat` slot, `role="alert"`/`aria-live`; consistent destructive copy | the 4 confirm shapes |
| **`<.empty_state>`** | `icon`, `title`, `message`, optional `:cta` slot; a distinct `search-error` variant | the 8 bare-gray sentences; disambiguates no-results vs failed-search |
| **`<.media_card>`** | `poster`, `title`, `year`, `type` (film/tv), `state` (or request affordance) slot | duplicated `movie_card`/`series_card` |
| **`<.page>` scaffold** | always `.header` + `:subtitle` slot + one container width | the 3 bare-`<h1>` pages + mismatched widths |
| **Loading affordances** | `<.spinner>` + a skeleton; convention: `phx-disable-with` on every mutating button; real health-check spinner | near-absent loading feedback |
| **Design tokens** | the ember daisyUI dark+light theme + vendored fonts | the two stock theme blocks (`app.css:24-92`) |

`status_badge` is also the natural place to add the icon+text redundancy that fixes the
color-only a11y problem, so the a11y baseline largely falls out of the consolidation.

## Delivery — five phases (one per session, green + commit at each boundary)

Risk rises only after the safe foundation. Phases UX-1 + UX-2 alone remove the "all over the
place" feeling; UX-3 + UX-4 deliver the reimagined IA; UX-5 hardens.

### UX-1 — Foundation: identity + app shell

Ember daisyUI dark+light theme + vendored Inter/Inter Tight in `app.css`; rewrite `Layouts.app`
as the sidebar shell; delete the dead Phoenix navbar; replace the `root.html.heex` `<ul>`; fix the
`<.live_title>` suffix; widen the content container; add `<main>` landmark + skip-to-content + a
**working off-canvas mobile drawer** (hamburger + slim mobile top bar). **No IA change** — every
existing page renders in the new shell/theme.

**Done when:** conventions pass; the Phoenix "Website/GitHub/Get Started" chrome is gone (grep
clean); the tab title no longer says "Phoenix Framework"; every current route renders inside the
ember sidebar shell with an active-nav indicator; **the sidebar collapses to a functioning drawer
at 390px with no horizontal overflow**; a test covers role-aware nav visibility (non-admin does
not see admin links — presentation parity with the existing route guards).

### UX-2 — Shared component layer

Build `<.status_badge>`, `<.confirm_action>`, `<.empty_state>`, `<.page>`, `<.spinner>`/skeleton;
adopt across **all** current pages — delete the 6 badge helpers, the 4 confirm shapes, the 8
empty-state sentences; switch the 3 bare-`<h1>` pages to `<.page>`; add `phx-disable-with` to
admin mutating buttons. Pure consolidation; no new screens.

**Done when:** conventions pass; the 6 duplicate badge helpers and 4 confirm variants are gone
(one component each); a test renders `<.status_badge>` across movie/request/grab/health/episode
states with icon+text; empty/search-error states are distinguishable; no page hand-rolls a
status color; the shared components are responsive (cards/confirm/empty stack cleanly at 390px,
touch targets ≥ 44px).

### UX-3 — Unified Discover

Merge `/` (movies) + `/series` (TV search) + `/series/tmdb/:id` (season request) into one Discover
surface: one search → movies+TV mixed grid via `<.media_card>`; per-card state preserved; movie →
request inline, TV → season picker (route vs modal decided in-plan). The **approval gate and
request creation are unchanged** — only the entry UI is unified.

**Done when:** conventions pass; one search returns and renders movies+TV together with correct
per-user state badges; requesting a movie and requesting a TV season both still flow through
`Cinder.Requests` exactly as today (regression test: a non-admin request creates no `:requested`
row before approval); the old split routes redirect; **Discover and the request/season-picker
flow are designed mobile-first — the grid reflows to 2 columns at 390px, request affordances are
always rendered (not hover-only), and the season picker is fully operable by touch.**

### UX-4 — Admin home: Dashboard + Activity + Library

Build `/dashboard` (role-aware landing: stat row, inline pending-approval queue with
approve/deny, service health, recent-activity feed, drill-downs); consolidate `/status` +
`/grabs` into **Activity** `/activity`; merge `/movies` + the added-series list into **Library**
`/library` with detail drill-downs (reusing `SeriesDetailLive` monitoring). All read existing
context functions (additive read helpers only if needed).

**Done when:** conventions pass; an admin logs in and lands on `/dashboard` showing live pending
count, health, and recent activity; approve/deny from the dashboard behaves identically to
`/requests`; Library lists movies+TV and drills into detail; `/status` and `/grabs` content is
reachable under Activity; old routes redirect; **Dashboard/Activity/Library are fully usable at
390px — the Activity/Calendar tables degrade to stacked cards with no horizontal scroll, and the
dashboard panels stack to a single column.**

### UX-5 — Hardening: a11y, motion, light theme, cross-device QA

Mobile is already built into UX-1…UX-4; this phase is *final hardening*, not where responsiveness
starts. Table semantics (`scope`, `<caption>`/`aria-label`) on Activity/Calendar; `aria-label` on
icon-only controls; `role`/`aria-live` on confirmations; `prefers-reduced-motion`; a full
light-theme pass; and a **cross-device sweep** (phone / tablet / desktop) catching any remaining
overflow, tap-target, or focus issue. Optional live visual check against the running instance.

**Done when:** conventions pass; a keyboard-only pass reaches every primary action; status is
never conveyed by color alone; light theme is visually complete; and a documented pass at 390px /
768px / 1440px shows no horizontal overflow, all touch targets ≥ 44px, and the drawer/tables/grids
behaving correctly at each.

## Risks & how managed

- **Touching the security-critical approval path by accident.** Mitigation: the hard constraint
  above + a regression test in UX-3 asserting non-admin → no `:requested` row before approval;
  no route's `on_mount` guard changes in any phase.
- **Big-bang risk.** Mitigation: 5 independently-green phases; UX-1/UX-2 change look without
  changing IA, so a problem is isolated to a phase.
- **Theme contrast regressions.** Mitigation: tune the ember tokens to WCAG AA in UX-1; verify in
  both themes.
- **Route renames breaking bookmarks/links.** Mitigation: redirects from old paths; update
  in-app links to the new shell nav (removing the ad-hoc in-body links the audit flagged).
- **Scope creep into pipeline/feature work.** Mitigation: non-goals are explicit; any data/logic
  need is an additive *read* helper, never a writer or a new feature.

## Open questions (settled per-phase, not blocking)

- Discover TV season-picker: dedicated route (`/discover/tv/:tmdb_id`) vs modal/drawer — UX-3.
- Library detail: reuse `/series/:id` and add a movie-detail sibling vs a unified detail — UX-4.
- Whether Activity and Dashboard's "recent activity" share one component — UX-4.
