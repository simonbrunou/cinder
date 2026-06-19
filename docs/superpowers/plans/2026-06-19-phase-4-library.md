# Phase 4 — Library (import into Jellyfin) Implementation Plan

**Council review: 2 rounds — sound. R1 (compile/credo, test/Mox, completeness reviewers) confirmed
the code compiles under `--warnings-as-errors`, passes `credo --strict` (nesting ≤1, literal-list
guards, no unused vars/aliases), and that all tests pass-as-written with correct TDD-red — including
the load-bearing invariant that the four existing poller tests stay green unchanged (nil `file_path`
→ clean `:no_file_path` skip). Fixes applied: split the multi-alias into two single lines
(credo consistency), baked the session footer into all six commit heredocs, and documented the
unset-`LIBRARY_PATH` dev gap + the intentional supersede of the spec's stub-update step. R2 verified
all fixes are correct with no new issues. No residual disagreement.**

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a movie reaches `:downloaded`, hardlink its file into a Jellyfin library renamed to `Title (Year)/Title (Year).ext`, trigger a Jellyfin scan, and mark it `:available` — crash-recoverably, via the existing stateless poller.

**Architecture:** A new `Cinder.Library` context orchestrates import using two behaviours — `Cinder.Library.Filesystem` (thin disk primitives) and the existing `Cinder.Library.MediaServer` (Jellyfin scan). The poller persists the at-rest `content_path` to a new `Movie.file_path` on the `:downloading → :downloaded` transition, then a second poll pass imports `:downloaded` movies → `:available`. A crash between the two leaves the movie at `:downloaded` and the next tick retries.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto + ecto_sqlite3, `Req`, Mox, ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-19-phase-4-library-design.md`

## Global Constraints

- Elixir `~> 1.15`. Branch: `phase-4-library` (already checked out).
- The gate for every task is the `test` alias: `mix test` runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `ecto.create --quiet`, `ecto.migrate --quiet`, `test`. A task is done only when `mix format` + `mix test` are clean.
- External services are reached **only** through behaviours, resolved at runtime with `Application.fetch_env!/2` at the point of use — **never `compile_env!`** (it inlines the Mox mock, which warns under `--warnings-as-errors`).
- Tests never hit the network or disk — **except** the one `Filesystem.Disk` test, which is explicitly isolated with ExUnit's `@tag :tmp_dir`.
- Mox mocks are defined in `test/test_helper.exs`. Poller-process tests use `set_mox_global` + `stub` + `async: false` and assert outcomes; in-test-process unit tests use `expect` + `verify_on_exit!` + `async: true`.
- Every commit message ends with the session footer (already baked into the `git commit` heredocs below):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01MukXNoDXdSQNtfptEqzQCJ
  ```
- No UI change: the watchlist LiveView already renders any status (including `:available`) as a badge.

---

### Task 1: Add `file_path` to the Movie schema

**Files:**
- Create: `priv/repo/migrations/<generated>_add_file_path_to_movies.exs`
- Modify: `lib/cinder/catalog/movie.ex` (schema + `transition_changeset/2`)
- Test: `test/cinder/catalog_test.exs` (add one transition round-trip test)

**Interfaces:**
- Produces: `%Cinder.Catalog.Movie{file_path: String.t() | nil}`; `Catalog.transition(movie, %{status: ..., file_path: ...})` persists `file_path`.

- [ ] **Step 1: Write the failing test**

Append to `test/cinder/catalog_test.exs` (inside the test module, alongside the existing `transition/2` tests):

```elixir
  test "transition/2 persists file_path" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9001, title: "Heat"})

    assert {:ok, %Movie{file_path: "/downloads/Heat.1995.mkv"}} =
             Catalog.transition(movie, %{status: :downloaded, file_path: "/downloads/Heat.1995.mkv"})

    assert %Movie{file_path: "/downloads/Heat.1995.mkv"} = Repo.get!(Movie, movie.id)
  end
```

(If `Movie`/`Repo` aren't already aliased in this file, add `alias Cinder.Catalog.Movie` and `alias Cinder.Repo` — check the top of the file first; the catalog tests already use them.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/catalog_test.exs`
Expected: FAIL — `file_path` is dropped (not cast), so the returned/reloaded struct has `file_path: nil`.

- [ ] **Step 3: Generate the migration**

Run: `mix ecto.gen.migration add_file_path_to_movies`

Replace the generated file's body with:

```elixir
defmodule Cinder.Repo.Migrations.AddFilePathToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :file_path, :string
    end
  end
end
```

- [ ] **Step 4: Add the field + cast**

In `lib/cinder/catalog/movie.ex`, add the field to the schema (after `field :download_id, :string`):

```elixir
    field :download_id, :string
    field :file_path, :string
```

And add `:file_path` to the transition cast list:

```elixir
  def transition_changeset(movie, attrs) do
    movie
    |> cast(attrs, [:status, :download_id, :imdb_id, :file_path])
    |> validate_required([:status])
  end
```

- [ ] **Step 5: Migrate and run the test**

Run: `mix ecto.migrate && mix test test/cinder/catalog_test.exs`
Expected: PASS.

- [ ] **Step 6: Full gate + commit**

```bash
mix format
mix test
git add priv/repo/migrations lib/cinder/catalog/movie.ex test/cinder/catalog_test.exs
git commit -m "$(cat <<'EOF'
Phase 4: add Movie.file_path (downloaded file on disk)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01MukXNoDXdSQNtfptEqzQCJ
EOF
)"
```

---

### Task 2: `Cinder.Library.Filesystem` behaviour + `Disk` impl

**Files:**
- Create: `lib/cinder/library/filesystem.ex` (behaviour)
- Create: `lib/cinder/library/filesystem/disk.ex` (real impl)
- Modify: `test/test_helper.exs` (Mox mock)
- Modify: `config/config.exs` (real impl), `config/test.exs` (mock)
- Test: `test/cinder/library/filesystem/disk_test.exs`

**Interfaces:**
- Produces — `Cinder.Library.Filesystem` callbacks:
  - `dir?(path :: String.t()) :: boolean()`
  - `find_files(dir :: String.t()) :: {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}`
  - `mkdir_p(dir :: String.t()) :: :ok | {:error, term()}`
  - `ln(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}`
- Produces — config key `config :cinder, :filesystem` (impl module) and Mox `Cinder.Library.FilesystemMock`.

- [ ] **Step 1: Define the behaviour**

Create `lib/cinder/library/filesystem.ex`:

```elixir
defmodule Cinder.Library.Filesystem do
  @moduledoc """
  Thin filesystem primitives behind a behaviour so the import is testable
  without touching disk. The "pick the right video file" policy lives in
  `Cinder.Library`, not here.
  """

  @callback dir?(path :: String.t()) :: boolean()
  @callback find_files(dir :: String.t()) ::
              {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  @callback mkdir_p(dir :: String.t()) :: :ok | {:error, term()}
  @callback ln(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
end
```

- [ ] **Step 2: Register the Mox mock + config**

In `test/test_helper.exs`, add after the existing `Mox.defmock(...)` lines:

```elixir
Mox.defmock(Cinder.Library.FilesystemMock, for: Cinder.Library.Filesystem)
```

In `config/config.exs`, add after `config :cinder, download_client: Cinder.Download.Client.QBittorrent`:

```elixir
config :cinder, filesystem: Cinder.Library.Filesystem.Disk
```

In `config/test.exs`, add `filesystem:` to the mock block so it reads:

```elixir
config :cinder,
  tmdb: Cinder.Catalog.TMDBMock,
  indexer: Cinder.Acquisition.IndexerMock,
  download_client: Cinder.Download.ClientMock,
  media_server: Cinder.Library.MediaServerMock,
  filesystem: Cinder.Library.FilesystemMock
```

- [ ] **Step 3: Write the failing Disk test**

Create `test/cinder/library/filesystem/disk_test.exs`:

```elixir
defmodule Cinder.Library.Filesystem.DiskTest do
  # The one place real disk is allowed: ExUnit's :tmp_dir, auto-created and
  # cleaned per test. Everything else mocks the Filesystem behaviour.
  use ExUnit.Case, async: true

  alias Cinder.Library.Filesystem.Disk

  @tag :tmp_dir
  test "dir?/find_files/mkdir_p/ln operate on real files", %{tmp_dir: tmp} do
    refute Disk.dir?(Path.join(tmp, "nope.mkv"))
    assert Disk.dir?(tmp)

    release = Path.join(tmp, "release")
    File.mkdir_p!(Path.join(release, "Sample"))
    File.write!(Path.join(release, "feature.mkv"), String.duplicate("x", 100))
    File.write!(Path.join(release, "Sample/sample.mkv"), "x")

    assert {:ok, files} = Disk.find_files(release)
    paths = Enum.map(files, fn {p, _size} -> p end)
    assert Path.join(release, "feature.mkv") in paths
    assert Path.join(release, "Sample/sample.mkv") in paths
    assert {_, 100} = Enum.find(files, fn {p, _} -> p == Path.join(release, "feature.mkv") end)

    lib = Path.join(tmp, "lib/Movie (2020)")
    assert :ok = Disk.mkdir_p(lib)
    assert Disk.dir?(lib)

    src = Path.join(release, "feature.mkv")
    dest = Path.join(lib, "Movie (2020).mkv")
    assert :ok = Disk.ln(src, dest)
    assert File.read!(dest) == String.duplicate("x", 100)
    # Hardlink shares the inode; a second link to the same dest is :eexist.
    assert {:error, :eexist} = Disk.ln(src, dest)
  end
end
```

- [ ] **Step 4: Run to verify it fails**

Run: `mix test test/cinder/library/filesystem/disk_test.exs`
Expected: FAIL — `Cinder.Library.Filesystem.Disk` is undefined.

- [ ] **Step 5: Implement the Disk impl**

Create `lib/cinder/library/filesystem/disk.ex`:

```elixir
defmodule Cinder.Library.Filesystem.Disk do
  @moduledoc """
  Real `Cinder.Library.Filesystem` impl over the local filesystem.
  `ln/2` is a hardlink (`File.ln/2`) — the library must be on the same
  filesystem as the downloads (see the Phase-4 spec's Assumptions).
  """
  @behaviour Cinder.Library.Filesystem

  @impl true
  def dir?(path), do: File.dir?(path)

  @impl true
  def find_files(dir) do
    files =
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        case File.stat(path) do
          {:ok, %File.Stat{size: size}} -> [{path, size}]
          {:error, _reason} -> []
        end
      end)

    {:ok, files}
  end

  @impl true
  def mkdir_p(dir), do: File.mkdir_p(dir)

  @impl true
  def ln(source, dest), do: File.ln(source, dest)
end
```

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/cinder/library/filesystem/disk_test.exs`
Expected: PASS.

- [ ] **Step 7: Full gate + commit**

```bash
mix format
mix test
git add lib/cinder/library/filesystem.ex lib/cinder/library/filesystem/disk.ex \
        test/cinder/library/filesystem/disk_test.exs test/test_helper.exs \
        config/config.exs config/test.exs
git commit -m "$(cat <<'EOF'
Phase 4: Filesystem behaviour + Disk impl (hardlink primitives)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01MukXNoDXdSQNtfptEqzQCJ
EOF
)"
```

---

### Task 3: `Cinder.Library.MediaServer.Jellyfin` impl

**Files:**
- Create: `lib/cinder/library/media_server/jellyfin.ex`
- Modify: `config/config.exs` (real impl), `config/test.exs` (Req.Test stub for the impl's own test), `config/runtime.exs` (Jellyfin url/key)
- Test: `test/cinder/library/media_server/jellyfin_test.exs`

**Interfaces:**
- Consumes: existing `Cinder.Library.MediaServer` behaviour (`@callback scan() :: :ok | {:error, term()}`).
- Produces: `config :cinder, :media_server` (impl module); `Cinder.Library.MediaServer.Jellyfin.scan/0`.

- [ ] **Step 1: Wire config**

In `config/config.exs`, add after the `filesystem:` line from Task 2:

```elixir
config :cinder, media_server: Cinder.Library.MediaServer.Jellyfin
```

In `config/test.exs`, add (the suite uses the mock for `:media_server`; this block is only for the Jellyfin impl's own unit test, which routes `Req` through a stub):

```elixir
config :cinder, Cinder.Library.MediaServer.Jellyfin,
  url: "http://localhost:8096",
  api_key: "test-key",
  req_options: [plug: {Req.Test, Cinder.JellyfinStub}, retry: false]
```

In `config/runtime.exs`, add after the qBittorrent block (guarded, so dev/test boot without it):

```elixir
# Real Jellyfin connection, read in every environment. Unset in test/CI, where
# the suite either mocks media_server or stubs Req, so it has no effect there.
if url = System.get_env("JELLYFIN_URL") do
  config :cinder, Cinder.Library.MediaServer.Jellyfin,
    url: url,
    api_key: System.get_env("JELLYFIN_API_KEY")
end
```

- [ ] **Step 2: Write the failing test**

Create `test/cinder/library/media_server/jellyfin_test.exs`:

```elixir
defmodule Cinder.Library.MediaServer.JellyfinTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.MediaServer.Jellyfin

  test "scan/0 posts to /Library/Refresh with the api token and returns :ok on 204" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/Library/Refresh"
      assert Plug.Conn.get_req_header(conn, "x-emby-token") == ["test-key"]

      conn
      |> Plug.Conn.put_status(204)
      |> Req.Test.text("")
    end)

    assert :ok = Jellyfin.scan()
  end

  test "scan/0 surfaces a non-2xx status as an error" do
    Req.Test.stub(Cinder.JellyfinStub, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.text("Unauthorized")
    end)

    assert {:error, {:jellyfin_status, 401}} = Jellyfin.scan()
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/cinder/library/media_server/jellyfin_test.exs`
Expected: FAIL — `Cinder.Library.MediaServer.Jellyfin` is undefined.

- [ ] **Step 4: Implement the impl**

Create `lib/cinder/library/media_server/jellyfin.ex`:

```elixir
defmodule Cinder.Library.MediaServer.Jellyfin do
  @moduledoc """
  Real `Cinder.Library.MediaServer` impl, backed by `Req`, against Jellyfin's
  HTTP API. `scan/0` triggers a full library refresh (`POST /Library/Refresh`).

  Reads `url`, `api_key`, and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Validated against a live
  Jellyfin only in Phase 5.
  """
  @behaviour Cinder.Library.MediaServer

  @impl true
  def scan do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: Keyword.get(config, :url),
      headers: [{"x-emby-token", Keyword.get(config, :api_key)}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
    |> Req.post(url: "/Library/Refresh")
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:jellyfin_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/cinder/library/media_server/jellyfin_test.exs`
Expected: PASS.

- [ ] **Step 6: Full gate + commit**

```bash
mix format
mix test
git add lib/cinder/library/media_server/jellyfin.ex \
        test/cinder/library/media_server/jellyfin_test.exs \
        config/config.exs config/test.exs config/runtime.exs
git commit -m "$(cat <<'EOF'
Phase 4: Jellyfin MediaServer impl (full library refresh)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01MukXNoDXdSQNtfptEqzQCJ
EOF
)"
```

---

### Task 4: `Cinder.Library` context (`import_movie/1`)

**Files:**
- Create: `lib/cinder/library.ex`
- Modify: `config/test.exs` (test `library_path`), `config/runtime.exs` (`LIBRARY_PATH`)
- Test: `test/cinder/library_test.exs`

**Interfaces:**
- Consumes: `Cinder.Library.Filesystem` mock (Task 2), `Cinder.Library.MediaServer` mock (already wired), `config :cinder, :library_path`, `%Cinder.Catalog.Movie{title, year, file_path}`.
- Produces: `Cinder.Library.import_movie(%Movie{}) :: {:ok, dest :: String.t()} | {:error, term()}` — errors include `:no_file_path`, `:no_video_file`.

- [ ] **Step 1: Wire `library_path` config**

In `config/test.exs`, add (never written — the FS is mocked; it only needs to be a stable string for dest assertions):

```elixir
config :cinder, :library_path, "/tmp/cinder-test-library"
```

In `config/runtime.exs`, add after the Jellyfin block (guarded):

```elixir
# Where Cinder hardlinks imported movies (Jellyfin's library root).
if path = System.get_env("LIBRARY_PATH") do
  config :cinder, :library_path, path
end
```

- [ ] **Step 2: Write the failing tests**

Create `test/cinder/library_test.exs`:

```elixir
defmodule Cinder.LibraryTest do
  # In-test-process unit tests: expect + verify_on_exit!, no DB, no disk.
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Catalog.Movie
  alias Cinder.Library

  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"

  test "single-file source: hardlinks to Title (Year)/Title (Year).ext and scans" do
    movie = %Movie{title: "Inception", year: 2010, file_path: "/dl/Inception.2010.1080p.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Inception.2010.1080p.mkv" -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/Inception (2010)" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Inception.2010.1080p.mkv",
                                                  "#{@lib}/Inception (2010)/Inception (2010).mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, "#{@lib}/Inception (2010)/Inception (2010).mkv"} = Library.import_movie(movie)
  end

  test "folder source: picks the largest video file and skips the sample" do
    movie = %Movie{title: "Dune", year: 2021, file_path: "/dl/Dune.2021"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Dune.2021" -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/Dune.2021" ->
      {:ok,
       [
         {"/dl/Dune.2021/sample.mkv", 50_000_000},
         {"/dl/Dune.2021/Dune.2021.1080p.mkv", 9_000_000_000},
         {"/dl/Dune.2021/readme.nfo", 2_000}
       ]}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Dune.2021/Dune.2021.1080p.mkv",
                                                  "#{@lib}/Dune (2021)/Dune (2021).mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end

  test "treats :eexist from ln as success (idempotent re-run)" do
    movie = %Movie{title: "Heat", year: 1995, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end

  test "folder with no video file → {:error, :no_video_file}, no scan" do
    movie = %Movie{title: "X", year: 2000, file_path: "/dl/X"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/X/a.nfo", 10}, {"/dl/X/b.rar", 9_999}]}
    end)

    # No mkdir_p / ln / scan expected — verify_on_exit! fails if any is called.
    assert {:error, :no_video_file} = Library.import_movie(movie)
  end

  test "nil file_path → {:error, :no_file_path}, no FS calls" do
    assert {:error, :no_file_path} =
             Library.import_movie(%Movie{title: "X", year: 2000, file_path: nil})
  end

  test "sanitizes filesystem-illegal characters in the title" do
    movie = %Movie{title: "Face/Off", year: 1997, file_path: "/dl/FaceOff.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/FaceOff (1997)" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/FaceOff (1997)/FaceOff (1997).mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/cinder/library_test.exs`
Expected: FAIL — `Cinder.Library.import_movie/1` is undefined.

- [ ] **Step 4: Implement the context**

Create `lib/cinder/library.ex`:

```elixir
defmodule Cinder.Library do
  @moduledoc """
  Import: hardlink a completed download into the Jellyfin library, renamed to
  `Title (Year)/Title (Year).ext`, then trigger a library scan.

  Filesystem ops and the media server are reached only through behaviours
  (`Cinder.Library.Filesystem`, `Cinder.Library.MediaServer`), resolved from
  config at runtime so tests use Mox mocks and never touch disk or the network.
  Owns filesystem + Jellyfin only — `Catalog` remains the status choke-point.
  """

  alias Cinder.Catalog.Movie

  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)
  @illegal ~r/[\/\\:*?"<>|]/

  @doc """
  Hardlinks `movie`'s downloaded file into the library and triggers a scan.
  Returns `{:ok, dest_path}` or `{:error, reason}`. Idempotent: a dest that
  already exists (`:eexist`) is treated as success.
  """
  @spec import_movie(Movie.t()) :: {:ok, String.t()} | {:error, term()}
  def import_movie(%Movie{file_path: path}) when path in [nil, ""], do: {:error, :no_file_path}

  def import_movie(%Movie{} = movie) do
    with {:ok, source} <- resolve_source(movie.file_path),
         dest = build_dest(movie, source),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         :ok <- link(source, dest),
         :ok <- media_server().scan() do
      {:ok, dest}
    end
  end

  # content_path is a file for single-file torrents, a folder for multi-file ones.
  defp resolve_source(path) do
    if fs().dir?(path) do
      with {:ok, files} <- fs().find_files(path), do: pick_video(files)
    else
      {:ok, path}
    end
  end

  # Largest video file wins (skips samples/extras); lexicographic path breaks ties
  # so the choice — and therefore the dest — is stable across retries.
  defp pick_video(files) do
    files
    |> Enum.filter(fn {p, _size} -> String.downcase(Path.extname(p)) in @video_exts end)
    |> Enum.sort_by(fn {p, size} -> {-size, p} end)
    |> case do
      [{path, _size} | _] -> {:ok, path}
      [] -> {:error, :no_video_file}
    end
  end

  defp build_dest(%Movie{title: title, year: year}, source) do
    name = "#{sanitize(title)} (#{year})"
    Path.join([library_path(), name, name <> Path.extname(source)])
  end

  defp sanitize(title), do: String.replace(title, @illegal, "")

  # ponytail: hardlink only; library must share the downloads' filesystem (see spec).
  defp link(source, dest) do
    case fs().ln(source, dest) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp media_server, do: Application.fetch_env!(:cinder, :media_server)
  defp library_path, do: Application.fetch_env!(:cinder, :library_path)
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/cinder/library_test.exs`
Expected: PASS (all 6 tests).

- [ ] **Step 6: Full gate + commit**

```bash
mix format
mix test
git add lib/cinder/library.ex test/cinder/library_test.exs config/test.exs config/runtime.exs
git commit -m "$(cat <<'EOF'
Phase 4: Library.import_movie/1 (hardlink + rename + scan)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01MukXNoDXdSQNtfptEqzQCJ
EOF
)"
```

---

### Task 5: qBittorrent — carry `content_path`, hold `moving` as not-at-rest

**Files:**
- Modify: `lib/cinder/download/client/qbittorrent.ex` (`normalize/1`, `@completed`, `classify/2`)
- Test: `test/cinder/download/client/qbittorrent_test.exs` (add two tests)

**Interfaces:**
- Produces: `Cinder.Download.Client.QBittorrent.status/1` now returns `%{state:, progress:, content_path:}`; a `moving` torrent classifies `:downloading` (not `:completed`).

- [ ] **Step 1: Write the failing tests**

Append to `test/cinder/download/client/qbittorrent_test.exs` (inside the module):

```elixir
  test "status/1 carries the content_path from the torrent info" do
    stub_qbit(fn conn ->
      Req.Test.json(conn, [
        %{"state" => "uploading", "progress" => 1.0, "content_path" => "/downloads/Movie/Movie.mkv"}
      ])
    end)

    assert {:ok, %{state: :completed, content_path: "/downloads/Movie/Movie.mkv"}} =
             QBittorrent.status("abc123")
  end

  test "status/1 classifies a relocating (moving) torrent as still downloading" do
    stub_qbit(fn conn ->
      Req.Test.json(conn, [%{"state" => "moving", "progress" => 1.0}])
    end)

    assert {:ok, %{state: :downloading}} = QBittorrent.status("abc123")
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/cinder/download/client/qbittorrent_test.exs`
Expected: FAIL — `content_path` key absent; `moving` at `progress 1.0` currently classifies `:completed`.

- [ ] **Step 3: Implement the changes**

In `lib/cinder/download/client/qbittorrent.ex`, change the module attributes (drop `moving` from `@completed`, add `@in_transit`):

```elixir
  # qBit upload-phase / post-download states all mean "download finished, at rest".
  @completed ~w(uploading stalledUP pausedUP forcedUP queuedUP checkingUP)
  # Finished downloading but relocating the file — not at rest, path not yet final.
  @in_transit ~w(moving)
  @errored ~w(error missingFiles)
```

Change `normalize/1` to carry `content_path`:

```elixir
  defp normalize(torrent) do
    progress = torrent["progress"] || 0.0

    %{
      state: classify(torrent["state"], progress),
      progress: progress,
      content_path: torrent["content_path"]
    }
  end
```

Add the `@in_transit` clause to `classify/2`, ordered **before** the completed clause (the `progress >= 1.0` fallback stays so any non-`moving` finished torrent still completes):

```elixir
  defp classify(state, _progress) when state in @errored, do: :error
  defp classify(state, _progress) when state in @in_transit, do: :downloading
  defp classify(state, progress) when state in @completed or progress >= 1.0, do: :completed
  # Catch-all so unlisted/future qBit states (forcedMetaDL, unknownState, …) are safe.
  defp classify(_state, _progress), do: :downloading
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/cinder/download/client/qbittorrent_test.exs`
Expected: PASS (existing tests — `uploading`→`:completed`, `downloading`→`:downloading`, `:not_found` — still pass; the `content_path: nil` they now also return is not asserted, so partial map matches hold).

- [ ] **Step 5: Full gate + commit**

```bash
mix format
mix test
git add lib/cinder/download/client/qbittorrent.ex test/cinder/download/client/qbittorrent_test.exs
git commit -m "$(cat <<'EOF'
Phase 4: qBittorrent status carries content_path; hold moving as in-transit

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01MukXNoDXdSQNtfptEqzQCJ
EOF
)"
```

---

### Task 6: Poller — snapshot `file_path`, second pass imports to `:available`

**Files:**
- Modify: `lib/cinder/download/poller.ex` (two passes + error isolation)
- Test: `test/cinder/download/poller_test.exs` (add import tests; existing tests stay green unchanged)

**Interfaces:**
- Consumes: `Catalog.transition/2` with `:file_path` (Task 1), `Cinder.Library.import_movie/1` (Task 4), `client().status/1` returning `:content_path` (Task 5).
- Produces: the full `:downloading → :downloaded → :available` pipeline, driven statelessly each tick.

> **Note on existing tests:** the four current poller tests stub `status` as `{:ok, %{state: :completed}}` with no `content_path`, so pass 1 records `file_path: nil`; pass 2's `import_movie` returns `{:error, :no_file_path}` cleanly (no FS mock call, no crash) and the movie stays `:downloaded`. Their `:downloaded` assertions therefore still pass **unchanged** — do not edit them. New behaviour gets new tests. (This intentionally supersedes the spec's build-step-7 "update existing stubs for fidelity" line: the lower-touch choice keeps the Phase-3 tests untouched and green, and the spec itself noted that update was for fidelity, not correctness.)

- [ ] **Step 1: Write the failing import tests**

Append to `test/cinder/download/poller_test.exs` (inside the module; `setup :set_mox_global` already applies):

```elixir
  defp downloaded_movie(tmdb_id, file_path) do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: tmdb_id, title: "Inception", year: 2010})
    {:ok, movie} = Catalog.transition(movie, %{status: :downloaded, file_path: file_path})
    movie
  end

  # Doubles as the import-pass crash-recovery proof: a movie already stranded at
  # :downloaded (crash after download, before import) is imported on a later poll.
  test "imports a :downloaded movie into the library and marks it :available" do
    movie = downloaded_movie(10, "/downloads/Inception.2010.1080p.mkv")
    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    assert_receive {:movie_updated, %Movie{status: :available}}
  end

  test "a failed import leaves the movie :downloaded for retry" do
    movie = downloaded_movie(11, "/downloads/Inception.2010.1080p.mkv")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn -> {:error, :jellyfin_down} end)

    assert :ok = Poller.poll()
    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/cinder/download/poller_test.exs`
Expected: FAIL — the poller does not yet import `:downloaded` movies, so the movie stays `:downloaded` (first test expects `:available`).

- [ ] **Step 3: Rewrite the poller's poll logic**

In `lib/cinder/download/poller.ex`:

Add `require Logger` and a `Library` alias near the top. Use two single-`alias` lines (not `alias Cinder.{Catalog, Library}`) to match the stacked single-alias style in `catalog.ex`/`acquisition.ex` — the lowest-risk choice for the majority-wins `Credo.Check.Consistency.MultiAliasImportRequireUse`. The existing line is `alias Cinder.Catalog`; make it:

```elixir
  use GenServer

  require Logger

  alias Cinder.Catalog
  alias Cinder.Library
```

Replace the entire `defp do_poll do … end` block with:

```elixir
  defp do_poll do
    advance_downloading()
    import_downloaded()
    :ok
  end

  defp advance_downloading do
    for movie <- Catalog.list_by_status(:downloading), do: isolate(movie, &advance/1)
  end

  defp import_downloaded do
    for movie <- Catalog.list_by_status(:downloaded), do: isolate(movie, &import_one/1)
  end

  defp advance(movie) do
    case client().status(movie.download_id) do
      {:ok, %{state: :completed} = status} ->
        Catalog.transition(movie, %{status: :downloaded, file_path: Map.get(status, :content_path)})

      # Still downloading / stalled / in transit / error: leave it, retry next tick.
      _ ->
        :ok
    end
  end

  defp import_one(movie) do
    case Library.import_movie(movie) do
      {:ok, _dest} ->
        Catalog.transition(movie, %{status: :available})

      {:error, reason} ->
        Logger.warning("import failed for movie #{movie.id}: #{inspect(reason)}")
    end
  end

  # Per-movie isolation: an unexpected raise skips that one movie (leaving it at
  # its current status for retry) instead of crashing the tick for the rest.
  defp isolate(movie, fun) do
    fun.(movie)
  rescue
    e -> Logger.error("poller skipped movie #{movie.id}: #{Exception.message(e)}")
  end
```

(Leave `schedule/1`, `config_interval/0`, and `client/0` unchanged.)

- [ ] **Step 4: Run the poller tests**

Run: `mix test test/cinder/download/poller_test.exs`
Expected: PASS — the two new tests pass, and the four existing tests still pass (nil `file_path` → import cleanly skipped → `:downloaded`).

- [ ] **Step 5: Full gate + commit**

```bash
mix format
mix test
git add lib/cinder/download/poller.ex test/cinder/download/poller_test.exs
git commit -m "$(cat <<'EOF'
Phase 4: poller imports :downloaded movies to :available (crash-recoverable)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01MukXNoDXdSQNtfptEqzQCJ
EOF
)"
```

---

## Done when

`mix test` (the full alias) is green, and:
- `test/cinder/library_test.exs` proves a completed download produces the correct `mkdir_p` + `ln(source, dest)` + `scan` calls against mocked FS and Jellyfin, with the exact `Title (Year)/Title (Year).ext` dest (call-shape regime).
- `test/cinder/download/poller_test.exs` proves a `:downloaded` movie ends `:available` after a poll (outcome regime + import-pass crash recovery), and a failed import leaves it `:downloaded` for retry.
- The existing Phase-3 poller and qBittorrent tests still pass.

## Out of scope (carried to Phase 5 / Parked, per the spec)

- Live validation that qBittorrent's `content_path` is visible to Cinder on the same filesystem (hardlink, no `:exdev` / path-translation) — the Phase-5 live smoke test.
- No `:import_failed` status: permanent failures surface as "stuck at `:downloaded`" + a log line.
- Disc rips (`.iso`/BDMV/VIDEO_TS), RAR-packed releases, and multi-part `CD1`/`CD2` releases are unsupported by the largest-video heuristic.
- `mix test` is fully green without any env vars. A **live dev import** additionally needs `LIBRARY_PATH` (and `JELLYFIN_URL`/`JELLYFIN_API_KEY`/`QBITTORRENT_*`) set — until then the dev poller's import pass logs `no_file_path`/raises-into-`isolate` and leaves the movie at `:downloaded` (no boot crash; `library_path` is `fetch_env!`'d only at import time). Wiring real dev services is Phase 5.
