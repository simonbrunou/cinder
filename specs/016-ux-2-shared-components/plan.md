# UX-2 Shared Component Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the app's duplicated UI idioms — 6 hand-rolled status-badge helpers, 4 incompatible confirm shapes, 15 bare empty-state sentences, 3 bare-`<h1>` page headers, and a near-total absence of loading feedback — with a small shared component layer adopted across every page, so the whole app speaks one visual language.

**Architecture:** Four net-new function components in `core_components.ex` — `<.status_badge>` (icon+text, one `{kind, status}` → `{label, colour, icon}` map subsuming all 6 helpers), `<.confirm_action>` (one inline `role="alert"` confirm with a `:caveat` slot, subsuming 8 of the 10 confirm flows), `<.empty_state>` (icon/title/message/`:cta` with a distinct `search-error` variant), and `<.spinner>` (the `hero-arrow-path` + `motion-safe:animate-spin` idiom). Plus two non-component sweeps: `phx-disable-with` on mutating buttons, and converting the 3 bare-`<h1>` pages to the **existing** `<.header>`. No new screens, no IA change, no pipeline/auth change.

**Tech Stack:** Phoenix 1.8 / LiveView, HEEx, Tailwind v4 + daisyUI (vendored), heroicons plugin, ExUnit + `Phoenix.LiveViewTest`. No React, no new deps.

## Decision: `<.page>` is dropped (council 3–0)

The design spec's component list names a `<.page>` scaffold ("always `.header` + `:subtitle` + one container width"). A perspective-diverse council (DRY / forward-looking / lazy-YAGNI lenses) voted **3–0 to skip it**: UX-1's shell `<main>` already provides the single `max-w-6xl` container width, so `<.page>` would only re-wrap the existing `<.header>` — manufacturing a second header idiom, the exact duplication UX-2 exists to delete. The forward-looking seat confirmed UX-4's TMDB backdrop hero is a **full-bleed shell concern** (it must escape `max-w-6xl`), so a header-wrapper would not be its seam anyway. **Resolution:** standardize on `<.header>` — convert only the 3 bare-`<h1>` offenders (Task 6). UX-2's formal Done-when does not mention `<.page>`; this satisfies it.
<!-- ponytail: no <.page> component — <.header> + the UX-1 shell already cover "one header + one container width". Upgrade path: if UX-4 needs shared chrome *around* the header on ≥3 pages, wrap <.header> then, migrating only those pages. -->

## Global Constraints

(Verbatim from `docs/specs/2026-06-24-ux-identity-overhaul-design.md`. Every task implicitly includes these.)

- **Do not touch the approval gate, role-gating, or pipeline logic.** Presentation/theme only. No route's `on_mount` *auth* guard changes; `Cinder.Requests.create_request/2` stays the only user-action path that can create a `:requested` row; the poller pickup is unchanged. UX-2 changes markup and deletes view helpers — it must not alter any `handle_event`/context call. Existing `phx-click`/`phx-submit` **event names and `phx-value-id` wiring are preserved** at every adoption site (the components are markup-only; per-page `@confirming`/`@search_error` assigns stay as they are).
- **Stay in-stack.** Tailwind v4 + daisyUI + HEEx. No React, no CSS framework swap, no new external service env vars.
- **Every phase is independently shippable and green.** `mix test` (the alias: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, suite) passes at the phase boundary; commit per task.
- **Mobile is built in, not bolted on.** The new shared components stack cleanly at 390px and their primary touch targets are ≥ 44px (`<.confirm_action>` uses full `btn`, ≈48px). Re-sizing the pre-existing `btn-xs` row actions is **out of scope — UX-5** (cross-device sweep).
- **No backend/data-model change** is required by this phase.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `lib/cinder_web/components/core_components.ex` | the 4 shared components | modify (add `status_badge`/`confirm_action`/`empty_state`/`spinner` + their private maps; delete `movie_status_badge`/`request_status_badge`/`status_badge_class`/`request_badge_class`) |
| `test/cinder_web/components/status_badge_test.exs` | `<.status_badge>` unit test | rewrite (currently tests the old `movie_status_badge`) |
| `test/cinder_web/components/shared_components_test.exs` | `<.confirm_action>`/`<.empty_state>` unit tests | create |
| `lib/cinder_web/live/watchlist_live.ex` | discovery grid | modify (movie + composite badges; empty/search-error states; `add` disable) |
| `lib/cinder_web/live/series_live.ex` | TV search/list | modify (empty/search-error states; nothing-yet) |
| `lib/cinder_web/live/series_discovery_live.ex` | season request | modify (request badge; bare-h1 → header; seasons empty; `request_season` disable) |
| `lib/cinder_web/live/series_detail_live.ex` | series monitor detail | modify (bare-h1 → header; cancel/delete confirms; seasons empty; `save_series` disable) |
| `lib/cinder_web/live/calendar_live.ex` | upcoming episodes | modify (episode badge; bare-h1 → header; empty state) |
| `lib/cinder_web/live/status_live.ex` | movie pipeline + health | modify (movie + health badges; spinner; empties; `retry`/`recheck` disable) |
| `lib/cinder_web/live/grabs_live.ex` | in-flight downloads | modify (grab badge; delete confirm; empty) |
| `lib/cinder_web/live/movies_live.ex` | admin movie list | modify (movie badge; cancel/delete confirms; empty; `save` disable) |
| `lib/cinder_web/live/requests_live.ex` | approval queue | modify (request badge; delete confirm; empty; `approve`/`deny` disable) |
| `lib/cinder_web/live/my_requests_live.ex` | requester view | modify (request + movie badges; empty) |
| `lib/cinder_web/live/users_live.ex` | admin users | modify (delete confirm; CRUD-submit disable) |
| `lib/cinder_web/live/settings_live.ex`, `setup_live.ex` | config forms | modify (`save`/`validate`/`finish` disable) |
| `lib/cinder_web/components/settings_components.ex` | shared settings/setup field markup | modify (Test-connection result badge → `<.status_badge kind={:health}>`) |

---

## Task 1: `<.status_badge>` component (build + unit test)

**Files:**
- Modify: `lib/cinder_web/components/core_components.ex` (add `status_badge/1` + `badge_spec/2` + `badge_title/2` + `humanize_status/1`; leave the old badges in place for now so the app stays green)
- Test: `test/cinder_web/components/status_badge_test.exs` (rewrite)

**Interfaces:**
- Produces: `CinderWeb.CoreComponents.status_badge/1` — `attr :kind` (`:movie | :request | :episode | :grab | :health`), `attr :status` (any), `attr :class` (any, default nil). Renders `<span class="badge badge-sm gap-1 …"><.icon …/>{label}</span>`. Derived-state callers (episode/grab) pass a resolved atom; health passes `:ok` or `{:error, reason}` (reason → hover `title`). Consumed by every badge call site in Task 2.

- [ ] **Step 1: Rewrite the unit test** — replace the whole contents of `test/cinder_web/components/status_badge_test.exs` (it currently exercises the soon-deleted `movie_status_badge`):

```elixir
defmodule CinderWeb.StatusBadgeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CinderWeb.CoreComponents

  defp badge(assigns), do: render_component(&CoreComponents.status_badge/1, assigns)

  test "renders every movie pipeline status with an icon and text label" do
    for status <- [
          :requested,
          :searching,
          :downloading,
          :downloaded,
          :available,
          :no_match,
          :search_failed,
          :import_failed,
          :cancelled
        ] do
      html = badge(%{kind: :movie, status: status})
      assert html =~ "badge"
      # icon+text, never colour alone: a heroicon span is present
      assert html =~ "hero-"
    end
  end

  test "covers request, episode, grab and health kinds with icon+text" do
    cases = [
      {%{kind: :request, status: :pending}, "Pending"},
      {%{kind: :request, status: :available}, "Available"},
      {%{kind: :episode, status: :wanted}, "Wanted"},
      {%{kind: :episode, status: :upcoming}, "Upcoming"},
      {%{kind: :grab, status: :downloading}, "Downloading"},
      {%{kind: :grab, status: :downloaded}, "Downloaded"},
      {%{kind: :health, status: :ok}, "OK"}
    ]

    for {assigns, label} <- cases do
      html = badge(assigns)
      assert html =~ label
      assert html =~ "hero-"
    end
  end

  test "a health error renders Unreachable, error colour, and the reason as a title" do
    html = badge(%{kind: :health, status: {:error, :timeout}})
    assert html =~ "Unreachable"
    assert html =~ "badge-error"
    assert html =~ ~s(title=)
    assert html =~ "timeout"
  end

  test "an unmapped status falls back to a neutral badge instead of raising" do
    html = badge(%{kind: :movie, status: :some_new_state})
    assert html =~ "badge-neutral"
    assert html =~ "Some new state"
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mix test test/cinder_web/components/status_badge_test.exs`
Expected: FAIL — `CoreComponents.status_badge/1` is undefined.

- [ ] **Step 3: Add the component** to `lib/cinder_web/components/core_components.ex`. Place it immediately **above** the existing `movie_status_badge/1` (the old badges and their private maps stay for now — Task 2 deletes them). Insert:

```elixir
  @doc """
  A status badge with an icon **and** a text label — never colour alone (a11y). One
  source of truth for every pipeline / request / episode / grab / health state.

  `kind` selects the vocabulary; `status` is the state within it. Derived-state callers
  (episode, grab) resolve the atom themselves and pass it; `health` passes `:ok` or
  `{:error, reason}` (the reason becomes the hover title).

  ## Examples

      <.status_badge kind={:movie} status={:downloading} />
      <.status_badge kind={:request} status={:pending} />
      <.status_badge kind={:episode} status={:wanted} />
      <.status_badge kind={:grab} status={:downloaded} />
      <.status_badge kind={:health} status={{:error, :timeout}} />
  """
  attr :kind, :atom, required: true, values: [:movie, :request, :episode, :grab, :health]
  attr :status, :any, required: true
  attr :class, :any, default: nil

  def status_badge(assigns) do
    {label, color, icon} = badge_spec(assigns.kind, assigns.status)

    assigns =
      assign(assigns,
        label: label,
        color: color,
        icon: icon,
        title: badge_title(assigns.kind, assigns.status)
      )

    ~H"""
    <span class={["badge badge-sm gap-1", @color, @class]} title={@title}>
      <.icon name={@icon} class="size-3.5" />{@label}
    </span>
    """
  end

  # movie pipeline status
  defp badge_spec(:movie, :requested), do: {"Requested", "badge-neutral", "hero-clock"}
  defp badge_spec(:movie, :searching), do: {"Searching", "badge-info", "hero-magnifying-glass"}
  defp badge_spec(:movie, :downloading), do: {"Downloading", "badge-info", "hero-arrow-down-tray"}
  defp badge_spec(:movie, :downloaded), do: {"Downloaded", "badge-accent", "hero-check"}
  defp badge_spec(:movie, :available), do: {"Available", "badge-success", "hero-check-circle"}
  defp badge_spec(:movie, :no_match), do: {"No match", "badge-warning", "hero-magnifying-glass"}

  defp badge_spec(:movie, :search_failed),
    do: {"Search failed", "badge-error", "hero-exclamation-triangle"}

  defp badge_spec(:movie, :import_failed),
    do: {"Import failed", "badge-error", "hero-exclamation-triangle"}

  defp badge_spec(:movie, :cancelled), do: {"Cancelled", "badge-error", "hero-x-circle"}

  # request / composite discovery state
  defp badge_spec(:request, :pending), do: {"Pending", "badge-warning", "hero-clock"}
  defp badge_spec(:request, :approved), do: {"Approved", "badge-info", "hero-check"}
  defp badge_spec(:request, :denied), do: {"Denied", "badge-error", "hero-x-circle"}
  defp badge_spec(:request, :available), do: {"Available", "badge-success", "hero-check-circle"}

  # episode derived-state
  defp badge_spec(:episode, :available), do: {"Available", "badge-success", "hero-check-circle"}

  defp badge_spec(:episode, :downloading),
    do: {"Downloading", "badge-info", "hero-arrow-down-tray"}

  defp badge_spec(:episode, :wanted), do: {"Wanted", "badge-warning", "hero-eye"}
  defp badge_spec(:episode, :upcoming), do: {"Upcoming", "badge-ghost", "hero-calendar"}

  # grab state
  defp badge_spec(:grab, :downloading), do: {"Downloading", "badge-info", "hero-arrow-down-tray"}
  defp badge_spec(:grab, :downloaded), do: {"Downloaded", "badge-success", "hero-check"}

  # service health
  defp badge_spec(:health, :ok), do: {"OK", "badge-success", "hero-check-circle"}

  defp badge_spec(:health, {:error, _reason}),
    do: {"Unreachable", "badge-error", "hero-exclamation-triangle"}

  # safe fallback — a view must never crash over an unmapped state
  defp badge_spec(_kind, status),
    do: {humanize_status(status), "badge-neutral", "hero-question-mark-circle"}

  defp badge_title(:health, {:error, reason}), do: inspect(reason)
  defp badge_title(_kind, _status), do: nil

  defp humanize_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp humanize_status(status), do: inspect(status)
```

Deliberate, intentional changes encoded here (call out in the commit body):
- **Drift fix:** movie `:downloading` moves `badge-primary` → `badge-info`, so "downloading" is one colour everywhere (movie/episode/grab agreed); the icon distinguishes searching vs downloading.
- **Grabs gain colour** (were colourless) and a `:downloaded → badge-success` treatment.
- **Labels are humanized/Title-cased** ("No match", "Search failed") for one casing convention.
- **Unknown states fall back to neutral** instead of raising `FunctionClauseError`.

- [ ] **Step 4: Run the test + compile clean**

Run: `mix test test/cinder_web/components/status_badge_test.exs && mix compile --warnings-as-errors`
Expected: PASS; compiles clean. (Credo may warn that `movie_status_badge`/`request_status_badge` are now unused-ish — they are still called by views until Task 2, so no warning yet.)

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/components/core_components.ex test/cinder_web/components/status_badge_test.exs
git commit -m "feat(ux-2): unified <.status_badge> (icon+text) — one source of truth for all states"
```

---

## Task 2: Adopt `<.status_badge>`; delete the 6 helpers

**Files:**
- Modify: `lib/cinder_web/components/core_components.ex` (delete `movie_status_badge/1`, `request_status_badge/1`, `status_badge_class/1`, `request_badge_class/1`)
- Modify: `requests_live.ex`, `watchlist_live.ex`, `my_requests_live.ex`, `movies_live.ex`, `status_live.ex` (incl. deleting its now-orphaned `health_*` helpers), `series_discovery_live.ex`, `calendar_live.ex`, `grabs_live.ex`, `components/settings_components.ex` (Test-connection badge) (swap call sites; delete in-view helpers; rework the two derived-state mappers)
- Test: the affected live-view tests (assertions on old lowercased labels) — fix to the new labels

**Interfaces:**
- Consumes: `status_badge/1` (Task 1).
- Produces: zero hand-rolled status-colour logic left in any LiveView (Done-when: "no page hand-rolls a status color").

- [ ] **Step 1: Swap the simple component call sites** (exact string replacements):

| File:line | From | To |
|---|---|---|
| `requests_live.ex:110` | `<.request_status_badge status={r.status} />` | `<.status_badge kind={:request} status={r.status} />` |
| `watchlist_live.ex:212` | `<.movie_status_badge status={m.status} />` | `<.status_badge kind={:movie} status={m.status} />` |
| `movies_live.ex:151` | `<.movie_status_badge status={m.status} />` | `<.status_badge kind={:movie} status={m.status} />` |
| `status_live.ex:160` | `<.movie_status_badge status={m.status} />` | `<.status_badge kind={:movie} status={m.status} />` |
| `status_live.ex:139` | `<.health_badge status={h.status} />` | `<.status_badge kind={:health} status={h.status} />` |
| `my_requests_live.ex:50` | `<.request_status_badge status={r.status} />` | `<.status_badge kind={:request} status={r.status} />` |

- [ ] **Step 2: Swap the `my_requests` movie badge** (lines 51–54). From:

```heex
            <.movie_status_badge
              :if={r.target_type == "movie" and @movie_status[r.target_id]}
              status={@movie_status[r.target_id]}
            />
```

to:

```heex
            <.status_badge
              :if={r.target_type == "movie" and @movie_status[r.target_id]}
              kind={:movie}
              status={@movie_status[r.target_id]}
            />
```

- [ ] **Step 3: Watchlist composite badge** — replace line 224 and delete `composite_class/1` (lines 237–240). Line 224 from:

```heex
    <span :if={@state != :none} class={["badge badge-sm", composite_class(@state)]}>{@state}</span>
```

to:

```heex
    <.status_badge :if={@state != :none} kind={:request} status={@state} />
```

Then delete the four `composite_class/1` clauses (237–240).

- [ ] **Step 4: Series-discovery request badge** — replace lines 175–176 and delete `badge_class/1` (190–192) + `badge_label/1` (194–196). From:

```heex
    <span :if={@status != nil} class={["badge badge-sm", badge_class(@status)]}>
      {badge_label(@status)}
    </span>
```

to:

```heex
    <.status_badge :if={@status != nil} kind={:request} status={@status} />
```

Then delete `badge_class/1` and `badge_label/1`.

- [ ] **Step 5: Calendar episode badge** — turn the `{label, class}` derivation into a resolved atom. In `assign_rows/1` (lines 25–29) from:

```elixir
    rows =
      for ep <- Catalog.upcoming_episodes() do
        {label, class} = badge(ep, today)
        %{ep: ep, label: label, class: class}
      end
```

to:

```elixir
    rows =
      for ep <- Catalog.upcoming_episodes() do
        %{ep: ep, state: episode_state(ep, today)}
      end
```

Replace `badge/2` (lines 36–43, plus its 34–35 doc comment) with:

```elixir
  # Derived episode state (no status enum): a file ⇒ available, an active grab ⇒ downloading,
  # an aired-but-missing monitored episode ⇒ wanted, else still upcoming.
  defp episode_state(ep, today) do
    cond do
      ep.file_path -> :available
      ep.grab_id -> :downloading
      Date.compare(ep.air_date, today) != :gt -> :wanted
      true -> :upcoming
    end
  end
```

And the render (line 74) from:

```heex
            <td><span class={["badge badge-sm", row.class]}>{row.label}</span></td>
```

to:

```heex
            <td><.status_badge kind={:episode} status={row.state} /></td>
```

- [ ] **Step 6: Grabs badge** — change `grab_state/1` (lines 50–51) to return atoms and swap the render (line 67). Mapper from:

```elixir
  defp grab_state(%{content_path: nil}), do: "downloading"
  defp grab_state(_grab), do: "downloaded"
```

to:

```elixir
  defp grab_state(%{content_path: nil}), do: :downloading
  defp grab_state(_grab), do: :downloaded
```

Render (line 67) from:

```heex
            <span class="badge badge-sm">{grab_state(g)}</span>
```

to:

```heex
            <.status_badge kind={:grab} status={grab_state(g)} />
```

- [ ] **Step 7: Adopt the last status badge (settings Test-connection), then delete every orphaned helper.**

**(a) `settings_components.ex` Test-connection badge** (shared by `/settings` + `/setup`). The per-service result badge at `lib/cinder_web/components/settings_components.ex:204–212` hand-rolls a status colour. Replace the body of `test_badge/1` from:

```elixir
  defp test_badge(assigns) do
    ~H"""
    <span
      class={["badge badge-sm", if(@result == :ok, do: "badge-success", else: "badge-error")]}
      title={test_title(@result)}
    >
      {if @result == :ok, do: "ok", else: "unreachable"}
    </span>
    """
  end
```

to:

```elixir
  defp test_badge(assigns) do
    ~H"""
    <.status_badge kind={:health} status={@result} />
    """
  end
```

Then delete `test_title/1` (its only caller was that `title=`). `SettingsComponents` already imports `CoreComponents` (it renders `<.input>`/`<.icon>`), so `<.status_badge>` resolves. The label changes `"ok"`/`"unreachable"` → `"OK"`/`"Unreachable"` (+ an icon) — update any `settings_live_test.exs`/`setup_live_test.exs` assertion on the lowercase strings in Step 8.

**(b) Delete the orphaned helpers** (each has zero remaining callers after the swaps above):
- `core_components.ex`: `movie_status_badge/1`, `request_status_badge/1` (the two `def`s + their `@doc`/`attr`, ~lines 507–523), `request_badge_class/1` (525–527), `status_badge_class/1` (529–537).
- `status_live.ex`: the private `health_badge/1` **and its `attr :status`** (lines 76–84), plus `health_class/1`, `health_text/1`, `health_title/1` (86–93) — the `:139` swap in Step 1 was their only caller, so `--warnings-as-errors` fails until they are removed. Keep `parked?/1` and `upsert_movie/1`.

Leave **everything else** (`header`, `button`, `icon`, `list`, `table`, the Task-1 `status_badge` and its `badge_spec`/`badge_title`/`humanize_status`; watchlist's non-status helpers).

> **Out of scope (leave as-is, note in commit):** `series_detail_live.ex:220` `<span class={["badge badge-sm mt-2", @series.monitored && "badge-success"]}>` is a **monitored/unmonitored flag**, and `users_live.ex:272` `class="badge badge-sm"` is a **role** label — neither is a pipeline/request/episode/grab/health *status*, so neither is a `<.status_badge>`. "No page hand-rolls a *status* colour" is satisfied.

- [ ] **Step 8: Run the full suite; fix label assertions**

Run: `mix test`
Expected: compile clean (no unused private fns — all deleted). Some live tests fail on the new labels/casing. Update these to match the new component output:
- `test/cinder_web/live/calendar_live_test.exs` — `"Available"`/`"Wanted"`/`"Upcoming"`/`"Downloading"` already Title-case (unchanged), but a test asserting the badge via `row.class` text won't exist; verify it asserts visible label text.
- `test/cinder_web/live/status_live_test.exs` — health label `"ok"` → `"OK"`, `"unreachable"` → `"Unreachable"`; movie statuses now Title-cased (e.g. a `=~ "available"` may need `=~ "Available"`).
- `test/cinder_web/live/{movies,watchlist,my_requests,series_discovery,requests}_live_test.exs` — any `=~ "<lowercased status>"` (e.g. `"pending"`, `"downloading"`, `"cancelled"`) → Title-case (`"Pending"`, `"Downloading"`, `"Cancelled"`). Specifically `watchlist_live_test.exs:84` (`"pending"`→`"Pending"`), `:137` (`"requested"`→`"Requested"`), `:142` (`"downloading"`→`"Downloading"`); the `refute` at `:143` still holds. Where a test asserts the raw atom string, switch to the new label.
- `test/cinder_web/live/{settings,setup}_live_test.exs` — any assertion on the Test-connection badge text `"ok"`/`"unreachable"` → `"OK"`/`"Unreachable"` (Step 7a).

For each failure, read the assertion and update it to the new visible text; do **not** weaken an assertion to `=~ "badge"` — keep it asserting the human label. Re-run `mix test` until green.

- [ ] **Step 9: Commit**

```bash
git add lib/cinder_web/components/core_components.ex lib/cinder_web/live test/cinder_web/live
git commit -m "refactor(ux-2): adopt <.status_badge> everywhere; delete 6 badge helpers"
```

---

## Task 3: `<.confirm_action>` component + adopt across the yes/no confirms

**Files:**
- Modify: `lib/cinder_web/components/core_components.ex` (add `confirm_action/1`)
- Modify: `requests_live.ex` (delete-confirm only), `movies_live.ex`, `series_live.ex`, `series_detail_live.ex`, `grabs_live.ex`, `users_live.ex`
- Test: `test/cinder_web/components/shared_components_test.exs` (create — `confirm_action` part)

**Interfaces:**
- Produces: `confirm_action/1` — `attr :id` (string, req), `:on_confirm` (string, req), `:on_cancel` (string, req), `:value` (any, default nil → `phx-value-id` sent on confirm only when present), `:confirm_label` (default "Confirm"), `:cancel_label` (default "Cancel"), `:variant` (`"error" | "warning"`, default "error"), `slot :caveat` (req). Markup-only: the caller keeps its `@confirming` assign + `:if` visibility and its existing event names.
- **Not subsumed:** the **deny-with-reason** flow (`requests_live.ex:119–132`) collects a free-text `reason` and submits a form — it stays bespoke (Task 5 only adds `phx-disable-with` to its submit). The single-click `retry` (`status_live.ex`) is not a confirm and is untouched here.

- [ ] **Step 1: Write the component test** — create `test/cinder_web/components/shared_components_test.exs`:

```elixir
defmodule CinderWeb.SharedComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Phoenix.Component

  alias CinderWeb.CoreComponents

  describe "confirm_action/1" do
    defp confirm(assigns) do
      render_component(fn assigns ->
        ~H"""
        <CoreComponents.confirm_action
          id={@id}
          on_confirm={@on_confirm}
          on_cancel={@on_cancel}
          value={@value}
          confirm_label={@confirm_label}
        >
          <:caveat>{@caveat}</:caveat>
        </CoreComponents.confirm_action>
        """
      end, assigns)
    end

    test "renders an alert with caveat, confirm and cancel wired to the given events" do
      html =
        confirm(%{
          id: "confirm-delete-7",
          on_confirm: "confirm_delete",
          on_cancel: "dismiss_confirm",
          value: 7,
          confirm_label: "Delete",
          caveat: "Delete this movie's record? (Library files are left on disk.)"
        })

      assert html =~ ~s(role="alert")
      assert html =~ "Library files are left on disk"
      assert html =~ ~s(phx-click="confirm_delete")
      assert html =~ ~s(phx-value-id="7")
      assert html =~ ~s(phx-click="dismiss_confirm")
      assert html =~ "Delete"
      assert html =~ "Cancel"
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mix test test/cinder_web/components/shared_components_test.exs`
Expected: FAIL — `confirm_action/1` is undefined.

- [ ] **Step 3: Add the component** to `core_components.ex` (near `button/1`):

```elixir
  @doc """
  Inline two-step confirmation for a destructive action: a `role="alert"` box with a
  caveat, a confirm button (emits `on_confirm`), and a cancel button (emits `on_cancel`).
  Markup only — the caller drives visibility with `:if` and keeps its own "confirming"
  assign and event names, so adoption preserves each page's existing wiring.

  ## Examples

      <.confirm_action
        :if={@confirming == {:delete, m.id}}
        id={"confirm-delete-#{m.id}"}
        on_confirm="confirm_delete"
        on_cancel="dismiss_confirm"
        value={m.id}
        confirm_label="Delete"
      >
        <:caveat>Delete this movie's record? (Library files are left on disk.)</:caveat>
      </.confirm_action>
  """
  attr :id, :string, required: true
  attr :on_confirm, :string, required: true
  attr :on_cancel, :string, required: true
  attr :value, :any, default: nil, doc: "phx-value-id sent with the confirm event (nil = omitted)"
  attr :confirm_label, :string, default: "Confirm"
  attr :cancel_label, :string, default: "Cancel"
  attr :variant, :string, default: "error", values: ~w(error warning)
  slot :caveat, required: true

  def confirm_action(assigns) do
    ~H"""
    <div
      id={@id}
      role="alert"
      aria-live="assertive"
      class="alert alert-warning flex flex-col items-start gap-2"
    >
      <p class="text-sm">{render_slot(@caveat)}</p>
      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          class={["btn", @variant == "warning" && "btn-warning", @variant == "error" && "btn-error"]}
          phx-click={@on_confirm}
          phx-value-id={@value}
          phx-disable-with="Working…"
        >
          {@confirm_label}
        </button>
        <button type="button" class="btn btn-ghost" phx-click={@on_cancel}>
          {@cancel_label}
        </button>
      </div>
    </div>
    """
  end
```

- [ ] **Step 4: Run the component test**

Run: `mix test test/cinder_web/components/shared_components_test.exs`
Expected: PASS.

- [ ] **Step 5: Adopt at each yes/no confirm site.** Replace the bespoke confirm markup; keep the existing `:if` condition, event names, and id. Do **not** touch the trigger buttons (`start_delete`/`ask_*`) or the `@confirming` assigns.

**5a — Requests delete** (`requests_live.ex`, the `:if={@confirming_delete == to_string(r.id)}` alert block, lines 151–170) → 

```heex
          <.confirm_action
            :if={@confirming_delete == to_string(r.id)}
            id={"confirm-delete-request-#{r.id}"}
            on_confirm="delete"
            on_cancel="cancel_delete"
            value={r.id}
            confirm_label="Delete request"
          >
            <:caveat>
              Deleting a request does not remove any movie or series it already created —
              that catalog row stays. If this request was denied or approved, the same title
              can be requested again afterwards.
            </:caveat>
          </.confirm_action>
```

**5b — Movies cancel** (`movies_live.ex:192–198`) →

```heex
          <.confirm_action
            :if={@confirming == {:cancel, to_string(m.id)}}
            id={"confirm-cancel-movie-#{m.id}"}
            on_confirm="confirm_cancel"
            on_cancel="dismiss_confirm"
            value={m.id}
            confirm_label="Cancel movie"
            variant="warning"
          >
            <:caveat>Cancel this movie and remove its download?</:caveat>
          </.confirm_action>
```

**5c — Movies delete** (`movies_live.ex:200–206`) →

```heex
          <.confirm_action
            :if={@confirming == {:delete, to_string(m.id)}}
            id={"confirm-delete-movie-#{m.id}"}
            on_confirm="confirm_delete"
            on_cancel="dismiss_confirm"
            value={m.id}
            confirm_label="Delete"
          >
            <:caveat>Delete this movie's record? (Library files are left on disk.)</:caveat>
          </.confirm_action>
```

**5d — Series list cancel** (`series_live.ex:176–186`) →

```heex
            <.confirm_action
              :if={@confirming == {:cancel, to_string(s.id)}}
              id={"confirm-cancel-series-#{s.id}"}
              on_confirm="confirm_cancel_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label="Cancel & unmonitor"
              variant="warning"
            >
              <:caveat>Cancel & unmonitor this series?</:caveat>
            </.confirm_action>
```

**5e — Series list delete** (`series_live.ex:188–198`) →

```heex
            <.confirm_action
              :if={@confirming == {:delete, to_string(s.id)}}
              id={"confirm-delete-series-#{s.id}"}
              on_confirm="confirm_delete_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label="Delete"
            >
              <:caveat>Delete this series record? (Library files are left on disk.)</:caveat>
            </.confirm_action>
```

**5f — Series detail cancel** (`series_detail_live.ex:192–196`; page-level, no id) →

```heex
      <.confirm_action
        :if={@confirming == :cancel}
        id="confirm-cancel-series"
        on_confirm="confirm_cancel_series"
        on_cancel="dismiss_confirm"
        confirm_label="Cancel series"
        variant="warning"
      >
        <:caveat>Cancel this series? Removes its downloads and unmonitors everything.</:caveat>
      </.confirm_action>
```

**5g — Series detail delete** (`series_detail_live.ex:198–204`) →

```heex
      <.confirm_action
        :if={@confirming == :delete}
        id="confirm-delete-series"
        on_confirm="confirm_delete_series"
        on_cancel="dismiss_confirm"
        confirm_label="Delete"
      >
        <:caveat>Delete this series and its seasons/episodes? (Library files are left on disk.)</:caveat>
      </.confirm_action>
```

**5h — Grabs delete** (`grabs_live.ex:81–87`) →

```heex
          <.confirm_action
            :if={@confirming == to_string(g.id)}
            id={"confirm-delete-grab-#{g.id}"}
            on_confirm="confirm_delete"
            on_cancel="dismiss_confirm"
            value={g.id}
            confirm_label="Delete"
          >
            <:caveat>Delete this grab? Its episodes are unlinked.</:caveat>
          </.confirm_action>
```

**5i — Users delete** (`users_live.ex`). This confirm uniquely sits **inside** an inline action row (`<div class="mt-2 flex items-center gap-2 flex-wrap">`, lines 325–355) as a bare `<span>` (343–354), next to the Reset-password/Delete buttons. Dropping the stacked alert mid-row would wedge it between buttons — so **delete the `<span :if={@confirming_delete == to_string(u.id)}>…</span>` (343–354)** and render the component as a **block sibling immediately after that row's closing `</div>`** (after line 355):

```heex
          <.confirm_action
            :if={@confirming_delete == to_string(u.id)}
            id={"confirm-delete-#{u.id}"}
            on_confirm="delete"
            on_cancel="cancel_delete"
            value={u.id}
            confirm_label="Delete"
          >
            <:caveat>Delete {u.email}? Requests cascade.</:caveat>
          </.confirm_action>
```

This intentionally replaces the compact inline `<span>` confirm (one of the 4 shapes UX-2 deletes) with the standard stacked alert below the action row.

- [ ] **Step 6: Run the suite; fix confirm assertions**

Run: `mix test`
Expected: green after fixes.
- `test/cinder_web/live/requests_live_test.exs` asserts confirm copy (`"Delete request"` / the caveat / `cancel_delete`) — strings preserved; update only if it asserted the old `<button>`/element shape.
- **`test/cinder_web/live/users_live_test.exs:165, 178, 192`** drive the confirm via `element("#confirm-delete-#{user.id}") |> render_click()`. After #5i that id is on the component's `<div role="alert">` (no `phx-click`), so `render_click` raises. Update each to target the inner confirm button:
  ```elixir
  lv |> element(~s|#confirm-delete-#{user.id} button[phx-click="delete"]|) |> render_click()
  ```
- The movies/series/grabs delete flows drive `phx-click` by event name + value (unchanged), so they pass; update only assertions on the old element structure.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder_web/components/core_components.ex lib/cinder_web/live test/cinder_web/components/shared_components_test.exs test/cinder_web/live
git commit -m "refactor(ux-2): unify destructive confirms behind <.confirm_action> (deny-reason stays bespoke)"
```

---

## Task 4: `<.empty_state>` component + adopt; add `search-error` variant

**Files:**
- Modify: `lib/cinder_web/components/core_components.ex` (add `empty_state/1`)
- Modify: `movies_live.ex`, `watchlist_live.ex`, `status_live.ex`, `my_requests_live.ex`, `requests_live.ex`, `calendar_live.ex`, `grabs_live.ex`, `series_live.ex`, `series_detail_live.ex`, `series_discovery_live.ex`
- Test: `test/cinder_web/components/shared_components_test.exs` (append `empty_state` cases)

**Interfaces:**
- Produces: `empty_state/1` — `attr :title` (string, req), `:message` (string, default nil), `:icon` (string, default `"hero-inbox"`), `:variant` (`"default" | "search-error"`, default `"default"`), `slot :cta`. The `search-error` variant renders an error icon + `text-error`, distinguishing a failed search from no-results.

- [ ] **Step 1: Append empty_state tests** to `test/cinder_web/components/shared_components_test.exs` (inside the module, after the `confirm_action` describe):

```elixir
  describe "empty_state/1" do
    test "default no-results state shows title, message and a neutral icon" do
      html =
        render_component(&CoreComponents.empty_state/1, %{
          title: "Your watchlist is empty",
          message: "Search above to add a movie.",
          icon: "hero-bookmark"
        })

      assert html =~ "Your watchlist is empty"
      assert html =~ "Search above to add a movie"
      assert html =~ "hero-bookmark"
      refute html =~ "text-error"
    end

    test "search-error variant is visually distinct (error icon + colour)" do
      html =
        render_component(&CoreComponents.empty_state/1, %{
          title: "Search failed",
          message: "TMDB didn't respond. Try again.",
          variant: "search-error"
        })

      assert html =~ "Search failed"
      assert html =~ "text-error"
      assert html =~ "hero-exclamation-triangle"
    end
  end
```

(The file already imports `render_component: 2` from Task 3; these cases reuse it — no import change.)

- [ ] **Step 2: Run to confirm failure**

Run: `mix test test/cinder_web/components/shared_components_test.exs`
Expected: FAIL — `empty_state/1` undefined.

- [ ] **Step 3: Add the component** to `core_components.ex`:

```elixir
  @doc """
  A centered empty / zero state: icon, title, optional message, optional `:cta` slot.
  `variant="search-error"` renders the failed-search treatment (error icon + colour),
  distinct from an ordinary no-results state.

  ## Examples

      <.empty_state title="No grabs" message="In-flight downloads will show here." icon="hero-arrow-down-tray" />
      <.empty_state variant="search-error" title="Search failed" message="TMDB didn't respond. Try again." />
  """
  attr :title, :string, required: true
  attr :message, :string, default: nil
  attr :icon, :string, default: "hero-inbox"
  attr :variant, :string, default: "default", values: ~w(default search-error)
  slot :cta

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-3 py-12 text-center">
      <.icon
        name={if @variant == "search-error", do: "hero-exclamation-triangle", else: @icon}
        class={["size-10", (@variant == "search-error" && "text-error") || "text-base-content/40"]}
      />
      <div>
        <p class="font-medium">{@title}</p>
        <p :if={@message} class="mt-1 text-sm text-base-content/60">{@message}</p>
      </div>
      <div :if={@cta != []}>{render_slot(@cta)}</div>
    </div>
    """
  end
```

- [ ] **Step 4: Run the component tests**

Run: `mix test test/cinder_web/components/shared_components_test.exs`
Expected: PASS.

- [ ] **Step 5: Adopt at the page-level empties.** Replace each bare `<p>` with `<.empty_state>`, preserving the `:if` guard:

| File:line | From | To |
|---|---|---|
| `movies_live.ex:144` | `<p :if={@movies == []} class="text-base-content/60">No movies yet.</p>` | `<.empty_state :if={@movies == []} icon="hero-film" title="No movies yet" message="Requested movies appear here." />` |
| `status_live.ex:145` | `<p :if={@movies == []} class="text-base-content/60">No movies yet.</p>` | `<.empty_state :if={@movies == []} icon="hero-film" title="No movies yet" message="Requested movies and their pipeline state appear here." />` |
| `my_requests_live.ex:39` | `<p :if={@requests == []} class="text-base-content/60">You haven't requested anything yet.</p>` | `<.empty_state :if={@requests == []} icon="hero-bookmark" title="No requests yet" message="Search the catalog to request a title." />` |
| `requests_live.ex:173` | `<p :if={@requests == []} class="opacity-60">No requests.</p>` | `<.empty_state :if={@requests == []} icon="hero-inbox-arrow-down" title="No requests" message="Pending requests will appear here for approval." />` |
| `calendar_live.ex:54–56` | the `No monitored episodes…` `<p>` | `<.empty_state :if={@rows == []} icon="hero-calendar" title="Nothing upcoming" message="Monitored episodes in the next 90 days will appear here." />` |
| `grabs_live.ex:61` | `<p :if={@grabs == []} class="text-base-content/60">No grabs.</p>` | `<.empty_state :if={@grabs == []} icon="hero-arrow-down-tray" title="No active downloads" message="In-flight grabs will appear here." />` |
| `series_live.ex:148` | `<p :if={@series == []} class="text-base-content/60">No series added yet.</p>` | `<.empty_state :if={@series == []} icon="hero-tv" title="No series added yet" message="Search above to add a show." />` |
| `series_detail_live.ex:226–228` | the `No seasons found…` `<p>` | `<.empty_state :if={@series.seasons == []} icon="hero-tv" title="No seasons found" message="TMDB returned no season data for this series." />` |
| `series_discovery_live.ex:150–152` | the `No seasons found…` `<p>` | `<.empty_state :if={@info.seasons == []} icon="hero-tv" title="No seasons found" message="TMDB returned no season data for this series." />` |

> **Leave as small inline text (out of scope — not page-level zero states):** the per-card `"No poster"` placeholders (`watchlist_live.ex:259`, `series_live.ex:225`) and the per-season `"No episodes yet."` micro-note (`series_detail_live.ex:249`). Converting a nested per-season note to a `py-12` empty state would be visually wrong.

- [ ] **Step 6: Add the `search-error` variant on the two search pages** (the no-results vs failed-search split — `@search_error` is already plumbed).

**Watchlist** (`watchlist_live.ex`, replace the no-results `<p>` at lines 201–206) →

```heex
          <.empty_state
            :if={@query != "" and @results == [] and not @search_error}
            icon="hero-magnifying-glass"
            title="No matches"
            message="No movies matched that search."
          />
          <.empty_state
            :if={@search_error}
            variant="search-error"
            title="Search failed"
            message="TMDB didn't respond. Try again."
          />
```

Also swap the watchlist-empty `<p>` (line 209) →

```heex
          <.empty_state
            :if={@watchlist == []}
            icon="hero-bookmark"
            title="Your watchlist is empty"
            message="Search above to add a movie."
          />
```

**Series** (`series_live.ex`, replace the no-results `<p>` at lines 139–144) →

```heex
          <.empty_state
            :if={@query != "" and @results == [] and not @search_error}
            icon="hero-magnifying-glass"
            title="No matches"
            message="No shows matched that search."
          />
          <.empty_state
            :if={@search_error}
            variant="search-error"
            title="Search failed"
            message="TMDB didn't respond. Try again."
          />
```

- [ ] **Step 7: Run the suite; fix empty-state assertions**

Run: `mix test`
Expected: green after fixes. Tests asserting the old copy (`"No movies yet."`, `"No matches"`, `"You haven't requested anything yet."`, `"No grabs."`, `"No series added yet."`) — update to the new titles/messages. `"No matches"` survives on both search pages. Confirm a search-error test (if any) now finds `"Search failed"` inline rather than only a flash; if none exists, add one assertion to `watchlist_live_test.exs` driving a mocked TMDB error and asserting `"Search failed"` renders.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder_web/components/core_components.ex lib/cinder_web/live test/cinder_web
git commit -m "feat(ux-2): <.empty_state> with search-error variant; replace ad-hoc empty sentences"
```

---

## Task 5: `<.spinner>` + loading feedback (health spinner, phx-disable-with)

**Files:**
- Modify: `lib/cinder_web/components/core_components.ex` (add `spinner/1`)
- Modify: `status_live.ex` (health "Checking…" → `<.spinner>`)
- Modify: `requests_live.ex`, `status_live.ex`, `watchlist_live.ex`, `series_discovery_live.ex`, `movies_live.ex`, `series_detail_live.ex`, `settings_live.ex`, `setup_live.ex`, `users_live.ex` (`phx-disable-with` on mutating submits/external-triggering clicks)

**Interfaces:**
- Produces: `spinner/1` — `attr :class` (default `"size-5"`), `attr :label` (string, default `"Loading…"`; nil = icon only). Wraps the `hero-arrow-path` + `motion-safe:animate-spin` idiom.

- [ ] **Step 1: Add the component** to `core_components.ex`:

```elixir
  @doc """
  A small inline loading spinner (respects `prefers-reduced-motion`).

      <.spinner label="Checking services…" />
  """
  attr :class, :any, default: "size-5"
  attr :label, :string, default: "Loading…"

  def spinner(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 text-base-content/60">
      <.icon name="hero-arrow-path" class={["motion-safe:animate-spin", @class]} />
      <span :if={@label} class="text-sm">{@label}</span>
    </span>
    """
  end
```

- [ ] **Step 2: Use it for the health check** — `status_live.ex:129` from:

```heex
        <p :if={@health == :loading} class="text-base-content/60">Checking…</p>
```

to:

```heex
        <div :if={@health == :loading}><.spinner label="Checking services…" /></div>
```

- [ ] **Step 3: Add `phx-disable-with`** to the mutating controls below (a `phx-submit` form's submit button or a state-mutating `phx-click`). Add `phx-disable-with="…"` to each listed button/submit; **do not** add it to local UI toggles (`start_*`, `ask_*`, `dismiss_confirm`, `cancel_delete`, `edit`, `toggle_season`, `toggle_episode`) or the search forms — those are instant client-side state flips, not server mutations. (Confirm buttons already got `phx-disable-with` via `<.confirm_action>` in Task 3.)

| File:line | Control (event) | Add |
|---|---|---|
| `requests_live.ex:114` | approve (`phx-click="approve"`) | `phx-disable-with="Approving…"` |
| `requests_live.ex:121` | deny form submit (`phx-submit="deny"`) | `phx-disable-with="Denying…"` on the submit button |
| `status_live.ex:123` | recheck health (`phx-click="recheck_health"`) | `phx-disable-with="Checking…"` |
| `status_live.ex:165` | retry (`phx-click="retry"`) | `phx-disable-with="Retrying…"` |
| `watchlist_live.ex:228` | add/request movie (`phx-click="add"`) | `phx-disable-with="Adding…"` |
| `series_discovery_live.ex:181` | request season (`phx-click="request_season"`) | `phx-disable-with="Requesting…"` |
| `movies_live.ex:182` | edit save (`phx-submit="save"`) | `phx-disable-with="Saving…"` |
| `series_detail_live.ex:183` | save series (`phx-submit="save_series"`) | `phx-disable-with="Saving…"` |
| `settings_live.ex:75` | settings save (`phx-submit="save"`) | `phx-disable-with="Saving…"` |
| `setup_live.ex:85` | validate (`phx-submit="validate"`) | `phx-disable-with="Validating…"` |
| `setup_live.ex:94` | finish (`phx-click="finish"`) | `phx-disable-with="Finishing…"` |
| `users_live.ex:241` | create user (`phx-submit="create"`) | `phx-disable-with="Creating…"` |
| `users_live.ex:273` | toggle role (`phx-click="toggle_role"`) | `phx-disable-with="…"` |
| `users_live.ex:289` | set quota (`phx-submit="set_quota"`) | `phx-disable-with="Saving…"` |
| `users_live.ex:310` | save email (`phx-submit="save_email"`) | `phx-disable-with="Saving…"` |
| `users_live.ex:360` | reset password (`phx-submit="reset_pw"`) | `phx-disable-with="Resetting…"` |

> **Cite note:** where the table points at a `<form phx-submit=…>` tag (movies:182, series_detail:183, settings:75, setup:85, users:241/289/310/360), `phx-disable-with` goes on that form's submit `<button>`, not on the `<form>` element.

<!-- ponytail: skeleton component skipped — no list shows one today; YAGNI. Add when UX-3's Discover grid wants perceived-load smoothing on the TMDB fetch. -->

- [ ] **Step 4: Run the suite**

Run: `mix test`
Expected: green. `phx-disable-with` is inert in tests (no failures expected); the health-check test asserting `"Checking…"` still passes (the new spinner keeps that label as `"Checking services…"` — if a test asserts the exact old `"Checking…"`, update it to `"Checking services…"` or assert the spinner's `animate-spin`).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/components/core_components.ex lib/cinder_web/live test
git commit -m "feat(ux-2): <.spinner> for the health check; phx-disable-with on mutating actions"
```

---

## Task 6: Convert the 3 bare-`<h1>` pages to `<.header>`

**Files:**
- Modify: `calendar_live.ex`, `series_detail_live.ex`, `series_discovery_live.ex`
- Test: `test/cinder_web/live/{calendar,series_detail,series_discovery}_live_test.exs` (add/adjust a header assertion)

**Interfaces:**
- Consumes: the existing `header/1` (slots: title via `inner_block`, `:subtitle`, `:actions`). No new component (see "Decision: `<.page>` is dropped").

- [ ] **Step 1: Calendar** — `calendar_live.ex:52` from:

```heex
      <h1 class="mb-6 text-2xl font-semibold">Upcoming</h1>
```

to:

```heex
      <.header>
        Upcoming
        <:subtitle>Monitored episodes airing in the next 90 days.</:subtitle>
      </.header>
```

- [ ] **Step 2: Series detail** — `series_detail_live.ex:214–222`. The dynamic title (title + year) becomes the header title; the monitored badge moves to `:actions` (keep the existing back-link above the header as-is). From:

```heex
        <h1 class="text-2xl font-semibold">
          {@series.title}
          <span :if={@series.year} class="font-normal text-base-content/60">
            ({@series.year})
          </span>
        </h1>
```

(plus the monitored `<span class={["badge badge-sm mt-2", @series.monitored && "badge-success"]}>…</span>` at 220–222) to:

```heex
        <.header>
          {@series.title}
          <span :if={@series.year} class="font-normal text-base-content/60">({@series.year})</span>
          <:actions>
            <span class={["badge badge-sm", @series.monitored && "badge-success"]}>
              {if @series.monitored, do: "Monitored", else: "Unmonitored"}
            </span>
          </:actions>
        </.header>
```

(This also gives the previously colourless "unmonitored" badge a visible label — icon-free is fine here; it is a monitoring flag, not a pipeline status.)

- [ ] **Step 3: Series discovery** — `series_discovery_live.ex:141–146` from:

```heex
    <h1 class="text-2xl font-semibold">
      {@info.title}
      <span :if={@info.year} class="font-normal text-base-content/60">
        ({@info.year})
      </span>
    </h1>
```

to:

```heex
    <.header>
      {@info.title}
      <span :if={@info.year} class="font-normal text-base-content/60">({@info.year})</span>
    </.header>
```

(Keep the existing `← TV series` back-link above it.)

- [ ] **Step 4: Add a header assertion** to each of the three live tests so the regression is locked. Example for `calendar_live_test.exs` (adapt the existing authenticated-admin setup already in the file):

```elixir
  test "renders the page under the shared header", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/calendar")
    assert html =~ "Upcoming"
    refute html =~ ~s(<h1 class="mb-6 text-2xl font-semibold">)
  end
```

For `series_detail` / `series_discovery`, assert the series title renders and the bare `text-2xl font-semibold` `<h1>` is gone. (Use each test's existing fixtures/route; if a file has no test yet, add a minimal one mirroring the page's current setup.)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: green. Fix any test asserting the old `<h1>` markup.

- [ ] **Step 6: Manual mobile check (no overflow at 390px)**

Run `mix phx.server`; at 390px open `/calendar`, a `/series/:id`, and a `/series/tmdb/:id`, plus one page each touched by Tasks 3–4 (e.g. `/movies` confirm, `/grabs` empty). Confirm: headers wrap cleanly, `<.confirm_action>` stacks (caveat over buttons) with ≥44px tap targets, `<.empty_state>` is centered, no horizontal scrollbar. (Visual check; satisfies the UX-2 mobile Done-when.)

- [ ] **Step 7: Commit**

```bash
git add lib/cinder_web/live test/cinder_web/live
git commit -m "feat(ux-2): convert the 3 bare-<h1> pages to the shared <.header>"
```

---

## Self-review

**1. Spec coverage (UX-2 Done-when):**
- "the 6 duplicate badge helpers … are gone (one component each)" → Task 1 builds `<.status_badge>`; Task 2 deletes `movie_status_badge`/`request_status_badge`/`status_badge_class`/`request_badge_class` + `composite_class`/`badge_class`/`badge_label`/`badge`(calendar)/`health_*`/`grab_state`-as-string. ✓
- "4 confirm variants are gone (one component each)" → Task 3 `<.confirm_action>` subsumes the alert / inline-div / bare-`<span>` shapes (8 sites); the two-step **deny-with-reason** stays bespoke **by design** (it collects input — noted, not a regression). ✓ (caveat: "4 → 1" holds for yes/no confirms; the input-collecting deny is a different control.)
- "a test renders `<.status_badge>` across movie/request/grab/health/episode states with icon+text" → Task 1 test (all 5 kinds; asserts `hero-` icon present). ✓
- "empty/search-error states are distinguishable" → Task 4 `search-error` variant + the two search pages branch on existing `@search_error`; test asserts the variant is visually distinct. ✓
- "no page hand-rolls a status color" → Task 2 deletes every status→colour map from the views **and adopts `<.status_badge kind={:health}>` for `settings_components.ex`'s Test-connection badge** (Step 7a); the monitored-flag and role badges are explicitly non-status, noted. ✓
- "shared components responsive (cards/confirm/empty stack at 390px, touch targets ≥ 44px)" → `<.confirm_action>` is `flex-col` with full `btn` (~48px); `<.empty_state>` is a centered column; Task 6 Step 6 manual 390px check. ✓
- `phx-disable-with` on mutating buttons (build list) → Task 5. ✓
- "switch the 3 bare-`<h1>` pages to `<.page>`" → satisfied via `<.header>` (council 3–0; `<.page>` dropped, decision documented). ✓

**2. Placeholder scan:** Every code step shows complete code; every adoption site is an exact from→to; the test/label fixups name the specific files. No "TBD"/"etc." ✓

**3. Type/name consistency:** `status_badge/1` attrs (`kind`/`status`/`class`) match all Task-2 call sites; `kind` values `:movie|:request|:episode|:grab|:health` match every `badge_spec/2` head + the catch-all. `confirm_action/1` attrs (`on_confirm`/`on_cancel`/`value`/`confirm_label`/`variant` + `:caveat`) match all Task-3 sites; preserved event names (`confirm_delete`/`dismiss_confirm`/`delete`/`cancel_delete`/`confirm_cancel`/`confirm_*_series`) match the existing `handle_event`s. `empty_state/1` (`title`/`message`/`icon`/`variant`/`:cta`) and `spinner/1` (`class`/`label`) are consistent across Tasks 4–5. `episode_state/2` (calendar) returns `:available|:downloading|:wanted|:upcoming` — exactly the `:episode` `badge_spec` heads; `grab_state/1` now returns `:downloading|:downloaded` — exactly the `:grab` heads. ✓

**Notes for the implementer:**
- Run `mix test` (the alias) at every task boundary, not just the per-task test — credo `--strict` will flag any orphaned private fn the moment its last caller is swapped, which is the signal you deleted the helper in the same task you removed its last use.
- The biggest assertion-churn is Task 2 (label casing) and Task 4 (empty copy). Read each failing assertion and update to the new visible text — don't weaken it to `=~ "badge"`.
- Touch only the markup and the named view helpers. No `handle_event`, context, or router change is part of UX-2.
