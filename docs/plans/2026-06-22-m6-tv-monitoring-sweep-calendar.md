# M6 — TV monitoring sweep + TMDB refresh + calendar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the Sonarr monitoring loop — keep TMDB season/episode data fresh so the existing air-date eligibility fires on time, index the wanted-episodes query, and add an upcoming/calendar view.

**Architecture:** Air-date eligibility, monitor-strategy enforcement, and the wanted-driven sweep already exist (`Catalog.wanted_episodes/0`, `TvPoller.search_wanted/1`). This milestone adds: (1) a partial index backing the wanted query; (2) `Catalog.refresh_series/1` reconciling a series against TMDB keyed on `tmdb_episode_id`, driven by a long-interval `Cinder.Catalog.Refresher` GenServer; (3) `Catalog.upcoming_episodes/0` + `CinderWeb.CalendarLive`. The movie pipeline is untouched.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView/HEEx, Ecto + `ecto_sqlite3`, `Req`, ExUnit + Mox, daisyUI. Spec: `docs/specs/2026-06-22-m6-design.md`.

## Global Constraints

- `mix test` (the alias) is the source of truth: runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Must be green at every task boundary.
- External services reached **only** through behaviours, resolved at runtime via `Application.fetch_env!/2`; tests use Mox and never hit the network.
- **Every movie writer goes through `Catalog.transition`.** Episode pipeline writes (`file_path`/`grab_id`/counters) go through `Catalog.transition_episode/2`. Identity + monitoring writes do **not** (they are not pipeline state) — they use plain changesets, like `set_episode_monitored/2`.
- SQLite is pinned WAL + `busy_timeout`; multi-row writes per series wrap in **one `Repo.transaction`**.
- `config/test.exs` sets `start_poller: false`, so background GenServers don't auto-run in the suite.
- License GPL-3.0. After code changes, `graphify update .`.
- Ponytail: minimum code, name deliberate ceilings with a `ponytail:` comment.

---

### Task 1: Wanted-episodes partial index

**Files:**
- Create: `priv/repo/migrations/20260623120000_add_wanted_episodes_index.exs`
- Test: `test/cinder/catalog_tv_pipeline_test.exs` (add one `describe` block)

**Interfaces:**
- Consumes: existing `Catalog.wanted_episodes/0` query shape.
- Produces: a partial index named `episodes_wanted_index` on `episodes(air_date)`.

- [ ] **Step 1: Write the failing test**

Add to the end of `test/cinder/catalog_tv_pipeline_test.exs`, inside the module (before the final `end`). It aliases `Episode` already; `Repo` + `Ecto.Query` come from `DataCase`.

```elixir
  describe "wanted_episodes/0 index" do
    test "is backed by the partial wanted index (no full episodes scan)" do
      %{rows: idx_rows} =
        Repo.query!(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='episodes'"
        )

      assert "episodes_wanted_index" in List.flatten(idx_rows)

      q =
        from e in Episode,
          join: s in assoc(e, :season),
          where:
            s.season_number > 0 and e.monitored and is_nil(e.file_path) and is_nil(e.grab_id) and
              not is_nil(e.air_date) and e.air_date <= ^Date.utc_today(),
          select: e.id

      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, q)
      %{rows: plan_rows} = Repo.query!("EXPLAIN QUERY PLAN " <> sql, params)
      plan = plan_rows |> Enum.map(&Enum.join(&1, " ")) |> Enum.join("\n")

      refute plan =~ ~r/SCAN episodes\b/, "wanted query should not full-scan episodes:\n#{plan}"
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs -o "wanted index"` (or run the whole file).
Expected: FAIL — `"episodes_wanted_index" in ...` is false (index does not exist yet).

- [ ] **Step 3: Write the migration**

`priv/repo/migrations/20260623120000_add_wanted_episodes_index.exs`:

```elixir
defmodule Cinder.Repo.Migrations.AddWantedEpisodesIndex do
  use Ecto.Migration

  # M6: partial index backing Catalog.wanted_episodes/0. The monitored, file-less, grab-less,
  # aired set is a small slice of episodes, so a partial index on air_date is exactly what the
  # poller's per-tick sweep wants — no full episodes scan. (ecto_sqlite3 stores booleans as 1/0,
  # hence `monitored = 1`.)
  def change do
    create index(:episodes, [:air_date],
             where: "file_path IS NULL AND grab_id IS NULL AND monitored = 1",
             name: :episodes_wanted_index
           )
  end
end
```

- [ ] **Step 4: Migrate the test DB and run the test**

Run: `MIX_ENV=test mix ecto.migrate && mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: PASS. (The `sqlite_master` assertion is the deterministic check that the migration ran. The EXPLAIN `refute SCAN episodes` is a sanity check — if SQLite's planner output surprises you, inspect the printed `plan` and confirm `episodes` is accessed via *an* index, not a full `SCAN`; adjust the `refute` regex only if the real plan text differs, never to weaken "no full scan".)

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260623120000_add_wanted_episodes_index.exs test/cinder/catalog_tv_pipeline_test.exs
git commit -m "M6: partial index backing wanted_episodes/0"
```

---

### Task 2: `refresh_series/1` — TMDB reconciliation

**Files:**
- Modify: `lib/cinder/catalog/episode.ex` (add `refresh_changeset/2`)
- Modify: `lib/cinder/catalog/season.ex` (add `refresh_changeset/2`)
- Modify: `lib/cinder/catalog.ex` (add `require Logger`, `refresh_series/1` + private helpers)
- Create: `test/cinder/catalog_refresh_test.exs`

**Interfaces:**
- Consumes: `tmdb().get_series/1` → `%{tmdb_id, tvdb_id, title, year, poster_path, seasons: [%{season_number}]}`; `tmdb().get_season/2` → `%{season_number, episodes: [%{tmdb_episode_id, episode_number, title, air_date}]}`; existing private `fetch_seasons/2`, `monitored?/3`, `broadcast_series/1`.
- Produces: `Catalog.refresh_series(%Series{}) :: {:ok, %Series{}} | {:error, term()}`; `Episode.refresh_changeset/2`; `Season.refresh_changeset/2`.

- [ ] **Step 1: Write the failing tests**

Create `test/cinder/catalog_refresh_test.exs`:

```elixir
defmodule Cinder.CatalogRefreshTest do
  # async: false — refresh_series wraps a Repo.transaction; the SQLite sandbox needs shared mode
  # for nested transactions (same reason as catalog_tv_pipeline_test.exs).
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season, Series}

  setup :verify_on_exit!

  @past ~D[2001-01-01]
  @future ~D[2099-01-01]

  defp series(strategy, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2008,
          monitored: strategy != :none,
          monitor_strategy: strategy
        },
        attrs
      )
    )
  end

  defp season(series, number) do
    Repo.insert!(%Season{series_id: series.id, season_number: number, monitored: true})
  end

  defp episode(season, attrs) do
    Repo.insert!(
      struct(
        %Episode{season_id: season.id, episode_number: 1, monitored: true, air_date: @past},
        attrs
      )
    )
  end

  # Stub TMDB to return the given seasons. `specs` is [{season_number, [episode_map]}].
  defp stub_tmdb(series, specs) do
    tmdb_id = series.tmdb_id
    season_numbers = for {n, _} <- specs, do: %{season_number: n}

    stub(Cinder.Catalog.TMDBMock, :get_series, fn ^tmdb_id ->
      {:ok,
       %{
         tmdb_id: tmdb_id,
         tvdb_id: nil,
         title: "Show",
         year: 2008,
         poster_path: nil,
         seasons: season_numbers
       }}
    end)

    by_number = Map.new(specs)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, n ->
      {:ok, %{season_number: n, episodes: Map.fetch!(by_number, n)}}
    end)
  end

  test "fills a late air_date on a matched episode, preserving monitored" do
    s = series(:future)
    sn = season(s, 1)
    ep = episode(sn, %{tmdb_episode_id: 500, episode_number: 1, air_date: nil, monitored: true})

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 500, episode_number: 1, title: "Now Dated", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)

    r = Repo.get!(Episode, ep.id)
    assert r.air_date == @past
    assert r.title == "Now Dated"
    assert r.monitored
    assert is_nil(r.file_path)
  end

  test "updates title/air_date in place but preserves file_path and monitored on a match" do
    s = series(:all)
    sn = season(s, 1)

    ep =
      episode(sn, %{
        tmdb_episode_id: 510,
        episode_number: 1,
        title: "Old",
        monitored: false,
        file_path: "/lib/x.mkv"
      })

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 510, episode_number: 1, title: "New", air_date: ~D[2002-02-02]}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    r = Repo.get!(Episode, ep.id)
    assert r.title == "New"
    assert r.air_date == ~D[2002-02-02]
    assert r.file_path == "/lib/x.mkv"
    refute r.monitored
  end

  test "renumbers a matched episode in place (by tmdb_episode_id), no duplicate row" do
    s = series(:all)
    sn = season(s, 1)
    ep = episode(sn, %{tmdb_episode_id: 520, episode_number: 2})

    # Same tmdb episode, now numbered 5 (no existing E5 → no collision).
    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 520, episode_number: 5, title: "Moved", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    assert Repo.get!(Episode, ep.id).episode_number == 5
    assert Repo.aggregate(from(e in Episode, where: e.season_id == ^sn.id), :count) == 1
  end

  test "inserts a genuinely new episode, applying the series monitor_strategy" do
    s = series(:future)
    sn = season(s, 1)
    episode(sn, %{tmdb_episode_id: 530, episode_number: 1, monitored: false})

    stub_tmdb(s, [
      {1,
       [
         %{tmdb_episode_id: 530, episode_number: 1, title: "Aired", air_date: @past},
         %{tmdb_episode_id: 531, episode_number: 2, title: "Future", air_date: @future}
       ]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    new = Repo.get_by!(Episode, tmdb_episode_id: 531)
    assert new.episode_number == 2
    assert new.monitored, "a future episode is monitored under :future"
  end

  test "inserts a new season and its episodes" do
    s = series(:all)
    s1 = season(s, 1)
    episode(s1, %{tmdb_episode_id: 540, episode_number: 1})

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 540, episode_number: 1, title: "E1", air_date: @past}]},
      {2, [%{tmdb_episode_id: 550, episode_number: 1, title: "S2E1", air_date: @future}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    s2 = Repo.get_by!(Season, series_id: s.id, season_number: 2)
    assert s2.monitored
    assert Repo.get_by!(Episode, tmdb_episode_id: 550).season_id == s2.id
  end

  test "leaves a row that vanished from TMDB untouched" do
    s = series(:all)
    sn = season(s, 1)
    keep = episode(sn, %{tmdb_episode_id: 560, episode_number: 1})
    gone = episode(sn, %{tmdb_episode_id: 561, episode_number: 2, file_path: "/lib/gone.mkv"})

    stub_tmdb(s, [
      {1, [%{tmdb_episode_id: 560, episode_number: 1, title: "Kept", air_date: @past}]}
    ])

    assert {:ok, _} = Catalog.refresh_series(s)
    assert Repo.get!(Episode, gone.id).file_path == "/lib/gone.mkv"
    assert Repo.get!(Episode, keep.id).title == "Kept"
  end

  test "a TMDB failure returns the error and writes nothing" do
    s = series(:all)
    sn = season(s, 1)
    ep = episode(sn, %{tmdb_episode_id: 570, episode_number: 1, title: "Original"})

    expect(Cinder.Catalog.TMDBMock, :get_series, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Catalog.refresh_series(s)
    assert Repo.get!(Episode, ep.id).title == "Original"
  end

  test "broadcasts {:series_updated, id} on success" do
    s = series(:all)
    season(s, 1)
    stub_tmdb(s, [{1, []}])
    Catalog.subscribe_series()
    id = s.id

    assert {:ok, _} = Catalog.refresh_series(s)
    assert_receive {:series_updated, ^id}
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog_refresh_test.exs`
Expected: FAIL — `Catalog.refresh_series/1` is undefined.

- [ ] **Step 3: Add the changesets**

In `lib/cinder/catalog/episode.ex`, add after `transition_changeset/2` (before the final `end`):

```elixir
  @doc """
  Changeset for the M6 TMDB refresh (`Catalog.refresh_series/1`): identity + placement only.
  `monitored` is castable (set on a brand-new episode) but the refresh caller omits it when
  *updating* an existing row, so a user's monitor toggle is preserved. The `(season_id,
  episode_number)` unique + season FK constraints are registered so a renumber collision returns
  `{:error, changeset}` (and Ecto wraps the write in a savepoint) instead of raising inside the
  reconcile transaction.
  """
  def refresh_changeset(episode, attrs) do
    episode
    |> cast(attrs, [:season_id, :tmdb_episode_id, :episode_number, :title, :air_date, :monitored])
    |> validate_required([:season_id, :episode_number])
    |> unique_constraint([:season_id, :episode_number])
    |> foreign_key_constraint(:season_id)
  end
```

In `lib/cinder/catalog/season.ex`, add after `nested_changeset/2` (before the final `end`):

```elixir
  @doc """
  Changeset for inserting a season discovered by the M6 TMDB refresh (`Catalog.refresh_series/1`),
  outside the `cast_assoc` create path. Registers the `(series_id, season_number)` unique + series
  FK constraints so an unexpected duplicate returns `{:error, changeset}` rather than raising.
  """
  def refresh_changeset(season, attrs) do
    season
    |> cast(attrs, [:series_id, :season_number, :monitored])
    |> validate_required([:series_id, :season_number])
    |> unique_constraint([:series_id, :season_number])
    |> foreign_key_constraint(:series_id)
  end
```

- [ ] **Step 4: Implement `refresh_series/1` in `lib/cinder/catalog.ex`**

At the top of the module, add `require Logger` immediately after `import Ecto.Query` (line 8):

```elixir
  import Ecto.Query
  require Logger
```

Add the following just after `wanted_episodes/0` ends (after `catalog.ex:543`), inside the module:

```elixir
  @doc """
  Re-fetches `series` from TMDB and reconciles its season/episode tree in one transaction, then
  broadcasts `{:series_updated, series.id}` once. Existing episodes are matched by
  `tmdb_episode_id` (series-wide, so a renumber that moves an episode across seasons is handled)
  and updated in place — preserving `monitored`, `file_path`, `grab_id`, and the attempt counters.
  Genuinely new episodes are inserted with `monitored` per the series' `monitor_strategy`; new
  seasons are inserted; rows that vanished from TMDB are left untouched.

  Returns `{:ok, series}`, or `{:error, reason}` if a TMDB fetch fails (short-circuits before any
  write, mirroring `create_series/2`).
  """
  def refresh_series(%Series{} = series) do
    with {:ok, info} <- tmdb().get_series(series.tmdb_id),
         {:ok, seasons} <- fetch_seasons(series.tmdb_id, info.seasons) do
      {:ok, _} = Repo.transaction(fn -> reconcile_tree(series, seasons) end)
      broadcast_series(series.id)
      {:ok, series}
    end
  end

  defp reconcile_tree(series, fetched_seasons) do
    today = Date.utc_today()
    existing_seasons = Map.new(seasons_for(series.id), &{&1.season_number, &1})
    by_tmdb = Map.new(episodes_for(series.id), &{&1.tmdb_episode_id, &1})

    Enum.each(fetched_seasons, fn fs ->
      case ensure_season(series, existing_seasons, fs.season_number) do
        %Season{} = season ->
          Enum.each(fs.episodes, &reconcile_episode(series, season, &1, by_tmdb, today))

        nil ->
          :ok
      end
    end)
  end

  defp seasons_for(series_id), do: Repo.all(from s in Season, where: s.series_id == ^series_id)

  defp episodes_for(series_id) do
    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where: s.series_id == ^series_id and not is_nil(e.tmdb_episode_id)
    )
  end

  defp ensure_season(_series, existing, number) when is_map_key(existing, number),
    do: Map.fetch!(existing, number)

  defp ensure_season(series, _existing, number) do
    attrs = %{
      series_id: series.id,
      season_number: number,
      monitored: series.monitor_strategy != :none
    }

    case %Season{} |> Season.refresh_changeset(attrs) |> Repo.insert() do
      {:ok, season} ->
        season

      {:error, changeset} ->
        Logger.warning(
          "refresh skipped new season #{number} of series #{series.id}: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  defp reconcile_episode(series, season, fe, by_tmdb, today) do
    case Map.get(by_tmdb, fe.tmdb_episode_id) do
      %Episode{} = existing -> update_episode(existing, season, fe)
      nil -> insert_episode(series, season, fe, today)
    end
  end

  # monitored/file_path/grab_id/counters omitted from attrs → preserved.
  defp update_episode(existing, season, fe) do
    existing
    |> Episode.refresh_changeset(%{
      season_id: season.id,
      episode_number: fe.episode_number,
      title: fe.title,
      air_date: fe.air_date
    })
    |> Repo.update()
    |> log_reconcile_error("update episode #{existing.id}")
  end

  defp insert_episode(series, season, fe, today) do
    %Episode{}
    |> Episode.refresh_changeset(%{
      season_id: season.id,
      tmdb_episode_id: fe.tmdb_episode_id,
      episode_number: fe.episode_number,
      title: fe.title,
      air_date: fe.air_date,
      monitored: monitored?(series.monitor_strategy, fe.air_date, today)
    })
    |> Repo.insert()
    |> log_reconcile_error("insert episode tmdb_ep #{fe.tmdb_episode_id}")
  end

  defp log_reconcile_error({:ok, _} = ok, _context), do: ok

  defp log_reconcile_error({:error, changeset}, context) do
    # A renumber collision on (season_id, episode_number) lands here: log and continue so the rest
    # of the tree still reconciles. ponytail: such a collision self-heals over refresh cycles as
    # the colliding row also moves; two-pass renumber is the upgrade path if it ever matters.
    Logger.warning("refresh skipped #{context}: #{inspect(changeset.errors)}")
    :ok
  end
```

Also update the stale note in `add_series_to_watchlist/2`'s `@doc` (around `catalog.ex:155`): change `"an already-added series is returned as-is — no re-sync (that's M6)."` to `"an already-added series is returned as-is; re-sync is `refresh_series/1` (the periodic Refresher)."`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog_refresh_test.exs`
Expected: PASS (all 8). If the savepoint-on-constraint behaviour of `ecto_sqlite3` surprises any test (none here force a collision), inspect the failure — the required tests use only non-colliding renumbers, so they must pass.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/catalog/episode.ex lib/cinder/catalog/season.ex lib/cinder/catalog.ex test/cinder/catalog_refresh_test.exs
git commit -m "M6: Catalog.refresh_series/1 — TMDB reconciliation by tmdb_episode_id"
```

---

### Task 3: Done-when integration — late air-date fill → auto-grab

**Files:**
- Test: `test/cinder/download/tv_poller_test.exs` (add one test, reusing the file's helpers)

**Interfaces:**
- Consumes: `Catalog.refresh_series/1` (Task 2), `Catalog.wanted_episodes/0`, `TvPoller.poll/0` (existing).
- Produces: none (verification only).

- [ ] **Step 1: Write the failing test**

Add to `test/cinder/download/tv_poller_test.exs`, inside the module (the file already has `setup :set_mox_global`, `@past`, and aliases `Catalog`, `Episode`, `Grab`, `Season`, `Series`, `TvPoller`):

```elixir
  test "a late-dated monitored episode becomes wanted after a refresh and grabs (M6 Done-when)" do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        tvdb_id: 99,
        title: "Show",
        year: 2008,
        monitored: true,
        monitor_strategy: :future
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})

    # Announced but undated → monitored under :future, yet NOT wanted (air_date is nil).
    ep =
      Repo.insert!(%Episode{
        season_id: season.id,
        tmdb_episode_id: 700,
        episode_number: 1,
        monitored: true,
        air_date: nil
      })

    assert Catalog.wanted_episodes() == []

    # TMDB now carries a (past) air_date for the same episode.
    stub(Cinder.Catalog.TMDBMock, :get_series, fn _ ->
      {:ok,
       %{
         tmdb_id: series.tmdb_id,
         tvdb_id: 99,
         title: "Show",
         year: 2008,
         poster_path: nil,
         seasons: [%{season_number: 1}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn _, 1 ->
      {:ok,
       %{
         season_number: 1,
         episodes: [%{tmdb_episode_id: 700, episode_number: 1, title: "Aired", air_date: @past}]
       }}
    end)

    assert {:ok, _} = Catalog.refresh_series(series)
    assert [%Episode{id: id}] = Catalog.wanted_episodes()
    assert id == ep.id

    # The poller now finds and grabs it.
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [%{title: "Show.S01E01.1080p.WEB-DL-GRP", size: 2_000_000_000, download_url: "u", seeders: 5}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-m6"} end)

    assert :ok = TvPoller.poll()

    linked = Repo.get!(Episode, ep.id)
    assert linked.grab_id
    assert Repo.get!(Grab, linked.grab_id).download_id == "hash-m6"
  end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/cinder/download/tv_poller_test.exs`
Expected: PASS (Task 2 already provides `refresh_series/1`; this only proves the end-to-end chain). If it fails, the failure is the real signal that the chain is broken — debug before proceeding.

- [ ] **Step 3: Commit**

```bash
git add test/cinder/download/tv_poller_test.exs
git commit -m "M6: Done-when test — late air-date fill makes an episode grab automatically"
```

---

### Task 4: `Cinder.Catalog.Refresher` GenServer + supervision

**Files:**
- Create: `lib/cinder/catalog/refresher.ex`
- Modify: `lib/cinder/application.ex:80-86` (`poller_child/0`)
- Create: `test/cinder/catalog/refresher_test.exs`

**Interfaces:**
- Consumes: `Catalog.list_series/0`, `Catalog.refresh_series/1` (Task 2).
- Produces: `Cinder.Catalog.Refresher.start_link/1`, `Cinder.Catalog.Refresher.poll/0..1`.

- [ ] **Step 1: Write the failing tests**

Create `test/cinder/catalog/refresher_test.exs`:

```elixir
defmodule Cinder.Catalog.RefresherTest do
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Catalog.{Season, Series}
  alias Cinder.Catalog.Refresher

  # The Refresher runs in its own process, so the mock must be global; shared Sandbox
  # (async: false) lets that process use the test-owned DB connection.
  setup :set_mox_global
  setup :verify_on_exit!

  test "poll refreshes every monitored series and skips unmonitored ones" do
    monitored =
      Repo.insert!(%Series{tmdb_id: 8001, title: "M", monitored: true, monitor_strategy: :all})

    Repo.insert!(%Season{series_id: monitored.id, season_number: 1, monitored: true})
    Repo.insert!(%Series{tmdb_id: 8002, title: "U", monitored: false, monitor_strategy: :none})

    # Only 8001 is fetched; a stray get_series(8002) would fail verify_on_exit! (no expectation).
    expect(Cinder.Catalog.TMDBMock, :get_series, fn 8001 ->
      {:ok,
       %{
         tmdb_id: 8001,
         tvdb_id: nil,
         title: "M",
         year: nil,
         poster_path: nil,
         seasons: [%{season_number: 1}]
       }}
    end)

    expect(Cinder.Catalog.TMDBMock, :get_season, fn 8001, 1 ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    start_supervised!({Refresher, interval: 60_000})
    assert :ok = Refresher.poll()
  end

  test "an error refreshing one series does not abort the tick" do
    Repo.insert!(%Series{tmdb_id: 8101, title: "A", monitored: true, monitor_strategy: :all})
    b = Repo.insert!(%Series{tmdb_id: 8102, title: "B", monitored: true, monitor_strategy: :all})
    Repo.insert!(%Season{series_id: b.id, season_number: 1, monitored: true})

    stub(Cinder.Catalog.TMDBMock, :get_series, fn
      8101 -> raise "boom"
      8102 -> {:ok, %{tmdb_id: 8102, tvdb_id: nil, title: "B", year: nil, poster_path: nil, seasons: [%{season_number: 1}]}}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 8102, 1 ->
      {:ok, %{season_number: 1, episodes: []}}
    end)

    start_supervised!({Refresher, interval: 60_000})
    # The raise on series A is isolated; the tick completes.
    assert :ok = Refresher.poll()
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog/refresher_test.exs`
Expected: FAIL — `Cinder.Catalog.Refresher` is undefined.

- [ ] **Step 3: Implement the GenServer**

Create `lib/cinder/catalog/refresher.ex`:

```elixir
defmodule Cinder.Catalog.Refresher do
  @moduledoc """
  Periodically re-fetches every monitored series from TMDB and reconciles its tree via
  `Cinder.Catalog.refresh_series/1`, so a late-filled `air_date` or a newly-announced
  episode/season becomes visible to the TV poller's wanted-episodes sweep. Mirrors the poller
  skeleton (self-rescheduling `Process.send_after`) but on a long interval (12h by default) —
  household-scale TMDB load is trivial. Holds no state; each tick re-derives its work from the
  DB, so it recovers cleanly after a crash. `:start_poller`-gated like the pollers, so the suite
  doesn't auto-run it.

  The interval is module config, not a `/settings` field (no string→int coercion seam exists in
  `Cinder.Settings`, and one interval doesn't justify adding one):
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.
  """
  use GenServer

  require Logger

  alias Cinder.Catalog

  @default_interval :timer.hours(12)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one refresh pass synchronously. The scheduled timer path is asynchronous."
  # :infinity — a full refresh issues 1 + N TMDB calls per series and can exceed the default
  # 5s call timeout on a large library; the caller (tests) is fine to wait.
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config_interval())
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    do_poll()
    {:reply, :ok, state}
  end

  defp do_poll do
    for series <- Catalog.list_series(), series.monitored do
      isolate("series #{series.id}", fn -> Catalog.refresh_series(series) end)
    end

    :ok
  end

  # Per-series isolation: a raise OR exit (e.g. a TMDB-layer crash, or a DBConnection checkout
  # timeout under write contention — not rescue-able) skips that series instead of the whole tick.
  defp isolate(label, fun) do
    fun.()
  rescue
    e -> Logger.error("refresher skipped #{label}: #{Exception.message(e)}")
  catch
    kind, value -> Logger.error("refresher skipped #{label}: #{inspect({kind, value})}")
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval, @default_interval)
  end
end
```

- [ ] **Step 4: Wire it into the supervision tree**

In `lib/cinder/application.ex`, change `poller_child/0` to include the Refresher:

```elixir
  defp poller_child do
    if Application.get_env(:cinder, :start_poller, true) do
      [Cinder.Download.Poller, Cinder.Download.TvPoller, Cinder.Catalog.Refresher]
    else
      []
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog/refresher_test.exs`
Expected: PASS (both).

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/catalog/refresher.ex lib/cinder/application.ex test/cinder/catalog/refresher_test.exs
git commit -m "M6: Catalog.Refresher GenServer (12h TMDB refresh, :start_poller-gated)"
```

---

### Task 5: `Catalog.upcoming_episodes/0`

**Files:**
- Modify: `lib/cinder/catalog.ex` (add `upcoming_episodes/0`)
- Test: `test/cinder/catalog_tv_pipeline_test.exs` (add one `describe` block)

**Interfaces:**
- Produces: `Catalog.upcoming_episodes() :: [%Episode{}]` with `season: :series` preloaded, ordered ascending by `air_date`.

- [ ] **Step 1: Write the failing tests**

Add to `test/cinder/catalog_tv_pipeline_test.exs` (it has the `series_with_season/0` and `episode/2` helpers, and aliases `Season`):

```elixir
  describe "upcoming_episodes/0" do
    test "returns monitored, dated, in-window, non-special episodes ordered by air_date" do
      {series, season} = series_with_season()
      today = Date.utc_today()
      recent = episode(season, %{air_date: Date.add(today, -3), monitored: true})
      soon = episode(season, %{air_date: Date.add(today, 10), monitored: true})

      # Excluded: before the window, after the window, undated, unmonitored, specials.
      episode(season, %{air_date: Date.add(today, -30), monitored: true})
      episode(season, %{air_date: Date.add(today, 200), monitored: true})
      episode(season, %{air_date: nil, monitored: true})
      episode(season, %{air_date: Date.add(today, 5), monitored: false})
      specials = Repo.insert!(%Season{series_id: series.id, season_number: 0, monitored: true})
      episode(specials, %{air_date: Date.add(today, 2), monitored: true})

      assert Enum.map(Catalog.upcoming_episodes(), & &1.id) == [recent.id, soon.id]
    end

    test "preloads season and series" do
      {series, season} = series_with_season()
      episode(season, %{air_date: Date.utc_today()})

      assert [ep] = Catalog.upcoming_episodes()
      assert ep.season.series.id == series.id
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: FAIL — `Catalog.upcoming_episodes/0` is undefined.

- [ ] **Step 3: Implement `upcoming_episodes/0`**

In `lib/cinder/catalog.ex`, add after `wanted_episodes/0` (and after `refresh_series/1` and its helpers from Task 2 — placement only needs to be inside the module):

```elixir
  @doc """
  Monitored, dated episodes in a calendar window (`today - 7 .. today + 90`), ordered by air date,
  with `season: :series` preloaded for the calendar view. Excludes season 0 (specials, never
  searched in M5) so the view's derived "wanted" badge stays honest.
  """
  def upcoming_episodes do
    today = Date.utc_today()
    from_date = Date.add(today, -7)
    to_date = Date.add(today, 90)

    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where:
          s.season_number > 0 and e.monitored and not is_nil(e.air_date) and
            e.air_date >= ^from_date and e.air_date <= ^to_date,
        order_by: [asc: e.air_date],
        preload: [season: :series]
    )
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_tv_pipeline_test.exs
git commit -m "M6: Catalog.upcoming_episodes/0 — windowed monitored episodes for the calendar"
```

---

### Task 6: `CinderWeb.CalendarLive` + route + nav

**Files:**
- Create: `lib/cinder_web/live/calendar_live.ex`
- Modify: `lib/cinder_web/router.ex:62-74` (add route to the `:admin` `live_session`)
- Modify: `lib/cinder_web/components/layouts/root.html.heex:43-56` (nav link in the admin block)
- Create: `test/cinder_web/live/calendar_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.upcoming_episodes/0` (Task 5), `Catalog.subscribe_series/0`.
- Produces: a LiveView at `/calendar` (admin-gated).

- [ ] **Step 1: Write the failing tests**

Create `test/cinder_web/live/calendar_live_test.exs`:

```elixir
defmodule CinderWeb.CalendarLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures

  alias Cinder.Repo
  alias Cinder.Catalog.{Episode, Season, Series}

  setup :register_and_log_in_admin

  defp tree do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Calendar Show",
        year: 2020,
        monitored: true,
        monitor_strategy: :all
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
    {series, season}
  end

  test "renders monitored upcoming episodes with state badges", %{conn: conn} do
    {_series, season} = tree()
    today = Date.utc_today()

    Repo.insert!(%Episode{
      season_id: season.id,
      episode_number: 1,
      title: "Coming Soon",
      monitored: true,
      air_date: Date.add(today, 5)
    })

    Repo.insert!(%Episode{
      season_id: season.id,
      episode_number: 2,
      title: "Just Aired",
      monitored: true,
      air_date: Date.add(today, -1)
    })

    {:ok, _lv, html} = live(conn, ~p"/calendar")

    assert html =~ "Calendar Show"
    assert html =~ "S01E01"
    assert html =~ "Coming Soon"
    assert html =~ "Upcoming"
    assert html =~ "S01E02"
    assert html =~ "Wanted"
  end

  test "shows an empty state when nothing is scheduled", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/calendar")
    assert html =~ "No monitored episodes scheduled"
  end

  test "a non-admin cannot reach the calendar", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/calendar")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder_web/live/calendar_live_test.exs`
Expected: FAIL — no `/calendar` route (`live/2` raises / redirects unexpectedly).

- [ ] **Step 3: Implement the LiveView**

Create `lib/cinder_web/live/calendar_live.ex`:

```elixir
defmodule CinderWeb.CalendarLive do
  @moduledoc """
  Admin-only upcoming/calendar view at `/calendar`: monitored episodes in a date window
  (`today - 7 .. today + 90`), ordered by air date, each with a derived pipeline-state badge.
  Read-only — subscribes to the `"series"` topic so badges advance live as the poller works.
  """
  use CinderWeb, :live_view

  alias Cinder.Catalog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe_series()
    {:ok, assign_rows(socket)}
  end

  @impl true
  def handle_info({:series_updated, _id}, socket), do: {:noreply, assign_rows(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_rows(socket) do
    today = Date.utc_today()

    rows =
      for ep <- Catalog.upcoming_episodes() do
        {label, class} = badge(ep, today)
        %{ep: ep, label: label, class: class}
      end

    assign(socket, rows: rows)
  end

  # Derived episode state (no status enum): a file ⇒ available, an active grab ⇒ downloading,
  # an aired-but-missing monitored episode ⇒ wanted, else still upcoming.
  defp badge(ep, today) do
    cond do
      ep.file_path -> {"Available", "badge-success"}
      ep.grab_id -> {"Downloading", "badge-info"}
      Date.compare(ep.air_date, today) != :gt -> {"Wanted", "badge-warning"}
      true -> {"Upcoming", "badge-ghost"}
    end
  end

  defp code(season, episode), do: "S#{pad(season)}E#{pad(episode)}"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="mb-6 text-2xl font-semibold">Upcoming</h1>

      <p :if={@rows == []} class="text-base-content/60">
        No monitored episodes scheduled in the next 90 days.
      </p>

      <table :if={@rows != []} class="table">
        <thead>
          <tr>
            <th>Air date</th>
            <th>Series</th>
            <th>Episode</th>
            <th>Title</th>
            <th>State</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td class="tabular-nums">{row.ep.air_date}</td>
            <td>{row.ep.season.series.title}</td>
            <td class="tabular-nums">{code(row.ep.season.season_number, row.ep.episode_number)}</td>
            <td>{row.ep.title}</td>
            <td><span class={["badge badge-sm", row.class]}>{row.label}</span></td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Add the route**

In `lib/cinder_web/router.ex`, inside the `live_session :admin` block (after `live "/series/:id", SeriesDetailLive`, ~line 73):

```elixir
      live "/calendar", CalendarLive
```

- [ ] **Step 5: Add the nav link**

In `lib/cinder_web/components/layouts/root.html.heex`, inside the admin block (`@current_scope.user.role == :admin`), add after the Status `<li>` (after line 49):

```heex
          <li>
            <.link navigate={~p"/calendar"}>Calendar</.link>
          </li>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/cinder_web/live/calendar_live_test.exs`
Expected: PASS (all 3).

- [ ] **Step 7: Commit**

```bash
git add lib/cinder_web/live/calendar_live.ex lib/cinder_web/router.ex lib/cinder_web/components/layouts/root.html.heex test/cinder_web/live/calendar_live_test.exs
git commit -m "M6: /calendar upcoming view (admin-gated, live badges)"
```

---

### Task 7: Full suite green + roadmap note + graph

**Files:**
- Modify: `ROADMAP.md` (mark M6 done with a `[done]` note, mirroring M5's style)

- [ ] **Step 1: Run the full alias**

Run: `mix test`
Expected: all green (compile `--warnings-as-errors`, format, `credo --strict`, full suite). The pre-M6 count was 479; M6 adds ~16 tests. If an unrelated test flakes on a `DBConnection` checkout timeout, that is the known `pool_size: 1` flake — re-run once to confirm before investigating.

- [ ] **Step 2: Update the graph**

Run: `graphify update .`
Expected: completes (AST-only, no API cost).

- [ ] **Step 3: Add the M6 done-note to `ROADMAP.md`**

Under the **M6** milestone, append a `**[done 2026-06-22]**` paragraph mirroring M5's: note that air-date eligibility/monitor-strategy/wanted-sweep were already present; M6 shipped the `episodes_wanted_index` partial index, `Catalog.refresh_series/1` (reconcile by `tmdb_episode_id`, fresh+grow, vanished-untouched), the 12h `Cinder.Catalog.Refresher` (`:start_poller`-gated), and `/calendar`; specials/per-episode-size-band/vanished-deletion remain deferred.

- [ ] **Step 4: Commit**

```bash
git add ROADMAP.md
git commit -m "M6: mark done in ROADMAP"
```

---

## Self-Review

**Spec coverage:**
- Indexed wanted-episodes query → Task 1. ✓
- Monitor-strategy enforcement gating the sweep → already enforced at the `monitored` leaf; re-applied to new episodes in `refresh_series` (Task 2). ✓
- Periodic TMDB refresh marking just-aired episodes search-eligible → Tasks 2 (logic) + 4 (scheduler); eligibility is automatic once `air_date` is filled (Task 3 proves it). ✓
- Calendar/upcoming view → Tasks 5 + 6. ✓
- Reconciliation for renumbering / late air-date fills → Task 2 (match by `tmdb_episode_id`). ✓
- Done-when (just-aired episode grabs automatically; wanted query not a full scan) → Task 3 + Task 1. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; the only deliberate "describe in prose" step is the ROADMAP note (Task 7 Step 3), which is documentation, not code.

**Type consistency:** `refresh_series/1` returns `{:ok, %Series{}} | {:error, term()}` (Tasks 2/3/4 agree). `Episode.refresh_changeset/2` + `Season.refresh_changeset/2` defined in Task 2, used only there. `upcoming_episodes/0` returns `[%Episode{}]` with `season: :series` preloaded — the CalendarLive template reads `row.ep.season.series.title` and `row.ep.season.season_number`, matching the preload. `badge/2`, `code/2`, `pad/1` are CalendarLive-private. The Refresher's `poll/0..1` and `start_link/1` match the test and `application.ex` child spec.
