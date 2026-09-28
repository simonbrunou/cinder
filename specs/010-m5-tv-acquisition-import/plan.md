# M5a — TV pipeline data model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the grab-centric TV download/import data layer — a `grabs` table (one download → N episodes), the per-episode pipeline columns, and the Catalog access functions — so M5b/M5c can wire the TV poller against it. The movie pipeline is untouched.

**Architecture:** Episodes stay status-less; state is derived (`file_path` ⇒ available, `grab_id` ⇒ downloading, else wanted). A transient `grabs` row owns the `download_id`/`download_protocol` and, via `content_path`, its phase (nil ⇒ downloading, set ⇒ ready to import). All episode/grab writes go through Catalog choke-points that broadcast `{:series_updated, series_id}` on the existing `"series"` topic. Multi-row writes are wrapped in `Repo.transaction` (the M0 WAL + `busy_timeout` correctness guarantee).

**Tech Stack:** Elixir/Phoenix 1.8, Ecto + `ecto_sqlite3`, ExUnit, Mox. Design spec: `docs/specs/2026-06-22-m5-design.md`.

## Global Constraints

- `mix test` (the alias) is the source of truth: it runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `ecto.create --quiet`, `ecto.migrate --quiet`, then the suite. "Green" means this passes. The new migration applies automatically.
- **Movies untouched.** Do not edit `movie.ex`, `download.ex`, `library.ex`, `poller.ex`, `acquisition*`, or any movie test. The 408-test movie suite must stay green as proof.
- **Every writer goes through a Catalog choke-point** (`transition_episode/2` for episode pipeline writes; the grab functions for grab writes). Multi-row writes use `Repo.transaction`. Never call a per-row pipeline write N times outside a transaction.
- **`monitored` is NOT pipeline state** — it keeps its own writers (`set_episode_monitored`/`set_season_monitored`). Do not route it through `transition_episode/2`.
- New test files that use `Repo.transaction` (the grab functions) must be `use Cinder.DataCase, async: false` — the SQLite sandbox needs shared mode for nested transactions (same reason as `catalog_series_test.exs`).
- Work on a branch `m5a-tv-pipeline-data-model`. Commit per task locally. **Do not push or open a PR until the user asks** (project: commit at phase boundaries, PR at milestone). End every commit message with the repo's standard trailers (`Co-Authored-By:` + `Claude-Session:`).
- Mirror existing style: `import Ecto.Query`; `DateTime.truncate(DateTime.utc_now(), :second)` for manual `updated_at` in `update_all`; module/function docs in the house voice.

---

### Task 1: Migration + Grab schema + Episode pipeline columns

**Files:**
- Create: `priv/repo/migrations/20260622140000_add_tv_pipeline_fields.exs`
- Create: `lib/cinder/catalog/grab.ex`
- Modify: `lib/cinder/catalog/episode.ex` (add 3 fields + `belongs_to :grab` + `transition_changeset/2`)
- Test: `test/cinder/catalog/episode_test.exs`

**Interfaces:**
- Produces: `Cinder.Catalog.Grab` schema (`download_id :: String.t`, `download_protocol :: :torrent | :usenet`, `content_path :: String.t | nil`, `download_attempts :: integer`, `has_many :episodes`) + `Grab.changeset/2`. `Cinder.Catalog.Episode` gains `file_path :: String.t | nil`, `grab_id :: integer | nil`, `search_attempts :: integer`, `import_attempts :: integer`, and `Episode.transition_changeset(episode, attrs) :: Ecto.Changeset.t` casting `[:file_path, :grab_id, :search_attempts, :import_attempts]`.

- [ ] **Step 1: Create the branch**

```bash
git checkout -b m5a-tv-pipeline-data-model
```

- [ ] **Step 2: Write the failing changeset test**

Create `test/cinder/catalog/episode_test.exs`:

```elixir
defmodule Cinder.Catalog.EpisodeTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.Episode

  test "transition_changeset/2 casts the pipeline fields" do
    cs =
      Episode.transition_changeset(%Episode{}, %{
        file_path: "/library/x.mkv",
        grab_id: 7,
        search_attempts: 2,
        import_attempts: 1
      })

    assert cs.valid?
    assert cs.changes == %{file_path: "/library/x.mkv", grab_id: 7, search_attempts: 2, import_attempts: 1}
  end

  test "transition_changeset/2 does not cast identity/monitoring fields" do
    cs = Episode.transition_changeset(%Episode{}, %{episode_number: 9, monitored: false, title: "x"})
    assert cs.changes == %{}
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/cinder/catalog/episode_test.exs`
Expected: FAIL — `function Cinder.Catalog.Episode.transition_changeset/2 is undefined`.

- [ ] **Step 4: Write the migration**

Create `priv/repo/migrations/20260622140000_add_tv_pipeline_fields.exs`:

```elixir
defmodule Cinder.Repo.Migrations.AddTvPipelineFields do
  use Ecto.Migration

  # M5a: the grab/download record (one download → N episodes) + the per-episode
  # pipeline fields. Additive — the movie loop is untouched. Episodes stay status-less:
  # state is derived (file_path ⇒ available, grab_id ⇒ downloading, else wanted). A grab's
  # phase is derived from content_path (nil ⇒ downloading, set ⇒ ready to import).
  def change do
    create table(:grabs) do
      add :download_id, :string, null: false
      add :download_protocol, :string, null: false
      add :content_path, :string
      add :download_attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    alter table(:episodes) do
      add :file_path, :string
      add :grab_id, references(:grabs, on_delete: :nilify_all)
      add :search_attempts, :integer, null: false, default: 0
      add :import_attempts, :integer, null: false, default: 0
    end

    create index(:episodes, [:grab_id])
  end
end
```

- [ ] **Step 5: Write the Grab schema**

Create `lib/cinder/catalog/grab.ex`:

```elixir
defmodule Cinder.Catalog.Grab do
  @moduledoc """
  An in-flight download serving one or more `Cinder.Catalog.Episode`s (a single episode or
  a season pack). `content_path` nil ⇒ still downloading; set ⇒ downloaded and ready to
  import. Grabs are transient: deleted once their episodes import (or on a terminal park),
  so the table only ever holds in-flight downloads.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Catalog.Episode

  schema "grabs" do
    field :download_id, :string
    field :download_protocol, Ecto.Enum, values: [:torrent, :usenet]
    field :content_path, :string
    field :download_attempts, :integer, default: 0
    has_many :episodes, Episode

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(grab, attrs) do
    grab
    |> cast(attrs, [:download_id, :download_protocol, :content_path, :download_attempts])
    |> validate_required([:download_id, :download_protocol])
  end
end
```

- [ ] **Step 6: Add the Episode pipeline fields + changeset**

In `lib/cinder/catalog/episode.ex`, add `Grab` to the alias and the new fields to the `schema`, and append `transition_changeset/2`. The schema block becomes:

```elixir
  alias Cinder.Catalog.{Grab, Season}

  schema "episodes" do
    field :tmdb_episode_id, :integer
    field :episode_number, :integer
    field :title, :string
    field :air_date, :date
    field :monitored, :boolean, default: true
    field :file_path, :string
    field :search_attempts, :integer, default: 0
    field :import_attempts, :integer, default: 0
    belongs_to :season, Season
    belongs_to :grab, Grab

    timestamps(type: :utc_datetime)
  end
```

And after `nested_changeset/2`, add:

```elixir
  @doc """
  Changeset for pipeline state writes (no status enum — episode state is derived from
  `file_path`/`grab_id`). Routed through `Cinder.Catalog.transition_episode/2`. `monitored`
  is deliberately excluded: it is not pipeline state and keeps its own writer.
  """
  def transition_changeset(episode, attrs) do
    cast(episode, attrs, [:file_path, :grab_id, :search_attempts, :import_attempts])
  end
```

(Update the existing `alias Cinder.Catalog.Season` line to the `{Grab, Season}` form shown above.)

- [ ] **Step 7: Run the changeset test to verify it passes**

Run: `mix test test/cinder/catalog/episode_test.exs`
Expected: PASS (both tests). The migration applies via the `ecto.migrate --quiet` alias step.

- [ ] **Step 8: Commit**

```bash
git add priv/repo/migrations/20260622140000_add_tv_pipeline_fields.exs \
        lib/cinder/catalog/grab.ex lib/cinder/catalog/episode.ex \
        test/cinder/catalog/episode_test.exs docs/specs/2026-06-22-m5-design.md \
        docs/plans/2026-06-22-m5a-tv-pipeline-data-model.md
git commit -m "M5a: grabs table + episode pipeline fields"
```

---

### Task 2: `transition_episode/2` — the episode pipeline choke-point

**Files:**
- Modify: `lib/cinder/catalog.ex` (add `Grab` to alias; add `transition_episode/2` + a `now/0` helper)
- Test: `test/cinder/catalog_tv_pipeline_test.exs`

**Interfaces:**
- Consumes: `Episode.transition_changeset/2`, the existing private `series_id_for_season/1` and `broadcast_series/1`.
- Produces: `Cinder.Catalog.transition_episode(%Episode{}, attrs) :: {:ok, %Episode{}} | {:error, changeset}` — updates via `Episode.transition_changeset/2`, then broadcasts `{:series_updated, series_id}`.
- Deferred to Task 3: the `Grab` alias and the private `now/0` helper — they have no *use* in this task, and an unused alias/function fails `compile --warnings-as-errors` (which `mix test` runs). They land in Task 3 where `create_grab/3` uses them.

- [ ] **Step 1: Write the failing test**

Create `test/cinder/catalog_tv_pipeline_test.exs`:

```elixir
defmodule Cinder.CatalogTvPipelineTest do
  # async: false — create_grab/3 wraps a Repo.transaction; the SQLite sandbox needs shared
  # mode for nested transactions (same reason as catalog_series_test.exs).
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  # Grab is added to this alias in Task 3 (first used by the grab-lifecycle tests). Keeping
  # the alias minimal per task avoids an unused-alias warning at the Task 2 boundary.
  alias Cinder.Catalog.{Episode, Season, Series}

  @past ~D[2001-01-01]
  @future ~D[2099-01-01]

  defp series_with_season do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Show",
        year: 2008,
        monitored: true,
        monitor_strategy: :all
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
    {series, season}
  end

  defp episode(season, attrs) do
    Repo.insert!(
      struct(
        %Episode{
          season_id: season.id,
          episode_number: System.unique_integer([:positive]),
          monitored: true,
          air_date: @past
        },
        attrs
      )
    )
  end

  describe "transition_episode/2" do
    test "sets a pipeline field, persists, and broadcasts {:series_updated, series_id}" do
      {series, season} = series_with_season()
      ep = episode(season, %{})
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, ep} = Catalog.transition_episode(ep, %{file_path: "/library/x.mkv"})
      assert ep.file_path == "/library/x.mkv"
      assert_receive {:series_updated, ^series_id}
      assert Repo.get(Episode, ep.id).file_path == "/library/x.mkv"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: FAIL — `function Cinder.Catalog.transition_episode/2 is undefined`.

- [ ] **Step 3: Implement `transition_episode/2`**

In `lib/cinder/catalog.ex`, in the TV section (after `set_season_monitored/2`, near the other `series_id_for_season`/`broadcast_series` helpers), add:

```elixir
  @doc """
  Single choke-point for episode **pipeline** writes (`file_path`, `grab_id`, attempt
  counters — no status enum; episode state is derived). On success broadcasts
  `{:series_updated, series_id}` on the `"series"` topic. `monitored` is NOT written here —
  it is not pipeline state and keeps `set_episode_monitored/2`.
  """
  def transition_episode(%Episode{} = episode, attrs) do
    with {:ok, updated} <- episode |> Episode.transition_changeset(attrs) |> Repo.update() do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end
```

(No `Grab` alias change here — `transition_episode/2` uses only the existing `Episode` alias and helpers. Grab arrives in Task 3.)

- [ ] **Step 4: Run it to verify it passes**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_tv_pipeline_test.exs
git commit -m "M5a: transition_episode/2 episode pipeline choke-point"
```

---

### Task 3: Grab lifecycle — create / mark downloaded / delete / list

**Files:**
- Modify: `lib/cinder/catalog.ex` (add the grab functions + a `series_id_for_grab/1` helper)
- Test: `test/cinder/catalog_tv_pipeline_test.exs` (add a `describe` block)

**Interfaces:**
- Consumes: `Grab.changeset/2`, `transition` helpers, `now/0` (Task 2).
- Produces:
  - `create_grab(download_id :: String.t, protocol :: :torrent | :usenet, episode_ids :: [integer]) :: {:ok, %Grab{}}` — one `Repo.transaction`: inserts the grab, sets `grab_id` on the episodes; broadcasts.
  - `mark_grab_downloaded(%Grab{}, content_path :: String.t) :: {:ok, %Grab{}}`.
  - `delete_grab(%Grab{}) :: {:ok, %Grab{}}` — deletes the grab; the FK nilifies the episodes' `grab_id`; broadcasts.
  - `list_grabs_downloading() :: [%Grab{}]` (`content_path` nil), `list_grabs_downloaded() :: [%Grab{}]` (`content_path` set).

- [ ] **Step 1: Add `Grab` to the test alias, then write the failing tests**

First update the test module's alias line (the grab tests reference `%Grab{}`):

```elixir
  alias Cinder.Catalog.{Episode, Grab, Season, Series}
```

(and delete the Task-2 comment line above it about Grab being added later).

Then append to `test/cinder/catalog_tv_pipeline_test.exs` (inside the module, after the `transition_episode/2` describe):

```elixir
  describe "grab lifecycle" do
    test "create_grab/3 links episodes, persists, and broadcasts" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      e2 = episode(season, %{})
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, grab} = Catalog.create_grab("HASH1", :torrent, [e1.id, e2.id])
      assert grab.download_id == "HASH1"
      assert grab.download_protocol == :torrent
      assert is_nil(grab.content_path)
      assert_receive {:series_updated, ^series_id}

      assert Repo.get(Episode, e1.id).grab_id == grab.id
      assert Repo.get(Episode, e2.id).grab_id == grab.id
    end

    test "mark_grab_downloaded/2 sets content_path and moves the grab between the lists" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{})
      {:ok, grab} = Catalog.create_grab("HASH2", :usenet, [e1.id])

      assert [%Grab{id: id}] = Catalog.list_grabs_downloading()
      assert id == grab.id
      assert Catalog.list_grabs_downloaded() == []

      assert {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/pack")
      assert grab.content_path == "/downloads/pack"
      assert Catalog.list_grabs_downloading() == []
      assert [%Grab{id: ^id}] = Catalog.list_grabs_downloaded()
    end

    test "delete_grab/1 removes the grab and nilifies its episodes' grab_id" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      series_id = series.id
      {:ok, grab} = Catalog.create_grab("HASH3", :torrent, [e1.id])
      Catalog.subscribe_series()

      assert {:ok, _} = Catalog.delete_grab(grab)
      assert_receive {:series_updated, ^series_id}
      assert Repo.get(Grab, grab.id) == nil
      assert Repo.get(Episode, e1.id).grab_id == nil
    end
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: FAIL — `function Cinder.Catalog.create_grab/3 is undefined`.

- [ ] **Step 3: Implement the grab functions**

In `lib/cinder/catalog.ex`, first add `Grab` to the alias (now used by the grab functions):

```elixir
  alias Cinder.Catalog.{Episode, Grab, Movie, Season, Series}
```

Then, after `transition_episode/2`, add the `now/0` helper and the grab functions (all uses of `now/0` and `series_id_for_grab/1` are within this block, so no unused-warning at this boundary):

```elixir
  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  @doc """
  Creates a grab for `episode_ids` (a single episode or a season pack) and links them in one
  transaction, then broadcasts `{:series_updated, series_id}`.
  """
  def create_grab(download_id, protocol, episode_ids) do
    result =
      Repo.transaction(fn ->
        grab =
          %Grab{}
          |> Grab.changeset(%{download_id: download_id, download_protocol: protocol})
          |> Repo.insert!()

        Repo.update_all(
          from(e in Episode, where: e.id in ^episode_ids),
          set: [grab_id: grab.id, updated_at: now()]
        )

        grab
      end)

    with {:ok, grab} <- result do
      broadcast_series(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  @doc "Marks a grab downloaded (records `content_path`, the at-rest path to import) and broadcasts."
  def mark_grab_downloaded(%Grab{} = grab, content_path) do
    with {:ok, grab} <- grab |> Grab.changeset(%{content_path: content_path}) |> Repo.update() do
      broadcast_series(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  @doc """
  Deletes a grab; the `grab_id` FK (`on_delete: :nilify_all`) unlinks its episodes. Broadcasts
  `{:series_updated, series_id}` (captured before the delete, while the links still exist).
  """
  def delete_grab(%Grab{} = grab) do
    series_id = series_id_for_grab(grab.id)

    with {:ok, grab} <- Repo.delete(grab) do
      if series_id, do: broadcast_series(series_id)
      {:ok, grab}
    end
  end

  @doc "Grabs still downloading (no `content_path` yet)."
  def list_grabs_downloading, do: Repo.all(from g in Grab, where: is_nil(g.content_path))

  @doc "Grabs downloaded and awaiting import (`content_path` set)."
  def list_grabs_downloaded, do: Repo.all(from g in Grab, where: not is_nil(g.content_path))

  defp series_id_for_grab(grab_id) do
    Repo.one(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.grab_id == ^grab_id,
        select: s.series_id,
        limit: 1
    )
  end
```

- [ ] **Step 4: Run them to verify they pass**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: PASS (all four tests in the file).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_tv_pipeline_test.exs
git commit -m "M5a: grab lifecycle (create/mark/delete/list)"
```

---

### Task 4: `wanted_episodes/0` — the SQL-expressible wanted set

**Files:**
- Modify: `lib/cinder/catalog.ex` (add `wanted_episodes/0`)
- Test: `test/cinder/catalog_tv_pipeline_test.exs` (add a `describe` block)

**Interfaces:**
- Produces: `wanted_episodes() :: [%Episode{}]` — monitored episodes with `file_path` nil, `grab_id` nil, and `air_date` set and `<= today`, preloaded `season: :series`. Backoff/bound filtering (`search_attempts`, retry window) is the poller's job (M5c), matching the movie poller's split.

- [ ] **Step 1: Write the failing tests**

Append to `test/cinder/catalog_tv_pipeline_test.exs` (inside the module):

```elixir
  describe "wanted_episodes/0" do
    test "returns monitored, aired, file-less, grab-less episodes only" do
      {_series, season} = series_with_season()
      wanted = episode(season, %{air_date: @past, monitored: true})
      _unaired = episode(season, %{air_date: @future, monitored: true})
      _tba = episode(season, %{air_date: nil, monitored: true})
      _unmonitored = episode(season, %{air_date: @past, monitored: false})

      assert Enum.map(Catalog.wanted_episodes(), & &1.id) == [wanted.id]
    end

    test "excludes episodes with a file or an active grab" do
      {_series, season} = series_with_season()
      imported = episode(season, %{})
      grabbed = episode(season, %{})
      free = episode(season, %{})

      {:ok, _} = Catalog.transition_episode(imported, %{file_path: "/x.mkv"})
      {:ok, _} = Catalog.create_grab("H", :torrent, [grabbed.id])

      assert Enum.map(Catalog.wanted_episodes(), & &1.id) == [free.id]
    end

    test "preloads season and series for the poller" do
      {series, season} = series_with_season()
      episode(season, %{})

      assert [ep] = Catalog.wanted_episodes()
      assert ep.season.id == season.id
      assert ep.season.series.id == series.id
    end
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: FAIL — `function Cinder.Catalog.wanted_episodes/0 is undefined`.

- [ ] **Step 3: Implement `wanted_episodes/0`**

In `lib/cinder/catalog.ex`, after `list_grabs_downloaded/0`, add:

```elixir
  @doc """
  The SQL-expressible wanted set: monitored episodes with no file and no active grab whose
  `air_date` has passed (set and `<= today`). Preloads `season: :series` for the poller's
  search + season-grouping. Backoff/bound filtering (search_attempts, retry window) is applied
  by the TV poller, matching the movie poller's split. Gated on the leaf `episode.monitored`
  flag (the cascade/add keep it the single source of truth).
  """
  def wanted_episodes do
    today = Date.utc_today()

    Repo.all(
      from e in Episode,
        where:
          e.monitored and is_nil(e.file_path) and is_nil(e.grab_id) and
            not is_nil(e.air_date) and e.air_date <= ^today,
        preload: [season: :series]
    )
  end
```

- [ ] **Step 4: Run them to verify they pass**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Run the full suite — prove movies untouched + everything green**

Run: `mix test`
Expected: PASS — the full alias (compile `--warnings-as-errors`, format, credo `--strict`, migrate, suite). The 408 movie/other tests stay green (movies untouched) plus the new M5a tests.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_tv_pipeline_test.exs
git commit -m "M5a: wanted_episodes/0 query"
```

---

## Self-Review

**Spec coverage (M5a section of `docs/specs/2026-06-22-m5-design.md`):**
- Migration: grabs table + 4 episode columns + `index(:episodes, [:grab_id])` → Task 1. ✓
- `Cinder.Catalog.Grab` schema + `Episode.transition_changeset/2` → Task 1. ✓
- `transition_episode/2` choke-point → Task 2. ✓
- `create_grab/3` (one transaction) → Task 3. ✓
- `mark_grab_downloaded/2`, `delete_grab/1`, `list_grabs_downloading/0`, `list_grabs_downloaded/0` → Task 3. ✓
- `wanted_episodes/0` (preloaded, leaf-monitored, aired) → Task 4. ✓
- M5a "Done when" (episode transition + grab lifecycle + wanted inclusion/exclusion tested; movie suite green) → Tasks 2–4 + Task 4 Step 5. ✓

**Placeholder scan:** none — every step has runnable code/commands and expected output.

**Type consistency:** `transition_episode/2`, `create_grab/3` (`download_id`, `protocol`, `episode_ids`), `mark_grab_downloaded/2`, `delete_grab/1`, `list_grabs_downloading/0`, `list_grabs_downloaded/0`, `wanted_episodes/0`, `series_id_for_grab/1`, `now/0` — names and arities are identical across the Interfaces blocks, the implementations, and the tests. `Grab.changeset/2` and `Episode.transition_changeset/2` field lists match the migration columns.

**Note for the executor:** the design defers to M5b/M5c — no parser, indexer, scorer, poller, or import code in M5a. If a task seems to call for those, stop: it belongs to a later sub-session.
