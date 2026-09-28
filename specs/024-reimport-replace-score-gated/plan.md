# Score-gated Replace on Re-import — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a re-import lands on an item already in the library, replace the file only if the new release is an upgrade (language-first, then resolution, then size); otherwise keep it and succeed — never park — and make library folders tmdb-unique so different titles can't collide.

**Architecture:** `Cinder.Library` gains a place/replace/keep decision at the dest (replacing the `:dest_exists` guard), keyed on tmdb-tagged folder names (which prove "same item") and a pure `Cinder.Library.Upgrade.better?/4` comparison. Quality (`imported_resolution/size/language`) is persisted on `movies` and `episodes`. Replace is an atomic hardlink-to-temp + `File.rename`.

**Tech Stack:** Elixir, Phoenix, Ecto + SQLite, Mox (behaviour mocks), ExUnit. Repo on CT113 at `/root/cinder`; run all commands there.

## Global Constraints

- Run everything in CT113: prefix with `pct exec 113 -- env -i HOME=/root TMPDIR=/tmp PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -lc 'cd /root/cinder && <cmd>'` (a login shell so `mise`/Elixir 1.20 is on PATH). Tests: `mix test`. Lint: `mix credo --strict`. Format: `mix format`.
- Branch `feat/import-upgrade-replace` off `main` (`0d0b66b`).
- TDD: failing test first, watch it fail, minimal impl, watch it pass, commit. Frequent commits.
- The codebase is `--warnings-as-errors` in CI; keep it clean. Tests are `async: true`, Mox `verify_on_exit!`, no real disk/network.
- `media_info` is `nil` in test config by default (no ffprobe); the import-time `verify_audio` is therefore a no-op in most tests unless a test opts into `MediaInfoMock`.
- Movies always have a `tmdb_id` (`NOT NULL`); test fixtures that omit it must add one once naming uses it.
- "Quality" is name-parsed; `resolution` is frequently `nil` (treat as worst rank). Replace only on a **strictly better** signal.

---

### Task 1: tmdb-tagged library names + Plex moduledoc + test sweep

**Files:**
- Modify: `lib/cinder/library.ex` — `library_name/3` (~L344-346), moduledoc (~L3) Jellyfin→Plex
- Test: `test/cinder/library_test.exs`, plus path-string updates in `test/cinder/download/poller_test.exs`, `test/cinder/download/tv_poller_test.exs`, `test/cinder/catalog_tv_pipeline_test.exs`, and any other file asserting a dest path.

**Interfaces:**
- Produces: `library_name(title, year, tmdb_id)` now emits `"#{title} (#{year}) {tmdb-#{id}}"`, `"#{title} {tmdb-#{id}}"`, or unchanged `"tmdb-#{id}"`. `build_dest`/`build_episode_dest` keep their signatures; only the leaf name changes.

- [ ] **Step 1: Update the failing tests first (naming).** In `test/cinder/library_test.exs`, give every `%Movie{}` a `tmdb_id` and change each dest assertion to the tagged form. Example — the first test becomes:

```elixir
test "single-file source: hardlinks to Title (Year) {tmdb-N}/… and scans" do
  movie = %Movie{title: "Inception", year: 2010, tmdb_id: 27205, file_path: "/dl/Inception.2010.1080p.mkv"}

  expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Inception.2010.1080p.mkv" -> false end)
  expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/Inception (2010) {tmdb-27205}" -> :ok end)

  expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Inception.2010.1080p.mkv",
                                                "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv" ->
    :ok
  end)

  expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

  assert {:ok, "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv"} =
           Library.import_movie(movie)
end
```

The `ep/4` helper already sets `tmdb_id: 1`, so TV dests become `#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E…`. Update every TV dest assertion accordingly.

- [ ] **Step 2: Find every other hardcoded dest path and update it.**

Run: `grep -rnE '\((19|20)[0-9]{2}\)/' test/ lib/` and `grep -rn 'tmdb-' test/`
Update each assertion to the `{tmdb-N}` form. Common files: `poller_test.exs`, `tv_poller_test.exs`, `catalog_tv_pipeline_test.exs`, `m3_pipeline_test.exs`.

- [ ] **Step 3: Run the naming tests to confirm they fail.**

Run: `mix test test/cinder/library_test.exs`
Expected: FAIL — current `library_name` emits the untagged name, so the `mkdir_p`/`ln`/return assertions mismatch.

- [ ] **Step 4: Implement the naming change.** In `lib/cinder/library.ex`:

```elixir
defp library_name("", _year, tmdb_id), do: "tmdb-#{tmdb_id}"
defp library_name(title, nil, tmdb_id), do: "#{title} {tmdb-#{tmdb_id}}"
defp library_name(title, year, tmdb_id), do: "#{title} (#{year}) {tmdb-#{tmdb_id}}"
```

Also update the moduledoc first paragraph: replace "Jellyfin" with "Plex" and the example `Title (Year)/` with `Title (Year) {tmdb-<id>}/`.

- [ ] **Step 5: Run the full suite; fix any remaining path assertions.**

Run: `mix test`
Expected: PASS. If a test still fails on a path, it's an un-updated assertion — fix it.

- [ ] **Step 6: Commit.**

```bash
git add lib/cinder/library.ex test/
git commit -m "feat(library): tmdb-tag library folder names; Plex moduledoc"
```

---

### Task 2: persist `imported_*` quality (migrations + changesets + clearing)

**Files:**
- Create: `priv/repo/migrations/20260626120000_add_imported_quality.exs`
- Modify: `lib/cinder/catalog/movie.ex` (`transition_changeset/2`), `lib/cinder/catalog/episode.ex` (`transition_changeset/2`), `lib/cinder/catalog.ex` (`do_delete_episode_file_txn/3` ~L687, `do_delete_season_files_txn/4` ~L747)
- Test: `test/cinder/catalog_test.exs` (or the existing delete-file test module)

**Interfaces:**
- Produces: `movies` and `episodes` rows carry `imported_resolution :string`, `imported_size :integer`, `imported_language :string`; both `transition_changeset/2` cast them; delete-file paths null them.

- [ ] **Step 1: Write the migration.**

```elixir
defmodule Cinder.Repo.Migrations.AddImportedQuality do
  use Ecto.Migration

  def change do
    for tbl <- [:movies, :episodes] do
      alter table(tbl) do
        add :imported_resolution, :string
        add :imported_size, :integer
        add :imported_language, :string
      end
    end
  end
end
```

- [ ] **Step 2: Add the fields to both schemas.** In `lib/cinder/catalog/movie.ex` add inside `schema "movies"`:

```elixir
    field :imported_resolution, :string
    field :imported_size, :integer
    field :imported_language, :string
```

and add `:imported_resolution, :imported_size, :imported_language` to the `cast(attrs, [...])` list in `transition_changeset/2`. Do the identical edits in `lib/cinder/catalog/episode.ex` (schema + `transition_changeset/2` cast list).

- [ ] **Step 3: Write a failing test for clearing on delete.** In the episode delete-file test module:

```elixir
test "delete_episode_file/3 clears imported quality" do
  # build an episode with a file_path and imported_* set, persisted via the repo,
  # then call Catalog.delete_episode_file(ep, actor) and assert the reloaded row has
  # file_path: nil and imported_resolution/size/language: nil.
end
```

(Follow the existing delete-file test's setup for building a persisted episode + actor.)

- [ ] **Step 4: Run it; expect failure (fields not cleared).**

Run: `mix test test/cinder/<delete-file test>.exs`
Expected: FAIL — reloaded `imported_*` are still set.

- [ ] **Step 5: Clear `imported_*` at both episode delete sites.** In `do_delete_episode_file_txn/3`:

```elixir
|> Episode.transition_changeset(%{
  file_path: nil,
  imported_resolution: nil,
  imported_size: nil,
  imported_language: nil
})
```

In `do_delete_season_files_txn/4`, extend the raw `set:` keyword list:

```elixir
[file_path: nil, imported_resolution: nil, imported_size: nil, imported_language: nil, updated_at: now()]
++ if(unmonitor?, do: [monitored: false], else: [])
```

(Movies that are deleted remove the whole row, so no clearing is needed there; if a movie-file-delete-without-row path exists, clear it the same way — grep `def delete_` in catalog.ex to confirm.)

- [ ] **Step 6: Run migration + tests.**

Run: `mix ecto.migrate && mix test`
Expected: PASS. (`retry_movie/1` already does not cast `imported_*`, so quality correctly persists across a re-request — no change there.)

- [ ] **Step 7: Commit.**

```bash
git add priv/repo/migrations/ lib/cinder/catalog/ lib/cinder/catalog.ex test/
git commit -m "feat(catalog): persist imported quality on movies+episodes; clear on file delete"
```

---

### Task 3: `Filesystem.rename` primitive + atomic replace helper

**Files:**
- Modify: `lib/cinder/library/filesystem.ex` (behaviour), `lib/cinder/library/filesystem/disk.ex` (impl), `lib/cinder/library.ex` (add `replace/2` + temp sweep)
- Test: `test/cinder/library/filesystem/disk_test.exs` (or the existing disk test), `test/cinder/library_test.exs`

**Interfaces:**
- Produces: `@callback rename(source, dest) :: :ok | {:error, term()}`; `Disk.rename/2 = File.rename/2`; private `Cinder.Library.replace(source, dest) :: :ok | {:error, term()}` that hardlinks to a temp then renames over dest (used by Tasks 5/6).

- [ ] **Step 1: Add the behaviour callback.** In `lib/cinder/library/filesystem.ex`:

```elixir
  @callback rename(source :: String.t(), dest :: String.t()) :: :ok | {:error, term()}
```

- [ ] **Step 2: Write the failing Disk test.** In the disk test module:

```elixir
test "rename/2 atomically replaces an existing dest" do
  dir = Path.join(System.tmp_dir!(), "cinder-rename-#{System.unique_integer([:positive])}")
  File.mkdir_p!(dir)
  src = Path.join(dir, "src"); dst = Path.join(dir, "dst")
  File.write!(src, "new"); File.write!(dst, "old")
  assert :ok = Cinder.Library.Filesystem.Disk.rename(src, dst)
  assert File.read!(dst) == "new"
  refute File.exists?(src)
end
```

- [ ] **Step 3: Run it; expect failure (no `rename/0` impl).**

Run: `mix test test/cinder/library/filesystem/disk_test.exs`
Expected: FAIL — `rename/2` undefined.

- [ ] **Step 4: Implement `Disk.rename/2`.** In `lib/cinder/library/filesystem/disk.ex`:

```elixir
  @impl true
  def rename(source, dest), do: File.rename(source, dest)
```

- [ ] **Step 5: Run the disk test; expect pass.**

Run: `mix test test/cinder/library/filesystem/disk_test.exs`
Expected: PASS.

- [ ] **Step 6: Write a failing test for `Library.replace` via the mock.** In `library_test.exs` (replace is private, so test it through the behaviour it calls). Add a focused test that drives a replace path; since `replace/2` is exercised by Task 5, write the unit here against the Mock expectations it will make: sweep (find stale temps) is best-effort. Minimal direct test:

```elixir
test "replace/2 hardlinks to a temp then renames over dest" do
  src = "/dl/new.mkv"
  dest = "#{@lib}/X (2020) {tmdb-9}/X (2020) {tmdb-9}.mkv"
  # sweep: list dest dir for stale temps (none)
  expect(Cinder.Library.FilesystemMock, :find_files, fn _dir -> {:ok, []} end)
  expect(Cinder.Library.FilesystemMock, :ln, fn ^src, tmp -> assert String.contains?(tmp, ".cinder-tmp-"); :ok end)
  expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, ^dest -> :ok end)
  assert :ok = Cinder.Library.replace_for_test(src, dest)  # thin public wrapper for the test
end
```

(If you prefer not to expose a wrapper, defer this test and cover `replace` through Task 5's replace-path test. Either is acceptable; pick one and keep it.)

- [ ] **Step 7: Implement `replace/2` + temp sweep in `lib/cinder/library.ex`.**

```elixir
# Atomic replace of an existing dest with source's content: sweep stale temps (a host crash
# between ln and rename can leak one), hardlink source -> unique temp in the dest dir, then
# rename over dest. Same-fs (hardlink invariant) so rename is atomic.
defp replace(source, dest) do
  dir = Path.dirname(dest)
  sweep_temps(dir)
  tmp = Path.join(dir, ".cinder-tmp-#{System.unique_integer([:positive])}")

  with :ok <- fs().ln(source, tmp),
       :ok <- fs().rename(tmp, dest) do
    :ok
  else
    {:error, _} = err ->
      _ = fs().rm(tmp)
      err
  end
end

defp sweep_temps(dir) do
  case fs().find_files(dir) do
    {:ok, files} ->
      for {path, _size} <- files, String.contains?(Path.basename(path), ".cinder-tmp-"), do: fs().rm(path)
      :ok

    _ ->
      :ok
  end
end
```

- [ ] **Step 8: Run tests; expect pass. Commit.**

Run: `mix test test/cinder/library/filesystem/disk_test.exs test/cinder/library_test.exs`
Expected: PASS.

```bash
git add lib/cinder/library/ lib/cinder/library.ex test/
git commit -m "feat(library): Filesystem.rename primitive + atomic replace with temp sweep"
```

---

### Task 4: `Cinder.Library.Upgrade` + `resolution_rank` string variant + `satisfies_lang?`

**Files:**
- Create: `lib/cinder/library/upgrade.ex`, `test/cinder/library/upgrade_test.exs`
- Modify: `lib/cinder/acquisition/scorer.ex` (public string `resolution_rank/2`), `lib/cinder/acquisition/language.ex` (`satisfies_lang?/2`)
- Test: add cases to `test/cinder/acquisition/language_test.exs` and `scorer_test.exs`

**Interfaces:**
- Consumes: `Scorer.resolution_rank(resolution :: String.t() | nil, preferred :: [String.t()])`, `Language.satisfies_lang?(code :: String.t() | nil, target :: String.t() | nil)`.
- Produces: `Cinder.Library.Upgrade.better?(new, old, target, preferred)` where `new`/`old` are `%{resolution:, size:, language:}` maps and `preferred` may be `nil`.

- [ ] **Step 1: Make `Scorer.resolution_rank/2` accept a string (failing test).** In `scorer_test.exs`:

```elixir
test "resolution_rank/2 ranks a resolution string by preference, nil/unknown last" do
  pref = ["1080p", "720p"]
  assert Cinder.Acquisition.Scorer.resolution_rank("1080p", pref) == 0
  assert Cinder.Acquisition.Scorer.resolution_rank("720p", pref) == 1
  assert Cinder.Acquisition.Scorer.resolution_rank("2160p", pref) == 2  # unlisted -> length
  assert Cinder.Acquisition.Scorer.resolution_rank(nil, pref) == 2
end
```

- [ ] **Step 2: Run it; expect failure (private / wrong arity).**

Run: `mix test test/cinder/acquisition/scorer_test.exs`
Expected: FAIL — `resolution_rank/2` is private and takes a `%Release{}`.

- [ ] **Step 3: Implement the public string variant in `scorer.ex`.** Replace the private clause with:

```elixir
@doc "Index of a resolution string in the preference list (lower = better); nil/unlisted sorts last."
def resolution_rank(resolution, preferred) when is_binary(resolution) or is_nil(resolution),
  do: Enum.find_index(preferred, &(&1 == resolution)) || length(preferred)

defp resolution_rank(%Release{} = release, preferred),
  do: resolution_rank(release.resolution, preferred)
```

(Keep the private `%Release{}` clause delegating, so `greedy_key`/`sort_key` are unchanged.)

- [ ] **Step 4: Run scorer tests; expect pass.**

Run: `mix test test/cinder/acquisition/scorer_test.exs`
Expected: PASS.

- [ ] **Step 5: Add `Language.satisfies_lang?/2` (failing test).** In `language_test.exs`:

```elixir
test "satisfies_lang?/2 truth table" do
  alias Cinder.Acquisition.Language
  assert Language.satisfies_lang?("MULTI", "fr")
  assert Language.satisfies_lang?(nil, "en")
  assert Language.satisfies_lang?("", "en")
  refute Language.satisfies_lang?(nil, "fr")
  assert Language.satisfies_lang?("FRENCH", "fr")
  refute Language.satisfies_lang?("HUNGARIAN", "fr")
  assert Language.satisfies_lang?("HUNGARIAN", nil) == true  # nil target: not discriminating
end
```

- [ ] **Step 6: Run it; expect failure. Implement `satisfies_lang?/2` in `language.ex`.**

```elixir
@doc "Whether a raw parsed language code satisfies the target (no %Release{} needed). nil target = true."
def satisfies_lang?(_code, nil), do: true
def satisfies_lang?("MULTI", _target), do: true
def satisfies_lang?(code, target) when code in [nil, ""], do: target == @default_audio
def satisfies_lang?(code, target), do: code == tag(target)
```

Run: `mix test test/cinder/acquisition/language_test.exs` → PASS.

- [ ] **Step 7: Write `Upgrade` tests (the core table).** In `test/cinder/library/upgrade_test.exs`:

```elixir
defmodule Cinder.Library.UpgradeTest do
  use ExUnit.Case, async: true
  alias Cinder.Library.Upgrade

  @pref ["2160p", "1080p", "720p"]
  defp q(res, size, lang), do: %{resolution: res, size: size, language: lang}

  test "nil baseline is always an upgrade" do
    assert Upgrade.better?(q("720p", 1, "en"), q(nil, nil, nil), nil, @pref)
  end

  test "language upgrade beats lower resolution (the French case)" do
    # target fr; old is Hungarian 1080p big, new is French untagged-resolution small
    assert Upgrade.better?(q(nil, 1_000, "FRENCH"), q("1080p", 9_000, "HUNGARIAN"), "fr", @pref)
  end

  test "language downgrade is blocked" do
    refute Upgrade.better?(q("2160p", 9_000, "HUNGARIAN"), q("1080p", 1_000, "FRENCH"), "fr", @pref)
  end

  test "nil target falls to quality only" do
    assert Upgrade.better?(q("2160p", 1, "x"), q("1080p", 9_000, "y"), nil, @pref)
    refute Upgrade.better?(q("720p", 9_000, "x"), q("1080p", 1, "y"), nil, @pref)
  end

  test "better resolution wins; nil resolution never out-ranks a known one" do
    assert Upgrade.better?(q("1080p", 1, "en"), q("720p", 9_000, "en"), nil, @pref)
    refute Upgrade.better?(q(nil, 9_000, "en"), q("1080p", 1, "en"), nil, @pref)
  end

  test "equal resolution: larger size wins (documented weak proxy)" do
    assert Upgrade.better?(q("1080p", 9_000, "en"), q("1080p", 1_000, "en"), nil, @pref)
    refute Upgrade.better?(q("1080p", 1_000, "en"), q("1080p", 9_000, "en"), nil, @pref)
  end

  test "nil preferred falls back to scorer defaults without crashing" do
    assert Upgrade.better?(q("1080p", 1, "en"), q("720p", 1, "en"), nil, nil)
  end
end
```

- [ ] **Step 8: Run it; expect failure (module missing). Implement `Upgrade`.**

```elixir
defmodule Cinder.Library.Upgrade do
  @moduledoc """
  Pure decision: is `new` a quality/language upgrade over `old`, per cinder's selection model
  (language-first, then resolution preference, then size)? `new`/`old` are
  `%{resolution: String.t()|nil, size: integer|nil, language: String.t()|nil}` describing a
  release/library file. Name-parsed; resolution is often nil (ranks last); size is a weak proxy.
  """
  alias Cinder.Acquisition.{Language, Scorer}

  @default_preferred ["1080p", "720p"]

  @spec better?(map(), map(), String.t() | nil, [String.t()] | nil) :: boolean()
  def better?(new, old, target, preferred) do
    cond do
      nil_baseline?(old) -> true
      language_decides?(new, old, target) != :tie -> language_decides?(new, old, target) == :upgrade
      true -> quality_better?(new, old, preferred || @default_preferred)
    end
  end

  defp nil_baseline?(%{resolution: nil, size: nil, language: nil}), do: true
  defp nil_baseline?(_), do: false

  defp language_decides?(new, old, target) do
    cond do
      is_nil(target) -> :tie
      not Language.satisfies_lang?(old.language, target) and Language.satisfies_lang?(new.language, target) -> :upgrade
      Language.satisfies_lang?(old.language, target) and not Language.satisfies_lang?(new.language, target) -> :downgrade
      true -> :tie
    end
  end

  defp quality_better?(new, old, preferred) do
    nr = Scorer.resolution_rank(new.resolution, preferred)
    orr = Scorer.resolution_rank(old.resolution, preferred)
    nr < orr or (nr == orr and (new.size || 0) > (old.size || 0))
  end
end
```

Run: `mix test test/cinder/library/upgrade_test.exs` → PASS.

- [ ] **Step 9: Commit.**

```bash
git add lib/cinder/library/upgrade.ex lib/cinder/acquisition/ test/
git commit -m "feat(library): Upgrade.better?/4 + string resolution_rank + satisfies_lang?"
```

---

### Task 5: movie import — place/replace/keep + contract + poller persistence

**Files:**
- Modify: `lib/cinder/library.ex` (`import_movie/1`, `link/2`→decision, helpers), `lib/cinder/download/poller.ex` (`import_one/1`)
- Test: `test/cinder/library_test.exs`, `test/cinder/download/poller_test.exs`

**Interfaces:**
- Consumes: `Upgrade.better?/4`, `replace/2`, `Parser.parse/1`, `fs().lstat/1` (→ `%File.Stat{size:}`), `movies_preferred_resolutions` env.
- Produces: `import_movie/1 :: {:ok, dest, quality} | {:error, term()}` where `quality = %{resolution:, size:, language:}`. `Poller.import_one/1` writes the quality on the `:available` transition.

- [ ] **Step 1: Failing test — first import returns quality.** In `library_test.exs`, update the single-file test to assert the 3-tuple and parsed quality:

```elixir
assert {:ok, dest, %{resolution: "1080p", size: 5_000_000_000, language: nil}} =
         Library.import_movie(movie)
```

Add an `lstat` expectation returning the size (parse comes from the file_path basename, size from lstat of the source):

```elixir
expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Inception.2010.1080p.mkv" ->
  {:ok, %File.Stat{size: 5_000_000_000, inode: 1}}
end)
```

- [ ] **Step 2: Failing test — replace on language upgrade.**

```elixir
test "re-import replaces the existing file on a language upgrade" do
  movie = %Movie{title: "Open Season", year: 2023, tmdb_id: 1001026,
                 preferred_language: "french", original_language: "hu",
                 imported_resolution: "1080p", imported_size: 9 * @gb, imported_language: "HUNGARIAN",
                 file_path: "/dl/Chasse.Gardee.2023.FRENCH.mkv"}
  dest = "#{@lib}/Open Season (2023) {tmdb-1001026}/Open Season (2023) {tmdb-1001026}.mkv"

  expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
  expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Chasse.Gardee.2023.FRENCH.mkv" ->
    {:ok, %File.Stat{size: 2 * @gb, inode: 7}}
  end)
  expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
  # ln to dest collides:
  expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Chasse.Gardee.2023.FRENCH.mkv", ^dest -> {:error, :eexist} end)
  # different inode (source 7 vs dest 99) -> replace path:
  expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
  expect(Cinder.Library.FilesystemMock, :find_files, fn _dir -> {:ok, []} end)      # sweep
  expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Chasse.Gardee.2023.FRENCH.mkv", tmp ->
    assert String.contains?(tmp, ".cinder-tmp-"); :ok
  end)
  expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, ^dest -> :ok end)
  expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

  assert {:ok, ^dest, %{resolution: nil, size: 2_000_000_000, language: "FRENCH"}} =
           Library.import_movie(movie)
end
```

- [ ] **Step 3: Failing test — keep on non-upgrade.** Same shape, but `imported_*` describe a better file and the new is worse; assert **no `rename`**, returns `{:ok, dest, old_quality}`, logs "kept existing":

```elixir
test "re-import keeps the existing file when the new release is not an upgrade" do
  movie = %Movie{title: "Heat", year: 1995, tmdb_id: 949,
                 imported_resolution: "1080p", imported_size: 9 * @gb, imported_language: nil,
                 file_path: "/dl/Heat.1995.720p.mkv"}
  dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"
  expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
  expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.1995.720p.mkv" -> {:ok, %File.Stat{size: 1 * @gb, inode: 7}} end)
  expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
  expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> {:error, :eexist} end)
  expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
  # no rename, no sweep:
  log = capture_log(fn ->
    assert {:ok, ^dest, %{resolution: "1080p", size: 9_000_000_000, language: nil}} =
             Library.import_movie(movie)
  end)
  assert log =~ "kept existing"
end
```

Also keep/adjust the existing same-inode idempotency test to assert `{:ok, dest, existing_quality}` with **no rename**.

- [ ] **Step 4: Run the new tests; expect failure.**

Run: `mix test test/cinder/library_test.exs`
Expected: FAIL — `import_movie` returns a 2-tuple and has no replace/keep branch.

- [ ] **Step 5: Implement the decision in `lib/cinder/library.ex`.** Rewrite `import_movie/1` and replace `link/2`+`idempotent_or_collision/2`:

```elixir
@spec import_movie(Movie.t()) :: {:ok, String.t(), map()} | {:error, term()}
def import_movie(%Movie{file_path: path}) when path in [nil, ""], do: {:error, :no_file_path}

def import_movie(%Movie{} = movie) do
  with {:ok, root} <- root(:movies),
       {:ok, source} <- resolve_source(movie.file_path),
       :ok <- verify_audio(source, Language.target(movie.preferred_language, movie.original_language)),
       {:ok, new_q} <- source_quality(movie.file_path, source),
       dest = build_dest(movie, source, root),
       :ok <- fs().mkdir_p(Path.dirname(dest)),
       {:ok, quality} <- place(source, dest, movie, new_q) do
    scan(:movies, dest)
    {:ok, dest, quality}
  end
end

# Parsed release attrs (from the download NAME) + actual size (from the picked source file).
defp source_quality(file_path, source) do
  parsed = Parser.parse(Path.basename(file_path))
  case fs().lstat(source) do
    {:ok, %{size: size}} -> {:ok, %{resolution: parsed.resolution, size: size, language: parsed.language}}
    {:error, _} = err -> err
  end
end

# Place source at dest, resolving a same-item collision by upgrade decision.
defp place(source, dest, movie, new_q) do
  case fs().ln(source, dest) do
    :ok -> {:ok, new_q}
    {:error, :eexist} -> resolve_collision(source, dest, movie, new_q)
    {:error, _} = err -> err
  end
end

defp resolve_collision(source, dest, movie, new_q) do
  with {:ok, %{inode: si}} <- fs().lstat(source),
       {:ok, %{inode: di}} <- fs().lstat(dest) do
    cond do
      si == di -> {:ok, existing_quality(movie, new_q)}      # idempotent re-link, no rename
      upgrade?(movie, new_q) -> with :ok <- replace(source, dest), do: {:ok, new_q}
      true -> keep(dest, movie, new_q)
    end
  end
end

defp existing_quality(movie, new_q) do
  if nil_q?(movie), do: new_q, else: %{resolution: movie.imported_resolution, size: movie.imported_size, language: movie.imported_language}
end

defp nil_q?(m), do: is_nil(m.imported_resolution) and is_nil(m.imported_size) and is_nil(m.imported_language)

defp upgrade?(movie, new_q) do
  old_q = %{resolution: movie.imported_resolution, size: movie.imported_size, language: movie.imported_language}
  target = Language.target(movie.preferred_language, movie.original_language)
  Cinder.Library.Upgrade.better?(new_q, old_q, target, preferred_resolutions(:movies))
end

defp keep(dest, movie, new_q) do
  old_q = existing_quality(movie, new_q)
  Logger.info("kept existing #{inspect(old_q.resolution)} file at #{dest}; new release not an upgrade")
  {:ok, old_q}
end

defp preferred_resolutions(kind),
  do: Application.get_env(:cinder, :"#{kind}_preferred_resolutions")
```

Add `alias Cinder.Acquisition.{Language, Parser}` already present; ensure `Cinder.Library.Upgrade` is reachable (full name used above). Delete the old `link/2` + `idempotent_or_collision/2` (movies path no longer uses them; TV still uses `link/2` until Task 6 — keep `link/2` for now and have `link_all` call it, OR move TV to `place` in Task 6. Simplest: keep `link/2` temporarily for TV, remove in Task 6).

- [ ] **Step 6: Update `Poller.import_one/1`.** In `lib/cinder/download/poller.ex`, change the success branch:

```elixir
defp import_one(movie) do
  case Library.import_movie(movie) do
    {:ok, _dest, q} ->
      with {:ok, available} <-
             Catalog.transition(movie, %{
               status: :available,
               imported_resolution: q.resolution,
               imported_size: q.size,
               imported_language: q.language
             }) do
        Notifier.notify({:movie_available, available})
        Download.remove_after_import(movie.download_protocol, movie.download_id)
      end
    # ... unchanged :library_not_configured / permanent / transient clauses ...
  end
end
```

- [ ] **Step 7: Fix `poller_test.exs` import stubs.** Any helper that stubs a successful import (`ln -> :ok`, `scan -> :ok`) must also `expect`/`stub` `lstat -> {:ok, %File.Stat{size: …, inode: 1}}` and assert/accept the 3-tuple. Update those helpers and the `:available` assertions to include `imported_*`.

- [ ] **Step 8: Run movie + poller tests; expect pass.**

Run: `mix test test/cinder/library_test.exs test/cinder/download/poller_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit.**

```bash
git add lib/cinder/library.ex lib/cinder/download/poller.ex test/
git commit -m "feat(library): score-gated replace/keep on movie re-import; persist quality"
```

---

### Task 6: TV import — per-episode decision + contract + persistence

**Files:**
- Modify: `lib/cinder/library.ex` (`import_episodes/2`, `link_all/2`→per-episode decision, remove old `link/2`/`idempotent_or_collision/2`), `lib/cinder/catalog.ex` (`finish_grab/2`), `lib/cinder/download/tv_poller.ex` (`notify_available/2`)
- Test: `test/cinder/library_test.exs` (TV cases), `test/cinder/download/tv_poller_test.exs`, `test/cinder/catalog_tv_pipeline_test.exs`

**Interfaces:**
- Produces: `import_episodes/2 :: {:ok, [{ep_id, dest, quality}], unmatched} | {:error, term()}`; `finish_grab/2` accepts 3-tuples and writes `imported_*`.

- [ ] **Step 1: Failing test — per-episode quality + replace/keep.** In `library_test.exs`, update the TV import tests to expect `{ep_id, dest, quality}` tuples and assert the dest is `{tmdb-1}`-tagged. Add a replace case: an `Episode` with `imported_resolution: "720p"` etc. whose new source parses `1080p` → replace (asserts `rename`); and a keep case (new worse) → no `rename`, quality unchanged, episode still in the returned list. Source quality for an episode comes from `Parser.parse(Path.basename(source))` + `lstat(source)`.

- [ ] **Step 2: Run; expect failure. Implement the TV decision.** In `link_all/2`, replace the `link` call with the same `place`-style decision per episode, accumulating `{ep.id, dest, quality}`; a "kept" episode is included with its existing quality. Sketch:

```elixir
defp link_all(to_import, root, episode_q) do
  Enum.reduce_while(to_import, {:ok, []}, fn {ep, source}, {:ok, acc} ->
    dest = build_episode_dest(ep, source, root)
    with {:ok, new_q} <- source_quality(source, source),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, q} <- place_episode(source, dest, ep, new_q) do
      {:cont, {:ok, [{ep.id, dest, q} | acc]}}
    else
      {:error, _} = err -> {:halt, err}
    end
  end)
end
```

`place_episode/4` mirrors `place`/`resolve_collision` but reads `ep.imported_*` and uses `episode_target(episodes)`/`preferred_resolutions(:tv)`. Thread `import_episodes` to compute `target`/prefs once and pass down. Update `do_import_episodes` to return the 3-tuple list. Remove the now-unused `link/2` + `idempotent_or_collision/2`.

- [ ] **Step 3: Update `finish_grab/2`.** In `lib/cinder/catalog.ex`:

```elixir
for {episode_id, dest, q} <- imported do
  Repo.update_all(from(e in Episode, where: e.id == ^episode_id),
    set: [file_path: dest, grab_id: nil,
          imported_resolution: q.resolution, imported_size: q.size, imported_language: q.language,
          updated_at: ts]
  )
end
```

(`imported_ids = Enum.map(&elem(&1, 0))` is unchanged — `elem(_, 0)` still works.)

- [ ] **Step 4: Update `notify_available/2`.** In `lib/cinder/download/tv_poller.ex`:

```elixir
imported_ids = MapSet.new(imported, fn {id, _dest, _q} -> id end)
```

- [ ] **Step 5: Run TV tests; fix path/tuple assertions in `tv_poller_test.exs` + `catalog_tv_pipeline_test.exs`.**

Run: `mix test test/cinder/library_test.exs test/cinder/download/tv_poller_test.exs test/cinder/catalog_tv_pipeline_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add lib/cinder/library.ex lib/cinder/catalog.ex lib/cinder/download/tv_poller.ex test/
git commit -m "feat(library): score-gated replace/keep on TV episode re-import; persist quality"
```

---

### Task 7: full suite, lint, format, manual verification

**Files:** none (verification only)

- [ ] **Step 1: Full suite.**

Run: `mix test`
Expected: PASS, 0 failures. Fix any stragglers (most likely un-updated path/tuple assertions).

- [ ] **Step 2: Credo + format.**

Run: `mix credo --strict && mix format --check-formatted`
Expected: no issues. Run `mix format` if needed and re-commit.

- [ ] **Step 3: Compile with warnings as errors (CI parity).**

Run: `mix compile --warnings-as-errors --force`
Expected: clean.

- [ ] **Step 4: Commit any format/lint fixes.**

```bash
git add -A && git commit -m "chore(library): format + credo for re-import replace"
```

- [ ] **Step 5: Manual smoke (optional, on the live CT121 deploy after merge).** Re-add an already-imported movie with a better release → confirm it replaces and lands in a `{tmdb-N}` folder; re-add with a worse release → confirm it keeps and marks available without parking.

---

## Self-Review

**Spec coverage:**
- tmdb naming (movies+TV) → Task 1 ✓
- Plex moduledoc → Task 1 ✓
- schema imported_* + casts + clearing sites → Task 2 ✓
- Filesystem.rename + atomic replace + temp sweep → Task 3 ✓
- Upgrade.better?/4 (nil baseline, language-first, nil-target limitation, nil-resolution last, size tiebreak, nil-pref guard) → Task 4 ✓
- string resolution_rank + satisfies_lang? → Task 4 ✓
- movie place/replace/keep + {:ok,dest,quality} + poller persistence → Task 5 ✓
- TV per-episode + finish_grab 3-tuple + notify_available → Task 6 ✓
- contract ripple + test sweep (poller lstat stub, :dest_exists rewrite) → Tasks 1/5/6 ✓
- full suite/credo/format → Task 7 ✓

**Type consistency:** `quality` map is `%{resolution:, size:, language:}` everywhere; `import_movie/1 → {:ok, dest, quality}`; `import_episodes/2 → {:ok, [{ep_id, dest, quality}], unmatched}`; `finish_grab` consumes the same 3-tuple. `Upgrade.better?(new, old, target, preferred)` and `Scorer.resolution_rank(string|nil, preferred)` consistent across Tasks 4-6.

**Note for the implementer:** `source_quality/2` is reused by movies (`source_quality(movie.file_path, source)`) and TV (`source_quality(source, source)` — the episode file name IS the release name). Keep one helper; the first arg is "the name to parse," the second is "the file to stat."
