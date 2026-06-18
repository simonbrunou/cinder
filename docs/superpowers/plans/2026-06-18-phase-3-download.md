# Phase 3 — Download (hand off + track) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the download half of the Cinder pipeline — a `start/1` hand-off, a supervised poller that tracks downloads to completion, a real qBittorrent client, and live status badges — so a movie can walk `:requested → :searching → :downloading → :downloaded`.

**Architecture:** Two pieces mirror "hand off + track": `Cinder.Download.start/1` (a plain function composing `Acquisition.best_release` + `Client.add`) and `Cinder.Download.Poller` (a supervised, stateless GenServer that re-derives its work from the DB each tick — that's the crash-recovery story). `Cinder.Catalog` owns the `Movie` schema and is the single choke-point for state transitions + PubSub broadcasts. Nothing auto-triggers the pipeline yet; that wiring is Phase 5.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto + ecto_sqlite3, Req (qBittorrent Web API v2), Phoenix.PubSub, Mox + Req.Test for tests.

**Design spec:** `docs/superpowers/specs/2026-06-18-phase-3-download-design.md` (council-reviewed). Read it for the *why*; this plan is the *how*.

Council review: 1 round (Claude-only harness — perspective-diverse seats: Opus code-correctness + Sonnet library-API verification against the vendored `deps/`). Consensus **READY-TO-IMPLEMENT**, no blockers. Both verified the riskiest claims empirically: the full-machine fixture survives `best_release` with no opts (confirmed no `Cinder.Acquisition.Scorer` config exists, so no size band rejects it), `Ecto.Enum`'s cast error really is `"is invalid"`, and the Req (`form_multipart`, `Req.Response.get_header` on `set-cookie`, `conn.params["hashes"]`, manual cookie threading — Req has no cookie jar), Mox (global mode + `async: false`), PubSub (synchronous `broadcast`, so `assert_receive` can't race), and `start_supervised!`/`:permanent`-restart flows are all correct. Two minor robustness fixes (the complete list both reviewers gave) applied: `await_restart/2` no longer busy-spins (added `Process.sleep(10)`), and the poller tests pass `interval: 60_000` to `start_supervised!` so the background timer can't fire mid-test. No NEEDS-REWORK; no second round warranted (the fixes were mechanical and pre-enumerated).

## Global Constraints

- `mix test` is the source of truth (the alias runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `ecto.create --quiet`, `ecto.migrate --quiet`, then the suite). "Green" means this passes.
- `mix test <path>` scopes to one file but still runs the full alias gates. On a RED step for a not-yet-created module/function, expect a **compile error / `UndefinedFunctionError`** (this is Elixir's TDD "red"), not a plain assertion failure.
- External services are reached only through behaviours, resolved at runtime via `Application.fetch_env!/2` (never `compile_env!` — it inlines the runtime-defined Mox module and breaks `--warnings-as-errors`). `config/test.exs` already points `download_client` at `Cinder.Download.ClientMock`.
- Tests never hit the network or a real service. SQLite, single household.
- Format every file before committing (the post-edit hook does this; `mix format` if needed).
- Commit at the end of each task.

---

### Task 1: Movie state mechanics — schema, migration, Catalog transitions + broadcast

**Files:**
- Modify: `lib/cinder/catalog/movie.ex`
- Create: `priv/repo/migrations/<generated>_add_download_fields_to_movies.exs`
- Modify: `lib/cinder/catalog.ex`
- Test: `test/cinder/catalog_test.exs`

**Interfaces:**
- Produces:
  - `Cinder.Catalog.Movie` schema gains `field :imdb_id, :string` and `field :download_id, :string`; status enum gains `:no_match`.
  - `Cinder.Catalog.Movie.transition_changeset(movie, attrs)` — casts `[:status, :download_id, :imdb_id]`, `validate_required([:status])`.
  - `Cinder.Catalog.list_by_status(status :: atom) :: [%Movie{}]`
  - `Cinder.Catalog.transition(%Movie{}, attrs :: map) :: {:ok, %Movie{}} | {:error, %Ecto.Changeset{}}` — updates **and** broadcasts `{:movie_updated, movie}` on topic `"movies"`.
  - `Cinder.Catalog.get_movie(tmdb_id :: integer) :: {:ok, map} | {:error, term}` — delegates to the TMDB behaviour.
  - `Cinder.Catalog.subscribe() :: :ok` — subscribes the caller to `"movies"`.

- [ ] **Step 1: Update the Movie schema**

Replace the contents of `lib/cinder/catalog/movie.ex`:

```elixir
defmodule Cinder.Catalog.Movie do
  @moduledoc """
  A watchlisted movie.

  Created `:requested`; the download pipeline advances `status`
  (`:searching → :downloading → :downloaded → :available`), or parks it at
  `:no_match` when no release survives the scorer.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses [:requested, :searching, :downloading, :downloaded, :available, :no_match]

  schema "movies" do
    field :tmdb_id, :integer
    field :imdb_id, :string
    field :title, :string
    field :year, :integer
    field :poster_path, :string
    field :status, Ecto.Enum, values: @statuses, default: :requested
    field :download_id, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(movie, attrs) do
    movie
    |> cast(attrs, [:tmdb_id, :imdb_id, :title, :year, :poster_path])
    |> validate_required([:tmdb_id, :title])
    |> unique_constraint(:tmdb_id)
  end

  @doc "Changeset for pipeline state transitions (status + optional download_id/imdb_id)."
  def transition_changeset(movie, attrs) do
    movie
    |> cast(attrs, [:status, :download_id, :imdb_id])
    |> validate_required([:status])
  end
end
```

- [ ] **Step 2: Generate and fill the migration**

Run: `mix ecto.gen.migration add_download_fields_to_movies`

Then replace the generated file's body with:

```elixir
defmodule Cinder.Repo.Migrations.AddDownloadFieldsToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :imdb_id, :string
      add :download_id, :string
    end
  end
end
```

(`:no_match` needs no migration — `Ecto.Enum` stores the status as a string.)

- [ ] **Step 3: Migrate the dev and test databases**

Run: `mix ecto.migrate` and `MIX_ENV=test mix ecto.migrate`
Expected: both report the migration applied (`:up`).

- [ ] **Step 4: Write failing tests for the Catalog functions**

Add to `test/cinder/catalog_test.exs` (inside the module, after the existing `describe` blocks):

```elixir
  describe "get_movie/1" do
    test "delegates to the configured TMDB impl" do
      expect(Cinder.Catalog.TMDBMock, :get_movie, fn 27_205 ->
        {:ok, %{tmdb_id: 27_205, imdb_id: "tt1375666"}}
      end)

      assert {:ok, %{imdb_id: "tt1375666"}} = Catalog.get_movie(27_205)
    end
  end

  describe "transition/2, list_by_status/1, subscribe/0" do
    test "transition/2 updates status + download_id and broadcasts the change" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 1, title: "M"})
      Catalog.subscribe()

      assert {:ok, %Movie{status: :downloading, download_id: "h"}} =
               Catalog.transition(movie, %{status: :downloading, download_id: "h"})

      assert_receive {:movie_updated, %Movie{id: id, status: :downloading}}
      assert id == movie.id
    end

    test "transition/2 rejects an unknown status" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 2, title: "M"})

      assert {:error, changeset} = Catalog.transition(movie, %{status: :bogus})
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "list_by_status/1 returns only movies in that status" do
      {:ok, _a} = Catalog.add_to_watchlist(%{tmdb_id: 4, title: "A"})
      {:ok, b} = Catalog.add_to_watchlist(%{tmdb_id: 5, title: "B"})
      {:ok, _} = Catalog.transition(b, %{status: :downloading, download_id: "h"})

      assert [%Movie{tmdb_id: 5}] = Catalog.list_by_status(:downloading)
      assert [%Movie{tmdb_id: 4}] = Catalog.list_by_status(:requested)
    end
  end
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog_test.exs`
Expected: FAIL — `UndefinedFunctionError` for `Catalog.get_movie/1` / `Catalog.transition/2` / `Catalog.list_by_status/1` / `Catalog.subscribe/0`.

- [ ] **Step 6: Implement the Catalog functions**

In `lib/cinder/catalog.ex`, add a module attribute near the top (after the `alias`/`import` lines) and the four functions. Add this attribute below the existing aliases:

```elixir
  @topic "movies"
```

Then add these functions to the module:

```elixir
  @doc "Subscribes the caller to movie state-change broadcasts (`{:movie_updated, movie}`)."
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @doc "Fetches full movie details from TMDB (the details endpoint carries `imdb_id`)."
  def get_movie(tmdb_id), do: tmdb().get_movie(tmdb_id)

  @doc "Lists movies in a given pipeline `status`."
  def list_by_status(status) do
    Repo.all(from m in Movie, where: m.status == ^status)
  end

  @doc """
  Applies a pipeline state transition and, on success, broadcasts
  `{:movie_updated, movie}` on the `"movies"` topic. This is the single
  choke-point for state changes — every transition broadcasts exactly once.
  `attrs` must set `:status`; it may also set `:download_id` and `:imdb_id`.
  """
  def transition(%Movie{} = movie, attrs) do
    with {:ok, updated} <- movie |> Movie.transition_changeset(attrs) |> Repo.update() do
      Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, {:movie_updated, updated})
      {:ok, updated}
    end
  end
```

(`import Ecto.Query`, `alias Cinder.Catalog.Movie`, and `alias Cinder.Repo` already exist in this file.)

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog_test.exs`
Expected: PASS (all existing + new tests).

- [ ] **Step 8: Run the full suite and commit**

Run: `mix test`
Expected: PASS.

```bash
git add lib/cinder/catalog/movie.ex lib/cinder/catalog.ex priv/repo/migrations test/cinder/catalog_test.exs
git commit -m "Phase 3: Movie download fields + Catalog transitions/broadcast"
```

---

### Task 2: `Cinder.Download.start/1` — the hand-off

**Files:**
- Create: `lib/cinder/download.ex`
- Test: `test/cinder/download_test.exs`

**Interfaces:**
- Consumes: `Catalog.transition/2`, `Catalog.get_movie/1` (Task 1); `Acquisition.best_release/1` (exists); the `Cinder.Download.Client` behaviour `add/1` (exists, mocked as `Cinder.Download.ClientMock`).
- Produces: `Cinder.Download.start(%Movie{}) :: {:ok, %Movie{}} | {:error, term}` — advances `:requested → :searching → :downloading` (or `:no_match`); on indexer/client error returns `{:error, reason}` and leaves the movie `:searching`.

- [ ] **Step 1: Write the failing tests**

Create `test/cinder/download_test.exs`:

```elixir
defmodule Cinder.DownloadTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.{Catalog, Download}
  alias Cinder.Catalog.Movie
  alias Cinder.Repo

  setup :verify_on_exit!

  defp requested(attrs) do
    {:ok, movie} =
      Catalog.add_to_watchlist(
        Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, attrs)
      )

    movie
  end

  # A raw indexer result that survives the default scorer (1080p, no size band configured).
  defp survivable_result do
    %{
      title: "Inception.2010.1080p.BluRay.x264-GRP",
      size: 8_000_000_000,
      download_url: "magnet:?xt=urn:btih:abc",
      seeders: 10
    }
  end

  test "hands a requested movie off and advances it to :downloading" do
    movie = requested(%{imdb_id: "tt1375666"})

    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" -> {:ok, [survivable_result()]} end)
    # The mock receives the chosen %Cinder.Acquisition.Release{}; we don't assert its internals here.
    expect(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-1"} end)

    assert {:ok, %Movie{status: :downloading, download_id: "hash-1"}} = Download.start(movie)
    assert %Movie{status: :downloading, download_id: "hash-1"} = Repo.get!(Movie, movie.id)
  end

  test "lazily resolves a missing imdb_id from TMDB and persists it" do
    movie = requested(%{imdb_id: nil})
    refute movie.imdb_id

    expect(Cinder.Catalog.TMDBMock, :get_movie, fn tmdb_id ->
      assert tmdb_id == movie.tmdb_id
      {:ok, %{tmdb_id: movie.tmdb_id, imdb_id: "tt1375666"}}
    end)

    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" -> {:ok, [survivable_result()]} end)
    expect(Cinder.Download.ClientMock, :add, fn _ -> {:ok, "hash-2"} end)

    assert {:ok, %Movie{status: :downloading, imdb_id: "tt1375666"}} = Download.start(movie)
  end

  test "parks the movie at :no_match when no release survives scoring" do
    movie = requested(%{imdb_id: "tt1375666"})
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, []} end)

    assert {:ok, %Movie{status: :no_match}} = Download.start(movie)
  end

  test "parks the movie at :no_match when the imdb_id can't be resolved" do
    movie = requested(%{imdb_id: nil})
    expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:ok, %{imdb_id: nil}} end)

    assert {:ok, %Movie{status: :no_match}} = Download.start(movie)
  end

  test "returns the client error and leaves the movie :searching on add failure" do
    movie = requested(%{imdb_id: "tt1375666"})
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, [survivable_result()]} end)
    expect(Cinder.Download.ClientMock, :add, fn _ -> {:error, :qbittorrent_down} end)

    assert {:error, :qbittorrent_down} = Download.start(movie)
    assert %Movie{status: :searching} = Repo.get!(Movie, movie.id)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/download_test.exs`
Expected: FAIL — `Cinder.Download.start/1` is undefined.

- [ ] **Step 3: Implement `Cinder.Download`**

Create `lib/cinder/download.ex`:

```elixir
defmodule Cinder.Download do
  @moduledoc """
  Hands a `:requested` movie off to the download client: search for the best
  release and add it, advancing `:requested → :searching → :downloading` (or
  `:no_match`). The background `Cinder.Download.Poller` then tracks it to
  `:downloaded`.

  The client is reached only through the `Cinder.Download.Client` behaviour,
  resolved from config (`config :cinder, :download_client`) so tests use a Mox
  mock and never hit the network. Not auto-triggered yet — Phase 5 wires it.
  """
  alias Cinder.{Acquisition, Catalog}
  alias Cinder.Catalog.Movie

  @doc """
  Hands `movie` off to the download client. Returns `{:ok, movie}` with the
  movie's new status (`:downloading` or `:no_match`), or `{:error, reason}` when
  the indexer or the client errors (the movie is left in `:searching`).
  """
  def start(%Movie{} = movie) do
    with {:ok, imdb_id} <- ensure_imdb_id(movie),
         {:ok, movie} <- Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id}) do
      case Acquisition.best_release(imdb_id) do
        {:ok, release} ->
          case client().add(release) do
            {:ok, download_id} ->
              Catalog.transition(movie, %{status: :downloading, download_id: download_id})

            {:error, _} = err ->
              err
          end

        :no_match ->
          Catalog.transition(movie, %{status: :no_match})

        {:error, _} = err ->
          err
      end
    else
      :no_imdb_id -> Catalog.transition(movie, %{status: :no_match})
      {:error, _} = err -> err
    end
  end

  defp ensure_imdb_id(%Movie{imdb_id: imdb_id}) when is_binary(imdb_id) and imdb_id != "" do
    {:ok, imdb_id}
  end

  defp ensure_imdb_id(%Movie{tmdb_id: tmdb_id}) do
    case Catalog.get_movie(tmdb_id) do
      {:ok, %{imdb_id: imdb_id}} when is_binary(imdb_id) and imdb_id != "" -> {:ok, imdb_id}
      _ -> :no_imdb_id
    end
  end

  defp client, do: Application.fetch_env!(:cinder, :download_client)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cinder/download_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite and commit**

Run: `mix test`
Expected: PASS.

```bash
git add lib/cinder/download.ex test/cinder/download_test.exs
git commit -m "Phase 3: Download.start/1 hand-off (search + add, no_match, lazy imdb_id)"
```

---

### Task 3: `Cinder.Download.Poller` — supervised tracker + full-machine + crash-recovery tests

**Files:**
- Create: `lib/cinder/download/poller.ex`
- Modify: `lib/cinder/application.ex`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Test: `test/cinder/download/poller_test.exs`

**Interfaces:**
- Consumes: `Catalog.list_by_status/1`, `Catalog.transition/2` (Task 1); `Download.start/1` (Task 2, for the full-machine test); the `Client` behaviour `status/1` (mocked).
- Produces:
  - `Cinder.Download.Poller.start_link(opts)` — `opts[:name]` (default `__MODULE__`), `opts[:interval]` (ms; default from config or 5_000).
  - `Cinder.Download.Poller.poll(server \\ __MODULE__) :: :ok` — runs one poll pass synchronously (the test seam).

- [ ] **Step 1: Gate the poller out of the test env (config)**

In `config/test.exs`, add (near the other `config :cinder` lines):

```elixir
# The app-level poller must not run during the suite (it would race Mox/Sandbox).
# Poller tests start their own supervised instance.
config :cinder, start_poller: false
```

In `config/config.exs`, add (after the `tmdb`/`indexer` impl lines):

```elixir
config :cinder, download_client: Cinder.Download.Client.QBittorrent
config :cinder, Cinder.Download.Poller, interval: 5_000
```

(The `download_client` impl module lands in Task 4; this atom is just config data and doesn't require the module to exist at config-load. `config/test.exs` already overrides `download_client` to the mock.)

- [ ] **Step 2: Write the failing poller tests**

Create `test/cinder/download/poller_test.exs`:

```elixir
defmodule Cinder.Download.PollerTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.{Catalog, Download}
  alias Cinder.Catalog.Movie
  alias Cinder.Download.Poller
  alias Cinder.Repo

  # The poller runs in its own process (and a fresh pid after a crash), so the
  # mock must be global. Shared Sandbox (async: false) lets those processes use
  # the test-owned DB connection.
  setup :set_mox_global

  defp downloading_movie(tmdb_id, download_id) do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: tmdb_id, title: "M"})
    {:ok, movie} = Catalog.transition(movie, %{status: :downloading, download_id: download_id})
    movie
  end

  defp await_restart(name, old_pid) do
    case GenServer.whereis(name) do
      new_pid when is_pid(new_pid) and new_pid != old_pid ->
        new_pid

      _ ->
        Process.sleep(10)
        await_restart(name, old_pid)
    end
  end

  test "a poll advances a :downloading movie to :downloaded and broadcasts" do
    movie = downloading_movie(1, "hash-1")
    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-1" -> {:ok, %{state: :completed}} end)

    assert :ok = Poller.poll()

    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)
    assert_receive {:movie_updated, %Movie{status: :downloaded}}
  end

  test "a non-completed status leaves the movie :downloading" do
    movie = downloading_movie(2, "hash-2")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-2" -> {:ok, %{state: :downloading}} end)

    assert :ok = Poller.poll()
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)
  end

  test "drives a movie through the full state machine: requested -> downloaded" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 3, title: "Inception", imdb_id: "tt1375666"})
    assert movie.status == :requested
    hash = "deadbeef"

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok,
       [%{title: "Inception.2010.1080p.BluRay.x264-GRP", size: 8_000_000_000, download_url: "magnet:?x", seeders: 10}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, hash} end)
    stub(Cinder.Download.ClientMock, :status, fn ^hash -> {:ok, %{state: :completed}} end)

    start_supervised!({Poller, interval: 60_000})

    assert {:ok, %Movie{status: :downloading, download_id: ^hash}} = Download.start(movie)
    assert :ok = Poller.poll()
    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)
  end

  test "the poller recovers from a crash and still advances work (OTP payoff)" do
    movie = downloading_movie(4, "hash-4")
    pid = start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-4" -> {:ok, %{state: :completed}} end)

    Process.exit(pid, :kill)
    new_pid = await_restart(Poller, pid)
    assert new_pid != pid

    assert :ok = Poller.poll(new_pid)
    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/cinder/download/poller_test.exs`
Expected: FAIL — `Cinder.Download.Poller` is undefined.

- [ ] **Step 4: Implement the poller**

Create `lib/cinder/download/poller.ex`:

```elixir
defmodule Cinder.Download.Poller do
  @moduledoc """
  Polls active (`:downloading`) movies via the download client and advances them
  to `:downloaded`, broadcasting each change (through `Catalog.transition/2`).

  Holds no in-flight state: every tick re-derives its work from the DB, so it
  recovers cleanly after a crash/restart. That is the OTP payoff Phase 3 proves.
  """
  use GenServer

  alias Cinder.Catalog

  @default_interval 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one poll pass synchronously. The scheduled timer path is asynchronous."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

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
    for movie <- Catalog.list_by_status(:downloading) do
      case client().status(movie.download_id) do
        {:ok, %{state: :completed}} -> Catalog.transition(movie, %{status: :downloaded})
        # Anything else (still downloading, stalled, error): leave it, retry next tick.
        _ -> :ok
      end
    end

    :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval, @default_interval)
  end

  defp client, do: Application.fetch_env!(:cinder, :download_client)
end
```

- [ ] **Step 5: Add the poller to the supervision tree (gated)**

In `lib/cinder/application.ex`, change the `children` list to append a gated poller child, and add the helper. Replace the `children = [...]` assignment with:

```elixir
    children =
      [
        CinderWeb.Telemetry,
        Cinder.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:cinder, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:cinder, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Cinder.PubSub},
        CinderWeb.Endpoint
      ] ++ poller_child()
```

And add this private function (next to `skip_migrations?/0`):

```elixir
  defp poller_child do
    if Application.get_env(:cinder, :start_poller, true) do
      [Cinder.Download.Poller]
    else
      []
    end
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/cinder/download/poller_test.exs`
Expected: PASS (all four, including full-machine and crash-recovery).

- [ ] **Step 7: Run the full suite and commit**

Run: `mix test`
Expected: PASS.

```bash
git add lib/cinder/download/poller.ex lib/cinder/application.ex config/config.exs config/test.exs test/cinder/download/poller_test.exs
git commit -m "Phase 3: supervised Download.Poller (tracking + crash recovery)"
```

---

### Task 4: `Cinder.Download.Client.QBittorrent` — real impl + config seam

**Files:**
- Create: `lib/cinder/download/client/qbittorrent.ex`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`
- Test: `test/cinder/download/client/qbittorrent_test.exs`

**Interfaces:**
- Consumes: the `Cinder.Download.Client` behaviour (`add/1`, `status/1`).
- Produces: `Cinder.Download.Client.QBittorrent` implementing the behaviour. `add/1` returns `{:ok, lowercased_btih_hash}` for magnet `download_url`s, `{:error, :unsupported_download_url}` otherwise. `status/1` returns `{:ok, %{state: :downloading | :completed | :error, progress: float}}` or `{:error, :not_found}`.

- [ ] **Step 1: Add the test config seam**

In `config/test.exs`, add (near the other per-impl config):

```elixir
config :cinder, Cinder.Download.Client.QBittorrent,
  base_url: "http://localhost:8080",
  username: "test",
  password: "test",
  req_options: [plug: {Req.Test, Cinder.QBittorrentStub}, retry: false]
```

- [ ] **Step 2: Write the failing tests**

Create `test/cinder/download/client/qbittorrent_test.exs`:

```elixir
defmodule Cinder.Download.Client.QBittorrentTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.QBittorrent

  # 40 hex chars; the impl lowercases what it extracts.
  @hash "0123456789ABCDEF0123456789ABCDEF01234567"

  # Serves the login round-trip (setting the SID cookie), then delegates the
  # action request to `action_fun`.
  defp stub_qbit(action_fun) do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn ->
      case conn.request_path do
        "/api/v2/auth/login" ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "SID=testsid; path=/")
          |> Req.Test.text("Ok.")

        _ ->
          action_fun.(conn)
      end
    end)
  end

  test "add/1 logs in, posts the magnet, and returns the lowercased btih hash" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/add"
      assert Plug.Conn.get_req_header(conn, "cookie") == ["SID=testsid"]
      Req.Test.text(conn, "Ok.")
    end)

    magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Movie"
    assert {:ok, "0123456789abcdef0123456789abcdef01234567"} =
             QBittorrent.add(%{download_url: magnet})
  end

  test "add/1 rejects a non-magnet download_url without calling qBittorrent" do
    assert {:error, :unsupported_download_url} =
             QBittorrent.add(%{download_url: "http://prowlarr/file/1.torrent"})
  end

  test "status/1 normalizes a completed torrent" do
    stub_qbit(fn conn ->
      assert conn.request_path == "/api/v2/torrents/info"
      assert conn.params["hashes"] == "abc123"
      Req.Test.json(conn, [%{"state" => "uploading", "progress" => 1.0}])
    end)

    assert {:ok, %{state: :completed, progress: 1.0}} = QBittorrent.status("abc123")
  end

  test "status/1 normalizes a still-downloading torrent" do
    stub_qbit(fn conn -> Req.Test.json(conn, [%{"state" => "downloading", "progress" => 0.42}]) end)

    assert {:ok, %{state: :downloading, progress: 0.42}} = QBittorrent.status("abc123")
  end

  test "status/1 returns :not_found when qBittorrent knows no such torrent" do
    stub_qbit(fn conn -> Req.Test.json(conn, []) end)

    assert {:error, :not_found} = QBittorrent.status("missing")
  end

  test "add/1 surfaces a login failure when no SID is returned" do
    Req.Test.stub(Cinder.QBittorrentStub, fn conn -> Req.Test.text(conn, "Fails.") end)

    magnet = "magnet:?xt=urn:btih:#{@hash}"
    assert {:error, :login_failed} = QBittorrent.add(%{download_url: magnet})
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/cinder/download/client/qbittorrent_test.exs`
Expected: FAIL — `Cinder.Download.Client.QBittorrent` is undefined.

- [ ] **Step 4: Implement the qBittorrent client**

Create `lib/cinder/download/client/qbittorrent.ex`:

```elixir
defmodule Cinder.Download.Client.QBittorrent do
  @moduledoc """
  Real `Cinder.Download.Client` impl, backed by `Req`, against qBittorrent's
  Web API v2.

  Reads `base_url`, `username`, `password` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. The auth flow is stateful:
  each call logs in (`POST /api/v2/auth/login`), threads the returned `SID`
  cookie into the action request, then performs it.

  Validated against a live qBittorrent only in Phase 5; the unit test is a shape
  sanity-check against `Req.Test`.
  """
  @behaviour Cinder.Download.Client

  @default_base_url "http://localhost:8080"

  # qBit upload-phase / post-download states all mean "download finished".
  @completed ~w(uploading stalledUP pausedUP forcedUP queuedUP checkingUP moving)
  @errored ~w(error missingFiles)

  @impl true
  def add(%{download_url: "magnet:" <> _ = magnet}) do
    with {:ok, hash} <- btih(magnet),
         {:ok, %{status: 200, body: body}} <-
           action(fn req -> Req.post(req, url: "/api/v2/torrents/add", form_multipart: [urls: magnet]) end) do
      # ponytail: magnet-only hash extraction; base32 btih and .torrent-URL→hash
      # (info-by-name lookup) are Phase-5 live concerns.
      if String.trim(body) == "Fails.", do: {:error, :add_rejected}, else: {:ok, hash}
    else
      :error -> {:error, :unsupported_download_url}
      other -> error(other)
    end
  end

  def add(%{download_url: _}), do: {:error, :unsupported_download_url}

  @impl true
  def status(hash) do
    case action(fn req -> Req.get(req, url: "/api/v2/torrents/info", params: [hashes: hash]) end) do
      {:ok, %{status: 200, body: [torrent | _]}} -> {:ok, normalize(torrent)}
      {:ok, %{status: 200, body: []}} -> {:error, :not_found}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  # Logs in, then runs `fun` with a Req carrying the SID cookie + base_url.
  defp action(fun) do
    config = config()

    with {:ok, sid} <- login(config) do
      config
      |> base()
      |> Keyword.put(:headers, [{"cookie", "SID=#{sid}"}])
      |> Req.new()
      |> fun.()
    end
  end

  defp login(config) do
    resp =
      config
      |> base()
      |> Keyword.put(:headers, [{"referer", Keyword.get(config, :base_url, @default_base_url)}])
      |> Req.new()
      |> Req.post(
        url: "/api/v2/auth/login",
        form: [username: Keyword.get(config, :username), password: Keyword.get(config, :password)]
      )

    case resp do
      {:ok, %{status: 200} = response} ->
        case sid_from(response) do
          nil -> {:error, :login_failed}
          sid -> {:ok, sid}
        end

      other ->
        error(other)
    end
  end

  defp sid_from(response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.find_value(fn cookie ->
      case Regex.run(~r/SID=([^;]+)/, cookie) do
        [_, sid] -> sid
        _ -> nil
      end
    end)
  end

  defp btih("magnet:" <> _ = magnet) do
    case Regex.run(~r/xt=urn:btih:([a-fA-F0-9]{40})/, magnet) do
      [_, hash] -> {:ok, String.downcase(hash)}
      _ -> :error
    end
  end

  defp normalize(torrent) do
    progress = torrent["progress"] || 0.0
    %{state: classify(torrent["state"], progress), progress: progress}
  end

  defp classify(state, _progress) when state in @errored, do: :error
  defp classify(state, progress) when state in @completed or progress >= 1.0, do: :completed
  # Catch-all so unlisted/future qBit states (forcedMetaDL, unknownState, …) are safe.
  defp classify(_state, _progress), do: :downloading

  defp base(config) do
    [base_url: Keyword.get(config, :base_url, @default_base_url)]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp error({:ok, %{status: status}}), do: {:error, {:qbittorrent_status, status}}
  defp error({:error, reason}), do: {:error, reason}
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cinder/download/client/qbittorrent_test.exs`
Expected: PASS.

- [ ] **Step 6: Add the runtime (prod/dev) config from env**

In `config/runtime.exs`, after the TMDB-token block (around line 27), add:

```elixir
# Real qBittorrent connection, read in every environment. Unset in test/CI, where
# the suite stubs Req regardless, so it has no effect there.
if base_url = System.get_env("QBITTORRENT_URL") do
  config :cinder, Cinder.Download.Client.QBittorrent,
    base_url: base_url,
    username: System.get_env("QBITTORRENT_USERNAME"),
    password: System.get_env("QBITTORRENT_PASSWORD")
end
```

- [ ] **Step 7: Run the full suite and commit**

Run: `mix test`
Expected: PASS.

```bash
git add lib/cinder/download/client/qbittorrent.ex config/test.exs config/runtime.exs test/cinder/download/client/qbittorrent_test.exs
git commit -m "Phase 3: qBittorrent Web API v2 client (login/add/status) + config"
```

---

### Task 5: Live status badges — `WatchlistLive` PubSub subscription

**Files:**
- Modify: `lib/cinder_web/live/watchlist_live.ex`
- Test: `test/cinder_web/live/watchlist_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.subscribe/0`, `Catalog.transition/2` (Task 1).
- Produces: `WatchlistLive` subscribes on connected mount and replaces the matching movie in its `watchlist` assign on `{:movie_updated, movie}`.

- [ ] **Step 1: Write the failing test**

Add to `test/cinder_web/live/watchlist_live_test.exs` (inside the module):

```elixir
  test "a movie's status change updates its badge live", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(@inception)
    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, "#watchlist", "requested")

    {:ok, _} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

    assert render(lv) =~ "downloading"
    refute has_element?(lv, "#watchlist .badge", "requested")
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder_web/live/watchlist_live_test.exs:<line>` (the new test's line)
Expected: FAIL — the badge still reads "requested"; the LiveView never received the broadcast.

- [ ] **Step 3: Subscribe and handle the broadcast**

In `lib/cinder_web/live/watchlist_live.ex`, update `mount/3` to subscribe before reading, and add a `handle_info/2`. Replace the existing `mount/3` with:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    # ponytail: subscribe-before-read closes the read/subscribe gap; full
    # reconciliation is Phase 5's dashboard concern.
    if connected?(socket), do: Catalog.subscribe()

    {:ok,
     socket
     |> assign(query: "", results: [], search_error: false)
     |> assign(watchlist: Catalog.list_watchlist())}
  end
```

And add this `handle_info/2` (place it after the `handle_event/3` clauses, before `render/1`):

```elixir
  @impl true
  def handle_info({:movie_updated, movie}, socket) do
    watchlist =
      Enum.map(socket.assigns.watchlist, fn m ->
        if m.id == movie.id, do: movie, else: m
      end)

    {:noreply, assign(socket, watchlist: watchlist)}
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cinder_web/live/watchlist_live_test.exs`
Expected: PASS (all, including the existing tests).

- [ ] **Step 5: Run the full suite and commit**

Run: `mix test`
Expected: PASS.

```bash
git add lib/cinder_web/live/watchlist_live.ex test/cinder_web/live/watchlist_live_test.exs
git commit -m "Phase 3: WatchlistLive subscribes to live status updates"
```

---

## Done-when verification (run after Task 5)

- [ ] `mix test` is fully green (the alias: compile `--warnings-as-errors`, format check, `credo --strict`, migrate, suite).
- [ ] `test/cinder/download/poller_test.exs` proves a movie walks `:requested → :searching → :downloading → :downloaded` (full-machine test) **and** the poller recovers from a kill and still advances work (crash-recovery test).
- [ ] No network in tests (Mox + Req.Test only).

## Self-review (completed during planning)

- **Spec coverage:** behaviour impl + mock (Task 4, mock pre-exists) ✓; poller advancing state under supervision (Task 3) ✓; PubSub broadcast (Task 1) + live LiveView (Task 5) ✓; full-state-machine test (Task 3) ✓; crash-recovery test (Task 3) ✓; `:no_match` terminal state (Tasks 1–2) ✓; lazy `imdb_id` (Task 2) ✓; migration (Task 1) ✓; config gating + runtime config (Tasks 3–4) ✓.
- **Type consistency:** `transition/2`, `list_by_status/1`, `get_movie/1`, `subscribe/0`, `start/1`, `Poller.poll/1`, and the `%{state:, progress:}` status shape are used identically across tasks.
- **No placeholders:** every step carries runnable code/commands.
