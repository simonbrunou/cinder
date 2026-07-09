# Harmonize Movie & TV UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make movies and TV behave identically across the admin UI — one console per title on the detail page, identical library cards, a live-only Activity board, and per-title state on Discover for both types.

**Architecture:** Pure UI relocation. Movie management handlers move from `LibraryLive` (edit) and `ActivityLive` (retry / better-match / cancel-upgrade / language) onto `MovieDetailLive`, mirroring how `SeriesDetailLive` already is the console for a series. `LibraryLive` and `ActivityLive` shed the moved actions. Discover gains a TV per-title badge. No `Catalog`, pipeline, approval-gate, or `transition` changes — every write uses an existing `Catalog` function.

**Tech Stack:** Elixir/Phoenix 1.8 LiveView (HEEx), daisyUI, ExUnit + Mox, `Phoenix.LiveViewTest`.

## Global Constraints

- `mix test` (the alias) is the gate: it runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Green or it's not done.
- All copy goes through `gettext(...)`.
- Every mutation routes through an **existing** `Catalog` function — no new writers, no new `Catalog.transition` callers.
- `/movies/:id`, `/library`, `/activity` are already in the `:admin` live_session — do not touch routing or gating.
- Follow house style: catch-all `handle_event(_event, _params, socket)`, defensive `Integer.parse` on client-controlled ids, `aria-label` on icon-only controls, one broadcast per transition (already handled by the Catalog fns).
- Reuse shared components: `media_card`, `status_badge`, `empty_state`, `confirm_action`, `language_select`, `ManualSearchComponent`. Don't add abstractions.

---

### Task 1: `MovieDetailLive` gains edit / cancel / delete (from `/library`)

Move the movie edit/cancel/delete surface onto the detail page. Copy the handlers **verbatim** from `LibraryLive`, scoping them to the single `@movie` assign instead of a list.

**Files:**
- Modify: `lib/cinder_web/live/movie_detail_live.ex`
- Test: `test/cinder_web/live/movie_detail_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.update_movie/2`, `Catalog.cancel_movie/2`, `Catalog.delete_movie/3`, `Catalog.cancellable?/1`, `Cinder.Catalog.Movie.changeset/2`.
- Produces: `/movies/:id` renders an action bar `[Edit] [Cancel|Delete]`, an inline edit form, and cancel/delete `confirm_action` dialogs. On delete → `push_navigate(to: ~p"/library")`.

- [ ] **Step 1: Write failing tests** — relocate four `LibraryLive` tests, retargeted at `~p"/movies/#{movie.id}"`. Copy the bodies from `test/cinder_web/live/library_live_test.exs` lines 42–75 and 110–150 (edits metadata; cancels an active movie; deletes an inactive movie; delete-with/without files box), changing only the `live(conn, ~p"/movies/#{m.id}")` mount and asserting the post-delete redirect goes to `/library`. The Mox `Download.ClientMock.remove` / `SabnzbdClientMock.remove` stubs from `library_live_test.exs:16-19` must be added to this suite's `setup`.

- [ ] **Step 2: Run, verify they fail**

Run: `mix test test/cinder_web/live/movie_detail_live_test.exs`
Expected: FAIL — no `edit` / `ask_cancel` / `ask_delete` handlers, no Edit button in the markup.

- [ ] **Step 3: Add the handlers.** Into `movie_detail_live.ex`, add `alias`-free reuse of `Cinder.Catalog.Movie` (already aliased). Add assigns `editing?: false, confirming: nil, form: nil, delete_files: false` in `mount/3`. Copy these handlers from `library_live.ex`, replacing `find_movie(socket, id)`/list lookups with `socket.assigns.movie` (the page is single-movie, so ignore the incoming `id` or assert it matches):
  - `edit` → `assign(editing?: true, confirming: nil, form: to_form(Movie.changeset(@movie, %{})))`
  - `cancel_edit` → `assign(editing?: false, form: nil)`
  - `save` (`%{"movie" => attrs}`) → `Catalog.update_movie(@movie, attrs)`; on ok `assign(editing?: false, form: nil)` + reload fresh + info flash; on error `assign(form: to_form(changeset))`
  - `ask_cancel` → `assign(confirming: :cancel, editing?: false)`
  - `ask_delete` → `assign(confirming: :delete, editing?: false, delete_files: false)`
  - `confirm_cancel` → `Catalog.cancel_movie(@movie, actor)`; handle `{:error, :not_cancellable}`
  - `confirm_delete` → `Catalog.delete_movie(@movie, actor, delete_files: @delete_files)` → info flash + `push_navigate(to: ~p"/library")`
  - `toggle_delete_files` → flip `delete_files`
  - `dismiss_confirm` → `assign(confirming: nil, delete_files: false)`

  Reuse `assign_fresh/2` (already in the file) after save/cancel. Keep the catch-all `handle_event(_event, _params, socket)` last.

- [ ] **Step 4: Add the markup.** Above the poster/header block in `render/1`, add the action bar + edit form + two `confirm_action` dialogs, copied from `series_detail_live.ex:377-431` and adapted (Cancel button gated by `Catalog.cancellable?(@movie)`, else Delete; edit form fields title/year via `@form`; delete dialog carries `checkbox_event="toggle_delete_files"` / `checkbox_checked={@delete_files}` / `checkbox_label={gettext("Also delete the file from disk")}`).

- [ ] **Step 5: Run, verify pass**

Run: `mix test test/cinder_web/live/movie_detail_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder_web/live/movie_detail_live.ex test/cinder_web/live/movie_detail_live_test.exs
git commit -m "feat: movie detail gains edit/cancel/delete console"
```

---

### Task 2: `MovieDetailLive` gains retry / better-match / cancel-upgrade / language (from `/activity`)

**Files:**
- Modify: `lib/cinder_web/live/movie_detail_live.ex`
- Test: `test/cinder_web/live/movie_detail_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.retry_movie/1`, `Catalog.abort_upgrade/2`, `Catalog.manual_grab_movie/2`, `Catalog.set_movie_language/2`, `CinderWeb.ManualSearchComponent` (`mode: :movie`).
- Produces: `/movies/:id` shows Retry when parked, Find a better match (toggles the inline panel) when `:available` or parked, Cancel upgrade when `:upgrading`, and a language `<select>`.

- [ ] **Step 1: Write failing tests** — relocate from `test/cinder_web/live/activity_live_test.exs`: lines 49–77 (parked→Retry re-queues; forged non-numeric id no-op; in-flight shows no Retry), 100–148 (Find a better match opens the panel and grab → `:upgrading`; Cancel upgrade reverts to `:available`), retargeted at `~p"/movies/#{movie.id}"`. Add a test that changing the language `<select>` calls through (asserts `set_movie_language` via reloading and checking `preferred_language`).

- [ ] **Step 2: Run, verify fail**

Run: `mix test test/cinder_web/live/movie_detail_live_test.exs`
Expected: FAIL — no `retry` / `manual_search` / `cancel_upgrade` / `set_movie_language` handlers.

- [ ] **Step 3: Add handlers.** Add assign `searching?: false` in `mount/3`. Copy from `activity_live.ex`, scoping to `@movie`:
  - `retry` → `Catalog.retry_movie(@movie)`; on `{:error,_}` flash "Couldn't retry: that movie has already moved on."
  - `manual_search` → toggle `searching?`
  - `cancel_upgrade` → `Catalog.abort_upgrade(@movie, current_scope.user)`; guarded-miss flash
  - `set_movie_language` (`%{"preferred_language" => lang}` when in `~w(original french any)`) → `Catalog.set_movie_language(@movie, lang)` + `assign_fresh`
  - `handle_info({:manual_grab, :movie, movie, release}, socket)` → `Catalog.manual_grab_movie(@movie, release)`; reuse the `grab_flash/1` helper (copy it from `activity_live.ex:65-70`); `assign(searching?: false)` + flash. Keep the existing `{:movie_updated}` / `{:movie_deleted}` handlers.

- [ ] **Step 4: Add markup.** In the poster/header block, add `<.status_badge>` already present; add a language `<form phx-change="set_movie_language">` with `<.language_select value={@movie.preferred_language} />` (mirror `series_detail_live.ex:473-475`). Below the metadata, add a pipeline-actions row: Retry (`parked?`), Find a better match (`@movie.status == :available or parked?`), Cancel upgrade (`:upgrading`), and the inline `<.live_component module={ManualSearchComponent} id={"ms-movie-#{@movie.id}"} mode={:movie} target={@movie} />` when `@searching?`. Add a private `parked?/1` (`status in [:no_match, :search_failed, :import_failed]`).

- [ ] **Step 5: Run, verify pass**

Run: `mix test test/cinder_web/live/movie_detail_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder_web/live/movie_detail_live.ex test/cinder_web/live/movie_detail_live_test.exs
git commit -m "feat: movie detail gains retry/better-match/cancel-upgrade/language"
```

---

### Task 3: Slim `/library` — drop movie edit, make series cards match

**Files:**
- Modify: `lib/cinder_web/live/library_live.ex`
- Test: `test/cinder_web/live/library_live_test.exs`

**Interfaces:**
- Consumes: `status_badge` (`kind: :monitored`).
- Produces: both movie and series cards render `poster(→detail) + badge + [Cancel] [Delete]`. No inline edit on `/library`.

- [ ] **Step 1: Update tests.** In `library_live_test.exs`: change "lists movies with edit/cancel/delete affordances" (line 35) to assert Cancel/Delete but **not** an "Edit" button; delete "edits a movie's metadata" (line 42, moved to Task 1). Update "lists series with a drill-down link…" (line 77) to assert a `status_badge` (Monitored/Unmonitored) rather than the "Configure monitoring" text.

- [ ] **Step 2: Run, verify fail**

Run: `mix test test/cinder_web/live/library_live_test.exs`
Expected: FAIL on the changed assertions.

- [ ] **Step 3: Edit `library_live.ex`.** Remove handlers `edit`, `cancel_edit`, `save` and the `editing`/`form` assigns from `mount/3`. In the movie card: keep the `.link`/`media_card`/`status_badge`/Cancel/Delete/confirm_action; delete the inline `<.form>` edit block (lines ~274-295) and the `@editing == m.id` branch of the `col-span` class. In the series card: replace the `<span>Configure monitoring →</span>` inner block (lines ~353-356) with `<.status_badge kind={:monitored} status={s.monitored} class="h-auto break-words text-center" />`.

- [ ] **Step 4: Run, verify pass**

Run: `mix test test/cinder_web/live/library_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/live/library_live.ex test/cinder_web/live/library_live_test.exs
git commit -m "refactor: /library sheds movie edit; series cards get a status badge"
```

---

### Task 4: Slim `/activity` — movie rows become status + link

**Files:**
- Modify: `lib/cinder_web/live/activity_live.ex`
- Test: `test/cinder_web/live/activity_live_test.exs`

**Interfaces:**
- Produces: movie rows show `title + status_badge + link(→ /movies/:id)`; no Retry / better-match / cancel-upgrade / language / manual-search on `/activity`. Grabs section unchanged.

- [ ] **Step 1: Update tests.** In `activity_live_test.exs`: keep "renders the movie pipeline and live-updates on transition" (line 38) but assert a link to `~p"/movies/#{m.id}"`. Delete the tests moved to Task 2 (Retry re-queues, forged-id no-op, in-flight-no-Retry, Find a better match, Cancel upgrade) — lines 49–77 and 100–148. Keep the grabs tests and the redirect tests.

- [ ] **Step 2: Run, verify fail**

Run: `mix test test/cinder_web/live/activity_live_test.exs`
Expected: FAIL (the retained pipeline test now expects a link that isn't there yet).

- [ ] **Step 3: Edit `activity_live.ex`.** Remove handlers `retry`, `set_movie_language`, `manual_search`, `cancel_upgrade`, and `handle_info({:manual_grab, :movie, …})` + the `grab_flash/1` helper + the `searching_movie_id` assign + `@parked`/`parked?` if now unused. In the movie `<li>`, replace the action buttons + language form + manual-search panel with `title` (as a `.link navigate={~p"/movies/#{m.id}"}`) + `<.status_badge kind={:movie} status={m.status} />`. Keep the grabs section and its `ask_delete`/`confirm_delete`/`dismiss_confirm` handlers verbatim. Update the moduledoc to drop the Retry mention.

- [ ] **Step 4: Run, verify pass**

Run: `mix test test/cinder_web/live/activity_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/live/activity_live.ex test/cinder_web/live/activity_live_test.exs
git commit -m "refactor: /activity movie rows become a read-only status board"
```

---

### Task 5: Discover TV cards get a per-title state badge

**Files:**
- Modify: `lib/cinder_web/live/discover_live.ex`
- Test: `test/cinder_web/live/discover_live_test.exs`

**Interfaces:**
- Consumes: `Cinder.Requests.list_for_user/1` (season rows), `Catalog.available_season_keys/0`, `latest_status_by/2`.
- Produces: a TV result card shows a `status_badge kind={:request}` (Available > Pending/Approved > Denied) when the user has any season request/available season for that `tmdb_id`; otherwise the existing "View seasons" button.

- [ ] **Step 1: Write failing test.** In `discover_live_test.exs`, add: a user with a pending season request for a series `tmdb_id`, then a TV search returning that series, renders a "Pending" badge on its card. (Model the season-request setup on `series_discovery_live_test.exs`.)

- [ ] **Step 2: Run, verify fail**

Run: `mix test test/cinder_web/live/discover_live_test.exs`
Expected: FAIL — no badge on the TV card.

- [ ] **Step 3: Implement.** In `assign_request_state/1`, also build `series_state` — a `%{tmdb_id => status}` map: from `Requests.list_for_user(user)` filter `target_type == "season"`, reduce with `latest_status_by(& &1.target_id)`; and a `MapSet` of `available_season_keys()` `tmdb_id`s. Add `tv_title_state(tmdb_id, series_request_status, available_tmdb_ids)` mirroring `title_state/3` precedence (available > pending > approved > denied > none). In `render/1`, for `r.type == :tv`, render `<.status_badge :if={state != :none} kind={:request} status={state} />` above the "View seasons" button (keep the button — a show can always be re-browsed for more seasons).

- [ ] **Step 4: Run, verify pass**

Run: `mix test test/cinder_web/live/discover_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/live/discover_live.ex test/cinder_web/live/discover_live_test.exs
git commit -m "feat: Discover TV cards show per-title request state"
```

---

### Task 6: Align detail-page poster size + full-suite gate

**Files:**
- Modify: `lib/cinder_web/live/series_detail_live.ex`, `lib/cinder_web/live/series_discovery_live.ex`

- [ ] **Step 1: Align posters.** Change the series detail hero poster from `w-24` to `w-40` (`series_detail_live.ex:440`) and the series discovery poster likewise (`series_discovery_live.ex:205`) so both detail heroes match the movie detail (`w-40`). Adjust the surrounding `gap`/flex only if the larger poster crowds the header.

- [ ] **Step 2: Run the full gate**

Run: `mix test`
Expected: PASS (compile-warnings-as-errors, format, credo --strict, suite all green). Fix any format/credo nits (`mix format`).

- [ ] **Step 3: Commit**

```bash
git add lib/cinder_web/live/series_detail_live.ex lib/cinder_web/live/series_discovery_live.ex
git commit -m "style: align detail-page poster sizes across movies and TV"
```

---

## Self-review notes

- **Spec coverage:** movie console (Tasks 1–2), library parity (Task 3), activity board (Task 4), Discover TV badge (Task 5), poster alignment (Task 6). Episode file-info chip and `MyRequestsLive` intentionally untouched (spec: out of scope).
- **Ordering:** console gains actions (1–2) **before** library/activity lose them (3–4) — no window where a movie action is unreachable.
- **No new writers:** every handler calls an existing `Catalog` fn; approval-gate / `transition` invariants untouched.
