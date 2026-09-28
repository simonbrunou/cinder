# TV per-season request/approval parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give TV the same multi-user request→approval→quota→my-requests→badge→grab loop movies have, at **season** granularity, via the existing `Cinder.Requests` gate made polymorphic on `target_type`.

**Architecture:** A season request is a `requests` row (`target_type: "season"`, `target_id:` series tmdb_id, `season_number: N`). The gate dispatches on `target_type`: `"movie"` keeps its exact path; `"season"` calls a new `Catalog.find_or_create_series_at_requested/2` that find-or-creates the series tree from TMDB and monitors **only** the requested season. The TV pages move `:admin → :authenticated`; requests happen on `/series/:id`; monitor toggles stay admin-gated inside the page. The TvPoller (unchanged) grabs the monitored season's wanted episodes.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView (HEEx), Ecto + `ecto_sqlite3`, ExUnit + Mox.

**Design spec:** `docs/specs/2026-06-23-tv-per-season-request-parity-design.md`.

## Global Constraints

- The gate (`Cinder.Requests`) is the **only** caller allowed to create a pipeline target from a user action; do not add a parallel TV request path.
- **The movie request/approval path stays byte-for-byte unchanged** — the `"movie"` clauses keep their exact current bodies (incl. the `Repo.transaction` wrapping). Season paths are *added* clauses.
- Every episode/season monitor write goes through the existing `Catalog` setters (`set_season_monitored/2`), never a raw `Repo.update_all`.
- Series creation does TMDB I/O, so it MUST run **outside** any `Repo.transaction`.
- `mix test` (the alias: `compile --warnings-as-errors` + `format --check-formatted` + `credo --strict` + suite) is green at every task's commit. Run it as the gate; targeted tests during a task are fine, but the commit step runs the alias.
- Monitor toggles on `/series/:id` and TV search-add are **admin-only**; requesting a season is open to all authenticated users.

---

### Task 1: `requests` schema — `season_number` + `"season"` target + season-aware uniqueness

**Files:**
- Create: `priv/repo/migrations/<gen-ts>_add_season_to_requests.exs`
- Modify: `lib/cinder/requests/request.ex`
- Test: `test/cinder/requests/request_test.exs` (create if absent)

**Interfaces:**
- Produces: `Request` schema gains `field :season_number, :integer`; `create_changeset/2` casts it, allowlists `target_type ∈ ["movie","series","season","episode"]`, and `unique_constraint`s on the new index name `:requests_user_target_season_index`.

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration add_season_to_requests`

- [ ] **Step 2: Write the migration**

Replace the generated `change/0`. The old unique index (`requests_user_id_target_type_target_id_index`) would collapse a user's season requests for one show into one row, so drop it and create a `COALESCE(season_number, -1)` expression index (movies' constant `-1` preserves their dedup; `S1`/`S2` of one show stay distinct):

```elixir
defmodule Cinder.Repo.Migrations.AddSeasonToRequests do
  use Ecto.Migration

  def change do
    alter table(:requests) do
      add :season_number, :integer
    end

    drop unique_index(:requests, [:user_id, :target_type, :target_id])

    create unique_index(
             :requests,
             [:user_id, :target_type, :target_id, "COALESCE(season_number, -1)"],
             name: :requests_user_target_season_index
           )
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `mix ecto.migrate`
Expected: `== Migrated <ts> in 0.0s` (creating the column + index).

- [ ] **Step 4: Write the failing changeset test**

In `test/cinder/requests/request_test.exs`:

```elixir
defmodule Cinder.Requests.RequestTest do
  use Cinder.DataCase, async: true
  alias Cinder.Requests.Request

  test "create_changeset casts a season request and accepts target_type \"season\"" do
    cs =
      Request.create_changeset(%Request{}, %{
        user_id: 1,
        target_type: "season",
        target_id: 1399,
        season_number: 2,
        title: "Game of Thrones",
        status: :pending
      })

    assert cs.valid?
    assert get_field(cs, :season_number) == 2
  end

  test "create_changeset rejects an unknown target_type" do
    cs =
      Request.create_changeset(%Request{}, %{
        user_id: 1,
        target_type: "bogus",
        target_id: 1,
        status: :pending
      })

    refute cs.valid?
    assert %{target_type: _} = errors_on(cs)
  end
end
```

- [ ] **Step 5: Run the test, verify it fails**

Run: `mix test test/cinder/requests/request_test.exs`
Expected: FAIL (`season_number` not cast / unknown field), or compile error if the field is missing.

- [ ] **Step 6: Add the field + update the changeset**

In `lib/cinder/requests/request.ex`: add `field :season_number, :integer` to the schema (after `:target_id`). Update `@target_types` to `["movie", "series", "season", "episode"]`. In `create_changeset/2`, add `:season_number` to the `cast/3` list, and change the `unique_constraint/2` `:name:` to `:requests_user_target_season_index`. (Leave `validate_required` as-is — `season_number` is nullable for movies.)

- [ ] **Step 7: Run the test, verify it passes**

Run: `mix test test/cinder/requests/request_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add priv/repo/migrations lib/cinder/requests/request.ex test/cinder/requests/request_test.exs
git commit -m "requests: add season_number + season-aware unique index"
```

---

### Task 2: `Catalog.find_or_create_series_at_requested/2` — create the tree, monitor one season

**Files:**
- Modify: `lib/cinder/catalog.ex` (add after `add_series_to_watchlist/2`, ~line 175)
- Test: `test/cinder/catalog_test.exs` (add a describe block)

**Interfaces:**
- Consumes: `add_series_to_watchlist/2` (with `monitor_strategy: :none`), `get_series_by_tmdb_id/1`, `get_series_with_tree/1`, `set_season_monitored/2` — all existing.
- Produces: `find_or_create_series_at_requested(tmdb_id, season_number) :: {:ok, %Series{}} | {:error, term()}`. Find-or-creates the series (tree from TMDB, nothing monitored), then monitors **only** `season_number` (cascading to its episodes) and sets `series.monitored: true`. Idempotent: re-calling for an already-monitored season is a no-op flip. NOT wrapped in a `Repo.transaction` (it does TMDB I/O).

- [ ] **Step 1: Write the failing tests**

In `test/cinder/catalog_test.exs`. The suite already mocks TMDB via `Cinder.Catalog.TMDBMock` (see existing series tests for the `get_series`/`get_season` stub shape). Add:

```elixir
describe "find_or_create_series_at_requested/2" do
  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 ->
      {:ok, %{tmdb_id: 1399, tvdb_id: 121361, title: "GoT", year: 2011, poster_path: nil,
              seasons: [%{season_number: 1}, %{season_number: 2}]}}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 1399, n ->
      {:ok, %{season_number: n,
              episodes: [%{tmdb_episode_id: n * 10 + 1, episode_number: 1, title: "e1",
                           air_date: ~D[2011-01-01]}]}}
    end)

    :ok
  end

  test "creates the series and monitors only the requested season" do
    assert {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 2)

    tree = Catalog.get_series_with_tree(series.id)
    assert tree.monitored
    s1 = Enum.find(tree.seasons, &(&1.season_number == 1))
    s2 = Enum.find(tree.seasons, &(&1.season_number == 2))
    refute s1.monitored
    assert s2.monitored
    assert Enum.all?(s2.episodes, & &1.monitored)
    refute Enum.any?(s1.episodes, & &1.monitored)
  end

  test "is idempotent and additive across seasons (S1 then S2 leaves both monitored)" do
    {:ok, series} = Catalog.find_or_create_series_at_requested(1399, 1)
    {:ok, ^series} = Catalog.find_or_create_series_at_requested(1399, 2)

    tree = Catalog.get_series_with_tree(series.id)
    assert Enum.find(tree.seasons, &(&1.season_number == 1)).monitored
    assert Enum.find(tree.seasons, &(&1.season_number == 2)).monitored
  end
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/catalog_test.exs`
Expected: FAIL (`find_or_create_series_at_requested/2` undefined).

- [ ] **Step 3: Implement the function**

In `lib/cinder/catalog.ex`, after `add_series_to_watchlist/2`:

```elixir
@doc """
Request-approval entry for TV: find-or-create the series tree (from TMDB, nothing monitored
on first create) and monitor **only** `season_number` (cascading to its episodes), leaving other
seasons untouched. Sets `series.monitored: true`. Idempotent and additive across seasons.

Does TMDB I/O on first create, so it must NOT be called inside a `Repo.transaction`.
Returns `{:ok, %Series{}}`, or `{:error, reason}` if the TMDB fetch fails or the season is absent.
"""
def find_or_create_series_at_requested(tmdb_id, season_number) do
  with {:ok, series} <- ensure_series(tmdb_id),
       %Season{} = season <- season_in(series, season_number) do
    {:ok, _} = set_season_monitored(season, true)
    {:ok, _} = mark_series_monitored(series)
    {:ok, series}
  else
    nil -> {:error, :season_not_found}
    {:error, _} = err -> err
  end
end

# Create with monitor_strategy: :none so NOTHING is monitored by default; the requested season
# is then flipped on explicitly. An existing series is returned as-is.
defp ensure_series(tmdb_id), do: add_series_to_watchlist(tmdb_id, monitor_strategy: :none)

defp season_in(series, season_number) do
  Repo.get_by(Season, series_id: series.id, season_number: season_number)
end

defp mark_series_monitored(series) do
  series |> Ecto.Changeset.change(monitored: true) |> Repo.update()
end
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder/catalog_test.exs`
Expected: PASS (both new tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_test.exs
git commit -m "catalog: find_or_create_series_at_requested/2 (monitor one season)"
```

---

### Task 3: `Requests` gate — dispatch on `target_type` (season path)

**Files:**
- Modify: `lib/cinder/requests.ex`
- Test: `test/cinder/requests_test.exs`

**Interfaces:**
- Consumes: `Catalog.find_or_create_series_at_requested/2` (Task 2).
- Produces: `create_request/2`, `approve_request/2` work for `target_type: "season"` attrs/rows. The `"movie"` clauses are unchanged. Season approval is NOT transaction-wrapped (TMDB I/O); it creates the series then updates/inserts the request.

- [ ] **Step 1: Write the failing tests**

In `test/cinder/requests_test.exs` (follow the existing movie tests for fixtures — `Cinder.AccountsFixtures.user_fixture/1`, an admin via `%{role: :admin}`, and the TMDBMock stub shape from Task 2):

```elixir
describe "season requests" do
  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 ->
      {:ok, %{tmdb_id: 1399, tvdb_id: 1, title: "GoT", year: 2011, poster_path: nil,
              seasons: [%{season_number: 1}, %{season_number: 2}]}}
    end)
    stub(Cinder.Catalog.TMDBMock, :get_season, fn 1399, n ->
      {:ok, %{season_number: n, episodes: [%{tmdb_episode_id: n, episode_number: 1,
              title: "e", air_date: ~D[2011-01-01]}]}}
    end)
    :ok
  end

  defp season_attrs do
    %{target_type: "season", target_id: 1399, season_number: 2, title: "GoT", year: 2011}
  end

  test "a non-admin season request is :pending and creates NO series (security gate)" do
    user = user_fixture()
    assert {:ok, req} = Requests.create_request(user, season_attrs())
    assert req.status == :pending
    assert Cinder.Catalog.get_series_by_tmdb_id(1399) == nil
  end

  test "approving a season request creates the series and monitors only that season" do
    user = user_fixture()
    admin = user_fixture(%{role: :admin})
    {:ok, req} = Requests.create_request(user, season_attrs())

    assert {:ok, approved} = Requests.approve_request(req, admin)
    assert approved.status == :approved

    series = Cinder.Catalog.get_series_by_tmdb_id(1399)
    tree = Cinder.Catalog.get_series_with_tree(series.id)
    assert Enum.find(tree.seasons, &(&1.season_number == 2)).monitored
    refute Enum.find(tree.seasons, &(&1.season_number == 1)).monitored
  end

  test "an admin's own season request auto-approves and creates the series immediately" do
    admin = user_fixture(%{role: :admin})
    assert {:ok, req} = Requests.create_request(admin, season_attrs())
    assert req.status == :approved
    assert Cinder.Catalog.get_series_by_tmdb_id(1399)
  end
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/requests_test.exs`
Expected: FAIL — the season approve path still calls the movie `find_or_create_at_requested`, so it creates a movie / errors rather than a series.

- [ ] **Step 3: Add the season clauses (movie clauses unchanged)**

In `lib/cinder/requests.ex`:

Add a `target_type`-matching `approve_request` clause **before** the existing one (keep the existing as the `"movie"` clause by adding `target_type: "movie"` to its head):

```elixir
def approve_request(%Request{status: :pending, target_type: "movie"} = request, %User{} = admin) do
  # ... EXISTING body, unchanged ...
end

def approve_request(%Request{status: :pending, target_type: "season"} = request, %User{} = admin) do
  # NOT transaction-wrapped: find_or_create_series_at_requested does TMDB I/O.
  with {:ok, _series} <-
         Catalog.find_or_create_series_at_requested(request.target_id, request.season_number),
       {:ok, approved} <-
         request
         |> Request.status_changeset(%{status: :approved, approved_by_id: admin.id})
         |> Repo.update() do
    announce_approved(approved)
    {:ok, approved}
  end
end

def approve_request(%Request{}, _admin), do: {:error, :not_pending}
```

Split `create_approved/3` the same way — keep the existing body as the `"movie"` branch, add a `"season"` branch that creates the series (no transaction) then inserts the request as approved:

```elixir
defp create_approved(user, %{target_type: "season"} = attrs, approver_id) do
  with {:ok, _series} <-
         Catalog.find_or_create_series_at_requested(attrs.target_id, attrs[:season_number]),
       {:ok, request} <-
         %Request{}
         |> Request.create_changeset(
           Map.merge(attrs, %{user_id: user.id, status: :approved, approved_by_id: approver_id})
         )
         |> Repo.insert() do
    announce_approved(request)
    {:ok, request}
  end
end

defp create_approved(user, attrs, approver_id) do
  # ... EXISTING movie body, unchanged ...
end
```

(`create_pending/2`, `over_quota?/1`, `deny_request/3`, `announce_approved/1` are already target-agnostic — leave them. The `movie_attrs`/`movie_attrs_from` helpers stay for the movie clauses.)

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder/requests_test.exs`
Expected: PASS (season + existing movie tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/requests.ex test/cinder/requests_test.exs
git commit -m "requests: dispatch season approvals to the series creator"
```

---

### Task 4: Routes — `/series` + a new `/series/tmdb/:tmdb_id` become authenticated; `/series/:id` stays admin

Two single-purpose detail surfaces (resolved seam): the **local** `/series/:id` stays admin-only for monitor management (unchanged); a **new** user-facing `/series/tmdb/:tmdb_id` (Task 6) is where any user requests a season from TMDB data. No in-page role-gating.

**Files:**
- Modify: `lib/cinder_web/router.ex`
- Test: `test/cinder_web/live/series_live_test.exs`

**Interfaces:**
- Produces: `/series` (search) and `/series/tmdb/:tmdb_id` (discovery detail) in the `:authenticated` live_session; `/series/:id` remains in `:admin`. The two patterns don't collide (`/series/tmdb/123` is 3 segments; `/series/123` is 2).

- [ ] **Step 1: Write the failing test**

```elixir
test "a non-admin can load /series but NOT the admin local detail /series/:id", %{conn: conn} do
  conn = log_in_user(conn, user_fixture())
  {:ok, _lv, _html} = live(conn, ~p"/series")
  assert {:error, {:redirect, _}} = live(conn, ~p"/series/1")
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/cinder_web/live/series_live_test.exs`
Expected: FAIL — `/series` is currently admin-only, so the first `live/2` redirects.

- [ ] **Step 3: Move/add the routes**

In `lib/cinder_web/router.ex`: move `live "/series", SeriesLive` from the `:admin` block into the `:authenticated` block, and add `live "/series/tmdb/:tmdb_id", SeriesDiscoveryLive` there too (the module lands in Task 6). **Leave `live "/series/:id", SeriesDetailLive` in the `:admin` block** (local monitor management stays admin-only).

- [ ] **Step 4: Run it, verify it passes**

Run: `mix test test/cinder_web/live/series_live_test.exs`
Expected: PASS (non-admin loads `/series`; `/series/1` redirects).

> Note: Step 3 references `SeriesDiscoveryLive`, created in Task 6 — the route won't compile until then. Either land Tasks 4+6 in one commit, or add the route in Task 6's commit. Recommended: do Step 3's `/series` move now and commit; add the `/series/tmdb/:tmdb_id` route line as the first edit of Task 6.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/router.ex test/cinder_web/live/series_live_test.exs
git commit -m "router: /series is authenticated; /series/:id stays admin"
```

---

### Task 5: `SeriesLive` — search navigates to detail; no admin-direct add

**Files:**
- Modify: `lib/cinder_web/live/series_live.ex`
- Test: `test/cinder_web/live/series_live_test.exs`

**Interfaces:**
- Produces: the search grid links each result to `~p"/series/tmdb/#{result.tmdb_id}"` (the request action lives on the discovery detail page, Task 6). The admin-direct `add`/`start_async` path and its button are removed.

- [ ] **Step 1: Write the failing test**

```elixir
test "search results link to the discovery detail page (by tmdb_id)", %{conn: conn} do
  conn = log_in_user(conn, user_fixture())
  # stub TMDBMock.search_tv to return one result with tmdb_id 1399 (see existing test setup)
  {:ok, lv, _} = live(conn, ~p"/series")
  html = lv |> form("#tv-search", %{q: "got"}) |> render_submit()
  assert html =~ ~s(href="/series/tmdb/1399") or has_element?(lv, ~s(a[href="/series/tmdb/1399"]))
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mix test test/cinder_web/live/series_live_test.exs`
Expected: FAIL — results currently render an admin "Add" button, not a discovery link.

- [ ] **Step 3: Replace add with a discovery link**

In `lib/cinder_web/live/series_live.ex`: in the search-results template, replace the admin "Add" button + its `phx-click="add"` handler with `<.link navigate={~p"/series/tmdb/#{result.tmdb_id}"}>` per result. Delete the `handle_event("add", ...)`/`handle_async` add path and any now-unused aliases/imports. No local-series lookup here — the discovery page (Task 6) is keyed by tmdb_id and fetches from TMDB, so this works for not-yet-added shows.

- [ ] **Step 4: Run it, verify it passes**

Run: `mix test test/cinder_web/live/series_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/live/series_live.ex test/cinder_web/live/series_live_test.exs
git commit -m "series: search grid links to the discovery detail page; drop admin-direct add"
```

---

### Task 6: New `SeriesDiscoveryLive` — TMDB-sourced seasons + per-season Request

A new **user-facing** page at `/series/tmdb/:tmdb_id`. Keyed by tmdb_id (not a local series id) so it works for not-yet-added shows. Read-only TMDB season list + per-season Request + the current user's per-season state badge. **No monitor toggles** — those stay on the admin `/series/:id`, which is untouched.

**Files:**
- Create: `lib/cinder_web/live/series_discovery_live.ex`
- Modify: `lib/cinder_web/router.ex` (add the `/series/tmdb/:tmdb_id` route line deferred from Task 4)
- Test: `test/cinder_web/live/series_discovery_live_test.exs`

**Interfaces:**
- Consumes: the TMDB behaviour (`Cinder.Catalog.TMDB`) via the configured impl for `get_series/1` (returns `%{tmdb_id, title, year, poster_path, seasons: [%{season_number: n}, …]}`); `Requests.create_request/2`, `Requests.list_for_user/1`, `Requests.subscribe/0`.
- Produces: a `"request_season"` event building `%{target_type: "season", target_id: tmdb_id, season_number: n, title: info.title, year: info.year, poster_path: info.poster_path}` → `Requests.create_request(current_user, attrs)`. (Resolve the TMDB impl the same way the contexts do — `Application.fetch_env!(:cinder, :tmdb)` — or, cleaner, add a thin `Catalog.tmdb_series(tmdb_id)` passthrough and call that; pick the passthrough so the LiveView doesn't reach into config.)

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule CinderWeb.SeriesDiscoveryLiveTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_global

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 ->
      {:ok, %{tmdb_id: 1399, tvdb_id: 1, title: "GoT", year: 2011, poster_path: nil,
              seasons: [%{season_number: 1}, %{season_number: 2}]}}
    end)
    :ok
  end

  test "lists seasons from TMDB with Request buttons for a not-yet-added show", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, lv, html} = live(conn, ~p"/series/tmdb/1399")
    assert html =~ "GoT"
    assert has_element?(lv, ~s(button[phx-value-season="1"]), "Request")
    assert has_element?(lv, ~s(button[phx-value-season="2"]), "Request")
  end

  test "requesting a season creates a pending request and swaps the button for a badge", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _} = live(conn, ~p"/series/tmdb/1399")
    html = lv |> element(~s(button[phx-value-season="2"]), "Request") |> render_click()
    assert [%{target_type: "season", target_id: 1399, season_number: 2, status: :pending}] =
             Cinder.Requests.list_for_user(user)
    assert html =~ "Pending"
  end
end
```

- [ ] **Step 2: Run them, verify they fail**

Run: `mix test test/cinder_web/live/series_discovery_live_test.exs`
Expected: FAIL — module/route does not exist.

- [ ] **Step 3: Add the route + the passthrough**

In `lib/cinder_web/router.ex` add (in `:authenticated`): `live "/series/tmdb/:tmdb_id", SeriesDiscoveryLive`.
In `lib/cinder/catalog.ex` add a thin passthrough: `def tmdb_series(tmdb_id), do: tmdb().get_series(tmdb_id)` (next to the other TMDB-backed reads).

- [ ] **Step 4: Implement `SeriesDiscoveryLive`**

`lib/cinder_web/live/series_discovery_live.ex`:
- `mount(%{"tmdb_id" => raw}, _session, socket)`: parse the id (`Integer.parse`; bail to a flash + redirect to `/series` on a non-numeric param — mirror `SeriesDetailLive`'s param parsing); `Catalog.tmdb_series(tmdb_id)` → on `{:error, _}` flash + redirect; assign `info`, `tmdb_id`, `current_user` (from scope), and `requests_by_season` = `Requests.list_for_user(user)` filtered to `target_type == "season" and target_id == tmdb_id`, `Map.new(& {&1.season_number, &1.status})`; `Requests.subscribe()`.
- Template: header (poster/title/year); a list of `info.seasons`; per season, if `@requests_by_season[n]` → a status badge (`Pending`/`Approved`/`Denied`), else `<button phx-click="request_season" phx-value-season={n}>Request</button>`. Mirror the movie request-button + badge markup/labels in `lib/cinder_web/live/watchlist_live.ex`.
- `handle_event("request_season", %{"season" => raw}, socket)`: parse the season int (tolerate non-numeric via the existing catch-all pattern), build the season attrs, `Requests.create_request(socket.assigns.current_user, attrs)`; on `{:ok, _}` reassign `requests_by_season` + info flash; on `{:error, :quota_exceeded}` a warning flash; on `{:error, %Ecto.Changeset{}}` (e.g. duplicate) an info flash. (Mirror `WatchlistLive`'s movie handler return-handling exactly.)
- `handle_info({event, _}, socket) when event in [:request_created, :request_approved, :request_denied]`: refresh `requests_by_season`.
- `handle_event(_, _, socket)`: `{:noreply, socket}` catch-all (house style).

- [ ] **Step 5: Run them, verify they pass**

Run: `mix test test/cinder_web/live/series_discovery_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder_web/live/series_discovery_live.ex lib/cinder_web/router.ex lib/cinder/catalog.ex test/cinder_web/live/series_discovery_live_test.exs
git commit -m "series discovery: /series/tmdb/:id — TMDB seasons + per-season Request (all users)"
```

---

### Task 7: `MyRequestsLive` + `RequestsLive` — render season requests

**Files:**
- Modify: `lib/cinder_web/live/my_requests_live.ex`, `lib/cinder_web/live/requests_live.ex`
- Test: `test/cinder_web/live/my_requests_live_test.exs`, `test/cinder_web/live/requests_live_test.exs`

**Interfaces:**
- Consumes: existing `Requests.list_for_user/1`, `Requests.list_pending/0`. No context change — these are render-only edits.

- [ ] **Step 1: Write the failing tests**

```elixir
# my_requests_live_test.exs
test "a season request shows the show and season", %{conn: conn} do
  user = user_fixture()
  {:ok, _} = Cinder.Requests.create_request(user, %{target_type: "season", target_id: 1399,
            season_number: 3, title: "GoT", year: 2011})   # stub TMDB for the admin/auto path if needed
  conn = log_in_user(conn, user)
  {:ok, _lv, html} = live(conn, ~p"/my-requests")
  assert html =~ "GoT"
  assert html =~ "Season 3"
end
```

(For `requests_live_test.exs`, assert a pending **season** request appears in the admin queue with its season label.)

- [ ] **Step 2: Run them, verify they fail**

Run: `mix test test/cinder_web/live/my_requests_live_test.exs test/cinder_web/live/requests_live_test.exs`
Expected: FAIL — the row renders no season number.

- [ ] **Step 3: Implement**

In both LiveViews' row markup, when `request.target_type == "season"`, render `"#{request.title} — Season #{request.season_number}"` (else the existing movie title). Keep the status badge logic; a season request's states are Pending/Approved/Denied (no extra state). This is a label-only change — no new handlers.

- [ ] **Step 4: Run them, verify they pass**

Run: `mix test test/cinder_web/live/my_requests_live_test.exs test/cinder_web/live/requests_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Full-suite gate + commit**

Run: `mix test`
Expected: PASS (full alias green; movie request/approval tests unchanged).

```bash
git add lib/cinder_web/live/my_requests_live.ex lib/cinder_web/live/requests_live.ex test/cinder_web/live/my_requests_live_test.exs test/cinder_web/live/requests_live_test.exs
git commit -m "requests UI: render per-season requests in my-requests + the admin queue"
```

---

### Task 8: Docs + graph refresh

**Files:**
- Modify: `README.md` (in-app config table / "How it works" — note TV is now request→approval like movies), `docs/operating.md` (TV requests), `CHANGELOG.md` (`[Unreleased]` Added: multi-user per-season TV requests; `/series` now user-facing).

- [ ] **Step 1: Update README + operating.md + CHANGELOG**

Add an `[Unreleased]` CHANGELOG entry: "TV is now a full multi-user request feature — any user requests a season on `/series/:id`, an admin approves, quota/My-requests/badges apply (parity with movies). `/series` pages moved admin→authenticated; monitor management stays admin-only." Mirror the movie wording in README's request section.

- [ ] **Step 2: Refresh the graph + commit**

```bash
graphify update .
git add README.md docs/operating.md CHANGELOG.md
git commit -m "docs: TV per-season requests reach parity with movies"
```

---

## Self-Review

**Spec coverage:** §1 data model → Task 1; §2 gate dispatch → Task 3; §3 season creation → Task 2; §4 routes/SeriesLive → Tasks 4–5; §4 user-facing season-pick → Task 6 (the new `SeriesDiscoveryLive`; the admin `/series/:id` is unchanged); §5 requester views → Task 7; testing → folded per task; docs → Task 8. All spec sections map to a task.

**Placeholder scan:** No "TBD"/"add error handling"/bare "write tests". The one soft spot — Task 6's exact HEEx — is delegated to "mirror the movie request-button + badge in `WatchlistLive`", referencing existing code (the established pattern), not a cross-task placeholder.

**Type consistency:** `find_or_create_series_at_requested/2` (Task 2) is the exact name called in Task 3. `target_type` values `"movie"`/`"season"` consistent across Tasks 1/3/6/7. `season_number` (Task 1 column) matches the attr key used in Tasks 3/6/7. Request attrs map shape (`target_type`/`target_id`/`season_number`/`title`/`year`/`poster_path`) is identical in Tasks 3 and 6. The discovery page is keyed by tmdb_id and never touches a local series row, so there is no tmdb-vs-local ambiguity; the admin `/series/:id` (local id) is untouched and stays admin-only.

**Seam resolved (was open):** "where a user picks a season for a not-yet-added show" → a dedicated user-facing `SeriesDiscoveryLive` at `/series/tmdb/:tmdb_id` (TMDB-sourced, request-only). The admin local detail `/series/:id` keeps monitor management, unchanged and admin-only — no in-page role-gating.
