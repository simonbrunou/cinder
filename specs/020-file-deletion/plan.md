# Delete-file option (movie / show / season / episode) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror Sonarr/Radarr — when deleting a movie, TV show, season, or episode, optionally delete the media file(s) from disk.

**Architecture:** Add one filesystem primitive (`rm`/`rmdir`) behind the existing `Cinder.Library.Filesystem` behaviour and a path-based `Library.delete_file/1` (unlink + prune empty folders up to the library root). Extend the existing `Catalog.delete_movie`/`delete_series` with an opt-in `delete_files:` flag (best-effort), and add two new file-only operations `delete_episode_file`/`delete_season_files` (clear `file_path`, optional `unmonitor:`). Wire checkboxes into the two admin LiveViews. File logic stays in `Library`; state changes stay audited and go through `Catalog`.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView (HEEx), Ecto + ecto_sqlite3, Mox, daisyUI.

**Spec:** `docs/specs/2026-06-25-file-deletion-design.md`.

**Council review:** 1 round (architecture / implementation / red-team), all seats **sound** — no design or data-safety flaws (prune guard fails closed; no layering cycle; choke-point + file_path⊕grab_id invariant respected). Folded in: a blocker Mox count fix (Task 5 `expect(:rm, 2, …)`), the `movie_fixture`→`movie!`+`Repo.update` fixtures (Task 6), explicit catch-all clause ordering (Tasks 6–7), an out-of-root prune safety test (Task 1), re-download caveat copy (Task 7), and minor notes (TOCTOU window, symlink-root fail-closed, credo nesting extraction).

## Global Constraints

- `mix test` (the alias) is the source of truth: it runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Every task ends green.
- External services (incl. the filesystem) are reached only through behaviours, resolved at runtime via `Application.fetch_env!(:cinder, :filesystem)`. Tests use `Cinder.Library.FilesystemMock` (`test/test_helper.exs`); they never touch real disk except the existing dedicated Disk tests.
- Every movie status change goes through `Catalog.transition`; episode pipeline writes (`file_path`) go through `Catalog.transition_episode` **or**, when audited/bulk, a `Repo.transaction` mirroring `cancel_movie`/`set_season_monitored` (changeset/`update_all` + `Audit.log_or_rollback` + a single post-commit broadcast). New writers MUST NOT sidestep this.
- Audit: destructive admin actions call `Audit.log_or_rollback(actor, action, entity, detail)` **inside** the `Repo.transaction`. `action` is any atom (it is `to_string`'d — no allowlist); `entity` is the persisted struct.
- Files are **hardlinks** into the library; deleting the library copy reclaims disk space only once the download client also drops its copy. This is documented, not coded.
- Test library roots (`config/test.exs`): movies `"/tmp/cinder-test-library"`, tv `"/tmp/cinder-test-tv-library"`. `library_test.exs` aliases the movies root as `@lib`.
- daisyUI + Tailwind only; match the existing `confirm_action` + `confirming`-assign dialog pattern. Admin gating is free (all four entry points already sit on `:admin` routes).

---

### Task 1: FS `rm`/`rmdir` primitives + `Library.delete_file/1`

**Files:**
- Modify: `lib/cinder/library/filesystem.ex` (add two callbacks)
- Modify: `lib/cinder/library/filesystem/disk.ex` (add two impls)
- Modify: `lib/cinder/library.ex` (add `delete_file/1` + private pruning)
- Test: `test/cinder/library_test.exs` (new describe block)

**Interfaces:**
- Produces: `Cinder.Library.delete_file(path :: String.t() | nil) :: :ok | {:error, term()}` — unlinks `path` (idempotent: a missing file is `:ok`), then removes now-empty parent dirs strictly inside a configured library root (never a root, never anything outside). Consumed by Tasks 2–5.
- Produces: `@callback rm/1`, `@callback rmdir/1` on `Cinder.Library.Filesystem` (auto-covered by `FilesystemMock`).

- [ ] **Step 1: Write the failing tests**

Add to `test/cinder/library_test.exs` (the file already has `use ExUnit.Case, async: true`, `import Mox`, `setup :verify_on_exit!`, `@lib "/tmp/cinder-test-library"`, and `@tv_lib "/tmp/cinder-test-tv-library"` at line 14 — **reuse `@tv_lib`, do not introduce a second `@tv` constant for the same path**):

```elixir
describe "delete_file/1" do
  test "nil/blank path is a no-op (no filesystem calls)" do
    assert :ok = Cinder.Library.delete_file(nil)
    assert :ok = Cinder.Library.delete_file("")
  end

  test "unlinks the file and prunes the now-empty movie folder, stopping at the root" do
    path = "#{@lib}/Inception (2010)/Inception (2010).mkv"
    expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)
    # parent "Inception (2010)" is empty -> removed; its parent is the root -> never attempted.
    expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@lib}/Inception (2010)" -> :ok end)

    assert :ok = Cinder.Library.delete_file(path)
  end

  test "prunes Season + show folders for an episode, stopping at the tv root" do
    path = "#{@tv_lib}/Show (2010)/Season 01/Show (2010) - S01E01.mkv"
    expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)
    expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@tv_lib}/Show (2010)/Season 01" -> :ok end)
    expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@tv_lib}/Show (2010)" -> :ok end)

    assert :ok = Cinder.Library.delete_file(path)
  end

  test "stops pruning at the first non-empty parent" do
    path = "#{@lib}/Inception (2010)/Inception (2010).mkv"
    expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)
    expect(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    assert :ok = Cinder.Library.delete_file(path)
  end

  test "a missing file is idempotent (:ok) and still prunes" do
    path = "#{@lib}/Gone (2000)/Gone (2000).mkv"
    expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> {:error, :enoent} end)
    expect(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enoent} end)

    assert :ok = Cinder.Library.delete_file(path)
  end

  test "a real unlink error is surfaced and nothing is pruned" do
    path = "#{@lib}/Locked (2000)/Locked (2000).mkv"
    expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> {:error, :eacces} end)
    # no rmdir expectation -> verify_on_exit! fails if pruning is attempted.

    assert {:error, :eacces} = Cinder.Library.delete_file(path)
  end

  # Data-safety guard: a stale/misconfigured file_path OUTSIDE every library root must unlink the
  # file but NEVER attempt a single rmdir (no rmdir expectation -> verify_on_exit! fails if pruned).
  test "a path outside every library root unlinks but prunes nothing" do
    path = "/var/old/loose-movie.mkv"
    expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)

    assert :ok = Cinder.Library.delete_file(path)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/library_test.exs --only describe:"delete_file/1"` (or run the file).
Expected: FAIL — `delete_file/1` undefined (and `rm`/`rmdir` not on the mock).

- [ ] **Step 3: Add the FS callbacks**

In `lib/cinder/library/filesystem.ex`, add inside the module (after the existing callbacks):

```elixir
  @callback rm(path :: String.t()) :: :ok | {:error, term()}
  @callback rmdir(dir :: String.t()) :: :ok | {:error, term()}
```

In `lib/cinder/library/filesystem/disk.ex`, add (faithful thin wrappers — the idempotency/pruning policy lives in `Cinder.Library`, per this module's moduledoc):

```elixir
  @impl true
  def rm(path), do: File.rm(path)

  @impl true
  def rmdir(dir), do: File.rmdir(dir)
```

- [ ] **Step 4: Implement `Library.delete_file/1`**

In `lib/cinder/library.ex`, add a public function near `import_movie/1` (and the private helpers near `root/1`):

```elixir
  @doc """
  Deletes one imported library file and prunes the folders it leaves empty.

  Idempotent: a `nil`/blank path or an already-missing file is `:ok`. After unlinking, empty
  parent directories are removed walking up, stopping at (never removing) the configured library
  root — so a `Title (Year)/` or `Season NN/`→show folder disappears when it empties, but the root
  and any non-empty or out-of-library directory are untouched. A real unlink error (e.g. `:eacces`)
  is surfaced and nothing is pruned. Hardlink note: this frees disk space only once the download
  client also drops its copy. (A path that `Path.expand` can't place strictly inside a root —
  relative, `..`-laden, or a symlinked root — fails CLOSED: the file is unlinked but no folder is
  pruned. Safe-by-default for a destructive op; a symlinked root may leave empty folders behind —
  do NOT "fix" this with `File.read_link`/realpath, which would widen the deletion surface.)
  """
  @spec delete_file(String.t() | nil) :: :ok | {:error, term()}
  def delete_file(path) when path in [nil, ""], do: :ok

  def delete_file(path) do
    case fs().rm(path) do
      :ok -> prune_empty_dirs(Path.dirname(path))
      {:error, :enoent} -> prune_empty_dirs(Path.dirname(path))
      {:error, _reason} = err -> err
    end
  end

  # Remove `dir` if it is empty and strictly inside a library root, then recurse to its parent.
  # `fs().rmdir/1` only removes an empty dir, so a non-empty parent returns an error and halts the
  # walk. Always returns :ok — pruning is best-effort cleanup, never the operation's success signal.
  defp prune_empty_dirs(dir) do
    if prunable?(dir) do
      case fs().rmdir(dir) do
        :ok -> prune_empty_dirs(Path.dirname(dir))
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  # Prunable only when `dir` sits strictly inside a configured library root (never the root itself,
  # never a path outside any root) — so a misconfigured/old file_path can never rmdir outside the
  # library or delete a root. Split into a flat helper to keep credo Refactor.Nesting happy.
  defp prunable?(dir) do
    expanded = Path.expand(dir)
    Enum.any?(@kinds, &prunable_under_kind?(expanded, &1))
  end

  defp prunable_under_kind?(expanded, kind) do
    case root(kind) do
      {:ok, r} ->
        r = Path.expand(r)
        expanded != r and String.starts_with?(expanded <> "/", r <> "/")

      _ ->
        false
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cinder/library_test.exs`
Expected: PASS (all delete_file/1 tests + the existing import tests).

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/library/filesystem.ex lib/cinder/library/filesystem/disk.ex lib/cinder/library.ex test/cinder/library_test.exs
git commit -m "feat(library): rm/rmdir FS primitives + delete_file/1 with empty-dir pruning"
```

---

### Task 2: `Catalog.delete_movie/3` — opt-in `delete_files:`

**Files:**
- Modify: `lib/cinder/catalog.ex` (`delete_movie`, `do_delete_txn`, add `alias Cinder.Library`, add `best_effort_delete_file/1`)
- Test: `test/cinder/catalog_admin_test.exs` (extend the `delete_movie` describe)

**Interfaces:**
- Consumes: `Cinder.Library.delete_file/1` (Task 1).
- Produces: `Catalog.delete_movie(movie, actor, opts \\ [])` — `opts[:delete_files]` (default false) unlinks `movie.file_path` after the row delete, best-effort. Arity-2 calls keep working.
- Produces: private `best_effort_delete_file(path)` (`:ok`, logs on error) — reused by Task 3.

- [ ] **Step 1: Write the failing tests**

In `test/cinder/catalog_admin_test.exs`, ensure the file has `setup :verify_on_exit!` (add it at the top of the module if absent). Add to the `delete_movie` describe (model the existing `movie!/1` helper; give the movie a `file_path` + `:available` status via a direct `Repo.update`):

```elixir
test "delete_files: true unlinks the file, then deletes the row" do
  movie = movie!(%{title: "Inception", year: 2010})
  {:ok, movie} = movie |> Ecto.Changeset.change(status: :available, file_path: "/tmp/cinder-test-library/Inception (2010)/Inception (2010).mkv") |> Repo.update()

  expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/cinder-test-library/Inception (2010)/Inception (2010).mkv" -> :ok end)
  stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

  assert {:ok, _} = Catalog.delete_movie(movie, nil, delete_files: true)
  refute Repo.get(Movie, movie.id)
end

test "without delete_files the file is left on disk (no FS calls)" do
  movie = movie!(%{title: "Inception", year: 2010})
  {:ok, movie} = movie |> Ecto.Changeset.change(status: :available, file_path: "/tmp/x.mkv") |> Repo.update()

  # No FS expectations: verify_on_exit! fails if delete_file is reached.
  assert {:ok, _} = Catalog.delete_movie(movie, nil)
  refute Repo.get(Movie, movie.id)
end

test "delete_files: true still deletes the row when the unlink fails (best-effort)" do
  movie = movie!(%{title: "Inception", year: 2010})
  {:ok, movie} = movie |> Ecto.Changeset.change(status: :available, file_path: "/tmp/locked.mkv") |> Repo.update()

  expect(Cinder.Library.FilesystemMock, :rm, fn _ -> {:error, :eacces} end)

  assert {:ok, _} = Catalog.delete_movie(movie, nil, delete_files: true)
  refute Repo.get(Movie, movie.id)
end

test "delete_files: true with no file_path makes no FS call" do
  movie = movie!()
  assert {:ok, _} = Catalog.delete_movie(movie, nil, delete_files: true)
  refute Repo.get(Movie, movie.id)
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog_admin_test.exs -k "delete_files"` (or run the file).
Expected: FAIL — `delete_movie/3` undefined.

- [ ] **Step 3: Implement**

In `lib/cinder/catalog.ex`, add the alias (next to `alias Cinder.Download`):

```elixir
  alias Cinder.Library
```

Replace `delete_movie/2` and `do_delete_txn/2` with:

```elixir
  def delete_movie(%Movie{} = movie, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)
    # Client removal is best-effort (see maybe_cancel_download_for_delete/1).
    maybe_cancel_download_for_delete(movie)

    with {:ok, deleted} <- do_delete_txn(movie, actor, delete_files?) do
      if delete_files?, do: best_effort_delete_file(movie.file_path)
      broadcast_movie_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  defp do_delete_txn(movie, actor, delete_files?) do
    Repo.transaction(fn ->
      case Repo.delete(movie) do
        {:ok, deleted} ->
          Audit.log_or_rollback(actor, :delete_movie, deleted, %{
            title: deleted.title,
            files_deleted: delete_files?
          })

          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end
```

Add the shared helper (near `best_effort_remove/2`):

```elixir
  # Best-effort library-file unlink shared by the movie and series delete paths: a failed unlink is
  # logged, never propagated, so it can't strand the row delete. Always returns :ok.
  defp best_effort_delete_file(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("library file delete failed for #{inspect(path)}: #{inspect(reason)}")
        :ok
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog_admin_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_admin_test.exs
git commit -m "feat(catalog): delete_movie/3 opt-in delete_files (best-effort unlink)"
```

---

### Task 3: `Catalog.delete_series/3` — opt-in `delete_files:`

**Files:**
- Modify: `lib/cinder/catalog.ex` (`delete_series`, `do_delete_series_txn`, add `episode_file_paths_for_series/1`)
- Test: `test/cinder/catalog_admin_test.exs` (extend the `delete_series` describe)

**Interfaces:**
- Consumes: `best_effort_delete_file/1` (Task 2), `Library.delete_file/1` (Task 1).
- Produces: `Catalog.delete_series(series, actor, opts \\ [])` — `opts[:delete_files]` unlinks every episode `file_path` in the tree after the cascade. Arity-2 calls keep working.

- [ ] **Step 1: Write the failing tests**

In the `delete_series` describe (reuse its existing series/season/episode fixture helpers; if none, insert a series with one season + two episodes where one has a `file_path`):

```elixir
test "delete_files: true unlinks every episode file, then cascades the tree" do
  series = series_with_episode_file!(file_path: "/tmp/cinder-test-tv-library/Show (2010)/Season 01/Show (2010) - S01E01.mkv")

  expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/cinder-test-tv-library/Show (2010)/Season 01/Show (2010) - S01E01.mkv" -> :ok end)
  stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

  assert {:ok, _} = Catalog.delete_series(series, nil, delete_files: true)
  refute Repo.get(Series, series.id)
end

test "without delete_files the episode files are left (no FS calls)" do
  series = series_with_episode_file!(file_path: "/tmp/show.mkv")
  assert {:ok, _} = Catalog.delete_series(series, nil)
  refute Repo.get(Series, series.id)
end
```

Add a fixture helper in the test module (adapt to existing helpers if present):

```elixir
defp series_with_episode_file!(file_path: path) do
  series = Repo.insert!(%Series{tmdb_id: System.unique_integer([:positive]), title: "Show", year: 2010})
  season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})
  Repo.insert!(%Cinder.Catalog.Episode{season_id: season.id, episode_number: 1, file_path: path})
  series
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog_admin_test.exs -k "episode file"`
Expected: FAIL — `delete_series/3` undefined.

- [ ] **Step 3: Implement**

In `lib/cinder/catalog.ex`, replace `delete_series/2` and `do_delete_series_txn/2`:

```elixir
  def delete_series(%Series{} = series, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)
    reap_series_grabs(series.id)
    # Collect episode file paths BEFORE the cascade deletes the rows.
    paths = if delete_files?, do: episode_file_paths_for_series(series.id), else: []

    with {:ok, deleted} <- do_delete_series_txn(series, actor, delete_files?) do
      Enum.each(paths, &best_effort_delete_file/1)
      broadcast_series_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  defp do_delete_series_txn(series, actor, delete_files?) do
    Repo.transaction(fn ->
      case Repo.delete(series) do
        {:ok, deleted} ->
          Audit.log_or_rollback(actor, :delete_series, deleted, %{
            title: deleted.title,
            files_deleted: delete_files?
          })

          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  defp episode_file_paths_for_series(series_id) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id and not is_nil(e.file_path),
        select: e.file_path
    )
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog_admin_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_admin_test.exs
git commit -m "feat(catalog): delete_series/3 opt-in delete_files (unlink whole tree)"
```

---

### Task 4: `Catalog.delete_episode_file/3` — file-only delete

**Files:**
- Modify: `lib/cinder/catalog.ex` (new `delete_episode_file/3` + `do_delete_episode_file_txn/3` + `maybe_unmonitor/2`)
- Test: `test/cinder/catalog_admin_test.exs` (new describe `delete_episode_file/3`)

**Interfaces:**
- Consumes: `Library.delete_file/1` (Task 1).
- Produces: `Catalog.delete_episode_file(episode, actor, opts \\ [])` — unlinks the file, then clears `file_path` (and `monitored: false` on `opts[:unmonitor]`) in one audited transaction; broadcasts `{:series_updated, series_id}`. Returns `{:ok, episode}`, `{:error, :no_file}` (no `file_path`), or the unlink's `{:error, reason}` (DB untouched). Consumed by Task 7.

- [ ] **Step 1: Write the failing tests**

```elixir
describe "delete_episode_file/3" do
  setup :verify_on_exit!

  defp episode_with_file!(path) do
    series = Repo.insert!(%Series{tmdb_id: System.unique_integer([:positive]), title: "Show", year: 2010})
    season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})
    ep = Repo.insert!(%Cinder.Catalog.Episode{season_id: season.id, episode_number: 1, monitored: true, file_path: path})
    {series, ep}
  end

  test "unlinks the file and clears file_path, leaving it monitored (re-grab parity)" do
    {_series, ep} = episode_with_file!("/tmp/ep.mkv")
    expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/ep.mkv" -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    assert {:ok, updated} = Catalog.delete_episode_file(ep, nil)
    assert is_nil(updated.file_path)
    assert updated.monitored == true
  end

  test "unmonitor: true also clears monitored" do
    {_series, ep} = episode_with_file!("/tmp/ep.mkv")
    expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    assert {:ok, updated} = Catalog.delete_episode_file(ep, nil, unmonitor: true)
    assert is_nil(updated.file_path)
    assert updated.monitored == false
  end

  test "no file_path returns {:error, :no_file} and makes no FS call" do
    {_series, ep} = episode_with_file!(nil)
    assert {:error, :no_file} = Catalog.delete_episode_file(ep, nil)
  end

  test "a failed unlink surfaces the error and leaves file_path untouched" do
    {_series, ep} = episode_with_file!("/tmp/ep.mkv")
    expect(Cinder.Library.FilesystemMock, :rm, fn _ -> {:error, :eacces} end)

    assert {:error, :eacces} = Catalog.delete_episode_file(ep, nil)
    assert Repo.get(Cinder.Catalog.Episode, ep.id).file_path == "/tmp/ep.mkv"
  end

  test "broadcasts {:series_updated, series_id}" do
    {series, ep} = episode_with_file!("/tmp/ep.mkv")
    expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)
    Catalog.subscribe_series()

    assert {:ok, _} = Catalog.delete_episode_file(ep, nil)
    assert_receive {:series_updated, id}
    assert id == series.id
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog_admin_test.exs -k "delete_episode_file"`
Expected: FAIL — `delete_episode_file/3` undefined.

- [ ] **Step 3: Implement**

In `lib/cinder/catalog.ex`, add near `transition_episode/2`:

```elixir
  @doc """
  Deletes one episode's library file (Sonarr "delete episode file"): unlinks the file, then clears
  `file_path` so the episode reverts to its derived missing state — left monitored (the poller
  re-grabs next tick) unless `opts[:unmonitor]` also flips `monitored` off. The DB write + audit run
  in one transaction (mirroring `cancel_movie/2`); broadcasts `{:series_updated, series_id}` after
  commit. Returns `{:error, :no_file}` when there is no file, or the unlink's `{:error, reason}`
  (the DB is then untouched — the file is the whole point, so the error is surfaced, not best-effort).
  Ordering caveat: the unlink runs before the DB txn, so a (rare) txn failure after a successful
  unlink leaves `file_path` pointing at a now-deleted file (the episode reads falsely-available)
  until re-deleted or a TMDB refresh corrects it — recoverable because `rm` of a missing file is
  idempotent (`:enoent` → `:ok`).
  """
  def delete_episode_file(episode, actor, opts \\ [])

  def delete_episode_file(%Episode{file_path: p}, _actor, _opts) when p in [nil, ""],
    do: {:error, :no_file}

  def delete_episode_file(%Episode{} = episode, actor, opts) do
    unmonitor? = Keyword.get(opts, :unmonitor, false)

    with :ok <- Library.delete_file(episode.file_path),
         {:ok, updated} <- do_delete_episode_file_txn(episode, actor, unmonitor?) do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end

  defp do_delete_episode_file_txn(episode, actor, unmonitor?) do
    Repo.transaction(fn ->
      changeset =
        episode
        |> Episode.transition_changeset(%{file_path: nil})
        |> maybe_unmonitor(unmonitor?)

      case Repo.update(changeset) do
        {:ok, updated} ->
          Audit.log_or_rollback(actor, :delete_episode_file, updated, %{unmonitored: unmonitor?})
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp maybe_unmonitor(changeset, true), do: Ecto.Changeset.put_change(changeset, :monitored, false)
  defp maybe_unmonitor(changeset, false), do: changeset
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog_admin_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_admin_test.exs
git commit -m "feat(catalog): delete_episode_file/3 (unlink + clear file_path, optional unmonitor)"
```

---

### Task 5: `Catalog.delete_season_files/3` — bulk file-only delete

**Files:**
- Modify: `lib/cinder/catalog.ex` (new `delete_season_files/3` + `do_delete_season_files_txn/4`)
- Test: `test/cinder/catalog_admin_test.exs` (new describe `delete_season_files/3`)

**Interfaces:**
- Consumes: `Library.delete_file/1` (Task 1).
- Produces: `Catalog.delete_season_files(season, actor, opts \\ [])` — unlinks each episode file in the season (best-effort, per-file), then clears `file_path` (and `monitored: false` on `opts[:unmonitor]`) for the episodes whose file was actually removed, in one transaction + one `{:series_updated, _}` broadcast (mirrors `set_season_monitored/2`). Returns `{:ok, cleared_count}`. Consumed by Task 7.

- [ ] **Step 1: Write the failing tests**

```elixir
describe "delete_season_files/3" do
  setup :verify_on_exit!

  defp season_with_files!(paths) do
    series = Repo.insert!(%Series{tmdb_id: System.unique_integer([:positive]), title: "Show", year: 2010})
    season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})
    eps =
      for {path, n} <- Enum.with_index(paths, 1) do
        Repo.insert!(%Cinder.Catalog.Episode{season_id: season.id, episode_number: n, monitored: true, file_path: path})
      end
    {series, season, eps}
  end

  test "clears file_path on every episode with a file, skips fileless ones, one broadcast" do
    {series, season, [e1, e2]} = season_with_files!(["/tmp/e1.mkv", nil])
    expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/e1.mkv" -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)
    Catalog.subscribe_series()

    assert {:ok, 1} = Catalog.delete_season_files(season, nil)
    assert is_nil(Repo.get(Cinder.Catalog.Episode, e1.id).file_path)
    assert is_nil(Repo.get(Cinder.Catalog.Episode, e2.id).file_path)
    assert_receive {:series_updated, id}
    assert id == series.id
    refute_received {:series_updated, ^id}
  end

  test "unmonitor: true clears monitored on the cleared episodes" do
    {_series, season, [e1]} = season_with_files!(["/tmp/e1.mkv"])
    expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    assert {:ok, 1} = Catalog.delete_season_files(season, nil, unmonitor: true)
    assert Repo.get(Cinder.Catalog.Episode, e1.id).monitored == false
  end

  test "a per-file unlink failure leaves that episode's file_path (not cleared)" do
    {_series, season, [e1, e2]} = season_with_files!(["/tmp/ok.mkv", "/tmp/bad.mkv"])
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)
    # TWO rm calls (one per episode) -> expect/4 with an explicit count of 2. A bare 2-clause
    # expect/3 is ONE allowed call and the second rm would raise Mox.UnexpectedCallError. The
    # clauses dispatch in call order (e1 then e2, the Repo.all id order).
    expect(Cinder.Library.FilesystemMock, :rm, 2, fn
      "/tmp/ok.mkv" -> :ok
      "/tmp/bad.mkv" -> {:error, :eacces}
    end)

    assert {:ok, 1} = Catalog.delete_season_files(season, nil)
    assert is_nil(Repo.get(Cinder.Catalog.Episode, e1.id).file_path)
    assert Repo.get(Cinder.Catalog.Episode, e2.id).file_path == "/tmp/bad.mkv"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog_admin_test.exs -k "delete_season_files"`
Expected: FAIL — `delete_season_files/3` undefined.

- [ ] **Step 3: Implement**

In `lib/cinder/catalog.ex`, add near `delete_episode_file/3`:

```elixir
  @doc """
  Deletes every library file in a season (Sonarr per-season "delete episode files"): unlinks each
  episode's file (best-effort, per file), then clears `file_path` — and `monitored` off on
  `opts[:unmonitor]` — for the episodes whose file was actually removed, in ONE transaction + ONE
  `{:series_updated, _}` broadcast (mirrors `set_season_monitored/2`). A per-file unlink failure is
  logged and that episode keeps its `file_path` (so it isn't falsely marked missing). Returns
  `{:ok, cleared_count}`.
  """
  def delete_season_files(%Season{} = season, actor, opts \\ []) do
    unmonitor? = Keyword.get(opts, :unmonitor, false)

    # Bulk path mirrors set_season_monitored/2: the txn writes file_path/monitored via update_all
    # (NOT Episode.transition_changeset — file_path: nil has no validation to enforce), and the
    # read-then-write window (episodes read, files unlinked, then update_all) is the same one
    # set_season_monitored carries. Accepted at household scale (WAL + busy_timeout serializes the
    # writes; worst case a just-imported file is re-cleared and the user re-deletes).
    episodes =
      Repo.all(from e in Episode, where: e.season_id == ^season.id and not is_nil(e.file_path))

    results = Enum.map(episodes, fn ep -> {ep, Library.delete_file(ep.file_path)} end)
    cleared_ids = for {ep, :ok} <- results, do: ep.id

    for {ep, {:error, reason}} <- results do
      Logger.warning("library file delete failed for #{inspect(ep.file_path)}: #{inspect(reason)}")
    end

    with {:ok, _} <- do_delete_season_files_txn(season, actor, cleared_ids, unmonitor?) do
      broadcast_series(season.series_id)
      {:ok, length(cleared_ids)}
    end
  end

  defp do_delete_season_files_txn(season, actor, cleared_ids, unmonitor?) do
    Repo.transaction(fn ->
      sets =
        [file_path: nil, updated_at: now()] ++ if(unmonitor?, do: [monitored: false], else: [])

      Repo.update_all(from(e in Episode, where: e.id in ^cleared_ids), set: sets)

      Audit.log_or_rollback(actor, :delete_season_files, season, %{
        count: length(cleared_ids),
        unmonitored: unmonitor?
      })

      season
    end)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog_admin_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog_admin_test.exs
git commit -m "feat(catalog): delete_season_files/3 (bulk unlink + clear, one txn/broadcast)"
```

---

### Task 6: `LibraryLive` — delete-files checkbox on movie + series dialogs

**Files:**
- Modify: `lib/cinder_web/live/library_live.ex`
- Test: `test/cinder_web/live/library_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.delete_movie/3`, `Catalog.delete_series/3` (Tasks 2–3).

- [ ] **Step 1: Write the failing tests**

`library_live_test.exs` uses `use CinderWeb.ConnCase, async: false`, `import Mox`, `setup :set_mox_global`. Add (reuse the file's existing admin-login + movie/series fixtures):

The file's helper is `movie!/1` (it routes through `add_to_watchlist`, which creates a `:requested` movie and cannot cast `status`/`file_path`). Set those with a follow-up `Repo.update` — add this helper to the test module:

```elixir
defp available_movie!(file_path) do
  movie = movie!(%{title: "M", year: 2010})
  {:ok, movie} =
    movie |> Ecto.Changeset.change(status: :available, file_path: file_path) |> Cinder.Repo.update()
  movie
end
```

```elixir
test "deleting a movie with the delete-files box ticked unlinks the file", %{conn: conn} do
  movie = available_movie!("/tmp/cinder-test-library/M (2010)/M (2010).mkv")
  expect(Cinder.Library.FilesystemMock, :rm, fn "/tmp/cinder-test-library/M (2010)/M (2010).mkv" -> :ok end)
  stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

  {:ok, lv, _html} = live(conn, ~p"/library")
  lv |> element("button[phx-click=ask_delete_movie][phx-value-id='#{movie.id}']") |> render_click()
  lv |> element("input[phx-click=toggle_delete_files]") |> render_click()
  lv |> element("button[phx-click=confirm_delete_movie][phx-value-id='#{movie.id}']") |> render_click()

  refute Cinder.Repo.get(Cinder.Catalog.Movie, movie.id)
end

test "deleting a movie without ticking the box leaves the file (no FS call)", %{conn: conn} do
  movie = available_movie!("/tmp/x.mkv")
  {:ok, lv, _html} = live(conn, ~p"/library")
  lv |> element("button[phx-click=ask_delete_movie][phx-value-id='#{movie.id}']") |> render_click()
  lv |> element("button[phx-click=confirm_delete_movie][phx-value-id='#{movie.id}']") |> render_click()
  refute Cinder.Repo.get(Cinder.Catalog.Movie, movie.id)
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/cinder_web/live/library_live_test.exs -k "delete-files"`
Expected: FAIL — no `toggle_delete_files` control / file not unlinked.

- [ ] **Step 3: Implement the LiveView**

> **Clause ordering:** every new `handle_event/3` clause (incl. `toggle_delete_files`) MUST go **above** the existing terminal catch-all `def handle_event(_event, _params, socket), do: {:noreply, socket}` (library_live.ex:141). A clause after it is unreachable → `--warnings-as-errors` fails and the event silently no-ops.

In `lib/cinder_web/live/library_live.ex`:

a) Add `delete_files: false` to the `mount/3` `assign(socket, ...)` call (it currently assigns `movies/series/editing/confirming/form`).

b) Add a reset to the two `ask_delete_*` handlers and a toggle + dismiss reset:

```elixir
  def handle_event("ask_delete_movie", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:movie, :delete, id}, editing: nil, delete_files: false)}
```
```elixir
  def handle_event("ask_delete_series", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:series, :delete, id}, delete_files: false)}
```
```elixir
  def handle_event("toggle_delete_files", _params, socket),
    do: {:noreply, assign(socket, delete_files: !socket.assigns.delete_files)}
```

Update `dismiss_confirm` to also clear the flag:
```elixir
  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil, delete_files: false)}
```

c) Pass the flag through the confirm handlers:
```elixir
  def handle_event("confirm_delete_movie", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with movie when not is_nil(movie) <- find_movie(socket, id),
         {:ok, _} <- Catalog.delete_movie(movie, actor, delete_files: socket.assigns.delete_files) do
      {:noreply, socket |> assign(confirming: nil, delete_files: false) |> put_flash(:info, "Movie deleted.")}
    else
      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete that movie.")}
    end
  end
```
```elixir
  def handle_event("confirm_delete_series", %{"id" => id}, socket) do
    flag = socket.assigns.delete_files

    run_series_op(
      socket,
      id,
      fn series, actor -> Catalog.delete_series(series, actor, delete_files: flag) end,
      "Series deleted.",
      "Couldn't delete the series."
    )
  end
```
*(`run_series_op` already invokes `op.(series, actor)` — the closure is arity-2, so no change there. `confirm_cancel_series` keeps passing `&Catalog.cancel_series/2`.)*

d) Render the checkbox in each delete dialog. Replace the movie delete `<.confirm_action>` block (currently `@confirming == {:movie, :delete, ...}`) with:

```heex
            <div :if={@confirming == {:movie, :delete, to_string(m.id)}} class="mt-2 space-y-2">
              <label class="flex cursor-pointer items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  phx-click="toggle_delete_files"
                  checked={@delete_files}
                />
                <span>Also delete the file from disk</span>
              </label>
              <.confirm_action
                id={"confirm-delete-movie-#{m.id}"}
                on_confirm="confirm_delete_movie"
                on_cancel="dismiss_confirm"
                value={m.id}
                confirm_label="Delete"
              >
                <:caveat>Delete this movie's record?</:caveat>
              </.confirm_action>
            </div>
```

Replace the series delete block (`@confirming == {:series, :delete, ...}`) with the same pattern, text "Also delete files from disk", caveat "Delete this series and its seasons/episodes?".

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/cinder_web/live/library_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/live/library_live.ex test/cinder_web/live/library_live_test.exs
git commit -m "feat(library_live): delete-files checkbox on movie + series delete"
```

---

### Task 7: `SeriesDetailLive` — series delete-files + per-episode/season delete-file actions

**Files:**
- Modify: `lib/cinder_web/live/series_detail_live.ex`
- Test: `test/cinder_web/live/series_detail_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.delete_series/3`, `Catalog.delete_episode_file/3`, `Catalog.delete_season_files/3` (Tasks 3–5).

**Design:** `confirming` already an atom (`:cancel`/`:delete`); extend with `{:episode_file, id}` and `{:season_files, id}` (raw string ids from `phx-value-id`). Add a single `confirm_opt` boolean assign (the dialog's secondary toggle — "delete files" for the series dialog, "stop monitoring" for episode/season). Reset it to `false` on every `ask_*` and `dismiss_confirm`; flip via `toggle_confirm_opt`.

- [ ] **Step 1: Write the failing tests**

In `series_detail_live_test.exs` (mirror its harness — `ConnCase`, admin login, `set_mox_global`; add an episode with a `file_path`):

```elixir
test "deleting an episode file unlinks it and clears file_path (stays monitored)", %{conn: conn} do
  %{series: series, episode: ep} = series_with_episode_file_fixture("/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv")
  expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
  stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

  {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
  lv |> element("button[phx-click=ask_delete_episode_file][phx-value-id='#{ep.id}']") |> render_click()
  lv |> element("button[phx-click=confirm_delete_episode_file][phx-value-id='#{ep.id}']") |> render_click()

  reloaded = Cinder.Repo.get(Cinder.Catalog.Episode, ep.id)
  assert is_nil(reloaded.file_path)
  assert reloaded.monitored == true
end

test "deleting a season's files clears every episode file", %{conn: conn} do
  %{series: series, season: season} = season_with_files_fixture(["/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv"])
  expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
  stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

  {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
  lv |> element("button[phx-click=ask_delete_season_files][phx-value-id='#{season.id}']") |> render_click()
  lv |> element("button[phx-click=confirm_delete_season_files][phx-value-id='#{season.id}']") |> render_click()

  assert Cinder.Catalog.get_series_with_tree(series.id).seasons
         |> Enum.flat_map(& &1.episodes)
         |> Enum.all?(&is_nil(&1.file_path))
end
```

*(Add the two fixtures to the test module: insert a series→season→episode tree with the given `file_path`(s), returning the structs.)*

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/cinder_web/live/series_detail_live_test.exs -k "episode file|season's files"`
Expected: FAIL — handlers/buttons absent.

- [ ] **Step 3: Implement the LiveView**

> **Clause ordering:** all new `handle_event/3` clauses (`toggle_confirm_opt`, `ask_delete_episode_file`, `ask_delete_season_files`, `confirm_delete_episode_file`, `confirm_delete_season_files`) MUST go **above** the existing terminal catch-all `def handle_event(_event, _params, socket)` (series_detail_live.ex:123), or `--warnings-as-errors` fails.

In `lib/cinder_web/live/series_detail_live.ex`:

a) Add `confirm_opt: false` to the existing `assign(socket, series:, editing?:, confirming:, form:)` keyword call in `mount/3` (it's `assign(socket, ...)` keyword args, not a map).

b) Reset `confirm_opt` on the existing `ask_*`/`dismiss_confirm` and add the new handlers + toggle. Replace the four existing handlers and add four new ones:

```elixir
  def handle_event("ask_cancel_series", _params, socket),
    do: {:noreply, assign(socket, confirming: :cancel, editing?: false, confirm_opt: false)}

  def handle_event("ask_delete_series", _params, socket),
    do: {:noreply, assign(socket, confirming: :delete, editing?: false, confirm_opt: false)}

  def handle_event("ask_delete_episode_file", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:episode_file, id}, confirm_opt: false)}

  def handle_event("ask_delete_season_files", %{"id" => id}, socket),
    do: {:noreply, assign(socket, confirming: {:season_files, id}, confirm_opt: false)}

  def handle_event("toggle_confirm_opt", _params, socket),
    do: {:noreply, assign(socket, confirm_opt: !socket.assigns.confirm_opt)}

  def handle_event("dismiss_confirm", _params, socket),
    do: {:noreply, assign(socket, confirming: nil, confirm_opt: false)}
```

Update `confirm_delete_series` to pass the flag:
```elixir
  def handle_event("confirm_delete_series", _params, socket) do
    actor = socket.assigns.current_scope.user

    case Catalog.delete_series(socket.assigns.series, actor, delete_files: socket.assigns.confirm_opt) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Series deleted.") |> push_navigate(to: ~p"/library")}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete the series.")}
    end
  end
```

Add the two new confirm handlers (place after `confirm_delete_series`):
```elixir
  def handle_event("confirm_delete_episode_file", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with {id, ""} <- Integer.parse(id),
         %Episode{} = ep <- find_episode(socket.assigns.series, id),
         {:ok, _} <- Catalog.delete_episode_file(ep, actor, unmonitor: socket.assigns.confirm_opt) do
      {:noreply, socket |> assign(confirming: nil) |> put_flash(:info, "Episode file deleted.") |> reload()}
    else
      {:error, :no_file} ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "That episode has no file.")}

      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete the episode file.")}
    end
  end

  def handle_event("confirm_delete_season_files", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with {id, ""} <- Integer.parse(id),
         %Season{} = season <- find_season(socket.assigns.series, id),
         {:ok, n} <- Catalog.delete_season_files(season, actor, unmonitor: socket.assigns.confirm_opt) do
      {:noreply, socket |> assign(confirming: nil) |> put_flash(:info, "Deleted #{n} file(s).") |> reload()}
    else
      _ ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, "Couldn't delete the season files.")}
    end
  end
```

c) Markup. Replace the series `:delete` `<.confirm_action>` block (lines ~203–213) with the checkbox-wrapped version:

```heex
      <div :if={@confirming == :delete} class="mb-6 space-y-2">
        <label class="flex cursor-pointer items-center gap-2 text-sm">
          <input type="checkbox" class="checkbox checkbox-sm" phx-click="toggle_confirm_opt" checked={@confirm_opt} />
          <span>Also delete files from disk</span>
        </label>
        <.confirm_action id="confirm-delete-series" on_confirm="confirm_delete_series" on_cancel="dismiss_confirm" confirm_label="Delete">
          <:caveat>Delete this series and its seasons/episodes?</:caveat>
        </.confirm_action>
      </div>
```

Add a per-season "Delete files" button next to the existing "Monitor all/none" button (inside the season header `<div>`, only when the season has files), plus its confirm dialog below the header:

```heex
          <button
            :if={Enum.any?(season.episodes, & &1.file_path)}
            type="button"
            class="btn btn-xs btn-error"
            phx-click="ask_delete_season_files"
            phx-value-id={season.id}
            aria-label={"Delete all files in #{season_label(season.season_number)}"}
          >
            Delete files
          </button>
```
```heex
        <div :if={@confirming == {:season_files, to_string(season.id)}} class="mb-2 space-y-2">
          <label class="flex cursor-pointer items-center gap-2 text-sm">
            <input type="checkbox" class="checkbox checkbox-sm" phx-click="toggle_confirm_opt" checked={@confirm_opt} />
            <span>Also stop monitoring these episodes</span>
          </label>
          <.confirm_action id={"confirm-delete-season-files-#{season.id}"} on_confirm="confirm_delete_season_files" on_cancel="dismiss_confirm" value={season.id} confirm_label="Delete files">
            <:caveat>
              Delete every downloaded file in {season_label(season.season_number)}? Monitored
              episodes will be re-downloaded next sweep unless you also stop monitoring.
            </:caveat>
          </.confirm_action>
        </div>
```

Add a per-episode "Delete file" button + confirm inside each episode `<li>` (only when `ep.file_path`):

```heex
          <li :for={ep <- season.episodes} class="flex flex-col gap-2 py-2">
            <div class="flex items-center gap-3">
              <input
                type="checkbox"
                class="toggle toggle-sm"
                checked={ep.monitored}
                phx-click="toggle_episode"
                phx-value-id={ep.id}
                aria-label={"Monitor #{season_label(season.season_number)} episode #{ep.episode_number}"}
              />
              <span class="w-8 text-sm tabular-nums text-base-content/60">{ep.episode_number}</span>
              <span class="flex-1 text-sm">{ep.title}</span>
              <span :if={ep.air_date} class="text-xs text-base-content/50">{ep.air_date}</span>
              <button
                :if={ep.file_path}
                type="button"
                class="btn btn-xs btn-error"
                phx-click="ask_delete_episode_file"
                phx-value-id={ep.id}
                aria-label={"Delete file for #{season_label(season.season_number)} episode #{ep.episode_number}"}
              >
                Delete file
              </button>
            </div>
            <div :if={@confirming == {:episode_file, to_string(ep.id)}} class="space-y-2">
              <label class="flex cursor-pointer items-center gap-2 text-sm">
                <input type="checkbox" class="checkbox checkbox-sm" phx-click="toggle_confirm_opt" checked={@confirm_opt} />
                <span>Also stop monitoring this episode</span>
              </label>
              <.confirm_action id={"confirm-delete-episode-file-#{ep.id}"} on_confirm="confirm_delete_episode_file" on_cancel="dismiss_confirm" value={ep.id} confirm_label="Delete file">
                <:caveat>
                  Delete the downloaded file for this episode? If it stays monitored the poller
                  re-downloads it next tick — tick "stop monitoring" to keep it gone.
                </:caveat>
              </.confirm_action>
            </div>
          </li>
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/cinder_web/live/series_detail_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder_web/live/series_detail_live.ex test/cinder_web/live/series_detail_live_test.exs
git commit -m "feat(series_detail_live): delete-files for series + per-episode/season file delete"
```

---

### Task 8: Docs + graph refresh

**Files:**
- Modify: `CHANGELOG.md` (the `[Unreleased]` section)
- Modify: `docs/operating.md` (deletion behavior note)
- Modify: `graphify-out/` (regenerated)

- [ ] **Step 1: CHANGELOG**

Under `## [Unreleased]` → `### Added`, add:

```markdown
- Delete media files from disk when removing a movie, TV show, season, or episode (opt-in
  checkbox on the delete dialogs; mirrors Sonarr/Radarr). Deleting a season/episode file leaves
  the item monitored so the poller re-grabs it, unless you also tick "stop monitoring". Empty
  library folders are pruned. Because library files are hardlinks, disk space is reclaimed only
  once the download client also drops its copy.
```

- [ ] **Step 2: operating.md**

Add a short "Deleting media" subsection to `docs/operating.md` capturing: where the controls live (`/library` for movie/show, `/series/:id` for season/episode), the opt-in nature, the re-grab-if-monitored behavior, and the hardlink space-reclamation caveat. Keep it to a short paragraph + a bullet or two — match the file's existing tone.

- [ ] **Step 3: Refresh the graph + run the full suite**

Run:
```bash
graphify update .
mix test
```
Expected: `mix test` fully green (compile clean, format clean, credo --strict clean, suite passing).

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md docs/operating.md graphify-out
git commit -m "docs(delete): document delete-file behavior; refresh graph"
```

---

## Self-Review

**Spec coverage:**
- FS `rm` primitive + idempotency → Task 1 (`rm` callback + `delete_file/1`). ✓ (also `rmdir`, needed for the spec's empty-folder pruning).
- `Library.delete_file/1` unlink + prune to root → Task 1. ✓
- Movie/show entity delete `delete_files?` (best-effort) → Tasks 2–3. ✓
- Episode/season file-only delete (clear `file_path`, optional `unmonitor`) → Tasks 4–5. ✓ (episode surfaces errors; season is per-file best-effort, one txn/broadcast mirroring `set_season_monitored`).
- UI checkboxes (movie/show dialogs + per-episode/season actions, "stop monitoring" default off) → Tasks 6–7. ✓
- Audit + broadcasts reused/extended → Tasks 2–5 (audit detail `files_deleted`/`unmonitored`/`count`; `{:movie_deleted}`/`{:series_deleted}`/`{:series_updated}`). ✓
- Hardlink doc note → Task 8. ✓
- Out of scope (movie-file-only-keep-movie, bulk multi-select, removing client copy) → not built. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. Test fixtures that "adapt to existing helpers" name the exact fields to set — acceptable, as the executor reads the neighboring fixtures.

**Type consistency:** `delete_file/1`, `best_effort_delete_file/1`, `delete_movie/3`, `delete_series/3`, `delete_episode_file/3`, `delete_season_files/3`, events `toggle_delete_files`/`toggle_confirm_opt`, assigns `delete_files`/`confirm_opt`, `confirming` tuples `{:episode_file, id}`/`{:season_files, id}` — used consistently across tasks. `delete_episode_file` returns `{:ok, episode} | {:error, :no_file} | {:error, reason}`; `delete_season_files` returns `{:ok, count}`. ✓
