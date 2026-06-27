# Impeccable UI overhaul — follow-ups

Deferred tail from the Impeccable critique + audit overhaul (PR #53). The overhaul moved
**Critique 27 → 33 / 40** and **Audit 12 → 17 / 20** (both into the "Good" band) with **0 confirmed
anti-pattern bans**. This file is the backlog that was explicitly *out of scope* for that PR plus
the residuals surfaced by the `/code-review` pass and the live browser pass. Nothing here is a
ship-blocker; the live loop and contrast were validated. Ordered roughly by value.

Each item: `file:line` (approximate; re-grep), why it matters, suggested fix.

## Bugs

- [ ] **Jellyfin health check raises `CaseClauseError` on an unreachable host.** The live
  `/dashboard` health probe returned `%CaseClauseError{term: nil}` for the Jellyfin media server
  when the host was down — an unhandled `case` on a nil/unexpected response. It is now *displayed*
  gracefully as "Check failed" (`core_components.ex` `health_reason/1`), but the check itself should
  handle the unreachable/nil branch and return a proper `{:error, reason}` (e.g. `:econnrefused` /
  `:timeout`) like the other impls. Find the Jellyfin `health/0` impl under
  `lib/cinder/library/media_server/` and add the missing case.

## Accessibility

- [ ] **Theme toggle lacks the radio keyboard pattern.** `layouts.ex` `theme_toggle/1` is now a
  `role="radiogroup"` of `role="radio"` buttons, but there is no roving `tabindex` / arrow-key
  navigation (a radiogroup should be one tab stop, arrows moving between options). Add a small hook
  or `tabindex` management.
- [ ] **Decorative heroicons have no `aria-hidden`.** `core_components.ex` `icon/1` (~`:530`) renders
  a bare `<span>`; icons that sit beside a visible text label should be `aria-hidden="true"` so
  screen readers don't double-announce. Cleanest: default `icon/1` to `aria-hidden` unless an
  `aria-label`/role is passed.
- [ ] **Locale switcher touch target.** `layouts.ex:272` locale buttons are `btn-xs` (~24px), on the
  WCAG 2.5.8 floor. Bump to `btn-sm` for a comfortable target.
- [ ] **Discover search has no visible `<label>` and no in-flight indicator.** `discover_live.ex`
  (~`:170-182`) relies on placeholder + `aria-label`; add a visible (or `sr-only`) label, and a
  loading state during the TMDB roundtrip (currently the only feedback gap in "visibility of
  system status").

## Performance

- [ ] **Preload the variable fonts.** `root.html.heex:8` links only `app.css`, so Inter /
  Inter Tight `woff2` are render-blocked (FOUT + LCP cost). Add
  `<link rel="preload" as="font" type="font/woff2" crossorigin>` for both.
- [ ] **`DashboardLive.load/1` recomputes everything on every PubSub message.** `dashboard_live.ex:89`
  runs a full `Catalog.list_watchlist()` load + `Enum.frequencies_by` + sort plus several
  count-only full loads on *every* movies/series/requests broadcast. Swap to `count`/`limit`
  queries before the catalog grows.
- [ ] **Bulk approve/deny is N transactions + N broadcasts**, and the acting `/requests` view
  reloads `list_requests/0` after its own broadcast (double reload). `requests_live.ex` `bulk/2`
  (~`:140`) + `approve_selected`/`deny_selected`. Batch into one transaction and drop the
  redundant reload (rely on the PubSub handler). Low priority at single-household volume.
- [ ] **Season bulk-approve does blocking TMDB I/O in `handle_event`.** `approve_request` for a
  `"season"` target is intentionally not transaction-wrapped (it does TMDB I/O); bulk-approving N
  seasons does N sequential blocking calls inside one `handle_event`, briefly blocking the LV.
  Consider `start_async` for the bulk season path.

## Consistency & polish

- [ ] **Auth copy is Title-Case, not sentence-case.** `user_live/settings.ex:15,28,64`
  ("Account Settings" / "Change Email" / "Save Password") — leftover `phx.gen.auth` scaffold
  against the PRODUCT.md sentence-case voice. Same for any other Title-Case auth strings.
- [ ] **ASCII `...` vs the `…` glyph** in some `phx-disable-with` labels (`confirmation.ex`,
  `registration.ex:60`, `user_live/settings.ex:28,64`) while every other label uses `…`.
- [ ] **Compressed type ramp.** h1 `text-xl` (1.25rem) over section h2 `text-lg` (1.125rem) is
  ~1.11×, below the design system's own ≥1.25 step (`core_components.ex` `header/1`). Widen h1
  (e.g. `text-2xl`) so headings read more distinct.
- [ ] **Link-affordance drift** for the same "navigate to X" pattern: `link` (`settings_live.ex:75`,
  `series_detail_live.ex`, `series_discovery_live.ex`) vs `link link-hover` (`dashboard_live.ex:175,298`)
  vs `link link-primary` (`library_live.ex`). Pick one treatment.
- [ ] **Card-as-list-row is the dominant primitive.** `requests_live`, `users_live`, `library_live`,
  `activity_live`, `my_requests_live` all use `card bg-base-200 p-4` for plain list rows — the
  "cards are the lazy answer" smell. Consider a lighter list-row treatment for the dense admin
  lists (reserve cards for the poster grid).
- [ ] **Bulk flash hardcodes English plural** `"%{count} request(s)"` (`requests_live.ex:107`).
  Use `ngettext`.
- [ ] **Deny form is triplicated** (bulk bar `requests_live.ex:180`, per-row `:244`, dashboard
  `dashboard_live.ex:231`) with only cosmetic variation. Extract one component.
- [ ] **`input/1` aria wiring is copy-pasted across its 4 clauses** (`core_components.ex` checkbox /
  select / textarea / text). Extract a shared error-attrs helper.
- [ ] **Inline admin edits bypass `<.input>`.** `users_live.ex` edit-email / reset-pw and the
  dashboard deny input use raw `input input-sm input-bordered`, so they skip the new
  `aria-invalid`/`aria-describedby` wiring. Route through `<.input>`.
- [ ] **`series_detail` monitored badge is hand-rolled** (`series_detail_live.ex:348`) rather than
  going through `status_badge`.
- [ ] **`discover_live` `{:error, _}` catch-all → "already requested" is over-broad.** Today the only
  reachable error on that path *is* the duplicate (verified), but if `create_changeset` validations
  loosen, a genuine failure would be mislabeled as a benign info toast. Match the duplicate
  specifically.

## Test-guard hardening

- [ ] **`no_em_dash_test` only catches single-line `gettext( … —`.** A `gettext` string wrapped
  across physical lines with the dash on a continuation line escapes the regex. Current copy is
  verified em-dash-free; harden the guard with a stateful scan or a broader quoted-string check if
  it ever regresses.
