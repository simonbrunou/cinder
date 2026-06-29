# Manual Search + Find-a-Better-Match Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-initiated interactive "manual search" (list indexer releases, grab any) plus an
auto "search now" — for movies (including replacing an already-available file via the dormant atomic
`replace/2`) and for TV (re-queue wanted episodes; grab a season's wanted episodes).

**Architecture:** Reuse what exists. Movie auto-search-now is the existing `Catalog.retry_movie/1`.
Replacing an available movie introduces one new status `:upgrading` whose downloads ride a dedicated
poller advance clause that imports through `Library.import_movie/2 replace: true` and reverts to
`:available` (old file intact) on any failure. TV "search missing" zeros `search_attempts` so the
existing sweep re-grabs. Interactive search lists every parsed release with a per-release verdict and
grabs the user's pick. A single shared `ManualSearchComponent` renders the panel in the movie and TV
views (inline, server-assign-gated — the project has no modals).

**Tech Stack:** Elixir/Phoenix 1.8 LiveView (HEEx), Ecto + `ecto_sqlite3`, `Req`, Tailwind + daisyUI,
ExUnit + Mox.

Spec: `docs/specs/2026-06-29-better-match-manual-search-design.md` (read it first).

## Global Constraints

- `mix test` (the alias) is the source of truth: it runs `compile --warnings-as-errors`,
  `format --check-formatted`, `credo --strict`, then the suite. It must be green before every commit.
- **Every movie status write goes through `Catalog.transition/2`; every episode write through
  `Catalog.transition_episode/2`.** No bare `Repo.update` of a status field outside Catalog.
- **External services only through behaviours** (`Indexer`, `Client`, `Filesystem`, `MediaServer`,
  `MediaInfo`), resolved at runtime via `Application.fetch_env!/2`. Tests never hit network/disk —
  use the Mox mocks: `Cinder.Acquisition.IndexerMock`, `Cinder.Download.ClientMock` (torrent) /
  `Cinder.Download.SabnzbdClientMock` (usenet), `Cinder.Library.FilesystemMock`,
  `Cinder.Library.MediaServerMock`.
- **All user-facing strings are wrapped in `gettext(...)`.** The project guards French i18n
  completeness — Task 14 extracts/merges/translates the new strings, and the i18n test must pass.
- daisyUI/house style: use the `<.button variant= size=>` component, `<.icon name="hero-...">`,
  `<.status_badge kind= status=>`, and the inline `<.confirm_action>` pattern — no `<dialog>`/modal.
- Commit at the end of every task with `mix test` green. Branch is `better-match-manual-search`.

## File structure (created / modified)

- `lib/cinder/acquisition/scorer.ex` — add `verdict/2`, `rank_key/2` (share predicates with `select/2`).
- `lib/cinder/acquisition.ex` — add `list_releases/2`, `list_releases_tv/3`.
- `lib/cinder/download.ex` — add `grab/1`.
- `lib/cinder/library.ex` — add `import_movie/2` (`replace:` opt) + force `new_q` on same-inode replace.
- `lib/cinder/catalog/movie.ex` — add `:upgrading` to `@statuses`.
- `lib/cinder/catalog.ex` — add `manual_grab_movie/2`, `abort_upgrade/2`, `search_episode_now/1`,
  `search_series_now/1`, `manual_grab_tv/3`; extend `maybe_cancel_download_for_delete/1` for `:upgrading`.
- `lib/cinder/download/poller.ex` — sweep `:upgrading`; add the upgrade advance/finish/revert clauses.
- `lib/cinder_web/components/core_components.ex` — add `badge_spec(:movie, :upgrading)`.
- `lib/cinder_web/live/dashboard_live.ex` — add `:upgrading` to the in-pipeline bucket.
- `lib/cinder_web/components/manual_search_component.ex` — new shared LiveComponent.
- `lib/cinder_web/live/activity_live.ex` — wire the movie panel + "Find a better match"/cancel.
- `lib/cinder_web/live/series_detail_live.ex` — wire per-episode/season search + the TV panel.
- `priv/gettext/**` — new translations.

Backend tasks 1–10 are independently testable and land first; UI tasks 11–14 build on them. There is
a natural review checkpoint after Task 10 (backend complete, full suite green).

---

### Task 1: `Scorer.verdict/2` + `Scorer.rank_key/2`

**Files:**
- Modify: `lib/cinder/acquisition/scorer.ex`
- Test: `test/cinder/acquisition/scorer_test.exs`

**Interfaces:**
- Produces: `Scorer.verdict(%Release{}, opts) :: :ok | {:rejected, :out_of_band | :blocklisted | :wrong_resolution | :wrong_source}` and `Scorer.rank_key(%Release{}, opts) :: {integer, integer, integer}` (sort ascending = best first). Both reuse the existing private `rules/1` and predicate helpers, so they can't drift from `select/2`.

- [ ] **Step 1: Write the failing tests**

Add to `test/cinder/acquisition/scorer_test.exs` (inside the existing module; add `alias Cinder.Acquisition.{Release, Scorer}` if absent):

```elixir
describe "verdict/2" do
  defp rel(attrs), do: struct(Release, Map.merge(%{title: "X", resolution: "1080p", source: "bluray", size: 5_000_000_000, language: "en", group: "G", protocol: :torrent, season: nil, episodes: nil}, Map.new(attrs)))

  test "accepts an in-band, allowed release" do
    assert Scorer.verdict(rel([]), preferred_resolutions: ["1080p"], min_size: 1, max_size: 10_000_000_000) == :ok
  end

  test "flags an out-of-band release" do
    assert Scorer.verdict(rel(size: 99_000_000_000), max_size: 10_000_000_000) == {:rejected, :out_of_band}
  end

  test "flags a blocklisted title" do
    assert Scorer.verdict(rel(title: "Bad.Release"), release_blocklist: ["bad.release"]) == {:rejected, :blocklisted}
  end

  test "flags a disallowed resolution" do
    assert Scorer.verdict(rel(resolution: "480p"), preferred_resolutions: ["1080p"]) == {:rejected, :wrong_resolution}
  end

  test "rank_key orders a preferred resolution ahead of a worse one" do
    a = Scorer.rank_key(rel(resolution: "1080p"), preferred_resolutions: ["1080p", "720p"])
    b = Scorer.rank_key(rel(resolution: "720p"), preferred_resolutions: ["1080p", "720p"])
    assert a < b
  end
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/acquisition/scorer_test.exs -v`
Expected: FAIL — `function Scorer.verdict/2 is undefined`.

- [ ] **Step 3: Implement `verdict/2` and `rank_key/2`**

In `lib/cinder/acquisition/scorer.ex`, after `select_for/4` (before the private `rules/1`), add:

```elixir
@doc """
Classifies a single `release` against the same rules `select/2` applies, returning `:ok` or
`{:rejected, reason}` with `reason` in `[:out_of_band, :blocklisted, :wrong_resolution,
:wrong_source]`. Used by the interactive manual-search panel to show WHY the auto-pick would
skip a release while still letting the user grab it. Shares the private predicates with
`select/2`, so the panel verdict and the auto-pick can never drift.
"""
def verdict(%Release{} = release, opts \\ []) do
  {min_size, max_size, preferred, sources, blocklist, release_blocklist} = rules(opts)

  cond do
    not within_band?(release, min_size, max_size) -> {:rejected, :out_of_band}
    blocked?(release, blocklist) or title_blocked?(release, release_blocklist) -> {:rejected, :blocklisted}
    not allowed_resolution?(release, preferred) -> {:rejected, :wrong_resolution}
    not allowed_source?(release, sources) -> {:rejected, :wrong_source}
    true -> :ok
  end
end

@doc "The ascending sort key `select/2` ranks by (resolution → source → larger size). Best sorts first."
def rank_key(%Release{} = release, opts \\ []) do
  {_min, _max, preferred, sources, _bl, _rbl} = rules(opts)
  sort_key(release, preferred, sources)
end
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder/acquisition/scorer_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/acquisition/scorer.ex test/cinder/acquisition/scorer_test.exs && \
git commit -m "feat(scorer): per-release verdict/2 + rank_key/2 for manual search"
```

---

### Task 2: `Acquisition.list_releases/2` + `list_releases_tv/3`

**Files:**
- Modify: `lib/cinder/acquisition.ex`
- Test: `test/cinder/acquisition_test.exs`

**Interfaces:**
- Consumes: `Scorer.verdict/2`, `Scorer.rank_key/2` (Task 1).
- Produces:
  - `Acquisition.list_releases(imdb_id, opts) :: {:ok, [{%Release{}, verdict}]} | {:error, term}`
  - `Acquisition.list_releases_tv(series, season_number, opts) :: {:ok, [{%Release{}, verdict}]} | {:error, term}`
  - `verdict :: :ok | {:rejected, :out_of_band | :blocklisted | :wrong_resolution | :wrong_source | :wrong_protocol}`. Releases sorted by `{verdict != :ok, rank_key}` (acceptable first, then best-ranked). `:wrong_protocol` = `release.protocol` not in `opts[:protocols]` (when given). Language is NOT a verdict — the panel renders `release.language` itself.

- [ ] **Step 1: Write the failing test**

Add to `test/cinder/acquisition_test.exs` (use the existing module's `import Mox`, `setup :verify_on_exit!`, and `alias Cinder.Acquisition`):

```elixir
describe "list_releases/2" do
  test "returns every release annotated with its verdict, acceptable first" do
    Cinder.Acquisition.IndexerMock
    |> expect(:search, fn "tt1" ->
      {:ok,
       [
         %{title: "Good 1080p", size: 5_000_000_000, seeders: 9, download_url: "u", protocol: :torrent},
         %{title: "Huge 1080p", size: 90_000_000_000, seeders: 9, download_url: "u", protocol: :torrent}
       ]}
    end)

    assert {:ok, [{first, v1}, {_second, v2}]} =
             Acquisition.list_releases("tt1",
               protocols: [:torrent],
               preferred_resolutions: ["1080p"],
               max_size: 10_000_000_000
             )

    assert v1 == :ok
    assert first.title == "Good 1080p"
    assert v2 == {:rejected, :out_of_band}
  end

  test "flags a release on an unconfigured protocol" do
    Cinder.Acquisition.IndexerMock
    |> expect(:search, fn _ -> {:ok, [%{title: "U", size: 1_000_000_000, protocol: :usenet, download_url: "u"}]} end)

    assert {:ok, [{_r, {:rejected, :wrong_protocol}}]} =
             Acquisition.list_releases("tt1", protocols: [:torrent])
  end

  test "passes through an indexer error" do
    Cinder.Acquisition.IndexerMock |> expect(:search, fn _ -> {:error, :down} end)
    assert Acquisition.list_releases("tt1", []) == {:error, :down}
  end
end
```

*(Adjust the raw result map keys — `:title/:size/:protocol/:download_url/:seeders` — to whatever
`Release.new/1` consumes; copy a raw fixture from an existing `best_release` test in this file.)*

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder/acquisition_test.exs -v`
Expected: FAIL — `function Acquisition.list_releases/2 is undefined`.

- [ ] **Step 3: Implement both functions**

In `lib/cinder/acquisition.ex`, add `alias Cinder.Acquisition.Scorer` is already present; add after `best_releases/4`:

```elixir
@doc """
Lists EVERY parsed release for `imdb_id`, each paired with the scorer's verdict (`:ok` or
`{:rejected, reason}`), sorted acceptable-first then best-ranked. Unlike `best_release/2` it
does not drop or collapse — the interactive manual-search panel shows them all and lets the
user grab any (overriding the band/blocklist). `opts[:protocols]` adds a `:wrong_protocol`
verdict for releases with no configured client (still listed, but the panel disables grab).
"""
def list_releases(imdb_id, opts \\ []) do
  case indexer().search(imdb_id) do
    {:ok, raw} -> {:ok, annotate(Enum.map(raw, &Release.new/1), opts)}
    {:error, _} = error -> error
  end
end

@doc "TV variant of `list_releases/2`: searches one `season_number` of `series` and annotates."
def list_releases_tv(series, season_number, opts \\ []) do
  case indexer().search_tv(series.tvdb_id, series.title, season_number) do
    {:ok, raw} -> {:ok, annotate(Enum.map(raw, &Release.new/1), opts)}
    {:error, _} = error -> error
  end
end

defp annotate(releases, opts) do
  protocols = Keyword.get(opts, :protocols)

  releases
  |> Enum.map(fn release -> {release, release_verdict(release, protocols, opts)} end)
  |> Enum.sort_by(fn {release, verdict} -> {verdict != :ok, Scorer.rank_key(release, opts)} end)
end

defp release_verdict(%Release{protocol: protocol}, protocols, _opts)
     when is_list(protocols) and protocol not in [nil] do
  if protocol in protocols, do: :pass, else: {:rejected, :wrong_protocol}
end

defp release_verdict(_release, _protocols, _opts), do: :pass
```

That `:pass` sentinel needs folding with the scorer verdict — replace the two `release_verdict`
clauses above with this single version that combines protocol + scorer:

```elixir
defp release_verdict(%Release{} = release, protocols, opts) do
  cond do
    is_list(protocols) and not is_nil(release.protocol) and release.protocol not in protocols ->
      {:rejected, :wrong_protocol}

    true ->
      Scorer.verdict(release, opts)
  end
end
```

*(Delete the `:pass` version; keep only the combined one.)*

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder/acquisition_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/acquisition.ex test/cinder/acquisition_test.exs && \
git commit -m "feat(acquisition): list_releases/2 + list_releases_tv/3 with per-release verdicts"
```

---

### Task 3: `Download.grab/1`

**Files:**
- Modify: `lib/cinder/download.ex`
- Test: `test/cinder/download_test.exs`

**Interfaces:**
- Produces: `Download.grab(%Release{}) :: {:ok, download_id :: String.t()} | {:error, :no_client | term}`. Adds one specific release to its protocol's client (the `add_to_client/2` logic minus the transition). No DB write — the caller transitions.

- [ ] **Step 1: Write the failing test**

Add to `test/cinder/download_test.exs` (use the module's `import Mox`, `setup :verify_on_exit!`):

```elixir
describe "grab/1" do
  test "adds the release to its client and returns the download id" do
    release = %Cinder.Acquisition.Release{title: "R", protocol: :torrent, download_url: "magnet:?x"}
    Cinder.Download.ClientMock |> expect(:add, fn ^release -> {:ok, "dl-1"} end)
    assert Cinder.Download.grab(release) == {:ok, "dl-1"}
  end

  test "returns {:error, :no_client} when no client is configured for the protocol" do
    # Temporarily empty the client map for this test, then restore.
    prev = Application.fetch_env!(:cinder, :download_clients)
    Application.put_env(:cinder, :download_clients, %{})
    on_exit(fn -> Application.put_env(:cinder, :download_clients, prev) end)
    release = %Cinder.Acquisition.Release{title: "R", protocol: :torrent}
    assert Cinder.Download.grab(release) == {:error, :no_client}
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder/download_test.exs -v`
Expected: FAIL — `function Cinder.Download.grab/1 is undefined`.

- [ ] **Step 3: Implement `grab/1`**

In `lib/cinder/download.ex`, add `alias Cinder.Acquisition.Release` to the existing alias line, then add after `start/1`:

```elixir
@doc """
Adds one specific `release` to its protocol's download client and returns `{:ok, download_id}`,
or `{:error, :no_client}` when no client is configured for the protocol. The manual-search
grab path: the caller has already chosen the release, so unlike `start/1` there is no search
and no `Catalog.transition` here — the caller records the new download.
"""
def grab(%Release{} = release) do
  case client_for(release.protocol) do
    {:ok, client} -> client.add(release)
    :error -> {:error, :no_client}
  end
end
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder/download_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/download.ex test/cinder/download_test.exs && \
git commit -m "feat(download): grab/1 to add a user-chosen release to its client"
```

---

### Task 4: `Library.import_movie/2` with `replace:`

**Files:**
- Modify: `lib/cinder/library.ex`
- Test: `test/cinder/library_source_upgrade_test.exs` (the existing replace-path test file)

**Interfaces:**
- Produces: `Library.import_movie(%Movie{}, replace: boolean) :: {:ok, dest, quality} | {:error, term}`. `replace: true` forces the collision to replace (bypass `Upgrade.better?`) AND records the NEW quality even on the same-inode idempotent short-circuit. `import_movie/1` delegates with `replace: false` (unchanged behaviour).

- [ ] **Step 1: Write the failing test**

Add to `test/cinder/library_source_upgrade_test.exs` (mirror an existing test's FS-mock setup):

```elixir
test "import_movie/2 replace: true swaps even a non-upgrade and records the new quality" do
  # An :eexist collision where the new file is NOT better than the existing one.
  # With replace: false it would keep the old; with replace: true it must replace and return new_q.
  movie = movie_fixture(file_path: "/dl/New.Movie.2020.720p.mkv",
                         imported_resolution: "1080p", imported_size: 9_000_000_000)
  stub_fs_collision_then_replace()  # helper: ln -> :eexist, lstat dest (diff inode), replace temp+rename -> :ok

  assert {:ok, _dest, q} = Cinder.Library.import_movie(movie, replace: true)
  assert q.resolution == "720p"   # the NEW file's quality, not the old 1080p
end
```

*(Reuse the file's existing collision/replace FS stub; the assertion that matters is `q.resolution`
being the **new** file's, proving the forced replace + new-quality recording.)*

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder/library_source_upgrade_test.exs -v`
Expected: FAIL — `function Cinder.Library.import_movie/2 is undefined` (or quality is the old value).

- [ ] **Step 3: Implement the `replace:` option**

In `lib/cinder/library.ex`: change `import_movie/1` to delegate, and thread `replace?` into `place/6`
and `do_resolve/6`.

```elixir
def import_movie(%Movie{} = movie), do: import_movie(movie, [])

@spec import_movie(Movie.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
def import_movie(%Movie{file_path: path}, _opts) when path in [nil, ""], do: {:error, :no_file_path}

def import_movie(%Movie{} = movie, opts) do
  replace? = Keyword.get(opts, :replace, false)

  with {:ok, root} <- root(:movies),
       {:ok, source} <- resolve_source(movie.file_path),
       :ok <- verify_audio(source, Language.target(movie.preferred_language, movie.original_language)),
       {:ok, %{size: size, inode: si, major_device: sdev}} <- fs().lstat(source),
       parsed = Parser.parse(Path.basename(movie.file_path)),
       new_q = new_quality(parsed, size),
       dest = build_dest(movie, source, root),
       :ok <- fs().mkdir_p(Path.dirname(dest)),
       {:ok, quality} <- place(source, dest, {si, sdev}, movie, new_q, replace?, fn -> upgrade?(movie, new_q) end) do
    scan(:movies, dest)
    {:ok, dest, quality}
  end
end
```

Update `place/6 → place/7` and `do_resolve/6 → do_resolve/7` to carry `replace?`. The same-inode
short-circuit must return `new_q` (not the stale existing quality) under a forced replace:

```elixir
defp place(source, dest, {si, sdev}, record, new_q, replace?, upgrade_fun) do
  case fs().ln(source, dest) do
    :ok -> {:ok, new_q}
    {:error, :exdev} -> with :ok <- replace(source, dest), do: {:ok, new_q}
    {:error, :eexist} ->
      with {:ok, %{inode: di, major_device: ddev}} <- fs().lstat(dest) do
        same_inode? = si == di and sdev == ddev
        do_resolve(source, dest, same_inode?, replace? or upgrade_fun.(), record, new_q, replace?)
      end
    {:error, _} = err -> err
  end
end

# Same inode: the file is already in place (idempotent). Normally we keep the recorded quality,
# but a forced replace (a manual upgrade re-importing after a crash) must record the NEW quality.
defp do_resolve(_source, _dest, true, _upgrade, movie, new_q, replace?),
  do: {:ok, if(replace?, do: new_q, else: existing_quality(movie, new_q))}

defp do_resolve(source, dest, false, true, _movie, new_q, _replace?) do
  with :ok <- replace(source, dest), do: {:ok, new_q}
end

defp do_resolve(_source, dest, false, false, movie, new_q, _replace?), do: keep(dest, movie, new_q)
```

Find any other callers of `place/6` (the episode path at `place_episode_file/4`) and pass
`replace?: false` so episode imports are byte-for-byte unchanged. (The episode call becomes
`place(source, dest, {si, sdev}, ep, new_q, false, fn -> ep_upgrade?(...) end)`.)

- [ ] **Step 4: Run the test, verify it passes (and the existing replace tests stay green)**

Run: `mix test test/cinder/library_source_upgrade_test.exs -v`
Expected: PASS, all of them.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/library.ex test/cinder/library_source_upgrade_test.exs && \
git commit -m "feat(library): import_movie/2 replace: forces swap + records new quality"
```

---

### Task 5: Movie `:upgrading` status + badge + dashboard bucket

**Files:**
- Modify: `lib/cinder/catalog/movie.ex`, `lib/cinder_web/components/core_components.ex`, `lib/cinder_web/live/dashboard_live.ex`
- Test: `test/cinder/catalog/movie_test.exs` (or wherever statuses are asserted) + `test/cinder_web/live/dashboard_live_test.exs`

**Interfaces:**
- Produces: `:upgrading` is a valid `Movie` status (no migration — `movies.status` is a plain string column), renders a badge, and counts in the dashboard's in-pipeline stat.

- [ ] **Step 1: Write the failing test**

Add to the dashboard live test (mirror its existing setup) a count assertion:

```elixir
test "an :upgrading movie counts as in-pipeline", %{conn: conn} do
  movie_fixture(status: :upgrading)
  {:ok, _lv, html} = live(conn, ~p"/")
  assert html =~ "In pipeline"
  # assert the in-pipeline count includes the upgrading movie (match the existing count assertion style)
end
```

And a badge render assertion in `test/cinder_web/components/core_components_test.exs` if present, else
rely on the dashboard/activity render:

```elixir
test "renders the upgrading movie badge" do
  assert render_component(&Cinder.CinderWeb.CoreComponents.status_badge/1, kind: :movie, status: :upgrading) =~ "Upgrading"
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder_web/live/dashboard_live_test.exs -v`
Expected: FAIL (count off / badge missing).

- [ ] **Step 3: Add the status, badge, and bucket**

In `lib/cinder/catalog/movie.ex`, add `:upgrading` to `@statuses`:

```elixir
@statuses [
  :requested,
  :searching,
  :downloading,
  :downloaded,
  :available,
  :upgrading,
  :no_match,
  :search_failed,
  :import_failed,
  :cancelled
]
```

In `lib/cinder_web/components/core_components.ex`, add a clause **before** the `defp badge_spec(_kind, status)` fallback (the `:kind` attr `values:` list does NOT change — `:upgrading` is a status, not a kind):

```elixir
defp badge_spec(:movie, :upgrading),
  do: {gettext("Upgrading"), "badge-info", "hero-arrow-up-circle"}
```

In `lib/cinder_web/live/dashboard_live.ex`, add `:upgrading` to `@pipeline`:

```elixir
@pipeline [:requested, :searching, :downloading, :downloaded, :upgrading]
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder_web/live/dashboard_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/catalog/movie.ex lib/cinder_web/components/core_components.ex lib/cinder_web/live/dashboard_live.ex test/ && \
git commit -m "feat(movie): add :upgrading status, badge, and dashboard bucket"
```

---

### Task 6: `Catalog.manual_grab_movie/2`

**Files:**
- Modify: `lib/cinder/catalog.ex`
- Test: `test/cinder/catalog_test.exs`

**Interfaces:**
- Consumes: `Download.grab/1` (Task 3), `:upgrading` status (Task 5), `transition/2`, the existing `@retryable` module attribute (`[:no_match, :search_failed, :import_failed]`).
- Produces: `Catalog.manual_grab_movie(%Movie{}, %Release{}) :: {:ok, %Movie{}} | {:error, :not_grabbable | :stale_entry | term}`. `:available` → `:upgrading` (file_path/imported_* preserved, `import_attempts: 0`). `@retryable` parked → `:downloading`. Anything else → `{:error, :not_grabbable}`. Rescues `Ecto.StaleEntryError`.

- [ ] **Step 1: Write the failing tests**

Add to `test/cinder/catalog_test.exs` (`import Mox`, `setup :verify_on_exit!`, `use Cinder.DataCase, async: false`):

```elixir
describe "manual_grab_movie/2" do
  setup do
    release = %Cinder.Acquisition.Release{title: "Pick", protocol: :torrent, download_url: "magnet:?x"}
    %{release: release}
  end

  test "an available movie goes :upgrading, preserving its file", %{release: release} do
    movie = movie_fixture(status: :available, file_path: "/lib/Movie (2020)/Movie (2020).mkv",
                          imported_resolution: "1080p")
    Cinder.Download.ClientMock |> expect(:add, fn _ -> {:ok, "dl-9"} end)

    assert {:ok, up} = Cinder.Catalog.manual_grab_movie(movie, release)
    assert up.status == :upgrading
    assert up.download_id == "dl-9"
    assert up.release_title == "Pick"
    assert up.file_path == "/lib/Movie (2020)/Movie (2020).mkv"   # untouched
    assert up.imported_resolution == "1080p"                       # untouched
  end

  test "a parked movie goes :downloading", %{release: release} do
    movie = movie_fixture(status: :no_match)
    Cinder.Download.ClientMock |> expect(:add, fn _ -> {:ok, "dl-7"} end)
    assert {:ok, dl} = Cinder.Catalog.manual_grab_movie(movie, release)
    assert dl.status == :downloading
  end

  test "an in-flight movie is rejected", %{release: release} do
    movie = movie_fixture(status: :downloading)
    assert Cinder.Catalog.manual_grab_movie(movie, release) == {:error, :not_grabbable}
  end
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/catalog_test.exs -v`
Expected: FAIL — `manual_grab_movie/2 is undefined`.

- [ ] **Step 3: Implement `manual_grab_movie/2`**

In `lib/cinder/catalog.ex`, near `retry_movie/1` (so it sits with the other manual movie actions),
add. `@retryable` and `alias Cinder.Acquisition.Release` must be in scope — add the alias if absent;
`@retryable` already exists at the `retry_movie` site.

```elixir
@doc """
Grabs a specific user-chosen `release` for `movie`. An `:available` movie enters `:upgrading`
(its library `file_path` and `imported_*` are preserved — the poller's upgrade clause swaps the
file only on a successful re-import). A parked movie (`#{inspect(@retryable)}`) enters
`:downloading` on the normal import path. Any other status returns `{:error, :not_grabbable}`
(rejecting in-flight/`:upgrading`/`:cancelled`, which also blocks a double-click). A movie deleted
mid-action surfaces `{:error, :stale_entry}`.
"""
def manual_grab_movie(%Movie{status: :available} = movie, %Release{} = release) do
  with {:ok, download_id} <- Download.grab(release) do
    transition(movie, %{
      status: :upgrading,
      download_id: download_id,
      download_protocol: release.protocol,
      release_title: release.title,
      import_attempts: 0
    })
  end
rescue
  Ecto.StaleEntryError -> {:error, :stale_entry}
end

def manual_grab_movie(%Movie{status: status} = movie, %Release{} = release)
    when status in @retryable do
  with {:ok, download_id} <- Download.grab(release) do
    transition(movie, %{
      status: :downloading,
      download_id: download_id,
      download_protocol: release.protocol,
      release_title: release.title,
      import_attempts: 0,
      search_attempts: 0
    })
  end
rescue
  Ecto.StaleEntryError -> {:error, :stale_entry}
end

def manual_grab_movie(%Movie{}, %Release{}), do: {:error, :not_grabbable}
```

Add `alias Cinder.Download` if not already aliased in `catalog.ex` (it is used by `remove_download/1`,
so it is — confirm).

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder/catalog_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/catalog.ex test/cinder/catalog_test.exs && \
git commit -m "feat(catalog): manual_grab_movie/2 (available->upgrading, parked->downloading)"
```

---

### Task 7: Poller `:upgrading` advance + finish + revert

**Files:**
- Modify: `lib/cinder/download/poller.ex`
- Test: `test/cinder/download/poller_test.exs`

**Interfaces:**
- Consumes: `Library.import_movie/2 replace:` (Task 4), `:upgrading` (Task 5), `Library.delete_file/1`, `Download.remove_after_import/2`, `Catalog.block_release/2`, `Catalog.transition/2`, `Notifier.notify/1`.
- Produces: an `:upgrading` movie whose download completes is imported via forced replace → `:available` (old file deleted if the container changed; new download removed); any failure reverts to `:available` (old file intact, new download fields cleared, the failed release blocklisted, `{:movie_upgrade_failed, movie, reason}` emitted).

- [ ] **Step 1: Write the failing tests**

Add to `test/cinder/download/poller_test.exs` (mirror existing poller test setup — it drives one tick
via the same internal entry the other tests use; copy that harness):

```elixir
describe "upgrade advance" do
  test "a completed upgrade download imports via replace and ends :available with new quality" do
    movie = movie_fixture(status: :upgrading, download_id: "dl-1", download_protocol: :torrent,
                          release_title: "Better", file_path: "/lib/M (2020)/M (2020).mkv",
                          imported_resolution: "720p")
    Cinder.Download.ClientMock |> expect(:status, fn "dl-1" -> {:ok, %{state: :completed, content_path: "/dl/Better.1080p.mkv"}} end)
    stub_filesystem_replace_to("/lib/M (2020)/M (2020).mkv")  # ln :eexist -> replace temp+rename ok; scan ok

    run_one_poll_tick()

    reloaded = Cinder.Catalog.get_movie_by_id(movie.id)
    assert reloaded.status == :available
    assert reloaded.imported_resolution == "1080p"
  end

  test "a failed upgrade reverts to :available with the old file and blocklists the release" do
    movie = movie_fixture(status: :upgrading, download_id: "dl-2", download_protocol: :torrent,
                          release_title: "Bad", file_path: "/lib/M (2020)/M (2020).mkv")
    Cinder.Download.ClientMock |> expect(:status, fn "dl-2" -> {:ok, %{state: :completed, content_path: "/dl/Bad.mkv"}} end)
    stub_filesystem_import_error(:wrong_audio_language)

    run_one_poll_tick()

    reloaded = Cinder.Catalog.get_movie_by_id(movie.id)
    assert reloaded.status == :available
    assert reloaded.file_path == "/lib/M (2020)/M (2020).mkv"   # intact
    assert reloaded.download_id == nil                           # cleared
    assert "Bad" in Cinder.Catalog.blocked_release_titles(reloaded)
  end
end
```

*(`run_one_poll_tick/0`, `movie_fixture/1`, and the FS stubs mirror the existing poller test helpers —
reuse them; the existing import tests already stub `Cinder.Library.FilesystemMock`.)*

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/download/poller_test.exs -v`
Expected: FAIL — `:upgrading` not swept / not handled.

- [ ] **Step 3: Implement the upgrade clauses**

In `lib/cinder/download/poller.ex`:

Extend the sweep:

```elixir
defp advance_downloading do
  movies = Catalog.list_by_status(:downloading) ++ Catalog.list_by_status(:upgrading)
  for movie <- movies, do: isolate("movie #{movie.id}", fn -> advance(movie) end)
end
```

Dispatch `:upgrading` to its own clause (add a head ABOVE the existing `advance/1`):

```elixir
defp advance(%Movie{status: :upgrading} = movie), do: advance_upgrade(movie)

defp advance(movie) do
  case Download.client_for(movie.download_protocol) do
    {:ok, client} -> advance_with(movie, client)
    :error -> retry_or_fail(movie, :no_client, :import_attempts, :import_failed)
  end
end
```

Add `alias Cinder.Catalog.Movie` to the poller's aliases. Then add the upgrade-specific clauses
(near `import_one/1`):

```elixir
# --- upgrade: re-download + atomic replace of an :available movie's file -----------------------

defp advance_upgrade(movie) do
  case Download.client_for(movie.download_protocol) do
    {:ok, client} -> advance_upgrade_with(movie, client)
    :error -> revert_upgrade(movie, :no_client)
  end
end

defp advance_upgrade_with(movie, client) do
  case client.status(movie.download_id) do
    {:ok, %{state: :completed, content_path: path}} when path not in [nil, ""] ->
      finish_upgrade(movie, path)

    {:ok, %{state: :completed}} -> retry_or_revert(movie, :no_content_path)
    {:ok, %{state: :error}} -> retry_or_revert(movie, :download_error)
    {:error, :not_found} -> retry_or_revert(movie, :torrent_not_found)
    # still downloading / transient client error: wait, no write, live file untouched
    _ -> :ok
  end
end

# Import the completed download by FORCED replace (the user chose this release). On success the
# library file is swapped (replace/2) and the movie returns :available with the new quality; if
# the new dest filename differs (a different container) the old file is removed best-effort so the
# library never holds two files. Any failure reverts to :available with the old file intact.
defp finish_upgrade(movie, content_path) do
  case Library.import_movie(%{movie | file_path: content_path}, replace: true) do
    {:ok, dest, q} ->
      with {:ok, available} <-
             Catalog.transition(movie, %{
               status: :available,
               file_path: dest,
               imported_resolution: q.resolution,
               imported_size: q.size,
               imported_language: q.language,
               imported_source: q.source
             }) do
        if dest != movie.file_path, do: best_effort_remove_old(movie.file_path)
        Download.remove_after_import(movie.download_protocol, movie.download_id)
        Notifier.notify({:movie_available, available})
      end

    {:error, :library_not_configured} ->
      Logger.warning("holding upgrade for movie #{movie.id}: movies_library_path not set")

    {:error, reason} when reason in @permanent_import_errors ->
      revert_upgrade(movie, reason)

    {:error, reason} ->
      retry_or_revert(movie, reason)
  end
end

# Bounded retry on the upgrade's download/transient-import side; after @max_attempts, revert.
defp retry_or_revert(movie, reason) do
  attempts = (movie.import_attempts || 0) + 1

  if attempts >= @max_attempts do
    revert_upgrade(movie, reason)
  else
    Logger.info("movie #{movie.id} upgrade #{attempts}/#{@max_attempts} (#{inspect(reason)}); retry")
    Catalog.transition(movie, %{import_attempts: attempts, status: :upgrading})
  end
end

# Abort the upgrade WITHOUT touching the live file: blocklist the failed release (movie still
# carries its title), then revert to :available clearing the upgrade's download fields. Blocklist
# only genuine release failures (mirrors park/3) so a config glitch (:no_client) doesn't blocklist.
defp revert_upgrade(movie, reason) do
  if reason in @permanent_import_errors or reason in @download_failure_errors,
    do: Catalog.block_release(movie, :upgrade_failed)

  with {:ok, reverted} <-
         Catalog.transition(movie, %{
           status: :available,
           download_id: nil,
           download_protocol: nil,
           release_title: nil
         }) do
    Logger.warning("movie #{movie.id} upgrade reverted to :available (#{inspect(reason)})")
    Notifier.notify({:movie_upgrade_failed, reverted, reason})
  end
end

defp best_effort_remove_old(path) do
  case Library.delete_file(path) do
    :ok -> :ok
    {:error, reason} -> Logger.warning("upgrade: couldn't remove old file #{inspect(path)}: #{inspect(reason)}")
  end
end
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder/download/poller_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/download/poller.ex test/cinder/download/poller_test.exs && \
git commit -m "feat(poller): :upgrading advance clause (forced-replace import, revert on failure)"
```

---

### Task 8: Abort + delete cleanup for `:upgrading`

**Files:**
- Modify: `lib/cinder/catalog.ex`
- Test: `test/cinder/catalog_test.exs`

**Interfaces:**
- Produces: `Catalog.abort_upgrade(%Movie{}, actor) :: {:ok, %Movie{}} | {:error, :not_upgrading | term}` — removes the in-flight upgrade download and reverts to `:available` (does NOT go to `:cancelled`). And `delete_movie/3` removes the in-flight download for an `:upgrading` movie (no orphan).

- [ ] **Step 1: Write the failing tests**

```elixir
describe "abort_upgrade/2" do
  test "reverts an :upgrading movie to :available and removes the download" do
    movie = movie_fixture(status: :upgrading, download_id: "dl-3", download_protocol: :torrent,
                          file_path: "/lib/M (2020)/M (2020).mkv")
    Cinder.Download.ClientMock |> expect(:remove, fn "dl-3", _ -> :ok end)
    assert {:ok, reverted} = Cinder.Catalog.abort_upgrade(movie, :system)
    assert reverted.status == :available
    assert reverted.download_id == nil
    assert reverted.file_path == "/lib/M (2020)/M (2020).mkv"
  end

  test "rejects a non-upgrading movie" do
    assert Cinder.Catalog.abort_upgrade(movie_fixture(status: :available), :system) == {:error, :not_upgrading}
  end
end

test "delete_movie removes the in-flight download of an :upgrading movie" do
  movie = movie_fixture(status: :upgrading, download_id: "dl-4", download_protocol: :torrent)
  Cinder.Download.ClientMock |> expect(:remove, fn "dl-4", _ -> :ok end)
  assert {:ok, _} = Cinder.Catalog.delete_movie(movie, :system)
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/catalog_test.exs -v`
Expected: FAIL — `abort_upgrade/2 is undefined`; the delete test fails Mox `expect` (remove not called).

- [ ] **Step 3: Implement abort + delete cleanup**

In `lib/cinder/catalog.ex`, add `abort_upgrade/2` near `cancel_movie/2`:

```elixir
@doc """
Aborts an in-flight movie upgrade: removes the replacement download (best-effort) and reverts the
movie to `:available`, keeping the existing library file. Distinct from `cancel_movie/2` — an
`:upgrading` movie must NOT become `:cancelled` (it still has a good file). Returns
`{:error, :not_upgrading}` otherwise.
"""
def abort_upgrade(%Movie{status: :upgrading} = movie, actor) do
  remove_download(movie)

  result =
    Repo.transaction(fn ->
      case movie
           |> Movie.transition_changeset(%{
             status: :available,
             download_id: nil,
             download_protocol: nil,
             release_title: nil
           })
           |> Repo.update() do
        {:ok, updated} ->
          Audit.log_or_rollback(actor, :abort_upgrade, updated, %{from: :upgrading})
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)

  with {:ok, updated} <- result do
    broadcast({:movie_updated, updated})
    {:ok, updated}
  end
end

def abort_upgrade(%Movie{}, _actor), do: {:error, :not_upgrading}
```

Extend `maybe_cancel_download_for_delete/1` so an `:upgrading` movie's download is removed on delete:

```elixir
defp maybe_cancel_download_for_delete(%Movie{download_id: nil}), do: :ok

defp maybe_cancel_download_for_delete(%Movie{} = movie) do
  if cancellable?(movie) or movie.status == :upgrading, do: remove_download(movie), else: :ok
end
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder/catalog_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/catalog.ex test/cinder/catalog_test.exs && \
git commit -m "feat(catalog): abort_upgrade/2 + delete-cleanup for :upgrading downloads"
```

---

### Task 9: `Catalog.search_episode_now/1` + `search_series_now/1`

**Files:**
- Modify: `lib/cinder/catalog.ex`
- Test: `test/cinder/catalog_series_test.exs`

**Interfaces:**
- Consumes: `transition_episode/2`, `wanted_episodes/0`.
- Produces: `search_episode_now(%Episode{}) :: {:ok, %Episode{}} | {:error, term} | :ok` and `search_series_now(%Series{}) :: :ok` — both zero `search_attempts` on wanted episode(s) so the TV sweep re-grabs next tick. A non-wanted episode (has a file or grab) is a harmless no-op.

- [ ] **Step 1: Write the failing tests**

```elixir
describe "search_now" do
  test "search_series_now zeros search_attempts on wanted episodes" do
    series = series_with_wanted_episode(search_attempts: 9)   # helper: monitored, aired, no file/grab
    assert :ok = Cinder.Catalog.search_series_now(series)
    [ep] = Cinder.Catalog.wanted_episodes()
    assert ep.search_attempts == 0
  end

  test "search_episode_now is a no-op on an episode that already has a file" do
    ep = episode_fixture(file_path: "/lib/x.mkv", search_attempts: 9)
    assert Cinder.Catalog.search_episode_now(ep) in [:ok, {:ok, ep}]
    assert Cinder.Catalog.get_episode(ep.id).search_attempts == 9
  end
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/catalog_series_test.exs -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement both**

In `lib/cinder/catalog.ex`, near `wanted_episodes/0`:

```elixir
@doc """
Re-queues a single wanted `episode` for the TV sweep by zeroing its `search_attempts` (clearing
any backoff/attempt-cap park). A no-op for an episode that already has a file or an active grab
(it isn't wanted). The sweep picks it up within one poll interval.
"""
def search_episode_now(%Episode{file_path: nil, grab_id: nil} = episode),
  do: transition_episode(episode, %{search_attempts: 0})

def search_episode_now(%Episode{}), do: :ok

@doc "Re-queues every still-wanted episode of `series` (zeroes their `search_attempts`)."
def search_series_now(%Series{id: series_id}) do
  wanted_episodes()
  |> Enum.filter(&(&1.season.series.id == series_id))
  |> Enum.each(&transition_episode(&1, %{search_attempts: 0}))
end
```

*(Confirm `wanted_episodes/0` preloads `season: :series` — it does, per the TvPoller's
`&1.season.series.id` usage. If `get_episode/1` doesn't exist for the test, use `Repo.get(Episode, id)`
via an existing accessor.)*

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder/catalog_series_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/catalog.ex test/cinder/catalog_series_test.exs && \
git commit -m "feat(catalog): search_episode_now/1 + search_series_now/1 re-queue wanted episodes"
```

---

### Task 10: `Catalog.manual_grab_tv/3`

**Files:**
- Modify: `lib/cinder/catalog.ex`
- Test: `test/cinder/catalog_series_test.exs`

**Interfaces:**
- Consumes: `Download.grab/1`, `create_grab/4`, `wanted_episodes/0`.
- Produces: `Catalog.manual_grab_tv(%Series{}, season_number, %Release{}) :: {:ok, %Grab{}} | {:error, :nothing_wanted | term}`. Recomputes the season's still-wanted episode numbers server-side, intersects with the release's coverage (`episodes: nil` = whole-season pack covers all wanted), grabs and creates the grab over exactly those episodes.

- [ ] **Step 1: Write the failing test**

```elixir
describe "manual_grab_tv/3" do
  test "creates a grab over the season's still-wanted episodes the release covers" do
    series = series_with_wanted_episodes(season: 1, numbers: [1, 2, 3])   # all wanted
    release = %Cinder.Acquisition.Release{title: "S01 Pack", protocol: :torrent, season: 1, episodes: nil, download_url: "magnet:?x"}
    Cinder.Download.ClientMock |> expect(:add, fn _ -> {:ok, "dl-tv"} end)

    assert {:ok, grab} = Cinder.Catalog.manual_grab_tv(series, 1, release)
    grab = Cinder.Repo.preload(grab, :episodes)
    assert Enum.map(grab.episodes, & &1.episode_number) |> Enum.sort() == [1, 2, 3]
  end

  test "returns :nothing_wanted when the season has no wanted episodes" do
    series = series_with_available_season(season: 1)   # all episodes have files
    release = %Cinder.Acquisition.Release{title: "S01", protocol: :torrent, season: 1, episodes: nil}
    assert Cinder.Catalog.manual_grab_tv(series, 1, release) == {:error, :nothing_wanted}
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder/catalog_series_test.exs -v`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement `manual_grab_tv/3`**

```elixir
@doc """
Grabs a user-chosen `release` for one `season_number` of `series`. Recomputes the season's
still-wanted episodes server-side (don't trust a stale panel snapshot) and creates the grab over
exactly the wanted episodes the release covers (`episodes: nil` = a whole-season pack covers them
all). `create_grab/4` itself skips any episode that already has a grab, so a concurrent sweep grab
can't be double-linked. `{:error, :nothing_wanted}` when the season has nothing to grab.
"""
def manual_grab_tv(%Series{id: series_id}, season_number, %Release{} = release) do
  wanted =
    wanted_episodes()
    |> Enum.filter(&(&1.season.series.id == series_id and &1.season.season_number == season_number))

  covered = cover_numbers(release, Enum.map(wanted, & &1.episode_number))
  episode_ids = wanted |> Enum.filter(&(&1.episode_number in covered)) |> Enum.map(& &1.id)

  case episode_ids do
    [] ->
      {:error, :nothing_wanted}

    ids ->
      with {:ok, download_id} <- Download.grab(release) do
        create_grab(download_id, release.protocol, ids, release.title)
      end
  end
end

# A whole-season pack (episodes: nil) covers every still-wanted number; an episode list covers its
# intersection with what's wanted. Mirrors Scorer.coverage/2.
defp cover_numbers(%Release{episodes: nil}, wanted_numbers), do: wanted_numbers
defp cover_numbers(%Release{episodes: eps}, wanted_numbers), do: Enum.filter(wanted_numbers, &(&1 in eps))
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder/catalog_series_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder/catalog.ex test/cinder/catalog_series_test.exs && \
git commit -m "feat(catalog): manual_grab_tv/3 grabs a season's still-wanted episodes"
```

> **Checkpoint:** backend complete. Run `mix test` (full alias) — all green — before the UI tasks.

---

### Task 11: `ManualSearchComponent` (shared LiveComponent)

**Files:**
- Create: `lib/cinder_web/components/manual_search_component.ex`
- Test: `test/cinder_web/components/manual_search_component_test.exs`

**Interfaces:**
- Consumes: `Acquisition.list_releases/2` (movie) / `list_releases_tv/3` (TV), `Download.available_protocols/0`.
- Produces: a `Cinder.CinderWeb.ManualSearchComponent` LiveComponent. Required assigns: `id`, `mode` (`:movie | :tv`), `target` (the `%Movie{}` or `%Series{}`), and for `:tv` a `season_number`. It runs the search via `start_async` on `update/2`, renders loading/empty/error/results states, lists each release with its verdict + language, and emits a `grab` event to the PARENT (`phx-target={@myself}` → forwards via `send(self(), {:manual_grab, ...})`) so the parent LiveView performs the grab (it owns the Catalog calls). A `:movie` result on an `:available` target shows a "Replace current file?" confirm before grabbing.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cinder.CinderWeb.ManualSearchComponentTest do
  use Cinder.CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  setup :verify_on_exit!

  test "renders results with verdicts and a grab control", %{conn: _conn} do
    # Drive it through a host LiveView or render_component with a stubbed Acquisition result.
    # Simplest: stub the indexer and assert the rendered markup lists the release + reason.
    Cinder.Acquisition.IndexerMock
    |> stub(:search, fn _ -> {:ok, [%{title: "Pick 1080p", size: 5_000_000_000, protocol: :torrent, download_url: "u"}]} end)

    html =
      render_component(Cinder.CinderWeb.ManualSearchComponent,
        id: "ms",
        mode: :movie,
        target: %Cinder.Catalog.Movie{id: 1, status: :available, imdb_id: "tt1", title: "M"},
        results: [{%Cinder.Acquisition.Release{title: "Pick 1080p", resolution: "1080p", protocol: :torrent, language: "en"}, :ok}]
      )

    assert html =~ "Pick 1080p"
    assert html =~ "Grab"
  end
end
```

*(If `render_component` can't exercise `start_async`, pass a `results:` assign directly as above and
have `update/2` skip the async fetch when `results` is provided — useful for testing and harmless in
prod. The async path is covered end-to-end in Tasks 12–13's LiveView tests.)*

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder_web/components/manual_search_component_test.exs -v`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the component**

Create `lib/cinder_web/components/manual_search_component.ex`:

```elixir
defmodule Cinder.CinderWeb.ManualSearchComponent do
  @moduledoc """
  Interactive manual-search panel, shared by the movie and TV views. Queries the indexer
  asynchronously and lists every release with its scorer verdict, letting the user grab any one
  (overriding the band/blocklist for selection). Grabs are forwarded to the parent LiveView, which
  owns the Catalog writes. For an `:available` movie target a "Replace current file?" confirm gates
  the grab; for a TV season with no wanted episodes the panel says replacing existing files isn't
  supported yet.
  """
  use Cinder.CinderWeb, :live_component

  alias Cinder.{Acquisition, Download}
  alias Cinder.Acquisition.Release

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      cond do
        # test/preseeded path: results supplied directly, skip the async fetch
        Map.has_key?(assigns, :results) and not is_nil(assigns[:results]) ->
          assign(socket, state: :loaded, confirming: nil)

        connected_search?(socket) ->
          socket |> assign(state: :loading, results: [], confirming: nil) |> start_search()

        true ->
          assign(socket, state: :loading, results: [], confirming: nil)
      end

    {:ok, socket}
  end

  # Only fetch once per panel open (when state isn't set yet).
  defp connected_search?(socket), do: is_nil(socket.assigns[:state])

  defp start_search(socket) do
    %{mode: mode, target: target} = socket.assigns
    opts = [protocols: Download.available_protocols()]

    start_async(socket, :search, fn ->
      case mode do
        :movie -> Acquisition.list_releases(target.imdb_id, opts)
        :tv -> Acquisition.list_releases_tv(target, socket.assigns.season_number, opts)
      end
    end)
  end

  @impl true
  def handle_async(:search, {:ok, {:ok, results}}, socket),
    do: {:noreply, assign(socket, state: :loaded, results: results)}

  def handle_async(:search, {:ok, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, state: :error)}

  def handle_async(:search, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, state: :error)}

  @impl true
  def handle_event("ask_replace", %{"title" => title}, socket),
    do: {:noreply, assign(socket, confirming: title)}

  def handle_event("dismiss_replace", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("grab", %{"title" => title}, socket) do
    release = Enum.find(socket.assigns.results, fn {r, _v} -> r.title == title end)

    if release do
      send(self(), {:manual_grab, socket.assigns.mode, socket.assigns.target, elem(release, 0)})
    end

    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-200 mt-2 p-3">
      <div :if={@state == :loading} class="flex items-center gap-2 text-sm">
        <span class="loading loading-spinner loading-sm" />{gettext("Searching releases…")}
      </div>
      <p :if={@state == :error} class="text-sm text-error">
        {gettext("Couldn't reach the indexer. Try again.")}
      </p>
      <p :if={@state == :loaded and @results == [] and not tv_full_season?(assigns)} class="text-sm">
        {gettext("No releases found.")}
      </p>
      <p :if={tv_full_season?(assigns)} class="text-sm text-base-content/70">
        {gettext("All episodes present — replacing existing TV files isn't supported yet.")}
      </p>

      <ul :if={@state == :loaded and @results != []} class="space-y-1">
        <li :for={{release, verdict} <- @results} class="flex flex-wrap items-center gap-2 text-sm">
          <span class="min-w-0 flex-1 truncate" title={release.title}>{release.title}</span>
          <span class="badge badge-xs">{release.resolution || gettext("?")}</span>
          <span :if={release.language} class="badge badge-ghost badge-xs">{release.language}</span>
          <span :if={verdict != :ok} class="text-xs text-warning">{verdict_reason(verdict)}</span>
          <.button
            :if={grabbable?(verdict)}
            type="button"
            size="xs"
            variant="ghost"
            phx-target={@myself}
            phx-click={grab_click(@mode, @target, release)}
            phx-value-title={release.title}
          >
            {gettext("Grab")}
          </.button>
        </li>
      </ul>

      <.confirm_action
        :if={@confirming}
        id={"#{@id}-replace-confirm"}
        on_confirm="grab"
        on_cancel="dismiss_replace"
        variant="warning"
        phx-target={@myself}
        confirm_label={gettext("Replace file")}
      >
        <:caveat>
          {gettext("Replace the current file for this movie with the selected release?")}
        </:caveat>
      </.confirm_action>
    </div>
    """
  end

  # An :available movie grab routes through the replace-confirm; everything else grabs directly.
  defp grab_click(:movie, %{status: :available}, _release), do: "ask_replace"
  defp grab_click(_mode, _target, _release), do: "grab"

  # :wrong_protocol means no configured client — can't grab. Everything else the user may override.
  defp grabbable?({:rejected, :wrong_protocol}), do: false
  defp grabbable?(_), do: true

  defp tv_full_season?(%{mode: :tv, state: :loaded, results: []} = _assigns), do: true
  defp tv_full_season?(_), do: false

  defp verdict_reason({:rejected, :out_of_band}), do: gettext("outside size band")
  defp verdict_reason({:rejected, :blocklisted}), do: gettext("blocklisted")
  defp verdict_reason({:rejected, :wrong_resolution}), do: gettext("resolution not preferred")
  defp verdict_reason({:rejected, :wrong_source}), do: gettext("source not preferred")
  defp verdict_reason({:rejected, :wrong_protocol}), do: gettext("no client for protocol")
  defp verdict_reason(_), do: ""
end
```

*Note:* the `<.confirm_action>` component's confirm button does not natively carry a `phx-value-title`.
For the replace-confirm, store the pending title in the `@confirming` assign (done) and read it in the
`"grab"` handler from `socket.assigns.confirming` when `params["title"]` is absent:

```elixir
def handle_event("grab", params, socket) do
  title = params["title"] || socket.assigns.confirming
  release = Enum.find(socket.assigns.results, fn {r, _v} -> r.title == title end)
  if release, do: send(self(), {:manual_grab, socket.assigns.mode, socket.assigns.target, elem(release, 0)})
  {:noreply, assign(socket, confirming: nil)}
end
```

*(Replace the earlier `"grab"` clause with this one.)*

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder_web/components/manual_search_component_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder_web/components/manual_search_component.ex test/cinder_web/components/manual_search_component_test.exs && \
git commit -m "feat(ui): shared ManualSearchComponent (async release list + grab/replace-confirm)"
```

---

### Task 12: Wire the movie panel into `activity_live`

**Files:**
- Modify: `lib/cinder_web/live/activity_live.ex`
- Test: `test/cinder_web/live/activity_live_test.exs`

**Interfaces:**
- Consumes: `ManualSearchComponent` (Task 11), `Catalog.manual_grab_movie/2` (Task 6), `Catalog.abort_upgrade/2` (Task 8).
- Produces: a "Find a better match" button on each movie row that opens the panel; a "Cancel upgrade" button on an `:upgrading` row; the parent `handle_info({:manual_grab, :movie, movie, release}, …)` that calls `manual_grab_movie/2` and flashes the outcome.

- [ ] **Step 1: Write the failing test**

```elixir
test "Find a better match opens the panel and grabbing transitions the movie", %{conn: conn} do
  movie = movie_fixture(status: :available, imdb_id: "tt1", file_path: "/lib/M (2020)/M (2020).mkv")
  Cinder.Acquisition.IndexerMock |> stub(:search, fn _ -> {:ok, [%{title: "Better 1080p", size: 5_000_000_000, protocol: :torrent, download_url: "u"}]} end)
  Cinder.Download.ClientMock |> stub(:add, fn _ -> {:ok, "dl-x"} end)

  {:ok, lv, _html} = live(conn, ~p"/activity")
  lv |> element("#movie-#{movie.id} button", "Find a better match") |> render_click()
  assert render(lv) =~ "Better 1080p"
  # Open the replace confirm, then confirm:
  lv |> element("#ms-movie-#{movie.id} button", "Grab") |> render_click()
  lv |> element("button", "Replace file") |> render_click()
  assert Cinder.Catalog.get_movie_by_id(movie.id).status == :upgrading
end
```

*(Adjust the route — `~p"/activity"` — and element selectors to the real markup; the point is the
open→grab→confirm flow flips the movie to `:upgrading`.)*

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder_web/live/activity_live_test.exs -v`
Expected: FAIL — no "Find a better match" control.

- [ ] **Step 3: Wire the LiveView**

In `lib/cinder_web/live/activity_live.ex`:

Track which movie's panel is open. Add to `mount/2`'s assigns: `searching_movie_id: nil`.

Add event handlers (before the catch-all `handle_event(_event, _params, …)`):

```elixir
def handle_event("manual_search", %{"id" => id}, socket) do
  {:noreply, assign(socket, searching_movie_id: to_string(id))}
end

def handle_event("close_search", _params, socket),
  do: {:noreply, assign(socket, searching_movie_id: nil)}

def handle_event("cancel_upgrade", %{"id" => id}, socket) do
  movie = find_by_id(socket.assigns.movies, id)
  if movie, do: Catalog.abort_upgrade(movie, current_actor(socket))
  {:noreply, socket}
end
```

*(`current_actor/1` — use whatever the existing delete/cancel call sites pass as the actor; if
`activity_live` has no actor in scope, pass `:system` or the `socket.assigns.current_user` per the
project's audit convention. Check an existing `cancel_movie`/`delete_movie` call site.)*

Add the grab handler (the panel forwards to the parent via `send(self(), …)`):

```elixir
def handle_info({:manual_grab, :movie, movie, release}, socket) do
  flash =
    case Catalog.manual_grab_movie(movie, release) do
      {:ok, _} -> {:info, gettext("Grabbing the selected release…")}
      {:error, :not_grabbable} -> {:error, gettext("That movie can't be grabbed right now.")}
      {:error, _} -> {:error, gettext("Couldn't grab that release.")}
    end

  {level, msg} = flash
  {:noreply, socket |> assign(searching_movie_id: nil) |> put_flash(level, msg)}
end
```

In the HEEx movie row (`activity_live.ex` ~110–135), add the button + panel inside the `<li>`, after
the Retry button:

```heex
<.button
  :if={m.status == :available or parked?(m.status)}
  type="button"
  variant="ghost"
  size="sm"
  phx-click="manual_search"
  phx-value-id={m.id}
>
  {gettext("Find a better match")}
</.button>
<.button
  :if={m.status == :upgrading}
  type="button"
  variant="ghost"
  size="sm"
  phx-click="cancel_upgrade"
  phx-value-id={m.id}
>
  {gettext("Cancel upgrade")}
</.button>
<.live_component
  :if={@searching_movie_id == to_string(m.id)}
  module={Cinder.CinderWeb.ManualSearchComponent}
  id={"ms-movie-#{m.id}"}
  mode={:movie}
  target={m}
/>
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder_web/live/activity_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder_web/live/activity_live.ex test/cinder_web/live/activity_live_test.exs && \
git commit -m "feat(ui): wire movie manual-search + cancel-upgrade into activity_live"
```

---

### Task 13: Wire TV search controls + panel into `series_detail_live`

**Files:**
- Modify: `lib/cinder_web/live/series_detail_live.ex`
- Test: `test/cinder_web/live/series_detail_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.search_episode_now/1`, `search_series_now/1` (Task 9), `manual_grab_tv/3` (Task 10), `ManualSearchComponent` (Task 11).
- Produces: a per-episode "Search" button, a per-season "Search all missing" button, a per-season "Find a better match" button opening the TV panel, and the parent `handle_info({:manual_grab, :tv, series, release}, …)` (with the open panel's season number) calling `manual_grab_tv/3`.

- [ ] **Step 1: Write the failing test**

```elixir
test "Search all missing re-queues the season's wanted episodes", %{conn: conn} do
  series = series_with_wanted_episode(season: 1, search_attempts: 9)
  {:ok, lv, _html} = live(conn, ~p"/series/#{series.id}")
  lv |> element("button", "Search all missing") |> render_click()
  [ep] = Cinder.Catalog.wanted_episodes()
  assert ep.search_attempts == 0
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder_web/live/series_detail_live_test.exs -v`
Expected: FAIL — no "Search all missing" control.

- [ ] **Step 3: Wire the LiveView**

In `lib/cinder_web/live/series_detail_live.ex`:

Add to `mount/2` assigns: `searching_season: nil`.

Event handlers (before the catch-all at line 227):

```elixir
def handle_event("search_episode", %{"id" => id}, socket) do
  with {id, ""} <- Integer.parse(id),
       %Episode{} = ep <- find_episode(socket.assigns.series, id) do
    Catalog.search_episode_now(ep)
    {:noreply, put_flash(socket, :info, gettext("Searching for this episode…"))}
  else
    _ -> {:noreply, socket}
  end
end

def handle_event("search_season", _params, socket) do
  Catalog.search_series_now(socket.assigns.series)
  {:noreply, put_flash(socket, :info, gettext("Searching for missing episodes…"))}
end

def handle_event("tv_manual_search", %{"season" => n}, socket) do
  case Integer.parse(n) do
    {season, ""} -> {:noreply, assign(socket, searching_season: season)}
    _ -> {:noreply, socket}
  end
end

def handle_event("close_search", _params, socket),
  do: {:noreply, assign(socket, searching_season: nil)}
```

Grab handler:

```elixir
def handle_info({:manual_grab, :tv, series, release}, socket) do
  msg =
    case Catalog.manual_grab_tv(series, socket.assigns.searching_season, release) do
      {:ok, _grab} -> {:info, gettext("Grabbing the selected release…")}
      {:error, :nothing_wanted} -> {:error, gettext("Nothing left to grab this season.")}
      {:error, _} -> {:error, gettext("Couldn't grab that release.")}
    end

  {level, text} = msg
  {:noreply, socket |> assign(searching_season: nil) |> put_flash(level, text) |> reload()}
end
```

In the HEEx season header (~377–397), after the existing buttons, add:

```heex
<.button
  :if={Enum.any?(season.episodes, &(is_nil(&1.file_path) and is_nil(&1.grab_id) and &1.monitored))}
  type="button"
  variant="neutral"
  size="sm"
  phx-click="search_season"
>
  {gettext("Search all missing")}
</.button>
<.button
  type="button"
  variant="ghost"
  size="sm"
  phx-click="tv_manual_search"
  phx-value-season={season.season_number}
>
  {gettext("Find a better match")}
</.button>
<.live_component
  :if={@searching_season == season.season_number}
  module={Cinder.CinderWeb.ManualSearchComponent}
  id={"ms-season-#{season.id}"}
  mode={:tv}
  target={@series}
  season_number={season.season_number}
/>
```

In the episode row (~438–496), after the Delete-file button, add the per-episode Search:

```heex
<.button
  :if={is_nil(ep.file_path) and is_nil(ep.grab_id)}
  type="button"
  variant="ghost"
  size="sm"
  phx-click="search_episode"
  phx-value-id={ep.id}
  aria-label={gettext("Search for episode %{number}", number: ep.episode_number)}
>
  {gettext("Search")}
</.button>
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder_web/live/series_detail_live_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix test && git add lib/cinder_web/live/series_detail_live.ex test/cinder_web/live/series_detail_live_test.exs && \
git commit -m "feat(ui): TV per-episode/season search + manual-search panel in series detail"
```

---

### Task 14: i18n — translate the new strings

**Files:**
- Modify: `priv/gettext/default.pot`, `priv/gettext/fr/LC_MESSAGES/default.po` (and `en` if the project keeps one)
- Test: the project's i18n completeness test (find it — likely `test/cinder_web/i18n_test.exs` or similar)

**Interfaces:** none — closes the French-completeness guard for every `gettext(...)` string added in Tasks 5, 11, 12, 13.

- [ ] **Step 1: Confirm the guard fails first**

Run: `mix test` (the alias) — or the specific i18n test if you can name it.
Expected: the i18n completeness test FAILS, listing the new untranslated msgids (e.g. "Upgrading",
"Find a better match", "Search all missing", "Replace file", "outside size band", …).

- [ ] **Step 2: Extract + merge**

Run:
```bash
mix gettext.extract
mix gettext.merge priv/gettext
```
This adds the new msgids to `default.pot` and every locale's `default.po`.

- [ ] **Step 3: Fill in the French translations**

Edit `priv/gettext/fr/LC_MESSAGES/default.po`, providing `msgstr` for each new `msgid`. Suggested:

```
msgid "Upgrading"                  → msgstr "Mise à niveau"
msgid "Find a better match"        → msgstr "Trouver une meilleure version"
msgid "Cancel upgrade"             → msgstr "Annuler la mise à niveau"
msgid "Search"                     → msgstr "Rechercher"
msgid "Search all missing"         → msgstr "Rechercher les épisodes manquants"
msgid "Searching releases…"        → msgstr "Recherche de versions…"
msgid "No releases found."         → msgstr "Aucune version trouvée."
msgid "Grab"                       → msgstr "Récupérer"
msgid "Replace file"               → msgstr "Remplacer le fichier"
msgid "Replace the current file for this movie with the selected release?"
                                   → msgstr "Remplacer le fichier actuel de ce film par la version sélectionnée ?"
msgid "All episodes present — replacing existing TV files isn't supported yet."
                                   → msgstr "Tous les épisodes sont présents — le remplacement des fichiers TV existants n'est pas encore pris en charge."
msgid "outside size band"          → msgstr "hors de la plage de taille"
msgid "blocklisted"                → msgstr "sur liste de blocage"
msgid "resolution not preferred"   → msgstr "résolution non préférée"
msgid "source not preferred"       → msgstr "source non préférée"
msgid "no client for protocol"     → msgstr "aucun client pour ce protocole"
```

Also translate every other new msgid the extract surfaces (the flash strings, aria-labels). Leave none
with an empty `msgstr` — the guard fails on blanks.

- [ ] **Step 4: Run the full suite, verify green**

Run: `mix test`
Expected: PASS, including the i18n completeness test.

- [ ] **Step 5: Commit**

```bash
git add priv/gettext && git commit -m "i18n: French translations for manual-search + better-match strings"
```

---

## Self-Review

**Spec coverage:**
- Movie auto "Search now" (stuck) → existing `retry_movie` exposed via the "Find a better match"
  open + the existing Retry button (Task 12). ✓
- Movie interactive manual search + replace-available → Tasks 4, 6, 7, 11, 12. ✓
- `:upgrading` state + every audited consumer (badge, dashboard, cancel/delete) → Tasks 5, 7, 8. ✓
- Verdict reasons correctly sourced (scorer + protocol; language as a UI hint) → Tasks 1, 2, 11. ✓
- TV "search missing episode / all missing" → Tasks 9, 13. ✓
- TV interactive better-match (wanted episodes; full-season "not supported" state) → Tasks 10, 11, 13. ✓
- Different-container old-file delete, best-effort → Task 7. ✓
- Failed upgrade reverts + blocklists; `block_release(movie, :upgrade_failed)` arity → Task 7. ✓
- Server guards + StaleEntryError rescue → Task 6. ✓
- i18n guard → Task 14. ✓
- Deferred (replace already-imported TV episode; auto upgrade sweep; global search-all): not built,
  as specified.

**Placeholder scan:** the only deliberate "adjust to the real markup/setup" notes are in test
selectors and fixture helpers, where the exact existing names must be matched at implementation time;
every production code block is complete.

**Type consistency:** `manual_grab_movie/2`, `manual_grab_tv/3`, `abort_upgrade/2`,
`search_episode_now/1`, `search_series_now/1`, `Download.grab/1`, `Acquisition.list_releases/2` +
`list_releases_tv/3`, `Scorer.verdict/2` + `rank_key/2`, `Library.import_movie/2` — names/arities are
consistent between their defining task and every consuming task. The panel→parent message
`{:manual_grab, mode, target, release}` is produced in Task 11 and consumed in Tasks 12 and 13 with
the same shape.
