# UX-3 — Unified Discover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the movie search (`/`), TV search (`/series`), and TV season-request (`/series/tmdb/:id`) surfaces into one **Discover** page: a single search that returns movies **and** TV in one mixed poster grid, with the approval gate and request creation untouched.

**Architecture:** A new `CinderWeb.DiscoverLive` at `/` replaces `WatchlistLive`. One search box drives a new `Catalog.search_discover/1` that calls both `search_movies/1` and `search_tv/1` and returns results tagged `:movie`/`:tv`, interleaved. A shared `<.media_card>` function component replaces the two duplicated private cards (`movie_card`, `series_card`). Movie cards keep the inline Add/state affordance; TV cards link to the **kept** `SeriesDiscoveryLive` season picker (decision: dedicated route, not a modal). `SeriesLive`'s admin-only "Added series" management block (cancel/delete) is relocated onto Discover, admin-gated (decision: keep on Discover during UX-3; UX-4 moves it to Library). `/series` redirects to `/`.

**Tech Stack:** Elixir/Phoenix 1.8 LiveView (HEEx), Tailwind v4 + daisyUI, ExUnit + Mox. No new deps.

## Global Constraints

- `mix test` (the alias: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then suite) is green at the end of **every** task. Commit per task.
- **Do not touch the approval gate / pipeline / role-gating.** `Cinder.Requests.create_request/2` stays the only user-action path that can create a `:requested` row. No route's `on_mount` guard changes — only grouping/labels/visuals. (Roadmap top risk: a non-admin who can write a `:requested` row is an approve-by-default leak.)
- Stay in-stack: HEEx + daisyUI, no JS framework, no new external service env vars.
- Mobile-first on this requester surface: the grid reflows to 2 columns at 390px (`grid-cols-2 sm:grid-cols-3`), request/season affordances are **always rendered** (never hover-only), touch targets ≥ 44px (use `btn btn-sm w-full` for actions).
- After code changes, run `graphify update .` (AST-only, no API cost) before the final commit.
- Poster base URL is `https://image.tmdb.org/t/p/w342` (centralized in `<.media_card>` going forward).

---

## File Structure

**Create:**
- `lib/cinder_web/live/discover_live.ex` — the merged Discover page (movie search + TV search → mixed grid; movie watchlist grid; admin "Added series" block).
- `lib/cinder_web/controllers/redirect_controller.ex` — one action, redirects `/series` → `/`.
- `test/cinder/catalog_discover_test.exs` — unit tests for `Catalog.search_discover/1`.
- `test/cinder_web/live/discover_live_test.exs` — the merged page's tests (ported movie tests + new TV/mixed tests + admin series tests + redirect).

**Modify:**
- `lib/cinder/catalog.ex` — add `search_discover/1` (+ private `merge_discover/2`, `tag/2`, `interleave/2`).
- `lib/cinder_web/components/core_components.ex` — add `media_card/1` + `@poster_base` + `type_icon/1` / `type_label/1`.
- `lib/cinder_web/router.ex` — route `/` → `DiscoverLive`; remove `live "/series", SeriesLive`; add `get "/series"` redirect. Keep `/series/tmdb/:tmdb_id` and `/series/:id`.
- `lib/cinder_web/components/layouts.ex` — sidebar nav item label `"Search"` → `"Discover"`.

**Delete:**
- `lib/cinder_web/live/watchlist_live.ex` (replaced by `discover_live.ex`).
- `lib/cinder_web/live/series_live.ex` (search merged into Discover; admin block relocated).
- `test/cinder_web/live/watchlist_live_test.exs` (ported into `discover_live_test.exs`).
- `test/cinder_web/live/series_live_test.exs` (TV-search + admin-series tests ported into `discover_live_test.exs`).

**Keep unchanged:** `lib/cinder_web/live/series_discovery_live.ex` (+ its test), `lib/cinder_web/live/series_detail_live.ex`, `lib/cinder_web/live/movies_live.ex`.

---

### Task 1: `Catalog.search_discover/1` — concurrent-shape combined search

**Files:**
- Modify: `lib/cinder/catalog.ex` (add after `search_tv/1`, ~`lib/cinder/catalog.ex:37`)
- Test: `test/cinder/catalog_discover_test.exs` (create)

**Interfaces:**
- Consumes: existing `Catalog.search_movies/1`, `Catalog.search_tv/1` (both `(query) :: {:ok, [map]} | {:error, term}`; each result map has `:tmdb_id, :title, :year, :poster_path`).
- Produces: `Catalog.search_discover(query :: String.t()) :: {:ok, [map]} | {:error, :search_failed}`. Each result map is a search map plus `:type` (`:movie | :tv`); blank query → `{:ok, []}`; both endpoints error → `{:error, :search_failed}`; one errors → that side omitted (logged), other side returned.

- [ ] **Step 1: Write the failing tests**

Create `test/cinder/catalog_discover_test.exs`:

```elixir
defmodule Cinder.CatalogDiscoverTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Catalog

  setup :verify_on_exit!

  @movie %{tmdb_id: 1, title: "A Movie", year: 2000, poster_path: "/m.jpg"}
  @show %{tmdb_id: 2, title: "A Show", year: 2001, poster_path: "/s.jpg"}

  test "a blank query short-circuits to {:ok, []} with no TMDB call" do
    assert {:ok, []} = Catalog.search_discover("   ")
  end

  test "tags each result :movie/:tv and interleaves them" do
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:ok, [@movie]} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:ok, [@show]} end)

    assert {:ok, results} = Catalog.search_discover("x")
    assert Enum.map(results, & &1.type) == [:movie, :tv]
    assert Enum.map(results, & &1.tmdb_id) == [1, 2]
  end

  @tag :capture_log
  test "one endpoint erroring still yields the other's results" do
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:ok, [@movie]} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:error, :timeout} end)

    assert {:ok, [%{type: :movie, tmdb_id: 1}]} = Catalog.search_discover("x")
  end

  @tag :capture_log
  test "both endpoints erroring yields {:error, :search_failed}" do
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:error, :timeout} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:error, :nxdomain} end)

    assert {:error, :search_failed} = Catalog.search_discover("x")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/cinder/catalog_discover_test.exs`
Expected: FAIL — `function Cinder.Catalog.search_discover/1 is undefined`.

- [ ] **Step 3: Implement `search_discover/1`**

In `lib/cinder/catalog.ex`, immediately after `search_tv/1` (`lib/cinder/catalog.ex:37`):

```elixir
  @doc """
  Combined Discover search: movies + TV for one query. Returns `{:ok, results}`
  where each result is a normalized search map plus a `:type` key (`:movie | :tv`),
  interleaved so both kinds surface near the top of the grid. A blank/whitespace
  query short-circuits to `{:ok, []}` with no API call. If *both* endpoints error,
  returns `{:error, :search_failed}`; if only one errors it is logged and its side
  is omitted — partial results beat none for discovery.

  ponytail: runs the two searches sequentially (matches the existing synchronous
  search style; household scale + 300ms debounce). Upgrade path if search latency
  bites: wrap each in Task.async/await_many to run them concurrently.
  """
  def search_discover(query) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      merge_discover(search_movies(query), search_tv(query))
    end
  end

  defp merge_discover({:error, _} = movies, {:error, _} = tv) do
    Logger.warning("Discover search failed entirely: movies=#{inspect(movies)} tv=#{inspect(tv)}")
    {:error, :search_failed}
  end

  defp merge_discover(movies_res, tv_res) do
    {:ok, interleave(tag(movies_res, :movie), tag(tv_res, :tv))}
  end

  defp tag({:ok, list}, type), do: Enum.map(list, &Map.put(&1, :type, type))

  defp tag({:error, reason}, type) do
    Logger.warning("Discover #{type} search failed: #{inspect(reason)}")
    []
  end

  # Round-robin so a 2-col mobile grid shows both kinds near the top, then any tail.
  defp interleave(a, b) do
    0..max(length(a), length(b))
    |> Enum.flat_map(fn i -> [Enum.at(a, i), Enum.at(b, i)] end)
    |> Enum.reject(&is_nil/1)
  end
```

(`require Logger` is already at the top of `catalog.ex` — confirm it is; it is at `lib/cinder/catalog.ex:9`.)

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/cinder/catalog_discover_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_discover_test.exs
git commit -m "feat(ux-3): Catalog.search_discover/1 — tagged, interleaved movies+TV"
```

---

### Task 2: `<.media_card>` shared component

**Files:**
- Modify: `lib/cinder_web/components/core_components.ex` (add near the other display components, e.g. after `status_badge`)
- Test: `test/cinder_web/components/media_card_test.exs` (create)

**Interfaces:**
- Produces: `<.media_card poster_path={} title={} year={} type={} >slot</.media_card>` — `poster_path` (string `/p.jpg` fragment or nil), `title` (required string), `year` (int or nil), `type` (`nil | :movie | :tv`; renders a small corner chip when set), inner block = the action/state affordance. Builds the full poster URL from the module's `@poster_base`.

- [ ] **Step 1: Write the failing test**

Create `test/cinder_web/components/media_card_test.exs`:

```elixir
defmodule CinderWeb.MediaCardTest do
  use CinderWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CinderWeb.CoreComponents

  test "renders title, year, poster and the action slot" do
    html =
      render_component(&media_card/1, %{
        poster_path: "/p.jpg",
        title: "Inception",
        year: 2010,
        type: :movie,
        inner_block: nil
      })
      |> then(fn _ -> nil end)

    # render_component with a slot: use the component in a heex harness instead.
    assert true
  end
end
```

> NOTE: `render_component` is awkward for slots. Test `media_card` through the LiveView render in Task 3 instead (the DiscoverLive tests assert the poster `<img>`, the title, and the `Film`/`TV` chip). **Skip this standalone component test** — delete the stub file and rely on Task 3's coverage.

- [ ] **Step 1 (revised): no standalone test — covered in Task 3**

Do not create `media_card_test.exs`. The component is exercised by `discover_live_test.exs` (Task 3): a movie search renders `Film` chip + `<img>`; a TV result renders `TV` chip; the watchlist renders cards without a chip.

- [ ] **Step 2: Implement `media_card/1` in `core_components.ex`**

Add near the top-level display components (after `status_badge/1`, ~`lib/cinder_web/components/core_components.ex:649`). First add the module attribute near the top of the module (after `use Phoenix.Component` / existing attrs; place beside any other `@`):

```elixir
  @poster_base "https://image.tmdb.org/t/p/w342"
```

Then the component:

```elixir
  @doc """
  A poster card for a movie or TV result/record. Renders the TMDB poster (or a
  "No poster" placeholder), the title + optional year, an optional film/TV corner
  chip, and an action affordance via the inner block (Add button, status badge,
  season-picker link, admin controls). Single source of truth for the discover/
  library poster card — replaces the duplicated `movie_card`/`series_card`.

  `poster_path` is the TMDB path fragment (`/abc.jpg`); the full URL is built here.
  """
  attr :poster_path, :string, default: nil
  attr :title, :string, required: true
  attr :year, :integer, default: nil
  attr :type, :atom, default: nil, values: [nil, :movie, :tv]
  slot :inner_block

  def media_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <figure class="relative">
        <img
          :if={@poster_path}
          src={@poster_base <> @poster_path}
          alt={@title}
          class="aspect-[2/3] w-full object-cover"
        />
        <div
          :if={!@poster_path}
          class="grid aspect-[2/3] w-full place-items-center bg-base-300 text-sm text-base-content/40"
        >
          No poster
        </div>
        <span
          :if={@type}
          class="badge badge-sm absolute left-2 top-2 gap-1 border-0 bg-base-100/80 backdrop-blur"
        >
          <.icon name={type_icon(@type)} class="size-3" />{type_label(@type)}
        </span>
      </figure>
      <div class="card-body gap-2 p-3">
        <h3 class="text-sm font-semibold leading-tight">
          {@title}
          <span :if={@year} class="font-normal text-base-content/60">({@year})</span>
        </h3>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp type_icon(:movie), do: "hero-film"
  defp type_icon(:tv), do: "hero-tv"
  defp type_label(:movie), do: "Film"
  defp type_label(:tv), do: "TV"
```

Add `@poster_base` only once; if `core_components.ex` already defines a module attribute block, place it there.

- [ ] **Step 3: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: clean (no unused `type_icon`/`type_label` warnings — they're used by `media_card`).

- [ ] **Step 4: Commit**

```bash
git add lib/cinder_web/components/core_components.ex
git commit -m "feat(ux-3): shared <.media_card> (poster + optional film/TV chip + action slot)"
```

---

### Task 3: `DiscoverLive` — merged requester surface (movie + TV search, watchlist), route `/`

**Files:**
- Create: `lib/cinder_web/live/discover_live.ex`
- Modify: `lib/cinder_web/router.ex:59` (`live "/", WatchlistLive` → `live "/", DiscoverLive`)
- Delete: `lib/cinder_web/live/watchlist_live.ex`
- Create: `test/cinder_web/live/discover_live_test.exs`
- Delete: `test/cinder_web/live/watchlist_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.search_discover/1` (Task 1), `<.media_card>` (Task 2), `Catalog.list_watchlist/0`, `Catalog.subscribe/0`, `Cinder.Requests.subscribe/0`, `Cinder.Requests.create_request/2`, `Cinder.Requests.list_for_user/1`, `Catalog.list_by_status/1`.
- Produces: the page at `/`. Search form id `#search-form`, input `#query`; results grid id `#results`; watchlist grid id `#watchlist`. Movie cards render `#add-<tmdb_id>` (Add) or a request `<.status_badge>`; TV cards render a `~p"/series/tmdb/<id>"` season-picker link. (Admin "Added series" block is added in Task 4.)

- [ ] **Step 1: Write the failing tests**

Create `test/cinder_web/live/discover_live_test.exs` (ports the `watchlist_live_test.exs` movie cases, updates the search aria-label, and adds TV/mixed cases). The default setup stubs **both** TMDB search endpoints (`search_discover` always calls both, so an unstubbed endpoint would crash the search task):

```elixir
defmodule CinderWeb.DiscoverLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Requests

  # The LiveView runs in its own process, so the mock must be global (async: false).
  setup :register_and_log_in_admin
  setup :set_mox_global

  setup do
    # search_discover always hits both endpoints; default both to empty.
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:ok, []} end)
    :ok
  end

  @inception %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"}
  @got %{tmdb_id: 1399, title: "Game of Thrones", year: 2011, poster_path: "/got.jpg"}

  defp stub_movies(results),
    do: stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:ok, results} end)

  defp stub_tv(results),
    do: stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:ok, results} end)

  test "first load shows an empty-watchlist state and an accessible search field", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "watchlist is empty"
    assert has_element?(lv, "input#query[aria-label='Search movies and TV']")
  end

  test "typing a query renders movie results", %{conn: conn} do
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert html =~ "Inception"
    assert html =~ "2010"
    assert html =~ "Film"
  end

  test "typing a query renders TV results that link to the season picker", %{conn: conn} do
    stub_tv([@got])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "thrones"}) |> render_change()

    assert html =~ "Game of Thrones"
    assert html =~ "TV"
    assert has_element?(lv, ~s(#results a[href="/series/tmdb/1399"]))
  end

  test "a single query returns movies AND TV together in one grid", %{conn: conn} do
    stub_movies([@inception])
    stub_tv([@got])
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "x"}) |> render_change()

    assert html =~ "Inception"
    assert html =~ "Game of Thrones"
    # movie → inline Add; TV → season-picker link
    assert has_element?(lv, "#add-27205")
    assert has_element?(lv, ~s(#results a[href="/series/tmdb/1399"]))
  end

  test "admin add creates a :requested movie and shows it in the watchlist", %{conn: conn} do
    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    lv |> element("#add-27205") |> render_click()

    assert has_element?(lv, "#watchlist", "Inception")
    assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_watchlist()
  end

  # Regression (UX-3 Done-when): a non-admin add creates a pending request, NO :requested movie.
  test "non-admin add creates a pending request, no :requested movie row", %{conn: conn} do
    stub_movies([@inception])
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> element("#add-27205") |> render_click()

    assert html =~ "awaiting approval"
    assert Catalog.list_by_status(:requested) == []
    assert [%Requests.Request{status: :pending}] = Requests.list_for_user(user)
  end

  test "a pending request shows a Pending badge instead of Add", %{conn: _conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: 27_205,
        title: "Inception",
        year: 2010,
        poster_path: "/p.jpg"
      })

    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()

    assert has_element?(lv, "#results", "Pending")
    refute has_element?(lv, "#add-27205")
  end

  test "a quota-exceeded add shows the quota flash", %{conn: _conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    {:ok, _} = Cinder.Accounts.update_user_quota(user, 0)
    conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

    stub_movies([@inception])
    {:ok, lv, _html} = live(conn, ~p"/")

    lv |> form("#search-form", %{"query" => "inception"}) |> render_change()
    html = lv |> element("#add-27205") |> render_click()

    assert html =~ "request limit"
    assert Requests.list_for_user(user) == []
  end

  test "a total TMDB failure flashes and shows 'Search failed', not 'No matches'", %{conn: conn} do
    stub(Cinder.Catalog.TMDBMock, :search, fn _ -> {:error, :timeout} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn _ -> {:error, :nxdomain} end)
    {:ok, lv, _html} = live(conn, ~p"/")

    html = lv |> form("#search-form", %{"query" => "boom"}) |> render_change()

    assert html =~ "Search failed"
    refute html =~ "No matches"
    assert render(lv) =~ "search-form"
  end

  test "an add with a non-numeric tmdb_id is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    assert render_hook(lv, "add", %{"tmdb_id" => "not-a-number"}) =~ "search-form"
    assert Catalog.list_watchlist() == []
  end

  test "a malformed (non-binary) add payload is ignored, not a crash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    assert render_hook(lv, "add", %{"tmdb_id" => ["x"]}) =~ "search-form"
    assert Catalog.list_watchlist() == []
  end

  test "watchlist renders a colour-coded status badge", %{conn: conn} do
    {:ok, _movie} = Catalog.add_to_watchlist(%{tmdb_id: 8100, title: "M"})
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "badge-neutral"
  end

  test "a movie's status change updates its badge live", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(@inception)
    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, "#watchlist", "Requested")

    {:ok, _} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

    assert render(lv) =~ "Downloading"
    refute has_element?(lv, "#watchlist .badge", "Requested")
  end

  test "drops a deleted movie from the watchlist on {:movie_deleted, id}", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9500, title: "Gone Soon"})
    {:ok, lv, html} = live(conn, ~p"/")
    assert html =~ "Gone Soon"

    Catalog.broadcast_movie_deleted(movie.id)
    refute render(lv) =~ "Gone Soon"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/cinder_web/live/discover_live_test.exs`
Expected: FAIL — `/` still routes to `WatchlistLive`; no `DiscoverLive`.

- [ ] **Step 3: Create `DiscoverLive`**

Create `lib/cinder_web/live/discover_live.ex` (movie logic ported verbatim from `WatchlistLive`; search swapped to `search_discover`; results rendered via `<.media_card>` with per-type action; the admin "Added series" block is a stub `nil` assign for now and is filled in Task 4):

```elixir
defmodule CinderWeb.DiscoverLive do
  @moduledoc """
  Unified Discover surface, mounted at `/`. One search returns movies AND TV in a
  single mixed poster grid: movie cards request inline (Add → `Cinder.Requests`),
  TV cards link to the season picker (`/series/tmdb/:tmdb_id`). Below the grid: the
  movie watchlist, and (admin only) an "Added series" management block.

  The approval gate is untouched — every add/request goes through
  `Cinder.Requests.create_request/2`. Live via the `movies` + `requests` (+ `series`,
  admin) topics.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    admin? = socket.assigns.current_scope.user.role == :admin

    # ponytail: subscribe-before-read closes the read/subscribe gap.
    if connected?(socket) do
      Catalog.subscribe()
      Cinder.Requests.subscribe()
      if admin?, do: Catalog.subscribe_series()
    end

    {:ok,
     socket
     |> assign(query: "", results: [], search_error: false, confirming: nil, admin?: admin?)
     |> assign(watchlist: Catalog.list_watchlist())
     |> assign(series: if(admin?, do: Catalog.list_series(), else: []))
     |> assign_request_state()}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    case Catalog.search_discover(query) do
      {:ok, results} ->
        {:noreply, assign(socket, query: query, results: results, search_error: false)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(query: query, search_error: true)
         |> put_flash(:error, "TMDB search failed. Try again.")}
    end
  end

  def handle_event("add", %{"tmdb_id" => tmdb_id}, socket) when is_binary(tmdb_id) do
    # phx-value is client-controlled; tolerate non-numeric input and only match movies.
    with {id, ""} <- Integer.parse(tmdb_id),
         movie when not is_nil(movie) <-
           Enum.find(socket.assigns.results, &(&1.type == :movie and &1.tmdb_id == id)) do
      {:noreply, add(socket, movie)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("ask_cancel_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:cancel, id})}

  def handle_event("ask_delete_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:delete, id})}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("confirm_cancel_series", %{"id" => id}, socket) do
    run_series_op(socket, id, &Catalog.cancel_series/2, "Series cancelled.", "Couldn't cancel the series.")
  end

  def handle_event("confirm_delete_series", %{"id" => id}, socket) do
    run_series_op(socket, id, &Catalog.delete_series/2, "Series deleted.", "Couldn't delete the series.")
  end

  # The event payload is client-controlled; ignore any malformed/forged frame.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    watchlist = Enum.map(socket.assigns.watchlist, &if(&1.id == movie.id, do: movie, else: &1))
    {:noreply, socket |> assign(watchlist: watchlist) |> patch_movie_status(movie)}
  end

  def handle_info({:movie_created, movie}, socket) do
    {:noreply, socket |> update(:watchlist, &[movie | &1]) |> patch_movie_status(movie)}
  end

  def handle_info({:movie_deleted, id}, socket) do
    {:noreply, update(socket, :watchlist, fn wl -> Enum.reject(wl, &(&1.id == id)) end)}
  end

  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied] do
    {:noreply, assign_request_state(socket)}
  end

  def handle_info({:series_updated, _id}, socket),
    do: {:noreply, assign(socket, series: Catalog.list_series())}

  def handle_info({:series_deleted, _id}, socket),
    do: {:noreply, assign(socket, series: Catalog.list_series())}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp add(socket, movie) do
    user = socket.assigns.current_scope.user

    attrs = %{
      target_type: "movie",
      target_id: movie.tmdb_id,
      title: movie.title,
      year: movie.year,
      poster_path: movie.poster_path
    }

    case Cinder.Requests.create_request(user, attrs) do
      {:ok, %{status: :approved}} ->
        socket |> put_flash(:info, "#{movie.title} added.") |> assign_request_state()

      {:ok, %{status: :pending}} ->
        socket
        |> put_flash(:info, "#{movie.title} requested — awaiting approval.")
        |> assign_request_state()

      {:error, :quota_exceeded} ->
        put_flash(socket, :error, "You've reached your request limit. Wait for approvals to clear.")

      {:error, _} ->
        put_flash(socket, :error, "#{movie.title} is already requested.")
    end
  end

  defp run_series_op(socket, id, op, ok_msg, err_msg) do
    if socket.assigns.current_scope.user.role != :admin do
      {:noreply, socket}
    else
      actor = socket.assigns.current_scope.user
      series = Enum.find(socket.assigns.series, &(to_string(&1.id) == id))

      case series && op.(series, actor) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(confirming: nil, series: Catalog.list_series())
           |> put_flash(:info, ok_msg)}

        _ ->
          {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, err_msg)}
      end
    end
  end

  defp assign_request_state(socket) do
    user = socket.assigns.current_scope.user
    request_status = latest_request_status(Cinder.Requests.list_for_user(user))
    assign_movie_status(assign(socket, request_status: request_status))
  end

  defp assign_movie_status(socket) do
    assign(socket, movie_status: Map.new(Catalog.list_watchlist(), &{&1.tmdb_id, &1.status}))
  end

  defp patch_movie_status(socket, movie) do
    assign(socket, movie_status: Map.put(socket.assigns.movie_status, movie.tmdb_id, movie.status))
  end

  defp latest_request_status(requests) do
    Enum.reduce(requests, %{}, fn r, acc -> Map.put_new(acc, r.target_id, r.status) end)
  end

  # Precedence: an available movie outranks a stale denied/approved request.
  defp title_state(tmdb_id, request_status, movie_status) do
    cond do
      movie_status[tmdb_id] == :available -> :available
      request_status[tmdb_id] == :pending -> :pending
      request_status[tmdb_id] == :approved -> :approved
      request_status[tmdb_id] == :denied -> :denied
      true -> :none
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Discover
        <:subtitle>Search movies and TV — request what you want to watch.</:subtitle>
      </.header>

      <form id="search-form" phx-change="search" phx-submit="search" class="mb-8">
        <input
          type="text"
          id="query"
          name="query"
          value={@query}
          phx-debounce="300"
          autocomplete="off"
          aria-label="Search movies and TV"
          placeholder="Search movies and TV…"
          class="input w-full"
        />
      </form>

      <section :if={@results != []} class="mb-10">
        <h2 class="sr-only">Search results</h2>
        <div id="results" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
          <.media_card
            :for={r <- @results}
            poster_path={r.poster_path}
            title={r.title}
            year={r.year}
            type={r.type}
          >
            <.result_action
              :if={r.type == :movie}
              state={title_state(r.tmdb_id, @request_status, @movie_status)}
              tmdb_id={r.tmdb_id}
            />
            <.link
              :if={r.type == :tv}
              navigate={~p"/series/tmdb/#{r.tmdb_id}"}
              class="btn btn-primary btn-sm w-full"
            >
              View seasons →
            </.link>
          </.media_card>
        </div>
      </section>

      <.empty_state
        :if={@query != "" and @results == [] and not @search_error}
        icon="hero-magnifying-glass"
        title="No matches"
        message="No movies or shows matched that search."
      />
      <.empty_state
        :if={@search_error}
        variant="search-error"
        title="Search failed"
        message="TMDB didn't respond. Try again."
      />

      <h2 class="pb-4 text-lg font-semibold leading-8">Watchlist</h2>
      <.empty_state
        :if={@watchlist == []}
        icon="hero-bookmark"
        title="Your watchlist is empty"
        message="Search above to add a movie."
      />
      <div id="watchlist" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <.media_card
          :for={m <- @watchlist}
          poster_path={m.poster_path}
          title={m.title}
          year={m.year}
        >
          <.status_badge kind={:movie} status={m.status} />
        </.media_card>
      </div>

      <.series_admin_section :if={@admin?} series={@series} confirming={@confirming} />
    </Layouts.app>
    """
  end

  attr :state, :atom, required: true
  attr :tmdb_id, :integer, required: true

  defp result_action(assigns) do
    ~H"""
    <.status_badge :if={@state != :none} kind={:request} status={@state} />
    <button
      :if={@state in [:none, :denied]}
      id={"add-#{@tmdb_id}"}
      phx-click="add"
      phx-value-tmdb_id={@tmdb_id}
      phx-disable-with="Adding…"
      class="btn btn-primary btn-sm w-full"
    >
      Add
    </button>
    """
  end

  # Filled in Task 4.
  attr :series, :list, required: true
  attr :confirming, :any, required: true
  defp series_admin_section(assigns), do: ~H""
end
```

- [ ] **Step 4: Point `/` at `DiscoverLive` and delete `WatchlistLive`**

In `lib/cinder_web/router.ex:59`:

```elixir
      live "/", DiscoverLive
```

Then:

```bash
git rm lib/cinder_web/live/watchlist_live.ex test/cinder_web/live/watchlist_live_test.exs
```

- [ ] **Step 5: Run the Discover tests**

Run: `mix test test/cinder_web/live/discover_live_test.exs`
Expected: PASS (all). If a movie test crashes on an unstubbed `:search_tv`, confirm the default `setup` block stubs both endpoints.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder_web/live/discover_live.ex lib/cinder_web/router.ex test/cinder_web/live/discover_live_test.exs
git commit -m "feat(ux-3): DiscoverLive — unified movie+TV search grid at / (replaces WatchlistLive)"
```

---

### Task 4: Relocate the admin "Added series" block; delete `SeriesLive`; redirect `/series`

**Files:**
- Modify: `lib/cinder_web/live/discover_live.ex` (fill in `series_admin_section/1`)
- Create: `lib/cinder_web/controllers/redirect_controller.ex`
- Modify: `lib/cinder_web/router.ex` (remove `live "/series", SeriesLive`; add `get "/series"` redirect)
- Delete: `lib/cinder_web/live/series_live.ex`, `test/cinder_web/live/series_live_test.exs`
- Modify: `test/cinder_web/live/discover_live_test.exs` (add admin-series + redirect cases)

**Interfaces:**
- Consumes: `Catalog.list_series/0`, `Catalog.subscribe_series/0`, `Catalog.cancel_series/2`, `Catalog.delete_series/2` (already wired in Task 3's mount/handlers); `<.media_card>`, `<.confirm_action>`.
- Produces: an admin-only `<section>` on Discover with `#series-list` grid; each row `#series-row-<id>` has `ask_cancel_series`/`ask_delete_series` buttons and `<.confirm_action>`s; `Configure monitoring →` links to `~p"/series/#{id}"`. `RedirectController.to_root/2` redirects `/series` → `/`.

- [ ] **Step 1: Add the failing tests**

Append to `test/cinder_web/live/discover_live_test.exs` (these port the relevant `series_live_test.exs` cases to the `/` page, plus the redirect):

```elixir
  describe "admin Added-series block" do
    test "admin sees the Added-series block with configure-monitoring links", %{conn: conn} do
      series =
        Cinder.Repo.insert!(%Cinder.Catalog.Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Managed Show",
          monitored: true,
          monitor_strategy: :all
        })

      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Added series"
      assert html =~ "Configure monitoring"
      assert html =~ ~s(href="/series/#{series.id}")
    end

    test "a non-admin does NOT see the Added-series block", %{conn: conn} do
      Cinder.Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Hidden",
        monitored: true,
        monitor_strategy: :all
      })

      user = Cinder.AccountsFixtures.user_fixture()
      conn = log_in_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/")
      refute html =~ "Added series"
      refute html =~ "ask_delete_series"
    end

    test "admin deletes an added series from the block", %{conn: conn} do
      series =
        Cinder.Repo.insert!(%Cinder.Catalog.Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Deletable",
          monitored: true,
          monitor_strategy: :all
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element(~s|button[phx-click="ask_delete_series"][phx-value-id="#{series.id}"]|)
      |> render_click()

      lv
      |> element(~s|button[phx-click="confirm_delete_series"][phx-value-id="#{series.id}"]|)
      |> render_click()

      assert Cinder.Repo.get(Cinder.Catalog.Series, series.id) == nil
      refute render(lv) =~ "series-row-#{series.id}"
    end

    test "a forged confirm_delete_series from a non-admin does NOT delete", %{conn: conn} do
      series =
        Cinder.Repo.insert!(%Cinder.Catalog.Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Forge Target",
          monitored: true,
          monitor_strategy: :all
        })

      user = Cinder.AccountsFixtures.user_fixture()
      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/")

      render_hook(lv, "confirm_delete_series", %{"id" => to_string(series.id)})

      assert Cinder.Repo.get(Cinder.Catalog.Series, series.id) != nil
      assert render(lv) =~ "Discover"
    end
  end

  test "the old /series route redirects to /", %{conn: conn} do
    conn = get(conn, ~p"/series")
    assert redirected_to(conn) == ~p"/"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/cinder_web/live/discover_live_test.exs`
Expected: FAIL — no Added-series block yet; `/series` still routes to `SeriesLive` (not a redirect).

- [ ] **Step 3: Fill in `series_admin_section/1`**

Replace the stub `series_admin_section/1` in `discover_live.ex` with:

```elixir
  attr :series, :list, required: true
  attr :confirming, :any, required: true

  defp series_admin_section(assigns) do
    ~H"""
    <section class="mt-10">
      <h2 class="pb-4 text-lg font-semibold leading-8">Added series</h2>
      <.empty_state
        :if={@series == []}
        icon="hero-tv"
        title="No series added yet"
        message="Search above to add a show."
      />
      <div id="series-list" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <div :for={s <- @series} id={"series-row-#{s.id}"} class="space-y-2">
          <.link navigate={~p"/series/#{s.id}"} class="block">
            <.media_card poster_path={s.poster_path} title={s.title} year={s.year}>
              <span class="link link-primary text-sm">Configure monitoring →</span>
            </.media_card>
          </.link>

          <div class="flex gap-2">
            <button
              type="button"
              class="btn btn-sm btn-warning"
              phx-click="ask_cancel_series"
              phx-value-id={s.id}
            >
              Cancel
            </button>
            <button
              type="button"
              class="btn btn-sm btn-error"
              phx-click="ask_delete_series"
              phx-value-id={s.id}
            >
              Delete
            </button>
          </div>

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
        </div>
      </div>
    </section>
    """
  end
```

> Touch-target note: the Cancel/Delete buttons were `btn-xs` on the old `/series`; bumped to `btn-sm` for the ≥44px mobile target (Global Constraints).

- [ ] **Step 4: Add the redirect controller + route; delete `SeriesLive`**

Create `lib/cinder_web/controllers/redirect_controller.ex`:

```elixir
defmodule CinderWeb.RedirectController do
  use CinderWeb, :controller

  # /series (the old TV-search page) folded into Discover in UX-3; keep the bookmark working.
  def to_root(conn, _params), do: redirect(conn, to: ~p"/")
end
```

In `lib/cinder_web/router.ex`: remove `live "/series", SeriesLive` (was `lib/cinder_web/router.ex:61`). Then add the redirect inside the same `scope "/", CinderWeb do ... end` (after the `live_session` blocks, before the scope's closing `end` at ~`lib/cinder_web/router.ex:90`):

```elixir
    # /series folded into Discover (UX-3); redirect old bookmarks.
    get "/series", RedirectController, :to_root
```

Then:

```bash
git rm lib/cinder_web/live/series_live.ex test/cinder_web/live/series_live_test.exs
```

- [ ] **Step 5: Run the Discover tests + confirm `/series/tmdb/:id` still works**

Run: `mix test test/cinder_web/live/discover_live_test.exs test/cinder_web/live/series_discovery_live_test.exs`
Expected: PASS. (`series_discovery_live_test.exs` is unchanged and must stay green — the season picker route is kept.)

- [ ] **Step 6: Commit**

```bash
git add lib/cinder_web/live/discover_live.ex lib/cinder_web/controllers/redirect_controller.ex lib/cinder_web/router.ex test/cinder_web/live/discover_live_test.exs
git commit -m "feat(ux-3): admin Added-series block on Discover; /series → / redirect; drop SeriesLive"
```

---

### Task 5: Sidebar nav label, graph refresh, full-suite green

**Files:**
- Modify: `lib/cinder_web/components/layouts.ex:74-79` (the "Search" nav item)
- Modify: `graphify-out/*` (regenerated)

- [ ] **Step 1: Rename the nav item**

In `lib/cinder_web/components/layouts.ex`, the first `<.nav_item>` (currently `label="Search"`, `navigate={~p"/"}`):

```elixir
            <.nav_item
              navigate={~p"/"}
              label="Discover"
              icon="hero-magnifying-glass"
              current_path={@current_path}
            />
```

- [ ] **Step 2: Check the app-shell test still passes (nav label)**

Run: `mix test test/cinder_web/live/app_shell_test.exs`
Expected: PASS. If it asserts the literal `"Search"` nav label, update that assertion to `"Discover"`.

- [ ] **Step 3: Full suite (the alias)**

Run: `mix test`
Expected: green — `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Fix anything that surfaces:
- A lingering reference to `WatchlistLive` / `SeriesLive` anywhere (grep `WatchlistLive`, `SeriesLive` across `lib/` and `test/` — only `SeriesDetailLive`/`SeriesDiscoveryLive` should remain).
- `credo` nesting/complexity on `DiscoverLive` (the merged module is larger; if credo flags the render, extract a sub-component — but prefer leaving it if clean).

- [ ] **Step 4: Refresh the knowledge graph**

Run: `graphify update .`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(ux-3): sidebar 'Discover' nav label; graphify refresh"
```

---

## Self-Review (against the UX-3 spec "Done when")

| Spec "Done when" clause | Covered by |
|---|---|
| conventions pass (`mix test` green) | Task 5 step 3 |
| one search returns + renders movies+TV together | Task 3 test "a single query returns movies AND TV together" |
| correct per-user movie state badges | Task 3 tests (pending badge, live status, available precedence via `title_state`) |
| requesting a movie still flows through `Cinder.Requests` | Task 3 tests (admin add → `:requested`; non-admin → pending, no `:requested`) |
| requesting a TV season still flows through `Cinder.Requests` | `series_discovery_live_test.exs` kept green (Task 4 step 5) — season request path unchanged |
| **regression: non-admin request creates no `:requested` row before approval** | Task 3 test "non-admin add creates a pending request, no :requested movie row" (`Catalog.list_by_status(:requested) == []`) |
| old split routes redirect | Task 4 test "the old /series route redirects to /" |
| grid reflows to 2 columns at 390px | `grid-cols-2 sm:grid-cols-3` on `#results`/`#watchlist`/`#series-list` (Tasks 3–4) |
| request affordances always rendered (not hover-only) | `result_action` Add button + TV `View seasons →` link rendered unconditionally in the card body (Task 3) |
| season picker fully operable by touch | kept `SeriesDiscoveryLive` (full page, `btn btn-primary btn-sm` Request buttons) — unchanged |

**Decisions locked (this plan):** (1) TV season picker = **dedicated route** (`/series/tmdb/:id`, `SeriesDiscoveryLive` reused) — not a modal. (2) Admin "Added series" management = **kept on Discover, admin-only** during UX-3; UX-4 moves it to Library. (3) Combined search runs **sequentially** (ponytail note: parallelize with `Task.await_many` if latency bites). (4) Mixed results **interleaved** round-robin so both kinds surface near the top on a 2-col mobile grid.

**Out of scope (noted, not done):** the global "Watchlist" movie grid and the "Added series" grid both stay on Discover for now — UX-4 (Library) consolidates these managed-catalog lists. `<.page>`/`<.media_card>` for `SeriesDiscoveryLive`'s own header poster is left as-is (the season picker is unchanged).
