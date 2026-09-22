# Design

The visual system as actually implemented in `assets/css/app.css`,
`lib/cinder_web/components/core_components.ex`, and `lib/cinder_web/components/layouts.ex`.
Stack: Tailwind v4 + daisyUI, Phoenix LiveView (HEEx), heroicons. No React. Two daisyUI themes
share every token except color: dark is the default/hero, light is a first-class peer.

## Theme overview

**"Ember on charcoal."** A quiet, dark workshop with one warm signal light. The dark theme is
near-black charcoal (cool blue-grey, hue ~265) carrying a single warm **ember** accent
(orange-red, hue ~47) — this replaces the stock Phoenix-orange / Elixir-purple split with one
accent. The light theme is warm paper (hue ~90) with the same ember, slightly deeper. Flat by
design: `--depth: 1`, `--noise: 0`, `--border: 1px`, no gradients, no glass and no
`backdrop-blur`. Theme is chosen via a system / light / dark toggle and applied
to `<html data-theme>` before first paint (inline script in `root.html.heex`), so there is no
flash; `prefersdark` maps "system" to dark.

## Color

All values are oklch, exactly as defined. **Primary and accent are intentionally the same ember
value** in both themes (one accent, not two).

### Dark (default, `data-theme=dark`)
| Role | oklch | Use |
|---|---|---|
| base-100 | `oklch(15.5% 0.008 265)` | page background (charcoal) |
| base-200 | `oklch(19.5% 0.009 265)` | cards, sidebar surface |
| base-300 | `oklch(23% 0.01 262)` | poster placeholder, borders, toggle track |
| base-content | `oklch(93% 0.003 265)` | primary text (muted via `/70`, `/60`, `/40`) |
| primary | `oklch(72% 0.16 47)` | ember — brand mark, primary buttons, active nav |
| primary-content | `oklch(20% 0.04 50)` | text on ember |
| secondary | `oklch(55% 0.02 265)` | low-emphasis grey |
| secondary-content | `oklch(96% 0.003 265)` | text on secondary |
| accent | `oklch(72% 0.16 47)` | **same as primary** (downloaded badge) |
| accent-content | `oklch(20% 0.04 50)` | text on accent |
| focus-ring | `oklch(72% 0.16 47)` | `a`/poster-card focus outline — same as primary here (dark already clears WCAG 1.4.11 with headroom, #598) |
| neutral | `oklch(27% 0.012 265)` | neutral badge ("Requested") |
| neutral-content | `oklch(92% 0.003 265)` | text on neutral |
| info | `oklch(72% 0.13 250)` | blue — searching / downloading / approved |
| success | `oklch(74% 0.14 165)` | green — available / OK |
| warning | `oklch(80% 0.13 75)` | amber — pending / wanted / no-match |
| error | `oklch(68% 0.2 22)` | red — failed / denied / unreachable |
| *-content | per token above | foreground on each semantic color |

### Light (`data-theme=light`)
| Role | oklch |
|---|---|
| base-100 | `oklch(98.5% 0.002 90)` (warm paper) |
| base-200 | `oklch(96.5% 0.003 90)` |
| base-300 | `oklch(92% 0.004 90)` |
| base-content | `oklch(22% 0.01 265)` |
| primary / accent | `oklch(64% 0.17 45)` (deeper ember; again identical) |
| primary-content / accent-content | `oklch(98% 0.015 75)` |
| focus-ring | `oklch(52% 0.17 45)` (deeper still, same hue) — a separate token so the light-theme ring clears WCAG 1.4.11 without darkening the pinned primary/accent (#598) |
| secondary | `oklch(50% 0.02 265)` · neutral `oklch(44% 0.017 265)` |
| info | `oklch(58% 0.16 250)` · success `oklch(62% 0.15 165)` · warning `oklch(70% 0.16 70)` · error `oklch(58% 0.22 25)` |

Semantic colors map to a fixed status vocabulary (see `status_badge`). Text de-emphasis is done
with opacity on `base-content` (`/70` subtitles, `/60` secondary text, `/40` placeholders), not
separate grey tokens.

## Typography

- **Body:** `Inter` (variable woff2, weight `100 900`, `font-display: swap`), with
  `system-ui, -apple-system, sans-serif` fallback, set on `html`.
- **Display:** `Inter Tight` (variable woff2, same range/swap) for `h1, h2, h3, .font-display`,
  with `letter-spacing: -0.01em` (tighter headings). Fallback `Inter, system-ui, sans-serif`.
- Both faces are self-hosted from `/fonts/*-variable.woff2`.
- **Scale in use** (Tailwind utilities, not a formal ramp): page/section title `text-lg
  font-semibold leading-8` (`header`); brand wordmark `text-lg`–`text-2xl font-bold tracking-wide`
  via `.font-display`; card titles `text-sm font-semibold leading-tight`; body default; subtitles
  / secondary `text-sm` at reduced opacity; badges and chips `text-xs`-ish via `badge-sm`; menu
  section headers `menu-title`.
- **Wordmark:** uppercase `CINDER` in `.font-display`, bold with generous tracking. The word stays
  in `base-content`; the adjacent Ember Loop mark carries the accent.

## Brand mark

The **Ember Loop** is an open ember-orange `C` around a centered play cue, with one detached round
ember in the opening. The loop represents Cinder's request-to-library pipeline; the play cue names
the media category; the single ember gives the otherwise precise geometry warmth. It is an
evolution of Cinder's original arc-C and spark, not a separate visual language.

- `priv/static/images/logo.svg` is the transparent mark for light surfaces.
- `priv/static/images/logo-reverse.svg` is the transparent mark for dark surfaces.
- `priv/static/images/icon.svg` is the source of truth for the dark app/PWA icon and its raster
  exports.
- Keep exactly one round ember. Do not replace it with a star, add particles, animate the static
  silhouette, or apply gradients/glow.

## Radii / border / depth

Identical across both themes:

| Token | Value | Meaning |
|---|---|---|
| `--radius-selector` | `0.5rem` | toggles, small selectors, badges |
| `--radius-field` | `0.5rem` | inputs, selects, buttons |
| `--radius-box` | `0.875rem` | cards, alerts, larger containers |
| `--size-selector` | `0.21875rem` | selector sizing base |
| `--size-field` | `0.21875rem` | field sizing base |
| `--border` | `1px` | all borders are hairline (`border-base-300/60` for chrome) |
| `--depth` | `1` | minimal daisyUI depth |
| `--noise` | `0` | no texture overlay |

Shadows are sparing: `card` uses `shadow-sm` only. Surfaces are distinguished by the base-100 →
base-200 → base-300 step and hairline borders, not by elevation.

## Components

All from `core_components.ex` (daisyUI classes + house markup). Each is the single source of
truth for its pattern — assemble screens from these, don't reinvent.

- **`button`** — `btn`. Variants `primary` (solid ember) / `neutral` (plain) / `ghost` / `danger`
  / `warning`, sizes `xs|sm|md`; default is solid `primary`, and `class` is additive (extra
  utilities only). Renders `<button>` or, when `href`/`navigate`/`patch` is
  passed, a `<.link>` with identical styling. Loading via caller `phx-disable-with`.
- **`input`** — wrapped in a `fieldset` with a `.label`. Type-dispatched: text/email/etc. →
  `input`; `select`; `textarea`; `checkbox` (`checkbox checkbox-sm`, hidden false companion);
  `hidden`. Error state swaps in `input-error` / `select-error` / `textarea-error` and renders an
  `.error` line — `text-error`, an `hero-exclamation-circle` icon, and the message (color + icon +
  text, never color alone). Full-width by default.
- **`status_badge`** — the core state primitive. `badge badge-sm gap-1`, always **icon + text +
  color**. `kind` ∈ `{movie, request, episode, grab, health}` selects the vocabulary; `status` is
  the state. Color↔state map: neutral = requested; info = searching / downloading / approved;
  accent = movie downloaded; success = available / OK / grab downloaded; warning = pending /
  wanted / no-match; error = failed / denied / unreachable; ghost = upcoming. Health
  `{:error, reason}` puts the reason in the hover `title`. A safe fallback humanizes any unmapped
  atom (never crashes a view). Optional `id` opts a call site into the kindle flare (see Motion)
  on surfaces whose LiveView subscribes to PubSub.
- **`media_card`** — the poster card for movie/TV results and library records. `card bg-base-200
  shadow-sm`; the figure always renders the per-title gradient placeholder
  (`poster_fallback_style/1`) as a base layer, with `<img data-poster>` absolutely positioned on
  top of it once a `poster_path` exists — so a poster that fails to load degrades to the exact
  same tile as a title with no poster at all, never the browser's broken-image glyph (see Motion
  for the failure-detection half). The gradient's hue is per-title and fixed (identity feature);
  its lightness is theme-aware — a dark ramp under dark, a light ramp on the same hues under
  `[data-theme=light]` (`app.css`) — so the tile always tracks its own theme, and the "No
  poster" label can use the theme's own `text-base-content` instead of a pinned `text-white`.
  The label is CSS-gated to that same state
  (`:has(> img[data-poster]:not(.poster-broken))`) so it only shows, and is only announced, when
  it's actually true — not on every card while its real poster is still loading. Optional type
  chip (top-left, `bg-base-100`, film/TV icon + label). Body (`card-body p-3`) shows the title
  (`text-sm font-semibold leading-tight`) + dimmed year, then an inner-block action slot (Add
  button, status badge, season link, admin controls).
- **`detail_poster`** — the larger hero poster (`w-40`) on a title's own detail/discovery page:
  movie detail, movie/series discovery, series detail, and the entity-discovery person/collection
  headers. Same always-present-base-layer-plus-overlay mechanism as `media_card`, with each
  page's own `bg-base-300` "No poster" box (not the gradient) as the base layer.
- **`thumb_poster`** — the 48px (`w-12`, TMDB `w92`) list-row thumbnail in the admin approval
  queue and the requests list. Same mechanism again, sized down to a plain `bg-base-300` box with
  no label — there's no room to set "No poster" text at that size.
- **`confirm_action`** — inline two-step confirm for destructive actions. `alert alert-warning`,
  `role="alert" aria-live="assertive"`; a caveat line, a confirm button (`btn-error` or
  `btn-warning`, `phx-disable-with="Working…"`) and a `btn-ghost` cancel; optional inline
  checkbox ("also do X"). Markup only — caller drives visibility with `:if`.
- **`empty_state`** — centered zero state: large icon (`size-10`, `text-base-content/40`), title,
  optional dimmed message, optional `:cta` slot. `variant="search-error"` swaps to
  `hero-exclamation-triangle` in `text-error` for a failed search vs. ordinary no-results.
- **`header`** — page header: `h1` (`text-lg font-semibold leading-8`), optional subtitle
  (`text-sm text-base-content/70`), optional right-aligned `:actions` slot.
- **`spinner`** — inline `hero-arrow-path` with `motion-safe:animate-spin` + optional label, in
  `text-base-content/60`. Respects reduced motion (stops spinning).
- **`flash`** — toast (`toast toast-top toast-end`), `alert-info` / `alert-error`, leading icon,
  optional title, message, and an `aria-label`ed close. `flash_group` adds live client/server
  reconnection toasts.
- **`icon`** — heroicons via `hero-*` classes (outline default; `-solid` / `-mini` suffixes),
  default `size-4`.
- **`language_select`** — shared preferred-language select (Original / French / Any), `aria-label`ed.

## Motion

Functional only; no bounce, no spring, no decorative motion.

- **The kindle:** the focal moment. `status_badge` acknowledges a pipeline state change that
  arrived over PubSub — `@keyframes cinder-kindle` flares the badge's own colour
  (`filter: saturate(1.75) contrast(1.06)` decaying to none, 600ms,
  `cubic-bezier(0.16, 1, 0.3, 1)`). Driven by the `Kindle` hook in `app.js`, keyed on
  `data-kindle` (`"#{color}|#{label}"` — the user-visible state, not the raw status term).
  Opt-in per call site via `id`, wired only on surfaces whose LiveView subscribes to PubSub. It
  never fires on initial page load or on a progress tick — the hook's module-scope `kindleSeen`
  map is what makes that true across the `<span>`/`<div>` branch swap.
- **Colour travel:** `.status-badge` transitions `background-color`/`border-color`/`color` over
  400ms so a state change reads as a change rather than a teleport.
- **Reduced motion means fewer and gentler, not silent.** The global reset in `app.css` collapses
  every animation/transition duration to `0.01ms !important` under `prefers-reduced-motion:
  reduce` — but that alone would erase the kindle's state-change signal entirely, so the kindle
  carries a deliberate alternative: a static `filter: saturate(1.6)` under reduce, no animation,
  no movement. Everything else genuinely is covered for free by the reset; `motion-safe:*`
  utilities simply no-op under reduce.
- **Feedback:** `.btn:active` presses (`scale(0.985)`, with `transform` added to daisyUI's own
  `transition-property` list, which otherwise omits it); in-flight `.phx-click-loading` /
  `.phx-submit-loading` dims and disables pointer events so every click is acknowledged, even the
  many buttons with no `phx-disable-with`.
- **Poster reveal:** uncached posters fade in via `data-poster` on the `<img>` and
  `fadeUncachedPosters()` in `app.js`; a grid of cached posters renders with no fade at all, and
  the image is visible if JS never runs. The same pass also detects failure — the `error` event,
  or a synchronous `img.complete && naturalWidth === 0` check for a poster that already failed
  *before* this code ran (a cached 404, a fast failure) — and adds `.poster-broken`
  (`display: none`), so the always-present placeholder underneath (`media_card` /
  `detail_poster` / `thumb_poster`, above) re-exposes itself instead of the browser's
  broken-image glyph.
- **Loading bar:** the topbar is the ember accent, read from `--color-primary` at runtime and
  re-themed on `phx:set-theme`, replacing the stock Phoenix `#29d` blue.
- **Show / hide** (`JS.show`/`JS.hide` helpers): **show** = `ease-out duration-300`, fades + rises
  (`opacity-0 translate-y-4 sm:scale-95` → `opacity-100 translate-y-0 sm:scale-100`); **hide** =
  `ease-in duration-200`, the reverse. Asymmetric, gentle, no overshoot.
- **Theme toggle:** a sliding pill (`transition-[left]`) moving across system / light / dark.
- **Spinner / reconnect:** `motion-safe:animate-spin` only.

## Browser chrome

Stock browser defaults for UI the theme didn't explicitly draw — the cheapest signal a UI was
assembled rather than built. Everything here reads from the color tokens above; nothing new is
invented.

- **`::selection`** — an ember tint under the page's own `base-content` text, not the
  `primary`/`primary-content` pairing buttons and badges use for text-on-ember. That pairing was
  tried first and rejected: it measures 3.39:1 in the light theme, under WCAG AA's 4.5:1 for
  body text (fine for a button label at that size/weight, not for arbitrary selected text). A
  30%-opacity ember wash under `base-content` measures 9.68:1 / 8.85:1 (dark, over base-100 /
  base-200) and 11.63:1 / 11.09:1 (light) — comfortably clear in both themes, on both surfaces.
- **`caret-color`** on `input`/`textarea` — the ember accent, not the browser default.
- **Scrollbars are intentionally left alone.** daisyUI's own base layer already sets
  `:root { scrollbar-color: color-mix(currentColor 35%, transparent) transparent }`, which tracks
  both themes automatically. A second rule here would be redundant at best.
- **`:focus-visible`**, restated in ember wherever daisyUI's own default is a muted
  `base-content`-derived ring: `input`/`select`/`textarea`/`checkbox` (their `-error` states keep
  their own red — the override explicitly excludes them, rather than relying on cascade order to
  keep it that way, and stay on `--color-primary`, a border-colour not an outline) and any plain
  `<a>` outside `.link`/`.btn`, which — along with the poster card below — use the dedicated
  `focus-ring` token instead of `primary` (#598: `primary` only cleared WCAG 1.4.11's 3:1
  non-text floor by 0.25 against `bg-base-200` in the light theme, and fell under it against
  `bg-base-300`; `focus-ring` is deeper on the same hue, measured ≥4.5:1 against `base-100`/
  `base-200`/`base-300`, without touching the pinned `primary`/`accent` buttons and badges
  depend on). The handful of hand-set icon-only controls — the theme-toggle buttons
  (`bg-base-300`) and the settings disclosure `<summary>` headers (`bg-base-200`) — use the
  same `focus-visible:outline-(--color-focus-ring)` token for the same reason. This
  deliberately includes the
  sidebar `.menu`: daisyUI's own menu-item focus state is a 10%-opacity background tint with no
  outline at all, measured too faint to trust as the primary-navigation focus indicator, so the
  sidebar gets the same ember ring as everything else (verified it adds to the tint rather than
  fighting it, and doesn't double up with `.link`'s own `currentColor` ring — same `outline`
  property, one value wins). The poster card is a special case: `library_live` wraps every
  `media_card` in a plain `<a>` that receives focus, while the `.card` div inside it never does
  (no faked `tabindex`), so daisyUI's own `.card:focus-visible { outline-color: currentColor }`
  is unreachable dead CSS. `a:has(> .card):focus-visible { outline: none }` plus
  `a:focus-visible > .card { outline: 2px solid focus-ring }` rings the card itself instead, so
  the outline hugs its own rounded corners rather than a bare rectangle around the whole link.
- **`text-underline-offset: 3px`** on `a` — the browser default sits right on the baseline and
  clips descenders (g, y, p, j) in Inter.

## Layout

- **App shell (signed in):** daisyUI `drawer lg:drawer-open`. On `lg+` a persistent left sidebar
  (`aside`, `w-64`, `bg-base-200`, `border-r border-base-300/60`); below `lg` it collapses behind
  a top `navbar` (`bg-base-100`, hamburger + wordmark) with an overlay drawer.
- **Sidebar:** Ember Loop mark + wordmark; a `menu` grouped by `menu-title` sections — **Everyone** (Discover,
  My requests) and, role-gated, **Admin** (Dashboard, Requests, Library, Activity, Calendar,
  Settings, Users). Active item = `menu-active font-medium text-primary` + `aria-current="page"`.
  Footer pins the theme toggle + locale switcher (a `join` of `btn-xs` locale links), the current
  user's email (truncated), Account, and Log out.
- **Content column:** `main#main`, `mx-auto w-full max-w-6xl 2xl:max-w-[110rem]`,
  `px-4 py-8 sm:px-6 lg:px-8`. A
  `header#main` skip-to-content link precedes everything.
- **Signed-out shell:** no drawer — a centered `max-w-md` column, vertically centered, with the
  wordmark on top and the locale switcher below (auth/setup pages).
- **Grids:** poster surfaces (Discover, Library) lay `media_card`s in a responsive grid; each card
  is a fixed `aspect-[2/3]` poster + compact body. Content density is calm: generous padding,
  hairline dividers, one accent.

### Responsive rules (every new screen, ~360px first)

The content column is `mx-auto`, so any single descendant wider than the viewport centers its
overflow and clips the whole page on **both** edges (header included). The whole-app fix is a
handful of mechanical habits, not per-page tuning:

- **Rows of chips/controls wrap.** A flex row holding 2+ of {badge, button, input, status} gets
  `flex-wrap` (with `gap-y-*`), or `flex-col sm:flex-row` to stack on a phone. A bare `flex` row of
  controls is the default bug.
- **A flex child holding text gets `min-w-0`.** A flex item's min-width defaults to its longest
  word (`min-content`); an email/URL/path/infohash/title then can't shrink and forces overflow. Add
  `min-w-0` to the column, plus `truncate` (one-line ellipsis) or `break-words`/`break-all` (wrap)
  on the text itself. `truncate` does nothing without `min-w-0` on the flex item.
- **`justify-between`/`ml-auto` fight wrapping.** Pair them with `flex-wrap`, or gate the auto-margin
  behind `sm:` so the pinned item can drop to the next line on a phone.
- **Translated labels are wider.** French is ~30% longer; if a label, badge, or button only just
  fits in English it overflows in French. The shared `status_badge` is `shrink-0` (wraps as a whole
  unit in a flex row); daisyUI `.label` text is unpinned to wrap globally (`app.css`).
