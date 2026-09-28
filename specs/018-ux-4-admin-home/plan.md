# UX-4 — Admin home: Dashboard + Activity + Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the reimagined admin information architecture — a role-aware `/dashboard` landing, a consolidated `/activity` (movie pipeline + TV grabs), and a unified `/library` (movies + added series) — restyled into the UX-1 shell with the UX-2 component layer, fully usable at 390px, **without touching the approval gate, role-gating, or pipeline logic.**

**Architecture:** Three new admin LiveViews drop into the existing `:admin` `live_session` (which already carries `:require_authenticated` + `:require_admin` + `:require_setup` + `:current_path`), so **no `on_mount` guard changes**. `ActivityLive` merges `StatusLive`'s movie-pipeline + `GrabsLive`'s grabs (health moves to the Dashboard); `LibraryLive` merges `MoviesLive` + the Discover "Added series" block and drills into the unchanged `SeriesDetailLive` at `/series/:id`; `DashboardLive` reads existing context functions only (stat counts derived in-memory, the pending queue via `Cinder.Requests`, service health via the `StatusLive` `start_async` pattern, a compact recent-activity slice). Old routes (`/status`, `/grabs`, `/movies`) become `RedirectController` 302s; the sidebar nav is regrouped; `signed_in_path/1` and the sidebar wordmark become role-aware. **No new context writers; at most zero new read helpers** (everything composes from existing reads).

**Tech Stack:** Elixir / Phoenix 1.8 LiveView (HEEx), Tailwind v4 + daisyUI, Ecto + `ecto_sqlite3`, ExUnit + Mox. No new dependencies.

## Global Constraints

Every task's requirements implicitly include this section.

- **`mix test` (the alias: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite) is green at every task boundary.** Commit once per task with a `feat(ux-4): …` (or `refactor(ux-4):` / `test(ux-4):`) message.
- **Do not touch the approval gate, role-gating, or pipeline logic.** `Cinder.Requests.create_request/2` stays the only user-action path that creates a `:requested` movie; the poller pickup is unchanged; **no route's `on_mount` guard changes** — only its grouping/label/visuals/redirect. This is presentation + IA only.
- **Stay in-stack:** Tailwind v4 + daisyUI + HEEx. No React, no CSS framework swap, no new deps.
- **Mobile is built in, not bolted on.** Every new/changed surface is usable at **390px** with **no horizontal overflow** and **touch targets ≥ 44px**. Record lists are **cards** (the default record container); tables that would overflow are converted to stacked cards.
- **No new external-service env vars** (CLAUDE.md config rule).
- **Reuse the UX-2 component layer** (`<.status_badge>`, `<.confirm_action>`, `<.empty_state>`, `<.spinner>`, `<.media_card>`, `<.header>`) and the UX-1 shell wrapper `<Layouts.app flash current_scope current_path>`. There is **no `<.page>` component** — the page wrapper is `<Layouts.app>`, invoked at the top of every LiveView `render/1`.
- After the final code change, run `graphify update .` to keep the knowledge graph current (AST-only, no API cost).

---

## File Structure

**Create:**
- `lib/cinder_web/live/activity_live.ex` — `CinderWeb.ActivityLive` at `/activity`. Movie pipeline (cards, Retry on parked) + TV grabs (cards, delete-with-confirm). Subscribes `"movies"` + `"series"`.
- `lib/cinder_web/live/library_live.ex` — `CinderWeb.LibraryLive` at `/library`. Movies (cards, inline edit / cancel / delete) + Series (poster grid, cancel / delete, drill to `/series/:id`). Subscribes `"movies"` + `"series"`.
- `lib/cinder_web/live/dashboard_live.ex` — `CinderWeb.DashboardLive` at `/dashboard`. Stat row + inline pending-approval queue + service health + recent-activity slice. Subscribes `"movies"` + `"series"` + `"requests"`; health via `start_async`.
- `test/cinder_web/live/activity_live_test.exs`, `test/cinder_web/live/library_live_test.exs`, `test/cinder_web/live/dashboard_live_test.exs`.

**Modify:**
- `lib/cinder_web/router.ex:64-91` — in the `:admin` `live_session`: remove `live "/status"`, `live "/grabs"`, `live "/movies"`; add `live "/activity", ActivityLive`, `live "/library", LibraryLive`, `live "/dashboard", DashboardLive`. Outside the `live_session` (alongside the existing `get "/series"`): add `get "/status"`, `get "/grabs"` → `:to_activity`; `get "/movies"` → `:to_library`.
- `lib/cinder_web/controllers/redirect_controller.ex` — add `to_activity/2` (→ `~p"/activity"`) and `to_library/2` (→ `~p"/library"`).
- `lib/cinder_web/user_auth.ex:308-309` — make `signed_in_path/1` role-aware (admin → `/dashboard`, else `/`), reusing the existing private `admin?/1`.
- `lib/cinder_web/components/layouts.ex:66` — make the sidebar wordmark home link role-aware (admin → `/dashboard`). `:87-119` — regroup the Admin nav (Dashboard / Requests / Library / Activity / Calendar / Settings / Users; the "Status" item is gone).
- `lib/cinder_web/live/discover_live.ex` — strip the admin "Added series" block (moduledoc lines 6/9, the `admin?` var + `subscribe_series` + `confirming`/`admin?`/`series` assigns at 18/24/29/31, the five series `handle_event`s at 60-87, the two series `handle_info`s at 111-115, `run_series_op/5` at 151-169, the `<.series_admin_section …>` call at 289, and the `series_admin_section/1` component + its attrs at 313-379). The movie search/add/watchlist half is untouched.
- `lib/cinder_web/live/series_detail_live.ex` — repoint the "← Discover" back link (line 167) to `~p"/library"` ("← Library") and the four post-delete/vanish `push_navigate(to: ~p"/")` redirects (≈ lines 28, 115, 135, 147) to `~p"/library"`.
- `lib/cinder_web/live/calendar_live.ex:63-82` — replace the 5-column `<table>` with a wrapping card list (no horizontal overflow at 390px).
- `test/cinder_web/live/app_shell_test.exs` — update nav assertions for the new Admin group; assert role-aware visibility.
- `test/cinder_web/live/calendar_live_test.exs` — update any `<table>`/`<th>`-referencing assertions to the new card list.
- `test/cinder_web/live/discover_live_test.exs` — remove/adjust any "Added series" assertions (moved to Library).

**Delete:**
- `lib/cinder_web/live/status_live.ex` + `test/cinder_web/live/status_live_test.exs` (content → ActivityLive, health → DashboardLive).
- `lib/cinder_web/live/grabs_live.ex` + `test/cinder_web/live/grabs_live_test.exs` (content → ActivityLive).
- `lib/cinder_web/live/movies_live.ex` + `test/cinder_web/live/movies_live_test.exs` (content → LibraryLive).

**Keep unchanged (reused as-is):**
- `lib/cinder/catalog.ex`, `lib/cinder/requests.ex`, `lib/cinder/health.ex` — read/mutate functions reused; **no signature changes, no new writers**.
- `lib/cinder_web/live/series_detail_live.ex` route (`/series/:id`) and monitoring logic — only the back-link/redirect targets change.
- `lib/cinder_web/live/requests_live.ex`, `calendar_live.ex` logic, `my_requests_live.ex`, `settings_live.ex`, `users_live.ex`, `setup_live.ex` — kept.
- `lib/cinder_web/components/core_components.ex` — reused; no new component.

---

## Task 1: ActivityLive — merge `/status` + `/grabs` into `/activity`

Merges the movie-pipeline table (with Retry) and the grabs list (with delete) into one admin Activity feed, **as cards** (no table → mobile-clean). The service-health panel does **not** come here — it moves to the Dashboard (Task 3). Old `/status` and `/grabs` become redirects.

**Files:**
- Create: `lib/cinder_web/live/activity_live.ex`
- Create: `test/cinder_web/live/activity_live_test.exs`
- Modify: `lib/cinder_web/router.ex`, `lib/cinder_web/controllers/redirect_controller.ex`
- Delete: `lib/cinder_web/live/status_live.ex`, `lib/cinder_web/live/grabs_live.ex`, `test/cinder_web/live/status_live_test.exs`, `test/cinder_web/live/grabs_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.subscribe/0`, `Catalog.subscribe_series/0`, `Catalog.list_watchlist/0 :: [%Movie{}]`, `Catalog.list_grabs/0 :: [%Grab{episodes: [%Episode{season: %Season{series: %Series{}}}]}]`, `Catalog.get_movie_by_id/1 :: %Movie{} | nil`, `Catalog.retry_movie/1 :: {:ok, %Movie{}} | {:error, :not_retryable}`, `Catalog.delete_grab/1`.
- Produces: route `live "/activity", ActivityLive`; `RedirectController.to_activity/2`. PubSub messages handled: `{:movie_updated, m}`, `{:movie_created, m}`, `{:movie_deleted, id}`, `{:series_updated, id}`, `{:series_deleted, id}`. Events: `"retry"`, `"ask_delete"`, `"dismiss_confirm"`, `"confirm_delete"`.

- [ ] **Step 1: Write the failing test**

Create `test/cinder_web/live/activity_live_test.exs`:

```elixir
defmodule CinderWeb.ActivityLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Catalog
  alias Cinder.Repo

  setup :register_and_log_in_admin

  defp movie!(attrs) do
    {:ok, movie} = Catalog.add_to_watchlist(Enum.into(attrs, %{tmdb_id: System.unique_integer([:positive]), title: "Untitled"}))
    movie
  end

  defp grab!() do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: System.unique_integer([:positive]), title: "Severance", monitor_strategy: :all})
    season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})
    episode = Repo.insert!(%Cinder.Catalog.Episode{season_id: season.id, episode_number: 1, monitored: true})
    {:ok, grab} = Catalog.create_grab("abc123", :torrent, [episode.id])
    grab
  end

  test "renders the movie pipeline and live-updates on transition", %{conn: conn} do
    movie = movie!(%{title: "Dune", year: 2021})

    {:ok, lv, html} = live(conn, ~p"/activity")
    assert html =~ "Dune"
    assert html =~ "Movie pipeline"

    {:ok, _} = Catalog.transition(movie, %{status: :downloading})
    assert render(lv) =~ "badge-info"
  end

  test "a parked movie shows Retry that re-queues it to :requested", %{conn: conn} do
    movie = movie!(%{title: "Tenet"})
    {:ok, _} = Catalog.transition(movie, %{status: :no_match})

    {:ok, lv, _html} = live(conn, ~p"/activity")
    lv |> element("#movie-#{movie.id} button", "Retry") |> render_click()

    assert Catalog.get_movie_by_id(movie.id).status == :requested
  end

  test "an in-flight movie shows no Retry button", %{conn: conn} do
    movie = movie!(%{title: "Sicario"})
    {:ok, _} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

    {:ok, lv, _html} = live(conn, ~p"/activity")
    refute has_element?(lv, "#movie-#{movie.id} button", "Retry")
  end

  test "renders grabs and deletes one through the confirm step", %{conn: conn} do
    grab = grab!()

    {:ok, lv, html} = live(conn, ~p"/activity")
    assert html =~ "Severance"
    assert html =~ "Downloads"

    lv |> element("#grab-#{grab.id} button", "Delete") |> render_click()
    lv |> element("#confirm-delete-grab-#{grab.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#grab-#{grab.id}")
    assert Catalog.list_grabs() == []
  end

  test "non-admins are redirected away from /activity", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/activity")
  end

  test "/status and /grabs redirect to /activity", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/status")) == "/activity"
    assert redirected_to(get(conn, ~p"/grabs")) == "/activity"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder_web/live/activity_live_test.exs`
Expected: FAIL — `ActivityLive` is undefined / route `/activity` has no matching route.

- [ ] **Step 3: Create the ActivityLive module**

Create `lib/cinder_web/live/activity_live.ex`:

```elixir
defmodule CinderWeb.ActivityLive do
  @moduledoc """
  Admin live activity at `/activity`: the movie pipeline (Retry on parked movies) and
  in-flight TV downloads (grabs, delete-with-confirm), newest first — as cards, so it
  reflows cleanly on a phone. Merges the old `/status` and `/grabs` pages. Read-mostly:
  Retry routes through the server-guarded `Catalog.retry_movie/1` and delete through
  `Catalog.delete_grab/1`; no pipeline change. Live via the `movies` + `series` topics.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @parked [:no_match, :search_failed, :import_failed]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
    end

    {:ok,
     assign(socket,
       movies: Catalog.list_watchlist(),
       grabs: Catalog.list_grabs(),
       confirming: nil
     )}
  end

  @impl true
  def handle_info({:movie_updated, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}

  def handle_info({:movie_created, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket),
    do: {:noreply, assign(socket, grabs: Catalog.list_grabs())}

  def handle_info({:series_deleted, _id}, socket),
    do: {:noreply, assign(socket, grabs: Catalog.list_grabs())}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry", %{"id" => id}, socket) do
    case Catalog.get_movie_by_id(id) do
      nil -> :ok
      movie -> Catalog.retry_movie(movie)
    end

    {:noreply, socket}
  end

  def handle_event("ask_delete", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: id)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    grab = Enum.find(socket.assigns.grabs, &(to_string(&1.id) == id))
    if grab, do: Catalog.delete_grab(grab)

    {:noreply,
     socket
     |> assign(confirming: nil, grabs: Catalog.list_grabs())
     |> put_flash(:info, "Grab deleted.")}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp upsert(movies, movie) do
    if Enum.any?(movies, &(&1.id == movie.id)),
      do: Enum.map(movies, &if(&1.id == movie.id, do: movie, else: &1)),
      else: [movie | movies]
  end

  defp parked?(status), do: status in @parked
  defp series_title(%{episodes: [ep | _]}), do: ep.season.series.title
  defp series_title(_), do: "—"
  defp grab_state(%{content_path: nil}), do: :downloading
  defp grab_state(_), do: :downloaded

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Activity<:subtitle>Live pipeline and in-flight downloads.</:subtitle>
      </.header>

      <section class="mt-2">
        <h2 class="pb-3 text-lg font-semibold">Movie pipeline</h2>
        <.empty_state
          :if={@movies == []}
          icon="hero-film"
          title="No movies yet"
          message="Requested movies move through here."
        />
        <ul :if={@movies != []} id="activity-movies" class="space-y-2">
          <li
            :for={m <- @movies}
            id={"movie-#{m.id}"}
            class="card bg-base-200 p-3 flex flex-row flex-wrap items-center gap-3"
          >
            <span class="min-w-0 flex-1 truncate">
              {m.title}<span :if={m.year} class="text-base-content/50"> ({m.year})</span>
            </span>
            <.status_badge kind={:movie} status={m.status} />
            <button
              :if={parked?(m.status)}
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="retry"
              phx-value-id={m.id}
              phx-disable-with="Retrying…"
            >
              Retry
            </button>
          </li>
        </ul>
      </section>

      <section class="mt-10">
        <h2 class="pb-3 text-lg font-semibold">Downloads</h2>
        <.empty_state
          :if={@grabs == []}
          icon="hero-arrow-down-tray"
          title="No active downloads"
          message="In-flight TV downloads show here."
        />
        <ul :if={@grabs != []} id="activity-grabs" class="space-y-3">
          <li :for={g <- @grabs} id={"grab-#{g.id}"} class="card bg-base-200 p-4">
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-semibold">{series_title(g)}</span>
              <.status_badge kind={:grab} status={grab_state(g)} />
              <span class="text-xs text-base-content/50">{g.download_protocol}</span>
              <span class="text-xs text-base-content/50 truncate">{g.download_id}</span>
              <button
                type="button"
                class="btn btn-xs btn-error ml-auto"
                phx-click="ask_delete"
                phx-value-id={g.id}
                phx-disable-with="Deleting…"
              >
                Delete
              </button>
            </div>
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
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Wire the route + redirects, delete the old pages**

In `lib/cinder_web/controllers/redirect_controller.ex`, add below `to_root/2`:

```elixir
  # /status + /grabs folded into Activity (UX-4); keep bookmarks working.
  def to_activity(conn, _params), do: redirect(conn, to: ~p"/activity")

  # /movies folded into Library (UX-4).
  def to_library(conn, _params), do: redirect(conn, to: ~p"/library")
```

In `lib/cinder_web/router.ex`, inside the `:admin` `live_session` (currently lines 71/75/76) **delete** `live "/status", StatusLive`, `live "/movies", MoviesLive`, `live "/grabs", GrabsLive` and **add**:

```elixir
      live "/activity", ActivityLive
```

(Leave `live "/series/:id", SeriesDetailLive` and the others in place. `live "/library"` and `live "/dashboard"` are added in Tasks 2/3.)

Below the `live_session` blocks, alongside the existing `get "/series", RedirectController, :to_root`:

```elixir
    # /status, /grabs, /movies folded into Activity/Library (UX-4); redirect old bookmarks.
    get "/status", RedirectController, :to_activity
    get "/grabs", RedirectController, :to_activity
    get "/movies", RedirectController, :to_library
```

Delete the four old files:

```bash
git rm lib/cinder_web/live/status_live.ex lib/cinder_web/live/grabs_live.ex \
       test/cinder_web/live/status_live_test.exs test/cinder_web/live/grabs_live_test.exs
```

> Note: `MoviesLive` is still routed until Task 2. To keep this task green on its own, the `/movies` `get` redirect and the deletion of `movies_live.ex` happen in **Task 2** — in Task 1 only add the `/status` + `/grabs` redirects and delete `status_live.ex` + `grabs_live.ex`. Remove the `live "/movies"` line in Task 2, not here. (The `to_library/2` action is harmless to add now since `/library` is referenced by `~p` only from Task 2 onward — add `to_library/2` in Task 2 to avoid an unused-route `~p"/library"` verification error. **In Task 1, add only `to_activity/2` and the two `/status` + `/grabs` redirects.**)

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/cinder_web/live/activity_live_test.exs`
Expected: PASS (all six tests).

- [ ] **Step 6: Run the full suite + commit**

Run: `mix test`
Expected: PASS (the deleted `status_live_test`/`grabs_live_test` are gone; everything else green).

```bash
git add -A
git commit -m "feat(ux-4): ActivityLive — unified /activity (pipeline + grabs); redirect /status + /grabs"
```

---

## Task 2: LibraryLive — merge `/movies` + the Discover "Added series" block into `/library`

One admin managed-catalog page: movies (inline edit / cancel / delete) and added series (cancel / delete, drill into `/series/:id`). Strips the "Added series" block out of `DiscoverLive`, deletes `MoviesLive`, repoints `SeriesDetailLive`'s back-link to `/library`.

**Files:**
- Create: `lib/cinder_web/live/library_live.ex`
- Create: `test/cinder_web/live/library_live_test.exs`
- Modify: `lib/cinder_web/router.ex`, `lib/cinder_web/controllers/redirect_controller.ex`, `lib/cinder_web/live/discover_live.ex`, `lib/cinder_web/live/series_detail_live.ex`, `test/cinder_web/live/discover_live_test.exs`
- Delete: `lib/cinder_web/live/movies_live.ex`, `test/cinder_web/live/movies_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.subscribe/0`, `Catalog.subscribe_series/0`, `Catalog.list_watchlist/0`, `Catalog.list_series/0 :: [%Series{}]`, `Catalog.Movie.changeset/2`, `Catalog.update_movie/2 :: {:ok, %Movie{}} | {:error, changeset}`, `Catalog.cancellable?/1 :: boolean`, `Catalog.cancel_movie/2 :: {:ok, _} | {:error, :not_cancellable}`, `Catalog.delete_movie/2`, `Catalog.cancel_series/2`, `Catalog.delete_series/2`.
- Produces: route `live "/library", LibraryLive`; `RedirectController.to_library/2`. Disambiguated `confirming` shape `{:movie | :series, :cancel | :delete, id_string}`. Events: `"edit"`, `"cancel_edit"`, `"save"`, `"ask_cancel_movie"`, `"ask_delete_movie"`, `"confirm_cancel_movie"`, `"confirm_delete_movie"`, `"ask_cancel_series"`, `"ask_delete_series"`, `"confirm_cancel_series"`, `"confirm_delete_series"`, `"dismiss_confirm"`.

- [ ] **Step 1: Write the failing test**

Create `test/cinder_web/live/library_live_test.exs`:

```elixir
defmodule CinderWeb.LibraryLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Repo

  setup :register_and_log_in_admin
  setup :set_mox_global

  setup do
    # cancel_movie may remove an active download via the client; default to a no-op.
    stub(Cinder.Download.ClientMock, :remove, fn _ -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :remove, fn _ -> :ok end)
    :ok
  end

  defp movie!(attrs) do
    {:ok, movie} = Catalog.add_to_watchlist(Enum.into(attrs, %{tmdb_id: System.unique_integer([:positive]), title: "Untitled"}))
    movie
  end

  defp series!(attrs \\ %{}) do
    Repo.insert!(struct(%Cinder.Catalog.Series{tmdb_id: System.unique_integer([:positive]), title: "Severance", monitor_strategy: :future}, attrs))
  end

  test "lists movies with edit/cancel/delete affordances", %{conn: conn} do
    movie!(%{title: "Dune", year: 2021})
    {:ok, _lv, html} = live(conn, ~p"/library")
    assert html =~ "Dune"
    assert html =~ "Movies"
  end

  test "edits a movie's metadata", %{conn: conn} do
    movie = movie!(%{title: "Dune", year: 2021})
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#movie-#{movie.id} button", "Edit") |> render_click()

    lv
    |> form("#movie-form-#{movie.id}", movie: %{title: "Dune: Part Two", year: 2024})
    |> render_submit()

    assert Catalog.get_movie_by_id(movie.id).title == "Dune: Part Two"
  end

  test "cancels an active movie through the confirm step", %{conn: conn} do
    movie = movie!(%{title: "Tenet"})
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#movie-#{movie.id} button", "Cancel") |> render_click()
    lv |> element("#confirm-cancel-movie-#{movie.id} button", "Cancel movie") |> render_click()

    assert Catalog.get_movie_by_id(movie.id).status == :cancelled
  end

  test "deletes an inactive movie through the confirm step", %{conn: conn} do
    movie = movie!(%{title: "Old"})
    {:ok, _} = Catalog.transition(movie, %{status: :cancelled})
    {:ok, lv, _html} = live(conn, ~p"/library")

    lv |> element("#movie-#{movie.id} button", "Delete") |> render_click()
    lv |> element("#confirm-delete-movie-#{movie.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#movie-#{movie.id}")
    assert Catalog.get_movie_by_id(movie.id) == nil
  end

  test "lists series with a drill-down link and deletes one", %{conn: conn} do
    s = series!(%{title: "Severance"})
    {:ok, lv, html} = live(conn, ~p"/library")
    assert html =~ "Severance"
    assert has_element?(lv, ~s|#series-row-#{s.id} a[href="/series/#{s.id}"]|)

    lv |> element("#series-row-#{s.id} button", "Delete") |> render_click()
    lv |> element("#confirm-delete-series-#{s.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#series-row-#{s.id}")
    assert Catalog.list_series() == []
  end

  test "non-admins are redirected away from /library", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/library")
  end

  test "/movies redirects to /library", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/movies")) == "/library"
  end

  test "Discover no longer renders the Added series block", %{conn: conn} do
    series!(%{title: "Severance"})
    {:ok, _lv, html} = live(conn, ~p"/")
    refute html =~ "Added series"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder_web/live/library_live_test.exs`
Expected: FAIL — `LibraryLive` undefined / `/library` no route.

- [ ] **Step 3: Create the LibraryLive module**

Create `lib/cinder_web/live/library_live.ex`:

```elixir
defmodule CinderWeb.LibraryLive do
  @moduledoc """
  Admin managed-catalog at `/library`: every watchlisted movie (inline edit / cancel /
  delete) and every added series (cancel / delete; drill into `/series/:id` for per-episode
  monitoring). Merges the old `/movies` page and the Discover "Added series" block.
  Admin-gated by the `:admin` live_session; every mutation routes through the existing
  `Catalog` functions — no pipeline or gate change. Live via the `movies` + `series` topics.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
    end

    {:ok,
     assign(socket,
       movies: Catalog.list_watchlist(),
       series: Catalog.list_series(),
       editing: nil,
       confirming: nil,
       form: nil
     )}
  end

  # --- movies ---
  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case find_movie(socket, id) do
      nil -> {:noreply, socket}
      movie -> {:noreply, assign(socket, editing: movie.id, confirming: nil, form: to_form(Movie.changeset(movie, %{})))}
    end
  end

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, editing: nil, form: nil)}

  def handle_event("save", %{"id" => id, "movie" => attrs}, socket) do
    case find_movie(socket, id) do
      nil ->
        {:noreply, socket}

      movie ->
        case Catalog.update_movie(movie, attrs) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(editing: nil, form: nil, movies: Catalog.list_watchlist())
             |> put_flash(:info, "Movie updated.")}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  def handle_event("ask_cancel_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :cancel, id}, editing: nil)}

  def handle_event("ask_delete_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :delete, id}, editing: nil)}

  def handle_event("confirm_cancel_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <- Catalog.cancel_movie(movie, actor) do
      {:noreply,
       socket
       |> assign(confirming: nil, movies: Catalog.list_watchlist())
       |> put_flash(:info, "Movie cancelled.")}
    else
      {:error, :not_cancellable} ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "That movie can't be cancelled.")}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't cancel that movie.")}
    end
  end

  def handle_event("confirm_delete_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <- Catalog.delete_movie(movie, actor) do
      {:noreply, socket |> assign(confirming: nil) |> put_flash(:info, "Movie deleted.")}
    else
      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete that movie.")}
    end
  end

  # --- series ---
  def handle_event("ask_cancel_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :cancel, id})}

  def handle_event("ask_delete_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :delete, id})}

  def handle_event("confirm_cancel_series", %{"id" => id}, socket),
    do: run_series_op(socket, id, &Catalog.cancel_series/2, "Series cancelled.", "Couldn't cancel the series.")

  def handle_event("confirm_delete_series", %{"id" => id}, socket),
    do: run_series_op(socket, id, &Catalog.delete_series/2, "Series deleted.", "Couldn't delete the series.")

  # --- shared ---
  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}

  def handle_info({:movie_created, movie}, socket),
    do: {:noreply, assign(socket, movies: upsert(socket.assigns.movies, movie))}

  def handle_info({:movie_deleted, id}, socket),
    do: {:noreply, assign(socket, movies: Enum.reject(socket.assigns.movies, &(&1.id == id)))}

  def handle_info({:series_updated, _id}, socket),
    do: {:noreply, assign(socket, series: Catalog.list_series())}

  def handle_info({:series_deleted, _id}, socket),
    do: {:noreply, assign(socket, series: Catalog.list_series())}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp find_movie(socket, id),
    do: Enum.find(socket.assigns.movies, &(to_string(&1.id) == to_string(id)))

  defp upsert(movies, movie) do
    if Enum.any?(movies, &(&1.id == movie.id)),
      do: Enum.map(movies, &if(&1.id == movie.id, do: movie, else: &1)),
      else: [movie | movies]
  end

  # /library is admin-gated by its route, so no in-handler role re-check (Discover needed
  # one because it lived on a non-admin route).
  defp run_series_op(socket, id, op, ok_msg, err_msg) do
    actor = socket.assigns.current_scope.user
    series = Enum.find(socket.assigns.series, &(to_string(&1.id) == id))

    case series && op.(series, actor) do
      {:ok, _} ->
        {:noreply, socket |> assign(confirming: nil, series: Catalog.list_series()) |> put_flash(:info, ok_msg)}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, err_msg)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Library<:subtitle>Manage watchlisted movies and added series.</:subtitle>
      </.header>

      <section>
        <h2 class="pb-3 text-lg font-semibold">Movies</h2>
        <.empty_state
          :if={@movies == []}
          icon="hero-film"
          title="No movies yet"
          message="Requested movies appear here."
        />
        <ul :if={@movies != []} class="space-y-3">
          <li :for={m <- @movies} id={"movie-#{m.id}"} class="card bg-base-200 p-4">
            <div class="flex flex-wrap items-center gap-3">
              <span class="font-semibold">{m.title}</span>
              <span :if={m.year} class="text-base-content/60">({m.year})</span>
              <.status_badge kind={:movie} status={m.status} />
              <div class="ml-auto flex gap-2">
                <button type="button" class="btn btn-xs" phx-click="edit" phx-value-id={m.id}>Edit</button>
                <button
                  :if={Catalog.cancellable?(m)}
                  type="button"
                  class="btn btn-xs btn-warning"
                  phx-click="ask_cancel_movie"
                  phx-value-id={m.id}
                >
                  Cancel
                </button>
                <button
                  :if={not Catalog.cancellable?(m)}
                  type="button"
                  class="btn btn-xs btn-error"
                  phx-click="ask_delete_movie"
                  phx-value-id={m.id}
                >
                  Delete
                </button>
              </div>
            </div>

            <.form
              :if={@editing == m.id}
              for={@form}
              id={"movie-form-#{m.id}"}
              phx-submit="save"
              phx-value-id={m.id}
              class="mt-3 flex flex-wrap items-end gap-2"
            >
              <.input field={@form[:title]} type="text" label="Title" />
              <.input field={@form[:year]} type="number" label="Year" />
              <button class="btn btn-sm btn-primary" type="submit" phx-disable-with="Saving…">Save</button>
              <button class="btn btn-sm btn-ghost" type="button" phx-click="cancel_edit">Cancel edit</button>
            </.form>

            <.confirm_action
              :if={@confirming == {:movie, :cancel, to_string(m.id)}}
              id={"confirm-cancel-movie-#{m.id}"}
              on_confirm="confirm_cancel_movie"
              on_cancel="dismiss_confirm"
              value={m.id}
              confirm_label="Cancel movie"
              variant="warning"
            >
              <:caveat>Cancel this movie and remove its download?</:caveat>
            </.confirm_action>

            <.confirm_action
              :if={@confirming == {:movie, :delete, to_string(m.id)}}
              id={"confirm-delete-movie-#{m.id}"}
              on_confirm="confirm_delete_movie"
              on_cancel="dismiss_confirm"
              value={m.id}
              confirm_label="Delete"
            >
              <:caveat>Delete this movie's record? (Library files are left on disk.)</:caveat>
            </.confirm_action>
          </li>
        </ul>
      </section>

      <section class="mt-10">
        <h2 class="pb-3 text-lg font-semibold">Series</h2>
        <.empty_state
          :if={@series == []}
          icon="hero-tv"
          title="No series added yet"
          message="Add a show from Discover."
        />
        <div :if={@series != []} id="series-list" class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
          <div :for={s <- @series} id={"series-row-#{s.id}"} class="space-y-2">
            <.link navigate={~p"/series/#{s.id}"} class="block">
              <.media_card poster_path={s.poster_path} title={s.title} year={s.year} type={:tv}>
                <span class="link link-primary text-sm">Configure monitoring →</span>
              </.media_card>
            </.link>

            <div class="flex gap-2">
              <button type="button" class="btn btn-sm btn-warning" phx-click="ask_cancel_series" phx-value-id={s.id}>Cancel</button>
              <button type="button" class="btn btn-sm btn-error" phx-click="ask_delete_series" phx-value-id={s.id}>Delete</button>
            </div>

            <.confirm_action
              :if={@confirming == {:series, :cancel, to_string(s.id)}}
              id={"confirm-cancel-series-#{s.id}"}
              on_confirm="confirm_cancel_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label="Cancel & unmonitor"
              variant="warning"
            >
              <:caveat>Cancel & unmonitor this series?</:caveat>
            </.confirm_action>

            <.confirm_action
              :if={@confirming == {:series, :delete, to_string(s.id)}}
              id={"confirm-delete-series-#{s.id}"}
              on_confirm="confirm_delete_series"
              on_cancel="dismiss_confirm"
              value={s.id}
              confirm_label="Delete"
            >
              <:caveat>Delete this series record? (Library files are left on disk.)</:caveat>
            </.confirm_action>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Wire the route + redirect, delete MoviesLive**

In `lib/cinder_web/router.ex`, in the `:admin` `live_session` **delete** the `live "/movies", MoviesLive` line and **add**:

```elixir
      live "/library", LibraryLive
```

The `get "/movies", RedirectController, :to_library` redirect line and the `to_library/2` controller action were planned in Task 1's File Structure — **add `to_library/2` and the `get "/movies"` redirect now** (Task 2), so `~p"/library"` resolves before it is referenced.

Delete the old movie page + test:

```bash
git rm lib/cinder_web/live/movies_live.ex test/cinder_web/live/movies_live_test.exs
```

- [ ] **Step 5: Strip the "Added series" block out of DiscoverLive**

In `lib/cinder_web/live/discover_live.ex`:

1. Moduledoc: remove the "(admin only) Added series management block." clause (line 6) and the "(+ `series`, admin)" topic note (line 9) so the doc reads movies-only.
2. `mount/3`: remove `admin? = socket.assigns.current_scope.user.role == :admin` (line 18); remove `if admin?, do: Catalog.subscribe_series()` (line 24, keep the `Catalog.subscribe()` + `Cinder.Requests.subscribe()` lines); change the first `assign` (line 29) to drop `confirming: nil` and `admin?: admin?`:

```elixir
     |> assign(query: "", results: [], search_error: false)
```

   and delete the `series:` assign line (line 31):

```elixir
     |> assign(series: if(admin?, do: Catalog.list_series(), else: []))   # ← delete this line
```

3. Delete the five series `handle_event`s (lines 60-87): `"ask_cancel_series"`, `"ask_delete_series"`, `"dismiss_confirm"`, `"confirm_cancel_series"`, `"confirm_delete_series"`. (Keep the `"search"` and `"add"` handlers and the catch-all `handle_event(_event, _params, socket)`.)
4. Delete the two series `handle_info`s (lines 111-115): `{:series_updated, _id}` and `{:series_deleted, _id}`. (Keep the movie + request `handle_info`s and the catch-all.)
5. Delete `run_series_op/5` (lines 151-169).
6. In `render/1`, delete the call `<.series_admin_section :if={@admin?} series={@series} confirming={@confirming} />` (line 289).
7. Delete the `series_admin_section/1` component and its two `attr` declarations (lines 313-379).

Verify nothing else references `@admin?`, `@series`, or `@confirming` in DiscoverLive:

```bash
grep -nE "@admin\?|@series\b|@confirming|series_admin_section|run_series_op|subscribe_series" lib/cinder_web/live/discover_live.ex
```

Expected: no matches. (If `@confirming` is referenced anywhere in the movie-add path, leave its assign in — but per the current file it is series-only.)

In `test/cinder_web/live/discover_live_test.exs`, **delete the entire `describe "admin Added-series block"` block** (≈ lines 186-258) — every test in it references removed markup/handlers (`"Added series"`, `ask_delete_series`, the `series-row-#{id}` grid) and will fail post-strip. To preserve the **forge-resistance security assertion** that block contained (a non-admin on the open `/` route must not be able to act on a series), add this one test in its place — after the strip the forged event hits the catch-all `handle_event` and is a harmless no-op:

```elixir
  test "a forged series event from a non-admin on / is a harmless no-op", %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
    series = Cinder.Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 7777, title: "Severance", monitor_strategy: :future})

    {:ok, lv, _html} = live(conn, ~p"/")
    render_hook(lv, "confirm_delete_series", %{"id" => to_string(series.id)})

    assert Cinder.Catalog.get_series_by_id(series.id) != nil
  end
```

- [ ] **Step 6: Repoint SeriesDetailLive back to Library**

In `lib/cinder_web/live/series_detail_live.ex`:

- The back link (≈ line 167) `<.link navigate={~p"/"}>← Discover</.link>` → `<.link navigate={~p"/library"}>← Library</.link>`.
- The four `push_navigate(to: ~p"/")` targets (bad-id bounce in `mount`, post-delete, and the `{:series_deleted}` / vanished-on-reload bounces — ≈ lines 28, 115, 135, 147) → `push_navigate(to: ~p"/library")`.

Confirm:

```bash
grep -n '~p"/"' lib/cinder_web/live/series_detail_live.ex
```

Expected: no matches (all repointed to `/library`).

If `series_detail_live_test.exs` asserts a redirect target of `"/"`, update those expectations to `"/library"`.

- [ ] **Step 7: Run the tests**

Run: `mix test test/cinder_web/live/library_live_test.exs test/cinder_web/live/discover_live_test.exs test/cinder_web/live/series_detail_live_test.exs`
Expected: PASS.

- [ ] **Step 8: Full suite + commit**

Run: `mix test`
Expected: PASS.

```bash
git add -A
git commit -m "feat(ux-4): LibraryLive — unified /library (movies + series); strip Discover series block; redirect /movies"
```

---

## Task 3: DashboardLive — role-aware admin landing at `/dashboard`

Stat row + inline pending-approval queue (approve/deny via `Cinder.Requests` — identical behavior to `/requests`) + service health (the `StatusLive` `start_async` pattern) + a compact recent-activity slice. **No new context read helpers** — counts and the recent slice are derived in-memory from one `list_watchlist/0` load plus existing `length(list_*)` reads. Admins land here after login.

**Files:**
- Create: `lib/cinder_web/live/dashboard_live.ex`
- Create: `test/cinder_web/live/dashboard_live_test.exs`
- Modify: `lib/cinder_web/router.ex`, `lib/cinder_web/user_auth.ex`

**Interfaces:**
- Consumes: `Catalog.subscribe/0`, `Catalog.subscribe_series/0`, `Requests.subscribe/0`, `Catalog.list_watchlist/0`, `Catalog.list_series/0`, `Catalog.wanted_episodes/0`, `Catalog.list_grabs_downloading/0`, `Requests.list_pending/0 :: [%Request{user: %User{}}]`, `Requests.approve_request/2`, `Requests.deny_request/3`, `Health.check_all/0 :: [%{label: String.t(), status: :ok | {:error, term()}}]`, the existing private `UserAuth.admin?/1`.
- Produces: route `live "/dashboard", DashboardLive`; role-aware `UserAuth.signed_in_path/1`. Events: `"recheck_health"`, `"approve"`, `"start_deny"`, `"dismiss_deny"`, `"deny"`. `handle_async(:health, …)`.

- [ ] **Step 1: Write the failing test**

Create `test/cinder_web/live/dashboard_live_test.exs`:

```elixir
defmodule CinderWeb.DashboardLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.{Catalog, Requests}
  alias Cinder.Accounts.Scope

  setup :set_mox_global

  setup do
    # Dashboard runs Health.check_all/0 in a start_async task (separate process) → global mocks.
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    :ok
  end

  defp pending_movie_request(requester) do
    {:ok, req} =
      Requests.create_request(requester, %{
        target_type: "movie",
        target_id: System.unique_integer([:positive]),
        title: "Dune",
        year: 2021
      })

    req
  end

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "shows stats, the health panel, and recent activity", %{conn: conn} do
      {:ok, _} = Catalog.add_to_watchlist(%{tmdb_id: 1, title: "Arrival", year: 2016})

      {:ok, lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Dashboard"
      assert html =~ "Recent activity"
      assert html =~ "Arrival"
      # health resolves asynchronously
      assert render_async(lv) =~ "OK"
    end

    test "approving from the dashboard behaves identically to /requests", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      req = pending_movie_request(requester)

      {:ok, lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Dune"

      lv |> element("#pending-#{req.id} button", "Approve") |> render_click()

      assert Cinder.Repo.get(Cinder.Requests.Request, req.id).status == :approved
      assert Catalog.get_movie_by_tmdb_id(req.target_id).status == :requested
    end

    test "denying from the dashboard records the reason", %{conn: conn} do
      requester = Cinder.AccountsFixtures.user_fixture()
      req = pending_movie_request(requester)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("#pending-#{req.id} button", "Deny") |> render_click()

      lv
      |> form("#pending-#{req.id} form", %{reason: "Already own it"})
      |> render_submit()

      reloaded = Cinder.Repo.get(Cinder.Requests.Request, req.id)
      assert reloaded.status == :denied
      assert reloaded.denial_reason == "Already own it"
    end

    test "shows an empty pending state when there is nothing to approve", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Nothing to approve"
    end
  end

  test "non-admins are redirected away from /dashboard", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/dashboard")
  end

  test "signed_in_path is /dashboard for admins, / for users" do
    admin = Scope.for_user(Cinder.AccountsFixtures.admin_fixture())
    user = Scope.for_user(Cinder.AccountsFixtures.user_fixture())

    assert CinderWeb.UserAuth.signed_in_path(%{assigns: %{current_scope: admin}}) == "/dashboard"
    assert CinderWeb.UserAuth.signed_in_path(%{assigns: %{current_scope: user}}) == "/"
    assert CinderWeb.UserAuth.signed_in_path(%{assigns: %{}}) == "/"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder_web/live/dashboard_live_test.exs`
Expected: FAIL — `DashboardLive` undefined / `/dashboard` no route / `signed_in_path` returns `/` for admins.

- [ ] **Step 3: Make `signed_in_path/1` role-aware**

In `lib/cinder_web/user_auth.ex`, replace `def signed_in_path(_), do: ~p"/"` (≈ lines 308-309) with:

```elixir
  @doc "Returns the path to redirect to after log in (admins land on the dashboard)."
  def signed_in_path(%{assigns: %{current_scope: scope}}),
    do: if(admin?(scope), do: ~p"/dashboard", else: ~p"/")

  def signed_in_path(_), do: ~p"/"
```

`admin?/1` already exists privately (`admin?(%Scope{user: %{role: :admin}}) -> true; admin?(_) -> false`), so it safely handles a nil/absent scope. This is a pure presentation change — no `on_mount`/plug/route guard is touched. `log_in_user/3` still honors a stored `user_return_to` first, so deep links are unaffected.

- [ ] **Step 4: Create the DashboardLive module**

Create `lib/cinder_web/live/dashboard_live.ex`:

```elixir
defmodule CinderWeb.DashboardLive do
  @moduledoc """
  Admin landing at `/dashboard`: pipeline stats at a glance, an inline pending-approval
  queue (approve / deny), service health, and a compact recent-activity slice. Read-mostly;
  approve/deny route through `Cinder.Requests` exactly as `/requests` does — no new gate.
  Live via the `movies` + `series` + `requests` topics; health runs in a `start_async` task
  so a slow service can't block render.
  """
  use CinderWeb, :live_view

  alias Cinder.{Catalog, Health, Requests}

  @parked [:no_match, :search_failed, :import_failed]
  @pipeline [:requested, :searching, :downloading, :downloaded]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Catalog.subscribe_series()
      Requests.subscribe()
    end

    {:ok, socket |> assign(health: :loading, denying: nil) |> load() |> check_health()}
  end

  # Re-load on any pipeline/request change so stats, the queue, and recent activity stay live.
  @impl true
  def handle_info({:movie_updated, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:movie_created, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:movie_deleted, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:series_updated, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:series_deleted, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:request_created, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:request_approved, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:request_denied, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:health, {:ok, results}, socket),
    do: {:noreply, assign(socket, health: results)}

  def handle_async(:health, {:exit, reason}, socket),
    do: {:noreply, assign(socket, health: [%{label: "Health check", status: {:error, reason}}])}

  @impl true
  def handle_event("recheck_health", _params, socket),
    do: {:noreply, socket |> cancel_async(:health) |> assign(health: :loading) |> check_health()}

  def handle_event("approve", %{"id" => id}, socket) do
    with %{} = req <- find_pending(socket, id),
         {:error, _} <- Requests.approve_request(req, socket.assigns.current_scope.user) do
      {:noreply, put_flash(socket, :error, "Couldn't approve that request.")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start_deny", %{"id" => id}, socket),
    do: {:noreply, assign(socket, denying: id)}

  def handle_event("dismiss_deny", _params, socket),
    do: {:noreply, assign(socket, denying: nil)}

  def handle_event("deny", %{"_id" => id, "reason" => reason}, socket) do
    with %{} = req <- find_pending(socket, id),
         {:error, _} <- Requests.deny_request(req, socket.assigns.current_scope.user, reason) do
      {:noreply, socket |> assign(denying: nil) |> put_flash(:error, "Couldn't deny that request.")}
    else
      _ -> {:noreply, assign(socket, denying: nil)}
    end
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp find_pending(socket, id),
    do: Enum.find(socket.assigns.pending, &(to_string(&1.id) == id))

  # ponytail: derives counts + the recent slice from a single full-watchlist load and a few
  # length(list_*) reads — fine at single-household scale. Swap to count/limit queries if the
  # catalog ever grows large.
  defp load(socket) do
    movies = Catalog.list_watchlist()
    counts = Enum.frequencies_by(movies, & &1.status)
    recent = movies |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> Enum.take(8)

    assign(socket,
      pending: Requests.list_pending(),
      recent: recent,
      stats: %{
        movies_total: length(movies),
        movies_available: Map.get(counts, :available, 0),
        in_pipeline: Enum.sum(Enum.map(@pipeline, &Map.get(counts, &1, 0))),
        parked: Enum.sum(Enum.map(@parked, &Map.get(counts, &1, 0))),
        series_total: length(Catalog.list_series()),
        tv_wanted: length(Catalog.wanted_episodes()),
        downloading: length(Catalog.list_grabs_downloading())
      }
    )
  end

  defp check_health(socket) do
    if connected?(socket),
      do: start_async(socket, :health, &Health.check_all/0),
      else: socket
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :suffix, :any, default: nil
  attr :icon, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200 p-4">
      <div class="flex items-center gap-2 text-sm text-base-content/60">
        <.icon name={@icon} class="size-4" />{@label}
      </div>
      <div class="mt-1 text-2xl font-semibold tabular-nums">{@value}</div>
      <div :if={@suffix} class="text-xs text-base-content/50">{@suffix}</div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Dashboard<:subtitle>Pipeline at a glance.</:subtitle>
      </.header>

      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
        <.stat_card
          label="Movies available"
          value={@stats.movies_available}
          suffix={"of #{@stats.movies_total} total"}
          icon="hero-film"
        />
        <.stat_card
          label="In pipeline"
          value={@stats.in_pipeline}
          suffix={@stats.parked > 0 && "#{@stats.parked} parked"}
          icon="hero-arrow-path"
        />
        <.stat_card
          label="TV wanted"
          value={@stats.tv_wanted}
          suffix={"#{@stats.series_total} series"}
          icon="hero-tv"
        />
        <.stat_card
          label="Pending requests"
          value={length(@pending)}
          suffix={@stats.downloading > 0 && "#{@stats.downloading} downloading"}
          icon="hero-inbox-arrow-down"
        />
      </div>

      <div class="mt-8 grid gap-6 lg:grid-cols-2">
        <section>
          <div class="mb-3 flex items-center justify-between">
            <h2 class="text-lg font-semibold">Pending approvals</h2>
            <.link navigate={~p"/requests"} class="link link-hover text-sm">All requests →</.link>
          </div>
          <.empty_state
            :if={@pending == []}
            icon="hero-check-circle"
            title="Nothing to approve"
            message="New requests appear here."
          />
          <ul :if={@pending != []} class="space-y-3">
            <li :for={r <- @pending} id={"pending-#{r.id}"} class="card bg-base-200 p-4">
              <div class="flex flex-row items-center gap-4">
                <img
                  :if={r.poster_path}
                  src={"https://image.tmdb.org/t/p/w92" <> r.poster_path}
                  alt={r.title}
                  class="w-12 rounded"
                />
                <div class="min-w-0 flex-1">
                  <p class="truncate font-medium">
                    {if r.target_type == "season", do: "#{r.title} — Season #{r.season_number}", else: r.title}
                    <span :if={r.year} class="text-base-content/50">({r.year})</span>
                  </p>
                  <p class="truncate text-sm text-base-content/60">{r.user.email}</p>
                </div>
                <.status_badge kind={:request} status={r.status} />
              </div>
              <div class="mt-3 flex flex-wrap items-center gap-2">
                <button
                  class="btn btn-primary btn-sm"
                  phx-click="approve"
                  phx-value-id={r.id}
                  phx-disable-with="Approving…"
                >
                  Approve
                </button>
                <button
                  :if={@denying != to_string(r.id)}
                  class="btn btn-ghost btn-sm"
                  phx-click="start_deny"
                  phx-value-id={r.id}
                >
                  Deny
                </button>
                <form :if={@denying == to_string(r.id)} phx-submit="deny" class="flex flex-1 flex-wrap gap-2">
                  <input type="hidden" name="_id" value={r.id} />
                  <input
                    type="text"
                    name="reason"
                    placeholder="Reason (optional)"
                    class="input input-sm input-bordered flex-1"
                  />
                  <button type="submit" class="btn btn-error btn-sm" phx-disable-with="Denying…">Confirm deny</button>
                  <button type="button" class="btn btn-ghost btn-sm" phx-click="dismiss_deny">Cancel</button>
                </form>
              </div>
            </li>
          </ul>
        </section>

        <div class="space-y-6">
          <section>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">Service health</h2>
              <button class="btn btn-xs btn-ghost" phx-click="recheck_health" phx-disable-with="Checking…">Recheck</button>
            </div>
            <.spinner :if={@health == :loading} label="Checking services…" />
            <ul
              :if={@health != :loading}
              id="dashboard-health"
              class="menu menu-sm w-full rounded-box bg-base-200"
            >
              <li :for={h <- @health}>
                <div class="flex items-center justify-between">
                  <span>{h.label}</span>
                  <.status_badge kind={:health} status={h.status} />
                </div>
              </li>
            </ul>
          </section>

          <section>
            <div class="mb-3 flex items-center justify-between">
              <h2 class="text-lg font-semibold">Recent activity</h2>
              <.link navigate={~p"/activity"} class="link link-hover text-sm">View all →</.link>
            </div>
            <.empty_state
              :if={@recent == []}
              icon="hero-film"
              title="No activity yet"
              message="Request a movie to get started."
            />
            <ul :if={@recent != []} class="space-y-2">
              <li :for={m <- @recent} class="flex items-center gap-3">
                <.status_badge kind={:movie} status={m.status} />
                <span class="truncate">{m.title}</span>
                <span :if={m.year} class="text-sm text-base-content/50">({m.year})</span>
                <span class="ml-auto whitespace-nowrap text-xs text-base-content/40">
                  {Calendar.strftime(m.updated_at, "%b %-d")}
                </span>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: Add the route**

In `lib/cinder_web/router.ex`, in the `:admin` `live_session`, add:

```elixir
      live "/dashboard", DashboardLive
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/cinder_web/live/dashboard_live_test.exs`
Expected: PASS (all tests, including the `signed_in_path` unit assertions).

- [ ] **Step 7: Full suite + commit**

Run: `mix test`
Expected: PASS.

```bash
git add -A
git commit -m "feat(ux-4): DashboardLive — admin landing (stats, pending queue, health, recent); role-aware signed_in_path"
```

---

## Task 4: Sidebar nav — regroup the Admin section + role-aware wordmark

Add Dashboard / Library / Activity to the Admin nav group, drop the "Status" item (now `/activity`), and make the sidebar wordmark home link land admins on `/dashboard`. Pure presentation in `layouts.ex`.

**Files:**
- Modify: `lib/cinder_web/components/layouts.ex`
- Modify: `test/cinder_web/live/app_shell_test.exs`

**Interfaces:**
- Consumes: `nav_item/1` (existing, unchanged), `@admin?` / `@current_path` (existing layout assigns).
- Produces: the regrouped Admin nav (Dashboard, Requests, Library, Activity, Calendar, Settings, Users) and a role-aware wordmark target.

- [ ] **Step 1: Update the existing app-shell test (three concrete edits)**

`test/cinder_web/live/app_shell_test.exs` is `use CinderWeb.ConnCase, async: true` with **no Mox setup**. So for nav assertions navigate to a **non-health** admin live route (`/calendar`) — **not** `/dashboard`, whose `Health.check_all/0` `start_async` would call ungated mocks in an async test. There are existing assertions that this task **breaks and must change**, not just append to:

1. The existing admin-nav test (≈ lines 9-23) asserts a label list **including `"Status"`**. Replace its body so it asserts the **new** Admin group and **drops `"Status"`**:

```elixir
    conn = log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())
    {:ok, _lv, html} = live(conn, ~p"/calendar")

    for label <- ~w(Discover Dashboard Requests Library Activity Calendar Settings Users) do
      assert html =~ label
    end

    refute html =~ ">Status<"
```

2. The "marks the current route active" test (≈ lines 25-28) navigates with `live(conn, ~p"/status")`. After Task 1 `/status` is a `get` 302 (not a `live` route), so `live/2` returns `{:error, {:redirect, …}}` and the test errors. Repoint it to a surviving admin live route and assert the active marker:

```elixir
    conn = log_in_user(conn, Cinder.AccountsFixtures.admin_fixture())
    {:ok, _lv, html} = live(conn, ~p"/calendar")
    assert html =~ ~s(aria-current="page")
```

3. The non-admin test (≈ line 52) — keep/normalize it so it refutes the admin labels. Use:

```elixir
  test "non-admins see only the Everyone group", %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
    {:ok, _lv, html} = live(conn, ~p"/")

    assert html =~ "Discover"
    assert html =~ "My requests"
    refute html =~ "Dashboard"
    refute html =~ "Library"
    refute html =~ "Activity"
    refute html =~ "Settings"
  end
```

After editing, grep to confirm no admin-side `"Status"` assertion survives: `grep -n '"Status"\|/status' test/cinder_web/live/app_shell_test.exs` → expected: no admin-nav `"Status"` assertion and no `live(conn, ~p"/status")` left.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder_web/live/app_shell_test.exs`
Expected: FAIL — the new "Dashboard"/"Library"/"Activity" labels are not in the nav yet.

- [ ] **Step 3: Make the wordmark role-aware + regroup the Admin nav**

In `lib/cinder_web/components/layouts.ex`, change the sidebar wordmark home link (line 66):

```elixir
          <a href={if @admin?, do: ~p"/dashboard", else: ~p"/"} class="mb-2 flex items-center gap-2 px-2">
```

Replace the `<%= if @admin? do %> … <% end %>` Admin group (lines 87-119) with:

```elixir
            <%= if @admin? do %>
              <li class="menu-title mt-2">Admin</li>
              <.nav_item
                navigate={~p"/dashboard"}
                label="Dashboard"
                icon="hero-squares-2x2"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/requests"}
                label="Requests"
                icon="hero-inbox-arrow-down"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/library"}
                label="Library"
                icon="hero-rectangle-stack"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/activity"}
                label="Activity"
                icon="hero-bolt"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/calendar"}
                label="Calendar"
                icon="hero-calendar"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/settings"}
                label="Settings"
                icon="hero-cog-6-tooth"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/users"}
                label="Users"
                icon="hero-users"
                current_path={@current_path}
              />
            <% end %>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cinder_web/live/app_shell_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `mix test`
Expected: PASS.

```bash
git add -A
git commit -m "feat(ux-4): regroup Admin sidebar (Dashboard/Library/Activity); role-aware wordmark"
```

---

## Task 5: Calendar — degrade the table to mobile-safe cards

The `/calendar` table is 5 columns wide and overflows at 390px (named in the UX-4 Done-when). Replace it with a wrapping card list — single markup, no horizontal scroll. Logic is untouched.

**Files:**
- Modify: `lib/cinder_web/live/calendar_live.ex`
- Modify: `test/cinder_web/live/calendar_live_test.exs`

- [ ] **Step 1: Update the calendar test**

In `test/cinder_web/live/calendar_live_test.exs`, replace any `<table>`/`<th>`/`thead`-referencing assertion with the card list. Add:

```elixir
  test "renders upcoming episodes as cards (no overflow-prone table)", %{conn: conn} do
    # (use the existing fixture setup in this file to create a monitored, dated episode)
    {:ok, lv, html} = live(conn, ~p"/calendar")
    assert has_element?(lv, "#calendar-list")
    refute html =~ "<table"
  end
```

(Keep the file's existing fixture/setup for building a monitored upcoming episode; only the rendering-shape assertions change.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder_web/live/calendar_live_test.exs`
Expected: FAIL — there is still a `<table>` and no `#calendar-list`.

- [ ] **Step 3: Replace the table with cards**

In `lib/cinder_web/live/calendar_live.ex`, replace the `<table :if={@rows != []} …> … </table>` block (lines 63-82) with:

```elixir
      <ul :if={@rows != []} id="calendar-list" class="space-y-2">
        <li
          :for={row <- @rows}
          class="card bg-base-200 p-3 flex flex-row flex-wrap items-center gap-x-3 gap-y-1"
        >
          <span class="w-24 tabular-nums text-sm text-base-content/60">{row.ep.air_date}</span>
          <.status_badge kind={:episode} status={row.state} />
          <span class="font-medium">{row.ep.season.series.title}</span>
          <span class="tabular-nums text-sm text-base-content/60">
            {code(row.ep.season.season_number, row.ep.episode_number)}
          </span>
          <span class="truncate text-base-content/70">{row.ep.title}</span>
        </li>
      </ul>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cinder_web/live/calendar_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `mix test`
Expected: PASS.

```bash
git add -A
git commit -m "feat(ux-4): Calendar — card list instead of an overflow-prone table (mobile)"
```

---

## Task 6: Final verification + graphify refresh

**Files:** none (verification + graph refresh).

- [ ] **Step 1: Grep for the removed surfaces**

```bash
grep -rnE 'StatusLive|GrabsLive|MoviesLive|series_admin_section' lib/cinder_web | grep -v redirect_controller
```

Expected: no matches in `lib/` (the modules are deleted; only the `RedirectController` get-routes reference the old *paths*, not the modules).

- [ ] **Step 2: Confirm the IA is reachable + redirects land**

```bash
grep -nE '"/dashboard"|"/activity"|"/library"' lib/cinder_web/router.ex
grep -nE 'to_activity|to_library|to_root' lib/cinder_web/controllers/redirect_controller.ex
```

Expected: three `live` routes in the `:admin` session; three redirect actions in the controller.

- [ ] **Step 3: Run the full alias one more time**

Run: `mix test`
Expected: PASS — compile (warnings-as-errors), format, `credo --strict`, full suite all green.

- [ ] **Step 4: Refresh the knowledge graph**

Run: `graphify update .`

- [ ] **Step 5: Commit the graph refresh**

```bash
git add -A
git commit -m "chore(graph): refresh graphify report after UX-4 admin-home IA"
```

---

## Self-Review (against the UX-4 "Done when")

| UX-4 Done-when clause | Covered by |
|---|---|
| conventions pass (`mix test` green) | Every task ends with `mix test`; Task 6 Step 3 final pass. |
| an admin logs in and lands on `/dashboard` | Task 3 (`signed_in_path/1` role-aware) + test `signed_in_path is /dashboard for admins, / for users`. |
| dashboard shows live pending count, health, recent activity | Task 3 `DashboardLive` (stat row incl. pending count, `start_async` health, recent slice) + tests `shows stats, the health panel, and recent activity` (uses `render_async`) and the live PubSub `load/1` re-runs. |
| approve/deny from the dashboard behaves identically to `/requests` | Task 3 calls the same `Requests.approve_request/2` / `deny_request/3` + tests `approving … behaves identically` (asserts request `:approved` **and** movie created at `:requested`) and `denying … records the reason`. |
| Library lists movies+TV and drills into detail | Task 2 `LibraryLive` (movies + series grid, `~p"/series/#{id}"` drill) + tests `lists movies …` and `lists series with a drill-down link …`. |
| `/status` and `/grabs` content reachable under Activity | Task 1 `ActivityLive` (pipeline + grabs) + tests rendering both sections; health relocated to Dashboard (Task 3). |
| old routes redirect | Task 1 (`/status`,`/grabs`→`/activity`) + Task 2 (`/movies`→`/library`) + tests `…/status and /grabs redirect…`, `/movies redirects to /library`. |
| Dashboard/Activity/Library fully usable at 390px; Activity/Calendar tables degrade to stacked cards; dashboard panels stack to one column | Activity is cards (Task 1); Library is cards + 2-col-at-390px series grid (Task 2); Dashboard uses `grid-cols-2 lg:grid-cols-4` stats + `lg:grid-cols-2` panels that stack below `lg` (Task 3); Calendar table → cards (Task 5). |
| (constraint) no `:requested` row before approval; no `on_mount`/role-gating change | All three new routes drop into the **existing** `:admin` `live_session` unchanged; approve still find-or-creates the movie only on admin action; Task 3 approve test asserts the movie appears at `:requested` **only after** approve. Discover's non-admin add path is untouched. Task 2 retains a **forge-resistance test**: a non-admin forging a removed series event on `/` is a no-op. |

**Placeholder scan:** every code step contains complete, compilable code; tests embed full assertions; no "TBD"/"similar to"/"add error handling" left. The three "reconcile with existing test file" steps (app_shell, calendar, discover, series_detail) spell out the exact new assertions to add and which old ones to drop.

**Type/name consistency:** `confirming` is `{:movie | :series, :cancel | :delete, id_string}` in LibraryLive (disambiguated to avoid movie/series id collision), a bare `id_string` in ActivityLive (grabs only); the matching `<.confirm_action>` `:if` guards use the same shapes. Event names are disjoint across each LiveView; the movie events in LibraryLive carry the `_movie` suffix specifically so they don't collide with the ported `_series` events. `signed_in_path/1` returns a string path; `Health.check_all/0` rows are `%{label, status}` matching `<.status_badge kind={:health}>`.

**Cross-cutting audit:** the `signed_in_path/1` change alters the post-login redirect for **admins only**. Existing login / registration / session-controller tests assert `redirected_to(conn) == ~p"/"` using non-admin `user_fixture()` accounts, so they still pass unchanged — this is the one place the "presentation-only" change has test reach, and it's accounted for.

## Decisions locked (this plan)

1. **Library detail = reuse `/series/:id` for series + inline movie management; no new movie-detail page.** Movies don't have a rich detail page today (just inline edit), so Library keeps that inline and drills only series into the unchanged `SeriesDetailLive`. (Settles the design's open question "Library detail: reuse `/series/:id` vs a unified detail" → reuse.)
2. **No shared Activity/Dashboard "recent activity" component.** Activity is full pipeline+grabs tables-as-cards; the Dashboard's recent slice is a compact most-recently-updated-movies list linking to `/activity`. Two genuinely different densities — a shared component would be a forced abstraction. (Settles the design's open question "Whether Activity and Dashboard share one component" → no.) The shared *logic* (`Cinder.Requests` for approve/deny) **is** reused, which is what guarantees "behaves identically."
3. **Service health lives on the Dashboard, not Activity.** Per the IA (Dashboard = "service health"; Activity = "what's happening now" feed). `/status`→`/activity` lands on the pipeline content; an admin checks health on the Dashboard.
4. **No new `Cinder.Catalog`/`Requests` read helper.** Dashboard stats + recent slice derive from one `list_watchlist/0` load (`Enum.frequencies_by` + in-memory sort) plus existing `length(list_*)` reads — lazy and correct at single-household scale (ponytail comment marks the ceiling). If load ever shows up, add a `count_by_status/0` group_by query then.
5. **Series management moves entirely out of Discover.** The "Added series" block (admin-only, template-gated) relocates to the admin-route-gated `/library` — strictly tighter, and Discover returns to a pure requester surface.

## Out of scope (noted, not done)

- **Live sidebar count badges** (the IA sketch's "Requests (pending #)" / "Activity (active #)"). The nav has no count mechanism today, and threading live counts into `Layouts.app` from every caller is a cross-cutting change the UX-4 Done-when doesn't require (it asks for the live pending count **on the Dashboard**, which Task 3 delivers). Defer to a later polish pass.
- **Active-nav highlight on series detail.** `/series/:id` does not prefix-match `/library`, so the Library nav item won't stay highlighted on the series-detail drill-down. Minor cosmetic; leave for UX-5's cross-device sweep if it matters.
- **UX-5 items unchanged:** a11y table semantics are now largely moot for Activity/Calendar (converted to cards); `prefers-reduced-motion`, icon-only `aria-label`s, the full light-theme pass, and the documented 390/768/1440 sweep remain UX-5.
