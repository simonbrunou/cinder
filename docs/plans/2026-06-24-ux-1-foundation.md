# UX-1 Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Cinder's half-scaffold chrome with the "ember-on-charcoal" identity and a role-aware **left-sidebar app shell** (active-nav + working mobile drawer), with **no IA change** — every existing page renders inside the new shell.

**Architecture:** Three cohesive changes. (1) Swap the two stock daisyUI theme blocks in `app.css` for a single-accent **ember** dark+light theme and self-host Inter / Inter Tight. (2) Add a `:current_path` `on_mount` hook so the shell can highlight the active nav item (the shell lives in `Layouts.app`, which re-renders on live navigation — the root layout does not). (3) Rewrite `Layouts.app/1` as the daisyUI-`drawer` sidebar shell (role-aware via `current_scope`, active via `current_path`, mobile hamburger drawer), delete the dead Phoenix navbar + the `root.html.heex` `<ul>`, fix the page title, and update every `<Layouts.app>` call site to pass the two new assigns.

**Tech Stack:** Phoenix 1.8 / LiveView, HEEx, Tailwind v4 + daisyUI (vendored), ExUnit + `Phoenix.LiveViewTest`. No React, no new deps.

## Global Constraints

(Verbatim from `docs/specs/2026-06-24-ux-identity-overhaul-design.md`. Every task implicitly includes these.)

- **Do not touch the approval gate, role-gating, or pipeline logic.** Presentation/IA/theme only. No route's `on_mount` *auth* guard changes; `Cinder.Requests.create_request/2` stays the only user-action path that can create a `:requested` row. (UX-1 adds a *non-auth* `:current_path` hook alongside the existing guards — it must not alter who can access what.)
- **Stay in-stack.** Tailwind v4 + daisyUI + HEEx. No React, no CSS framework swap, no new external service env vars.
- **Every phase is independently shippable and green.** `mix test` (the alias: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, suite) passes at the phase boundary; commit per task.
- **Mobile is built in, not bolted on.** UX-1 ships the working drawer; nothing may overflow at 390px.
- **No backend/data-model change** is required by this phase.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `assets/css/app.css` | theme tokens + fonts | modify (replace lines 24–92 theme blocks; add `@font-face` + base font layer) |
| `priv/static/fonts/Inter-variable.woff2` | self-hosted body font | create (vendored) |
| `priv/static/fonts/InterTight-variable.woff2` | self-hosted display font | create (vendored) |
| `lib/cinder_web/user_auth.ex` | `:current_path` on_mount hook | modify (add one `on_mount` clause) |
| `lib/cinder_web/router.ex` | wire the hook into live_sessions | modify (add `{CinderWeb.UserAuth, :current_path}` to each `on_mount` list) |
| `lib/cinder_web/components/layouts.ex` | the sidebar app shell | modify (rewrite `app/1` + a `nav_item/1` helper; keep `flash_group/1`, `theme_toggle/1`) |
| `lib/cinder_web/components/layouts/root.html.heex` | outer HTML | modify (remove the `<ul>` nav, fix `<.live_title>`, add skip link) |
| `lib/cinder_web/live/**/*.ex` (every `<Layouts.app>` call site) | pass the new assigns | modify (mechanical) |
| `test/cinder_web/live/app_shell_test.exs` | shell behaviour | create |

---

## Task 1: Ember theme + self-hosted fonts

**Files:**
- Modify: `assets/css/app.css:24-92` (the two `@plugin "daisyui-theme"` blocks) + append `@font-face`/base layer
- Create: `priv/static/fonts/Inter-variable.woff2`, `priv/static/fonts/InterTight-variable.woff2`

**Interfaces:**
- Produces: the daisyUI semantic tokens (`primary` = ember, `base-100/200/300`, `info/success/warning/error`) and the `Inter` / `Inter Tight` font families that every later task and phase styles against. No Elixir interface.

- [ ] **Step 1: Vendor the two variable fonts**

Run (needs network — a one-time vendor step like the existing `assets/vendor/daisyui.js`):

```bash
mkdir -p priv/static/fonts
curl -fsSL -o priv/static/fonts/Inter-variable.woff2 \
  "https://cdn.jsdelivr.net/fontsource/fonts/inter:vf@latest/latin-wght-normal.woff2"
curl -fsSL -o priv/static/fonts/InterTight-variable.woff2 \
  "https://cdn.jsdelivr.net/fontsource/fonts/inter-tight:vf@latest/latin-wght-normal.woff2"
ls -l priv/static/fonts/
```

Expected: two `.woff2` files, each > 50 KB. (If a URL 404s, fetch the equivalent variable woff2 from https://fontsource.org/fonts/inter and `.../inter-tight` and save under the same names — the rest of the task is unchanged.)

- [ ] **Step 2: Replace the two theme blocks** in `assets/css/app.css`

Replace the entire block from `@plugin "../vendor/daisyui-theme" {` (line 24, `name: "dark"`) through the closing `}` of the light theme (line 92) with:

```css
/* Cinder "ember on charcoal" — dark is the default/hero theme. One ember accent
   across both themes (replaces the stock Phoenix-orange / Elixir-purple split). */
@plugin "../vendor/daisyui-theme" {
  name: "dark";
  default: true;
  prefersdark: true;
  color-scheme: "dark";
  --color-base-100: oklch(15.5% 0.008 265);
  --color-base-200: oklch(19.5% 0.009 265);
  --color-base-300: oklch(23% 0.01 262);
  --color-base-content: oklch(93% 0.003 265);
  --color-primary: oklch(72% 0.16 47);
  --color-primary-content: oklch(20% 0.04 50);
  --color-secondary: oklch(55% 0.02 265);
  --color-secondary-content: oklch(96% 0.003 265);
  --color-accent: oklch(72% 0.16 47);
  --color-accent-content: oklch(20% 0.04 50);
  --color-neutral: oklch(27% 0.012 265);
  --color-neutral-content: oklch(92% 0.003 265);
  --color-info: oklch(72% 0.13 250);
  --color-info-content: oklch(20% 0.03 250);
  --color-success: oklch(74% 0.14 165);
  --color-success-content: oklch(20% 0.04 165);
  --color-warning: oklch(80% 0.13 75);
  --color-warning-content: oklch(25% 0.05 75);
  --color-error: oklch(68% 0.2 22);
  --color-error-content: oklch(98% 0.01 20);
  --radius-selector: 0.5rem;
  --radius-field: 0.5rem;
  --radius-box: 0.875rem;
  --size-selector: 0.21875rem;
  --size-field: 0.21875rem;
  --border: 1px;
  --depth: 1;
  --noise: 0;
}

@plugin "../vendor/daisyui-theme" {
  name: "light";
  default: false;
  prefersdark: false;
  color-scheme: "light";
  --color-base-100: oklch(98.5% 0.002 90);
  --color-base-200: oklch(96.5% 0.003 90);
  --color-base-300: oklch(92% 0.004 90);
  --color-base-content: oklch(22% 0.01 265);
  --color-primary: oklch(64% 0.17 45);
  --color-primary-content: oklch(98% 0.015 75);
  --color-secondary: oklch(50% 0.02 265);
  --color-secondary-content: oklch(98% 0.002 247);
  --color-accent: oklch(64% 0.17 45);
  --color-accent-content: oklch(98% 0.015 75);
  --color-neutral: oklch(44% 0.017 265);
  --color-neutral-content: oklch(98% 0 0);
  --color-info: oklch(58% 0.16 250);
  --color-info-content: oklch(98% 0.013 236);
  --color-success: oklch(62% 0.15 165);
  --color-success-content: oklch(98% 0.014 180);
  --color-warning: oklch(70% 0.16 70);
  --color-warning-content: oklch(26% 0.06 70);
  --color-error: oklch(58% 0.22 25);
  --color-error-content: oklch(98% 0.01 20);
  --radius-selector: 0.5rem;
  --radius-field: 0.5rem;
  --radius-box: 0.875rem;
  --size-selector: 0.21875rem;
  --size-field: 0.21875rem;
  --border: 1px;
  --depth: 1;
  --noise: 0;
}
```

- [ ] **Step 3: Add the fonts** — append to the very end of `assets/css/app.css` (after the existing `/* This file is for your main application CSS */` comment):

```css
@font-face {
  font-family: "Inter";
  font-style: normal;
  font-weight: 100 900;
  font-display: swap;
  src: url("/fonts/Inter-variable.woff2") format("woff2");
}
@font-face {
  font-family: "Inter Tight";
  font-style: normal;
  font-weight: 100 900;
  font-display: swap;
  src: url("/fonts/InterTight-variable.woff2") format("woff2");
}
@layer base {
  html {
    font-family: "Inter", system-ui, -apple-system, sans-serif;
  }
  h1, h2, h3, .font-display {
    font-family: "Inter Tight", "Inter", system-ui, sans-serif;
    letter-spacing: -0.01em;
  }
}
```

- [ ] **Step 4: Build assets and verify the theme is applied**

Run:

```bash
mix assets.build && \
  grep -q "oklch(72% 0.16 47)" assets/css/app.css && echo "EMBER OK" && \
  ! grep -q "oklch(58% 0.233 277.117)" assets/css/app.css && echo "PURPLE GONE"
```

Expected: `mix assets.build` exits 0; prints `EMBER OK` and `PURPLE GONE` (the stock Elixir-purple primary is gone). If `mix assets.build` is not aliased, run `mix tailwind cinder` instead.

- [ ] **Step 5: Commit**

```bash
git add assets/css/app.css priv/static/fonts/
git commit -m "feat(ux-1): ember-on-charcoal daisyUI theme + self-hosted Inter fonts"
```

---

## Task 2: `:current_path` on_mount hook + live_session wiring

**Files:**
- Modify: `lib/cinder_web/user_auth.ex` (add one `on_mount/4` clause, after the `:require_setup` clause ~line 279)
- Modify: `lib/cinder_web/router.ex` (add `{CinderWeb.UserAuth, :current_path}` to the `on_mount:` list of each live_session)
- Test: `test/cinder_web/live/app_shell_test.exs` is created in Task 3; this task is gated by Step 4 below.

**Interfaces:**
- Produces: an `@current_path` assign (a string like `"/status"`) present on every LiveView mount/navigation, consumed by `Layouts.app` in Task 3. The hook only *adds* an assign — it never halts, so it cannot change access control.

- [ ] **Step 1: Add the on_mount clause** to `lib/cinder_web/user_auth.ex`, immediately after the `:require_setup` clause's closing `end` (before `defp enforce_setup?`):

```elixir
  @doc """
  Assigns `@current_path` on initial mount and every live navigation so layouts can
  highlight the active nav item. Read-only: attaches a `:handle_params` hook and never
  halts, so it does not affect authorization.
  """
  def on_mount(:current_path, _params, _session, socket) do
    socket =
      Phoenix.LiveView.attach_hook(socket, :current_path, :handle_params, fn _params, uri, socket ->
        {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
      end)

    {:cont, socket}
  end
```

- [ ] **Step 2: Wire it into every live_session** in `lib/cinder_web/router.ex`. Add `{CinderWeb.UserAuth, :current_path}` as the **last** entry of each `on_mount:` list. The five lists are the `:authenticated`, `:admin`, `:setup`, `:require_authenticated_user`, and `:current_user` sessions. For example, `:authenticated` (lines 53-57) becomes:

```elixir
    live_session :authenticated,
      on_mount: [
        {CinderWeb.UserAuth, :require_authenticated},
        {CinderWeb.UserAuth, :require_setup},
        {CinderWeb.UserAuth, :current_path}
      ] do
```

Apply the identical addition to `:admin` (after `:require_setup`), `:setup` (after `:require_admin`), `:require_authenticated_user` (after `:require_authenticated`), and `:current_user` (after `:mount_current_scope`).

- [ ] **Step 3: Verify nothing broke** — the hook must not disturb auth or rendering:

Run:

```bash
mix compile --warnings-as-errors && mix test test/cinder_web/live/watchlist_live_test.exs
```

Expected: compiles clean; the existing watchlist suite passes (an authenticated mount still works with the added hook).

- [ ] **Step 4: Commit**

```bash
git add lib/cinder_web/user_auth.ex lib/cinder_web/router.ex
git commit -m "feat(ux-1): add read-only :current_path on_mount for active-nav state"
```

---

## Task 3: Sidebar app shell + remove dead chrome

**Files:**
- Modify: `lib/cinder_web/components/layouts.ex` (rewrite `app/1`; add `nav_item/1`; keep `flash_group/1`, `theme_toggle/1`)
- Modify: `lib/cinder_web/components/layouts/root.html.heex` (remove `<ul>` nav, fix `<.live_title>`, add skip link)
- Modify: every `lib/cinder_web/live/**/*.ex` that renders `<Layouts.app flash={@flash}>` (pass `current_scope` + `current_path`)
- Test: `test/cinder_web/live/app_shell_test.exs` (create)

**Interfaces:**
- Consumes: `@current_scope` (existing) and `@current_path` (Task 2).
- Produces: `Layouts.app/1` now requires `current_scope` and `current_path` attrs. The sidebar lists exactly today's routes (no IA change): **Everyone** — Search `/`, My requests `/my-requests`; **Admin** — Requests `/requests`, Status `/status`, Calendar `/calendar`, Users `/users`, Settings `/settings`; **foot** — theme toggle, account `/users/settings`, log out `/users/log-out`.

- [ ] **Step 1: Write the failing shell test** — create `test/cinder_web/live/app_shell_test.exs`:

```elixir
defmodule CinderWeb.AppShellTest do
  use CinderWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "renders the role-grouped sidebar with all admin links", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      for label <- ["Search", "My requests", "Requests", "Status", "Calendar", "Users", "Settings"] do
        assert html =~ label
      end
    end

    test "marks the current route active", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/status")
      assert html =~ ~s(aria-current="page")
    end

    test "ships no Phoenix-generator chrome and a Cinder title", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      refute html =~ "phoenixframework.org"
      refute html =~ "Get Started"
      refute html =~ "Phoenix Framework"
    end

    test "exposes a skip-to-content link and a main landmark", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ ~s(href="#main")
      assert html =~ ~s(id="main")
    end
  end

  describe "as a non-admin user" do
    setup :register_and_log_in_user

    test "shows only the everyone links, never the admin group", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Search"
      assert html =~ "My requests"
      refute html =~ "Requests"
      refute html =~ "Status"
      refute html =~ "Users"
      refute html =~ "Settings"
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mix test test/cinder_web/live/app_shell_test.exs`
Expected: FAIL — the admin links live in `root.html.heex` today (not `Layouts.app`'s output) and the dead "Get Started"/"Phoenix Framework" chrome still renders, so the `refute`s fail.

- [ ] **Step 3: Rewrite `Layouts.app/1`** in `lib/cinder_web/components/layouts.ex`. Replace the whole `def app(assigns)` function (lines 36-73) and its `attr`/`slot` block (lines 28-34) with the shell below, and add the `nav_item/1` helper. Keep `flash_group/1` and `theme_toggle/1` as they are.

```elixir
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the current scope (may carry a nil user)"
  attr :current_path, :string, default: nil, doc: "the active request path, for nav highlighting"
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :admin?, match?(%{user: %{role: :admin}}, assigns.current_scope))
    assigns = assign(assigns, :signed_in?, match?(%{user: %{}}, assigns.current_scope))

    ~H"""
    <a href="#main" class="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:m-2 focus:btn focus:btn-primary">
      Skip to content
    </a>

    <div :if={@signed_in?} class="drawer lg:drawer-open">
      <input id="nav-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex min-h-screen flex-col">
        <header class="navbar border-b border-base-300/60 bg-base-100/80 backdrop-blur lg:hidden">
          <label for="nav-drawer" class="btn btn-ghost btn-square" aria-label="Open menu">
            <.icon name="hero-bars-3" class="size-6" />
          </label>
          <span class="font-display text-lg font-bold tracking-wide">
            CIN<span class="text-primary">DER</span>
          </span>
        </header>

        <main id="main" class="mx-auto w-full max-w-6xl flex-1 px-4 py-8 sm:px-6 lg:px-8">
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="drawer-side z-20">
        <label for="nav-drawer" aria-label="Close menu" class="drawer-overlay"></label>
        <aside class="flex min-h-screen w-64 flex-col gap-2 border-r border-base-300/60 bg-base-200 p-4">
          <a href={~p"/"} class="mb-2 flex items-center gap-2 px-2">
            <span class="font-display text-xl font-bold tracking-wide">
              CIN<span class="text-primary">DER</span>
            </span>
          </a>

          <ul class="menu w-full gap-1 px-0">
            <li class="menu-title">Everyone</li>
            <.nav_item navigate={~p"/"} label="Search" icon="hero-magnifying-glass" current_path={@current_path} />
            <.nav_item navigate={~p"/my-requests"} label="My requests" icon="hero-bookmark" current_path={@current_path} />

            <%= if @admin? do %>
              <li class="menu-title mt-2">Admin</li>
              <.nav_item navigate={~p"/requests"} label="Requests" icon="hero-inbox-arrow-down" current_path={@current_path} />
              <.nav_item navigate={~p"/status"} label="Status" icon="hero-bolt" current_path={@current_path} />
              <.nav_item navigate={~p"/calendar"} label="Calendar" icon="hero-calendar" current_path={@current_path} />
              <.nav_item navigate={~p"/users"} label="Users" icon="hero-users" current_path={@current_path} />
              <.nav_item navigate={~p"/settings"} label="Settings" icon="hero-cog-6-tooth" current_path={@current_path} />
            <% end %>
          </ul>

          <div class="mt-auto flex flex-col gap-3 border-t border-base-300/60 pt-3">
            <.theme_toggle />
            <div class="px-2 text-xs text-base-content/60 truncate">
              {@current_scope.user.email}
            </div>
            <ul class="menu w-full gap-1 px-0">
              <.nav_item navigate={~p"/users/settings"} label="Account" icon="hero-user-circle" current_path={@current_path} />
              <li>
                <.link href={~p"/users/log-out"} method="delete" class="flex items-center gap-3">
                  <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" /> Log out
                </.link>
              </li>
            </ul>
          </div>
        </aside>
      </div>
    </div>

    <main :if={!@signed_in?} id="main" class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-4 py-10">
      <div class="mb-6 text-center font-display text-2xl font-bold tracking-wide">
        CIN<span class="text-primary">DER</span>
      </div>
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :current_path, :string, default: nil

  defp nav_item(assigns) do
    active =
      assigns.current_path == assigns.navigate or
        (assigns.navigate != "/" and is_binary(assigns.current_path) and
           String.starts_with?(assigns.current_path, assigns.navigate))

    assigns = assign(assigns, :active, active)

    ~H"""
    <li>
      <.link
        navigate={@navigate}
        aria-current={@active && "page"}
        class={["flex items-center gap-3", @active && "menu-active font-medium text-primary"]}
      >
        <.icon name={@icon} class="size-5 opacity-80" />
        {@label}
      </.link>
    </li>
    """
  end
```

- [ ] **Step 4: Strip the dead chrome from `root.html.heex`.** In `lib/cinder_web/components/layouts/root.html.heex`: (a) change the title on line 7 from `suffix=" · Phoenix Framework"` to `suffix=" · Cinder"`; (b) delete the entire `<ul class="menu menu-horizontal …"> … </ul>` nav block (lines 32-74), leaving `{@inner_content}` as the only child of `<body>`. After the edit the `<body>` is:

```heex
  <body>
    {@inner_content}
  </body>
```

- [ ] **Step 5: Pass the new assigns at every `<Layouts.app>` call site.** First enumerate, then transform:

```bash
grep -rln "Layouts.app flash={@flash}>" lib/cinder_web/live
grep -rl "Layouts.app flash={@flash}>" lib/cinder_web/live | \
  xargs sed -i 's|<Layouts.app flash={@flash}>|<Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>|g'
```

Then catch any call site not matching the canonical string (e.g. one that already passes `current_scope`, or spans lines):

```bash
grep -rn "<Layouts.app" lib/cinder_web | grep -v "current_path"
```

For each line the second grep prints, hand-edit that `<Layouts.app …>` tag to also include `current_scope={@current_scope}` and `current_path={@current_path}`. Re-run the second grep until it prints nothing.

- [ ] **Step 6: Run the shell test and the full suite**

Run: `mix test test/cinder_web/live/app_shell_test.exs && mix test`
Expected: the shell test passes; the full suite stays green. (If a page test asserted old root-nav text like a bare `"Status"` link in the header, update that assertion to match the sidebar — note any such edits in the commit.)

- [ ] **Step 7: Manual mobile check (no overflow at 390px)**

Run `mix phx.server`, open `http://localhost:4000/` at 390px width (browser devtools device toolbar). Confirm: the sidebar is hidden behind the `☰` button, tapping it opens the drawer, the overlay closes it, and there is no horizontal scrollbar. (This satisfies the UX-1 mobile Done-when; it is a visual check, not an automated test.)

- [ ] **Step 8: Commit**

```bash
git add lib/cinder_web/components/layouts.ex \
        lib/cinder_web/components/layouts/root.html.heex \
        lib/cinder_web/live test/cinder_web/live/app_shell_test.exs
git commit -m "feat(ux-1): role-aware sidebar app shell; remove Phoenix scaffold chrome"
```

---

## Self-review

**1. Spec coverage (UX-1 Done-when):**
- "Phoenix Website/GitHub/Get Started chrome gone (grep clean)" → Task 3 Step 4 (delete nav) + test `refute html =~ "Get Started"` / `"phoenixframework.org"`. ✓
- "tab title no longer says Phoenix Framework" → Task 3 Step 4 (title suffix) + test `refute html =~ "Phoenix Framework"`. ✓
- "every route renders inside the ember sidebar shell with an active-nav indicator" → Task 1 (theme) + Task 3 (shell, `aria-current` active) + test. ✓
- "sidebar collapses to a functioning drawer at 390px, no horizontal overflow" → Task 3 daisyUI `drawer lg:drawer-open` + Step 7 manual check. ✓
- "a test covers role-aware nav visibility (non-admin does not see admin links)" → `app_shell_test.exs` non-admin describe block. ✓
- Theme/fonts (UX-1 build list) → Task 1. ✓

**2. Placeholder scan:** No "TBD"/"handle later"; every code step shows complete code; the call-site transformation is an exact `sed` + an exhaustive follow-up grep (not "etc."). ✓

**3. Type/name consistency:** `@current_path` assigned by `UserAuth.on_mount(:current_path, …)` (Task 2) and consumed by `Layouts.app`/`nav_item` `current_path` attr (Task 3) — names match. `current_scope` attr matches the existing `@current_scope` assign. The `:current_path` hook name (atom) is unique. ✓

**Note for the implementer:** the active-state `aria-current` requires `Layouts.app` to be rendered inside the LiveView (it is — every page wraps in `<Layouts.app>`), because the root layout does not re-render on intra-session live navigation. Do not move the sidebar into `root.html.heex`.
