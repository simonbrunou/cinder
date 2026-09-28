# Source-Aware Import-Time Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Cinder.Library.Upgrade.better?` rank `language → resolution → source → size` (consistent with the selection scorer), so a same-resolution better-source release the scorer chose actually replaces an imported lesser-source file instead of being discarded on a size tie. Movies and TV.

**Architecture:** Add a persisted `imported_source` column (movies + episodes; the clean library filename strips the source token, so it can't be re-derived). Thread `source` through the import quality maps and the two persist sites, re-expose `Scorer.source_rank/2`, and insert the source axis into the comparator via a shared tuple-rank.

**Tech Stack:** Elixir / Phoenix, Ecto + ecto_sqlite3, ExUnit + Mox. Spec: `docs/specs/2026-06-27-source-aware-upgrade-design.md`.

## Global Constraints

- `mix test` (the alias) must stay green: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Test output pristine.
- `mix` runs via mise; if `mix` is "command not found", run `eval "$(mise env -s bash)"` (or export the mise elixir/erlang install bins) and retry.
- This repo has a hook MANDATING `graphify query "<question>"` before reading/grepping a source file. The plan gives exact code + locations; query first if you must open a file.
- Comparator ordering is fixed: `language → resolution → source → size` (source ABOVE size).
- `preferred_sources` unset ⇒ `[]` ⇒ `source_rank` ties at `0` for all ⇒ comparator behaves byte-for-byte as before (a no-config regression invariant — the existing upgrade tests guard it).
- Movie path and TV path are symmetric; the movie selection/import logic for resolution/size/language is otherwise unchanged.
- Run `graphify update .` after the code is final (AST-only, no API cost).

---

### Task 1: `imported_source` column + schema fields

**Files:**
- Create: `priv/repo/migrations/20260627120000_add_imported_source.exs`
- Modify: `lib/cinder/catalog/movie.ex` (field + `transition_changeset` cast)
- Modify: `lib/cinder/catalog/episode.ex` (field + `transition_changeset` cast)
- Test: `test/cinder/catalog/imported_source_changeset_test.exs` (new)

**Interfaces:**
- Produces: `Movie.imported_source` / `Episode.imported_source` (`String.t() | nil`), both castable via each schema's `transition_changeset/2`.

- [ ] **Step 1: Write the failing changeset test**

Create `test/cinder/catalog/imported_source_changeset_test.exs`:
```elixir
defmodule Cinder.Catalog.ImportedSourceChangesetTest do
  use ExUnit.Case, async: true
  alias Cinder.Catalog.{Episode, Movie}

  test "movie transition_changeset casts imported_source" do
    cs = Movie.transition_changeset(%Movie{}, %{status: :available, imported_source: "bluray"})
    assert cs.changes.imported_source == "bluray"
  end

  test "episode transition_changeset casts imported_source" do
    cs = Episode.transition_changeset(%Episode{}, %{imported_source: "webdl"})
    assert cs.changes.imported_source == "webdl"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder/catalog/imported_source_changeset_test.exs`
Expected: FAIL — `imported_source` is not a schema field / not cast (KeyError on `cs.changes.imported_source` or the field is dropped).

- [ ] **Step 3: Write the migration**

Create `priv/repo/migrations/20260627120000_add_imported_source.exs` (mirrors `20260626120000_add_imported_quality.exs`):
```elixir
defmodule Cinder.Repo.Migrations.AddImportedSource do
  use Ecto.Migration

  def change do
    for tbl <- [:movies, :episodes] do
      alter table(tbl) do
        add :imported_source, :string
      end
    end
  end
end
```

- [ ] **Step 4: Add the field + cast to both schemas**

In `lib/cinder/catalog/movie.ex`, add the field after `:imported_language` (line ~42):
```elixir
    field :imported_language, :string
    field :imported_source, :string
```
and add `:imported_source` to the `transition_changeset` cast list (after `:imported_language`, line ~84):
```elixir
      :imported_resolution,
      :imported_size,
      :imported_language,
      :imported_source
```

In `lib/cinder/catalog/episode.ex`, add the field after `:imported_language` (line ~26):
```elixir
    field :imported_language, :string
    field :imported_source, :string
```
and add `:imported_source` to its `transition_changeset` cast list (after `:imported_language`, line ~56):
```elixir
      :imported_resolution,
      :imported_size,
      :imported_language,
      :imported_source
```

- [ ] **Step 5: Migrate and run the test**

Run: `mix ecto.migrate && mix test test/cinder/catalog/imported_source_changeset_test.exs`
Expected: migration runs; test PASSES.

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260627120000_add_imported_source.exs lib/cinder/catalog/movie.ex lib/cinder/catalog/episode.ex test/cinder/catalog/imported_source_changeset_test.exs priv/repo/structure.sql
git commit -m "feat(catalog): add imported_source column to movies and episodes"
```
(If `mix ecto.migrate` did not touch `priv/repo/structure.sql`, drop it from the `git add`.)

---

### Task 2: Re-expose `Scorer.source_rank/2`

**Files:**
- Modify: `lib/cinder/acquisition/scorer.ex` (`source_rank/2` `defp` → `def`)
- Test: `test/cinder/acquisition/scorer_test.exs`

**Interfaces:**
- Produces: public `Scorer.source_rank(source :: String.t() | nil, preferred :: [String.t()]) :: non_neg_integer()` — index of `source` in `preferred`, or `length(preferred)` for nil/unlisted. (Also the existing `source_rank(%Release{}, preferred)` clause.)

- [ ] **Step 1: Write the failing test**

Append to `test/cinder/acquisition/scorer_test.exs`, inside the top-level module (e.g. after the `describe "select_for/4"` block, before the final `end`):
```elixir
  describe "source_rank/2 (public for Library.Upgrade)" do
    test "index in the preference list; nil/unlisted sorts last" do
      assert Scorer.source_rank("bluray", ["bluray", "webdl"]) == 0
      assert Scorer.source_rank("webdl", ["bluray", "webdl"]) == 1
      assert Scorer.source_rank("hdtv", ["bluray", "webdl"]) == 2
      assert Scorer.source_rank(nil, ["bluray", "webdl"]) == 2
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder/acquisition/scorer_test.exs`
Expected: FAIL — `source_rank/2` is private (`UndefinedFunctionError` / `function source_rank/2 is undefined or private`).

- [ ] **Step 3: Make `source_rank/2` public with a string clause**

In `lib/cinder/acquisition/scorer.ex`, replace the current private definition:
```elixir
  # Source rank mirrors resolution_rank but stays private — only sort_key/greedy_key use it
  # (resolution_rank is public because Library.Upgrade also calls it).
  defp source_rank(%Release{} = release, preferred),
    do: rank_in(release.source, preferred)
```
with the public form (mirrors `resolution_rank/2`):
```elixir
  @doc "Index of a source string in the preference list (lower = better); nil/unlisted sorts last."
  def source_rank(source, preferred) when is_binary(source) or is_nil(source),
    do: rank_in(source, preferred)

  def source_rank(%Release{} = release, preferred),
    do: source_rank(release.source, preferred)
```
(`rank_in/2`, `sort_key`, and `greedy_key` are unchanged — they keep calling the `%Release{}` clause.)

- [ ] **Step 4: Run the scorer tests**

Run: `mix test test/cinder/acquisition/scorer_test.exs`
Expected: PASS (new `source_rank/2` block + all existing scorer tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/scorer.ex test/cinder/acquisition/scorer_test.exs
git commit -m "refactor(scorer): re-expose source_rank/2 (Library.Upgrade caller)"
```

---

### Task 3: Source axis in the `Upgrade` comparator

**Files:**
- Modify: `lib/cinder/library/upgrade.ex`
- Test: `test/cinder/library/upgrade_test.exs`

**Interfaces:**
- Consumes: `Scorer.source_rank/2` (Task 2); `imported_source` quality key (provided live by Tasks 4–5; in tests via the `q/4` helper).
- Produces: `Upgrade.better?(new, old, target, preferred, preferred_sources \\ [])` — quality maps are now `%{resolution:, size:, language:, source:}`; ranks `language → resolution → source → size`. `preferred_sources` defaults to `[]` (no source preference ⇒ source ties, identical to prior behavior).

- [ ] **Step 1: Update the test helper and add the failing source tests**

In `test/cinder/library/upgrade_test.exs`, change the helper to carry source (a default keeps the existing 3-arg calls working):
```elixir
  defp q(res, size, lang, source \\ nil),
    do: %{resolution: res, size: size, language: lang, source: source}
```
Add a preferred-sources module attribute next to `@pref`:
```elixir
  @psrc ["bluray", "webdl"]
```
Append these tests before the module's final `end`:
```elixir
  test "equal resolution: a more-preferred source wins over size" do
    # bluray (size 1) beats webdl (size 9000): source ranks above size.
    assert Upgrade.better?(q("1080p", 1, "en", "bluray"), q("1080p", 9_000, "en", "webdl"), nil, @pref, @psrc)
    refute Upgrade.better?(q("1080p", 9_000, "en", "webdl"), q("1080p", 1, "en", "bluray"), nil, @pref, @psrc)
  end

  test "a resolution change still outranks source" do
    refute Upgrade.better?(q("720p", 1, "en", "bluray"), q("1080p", 9_000, "en", "webdl"), nil, @pref, @psrc)
  end

  test "old nil source ranks last: a known source upgrades at equal resolution" do
    assert Upgrade.better?(q("1080p", 1, "en", "bluray"), q("1080p", 9_000, "en", nil), nil, @pref, @psrc)
  end

  test "empty preferred_sources leaves source out (falls to size — old behavior)" do
    refute Upgrade.better?(q("1080p", 1, "en", "bluray"), q("1080p", 9_000, "en", "webdl"), nil, @pref, [])
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder/library/upgrade_test.exs`
Expected: FAIL — `better?/5` is undefined (currently `better?/4`), so the new tests raise `UndefinedFunctionError`. (The existing 4-arg tests still compile/pass.)

- [ ] **Step 3: Add the source axis to the comparator**

Replace the body of `lib/cinder/library/upgrade.ex` from the `@moduledoc` through `quality_better?/3`. New full module:
```elixir
defmodule Cinder.Library.Upgrade do
  @moduledoc """
  Pure decision: is `new` a quality/language upgrade over `old`, per cinder's selection model
  (language-first, then resolution, then source, then size)? `new`/`old` are
  `%{resolution: String.t()|nil, size: integer|nil, language: String.t()|nil, source: String.t()|nil}`
  describing a release/library file. Name-parsed; resolution/source are often nil (rank last); size
  is a weak proxy. `preferred_sources` defaults to `[]` (no source preference ⇒ source ties).
  """
  alias Cinder.Acquisition.{Language, Scorer}

  @default_preferred ["1080p", "720p"]

  @spec better?(map(), map(), String.t() | nil, [String.t()] | nil, [String.t()] | nil) :: boolean()
  def better?(new, old, target, preferred, preferred_sources \\ []) do
    lang_verdict = language_decides?(new, old, target)

    cond do
      nil_baseline?(old) -> true
      lang_verdict != :tie -> lang_verdict == :upgrade
      true -> quality_better?(new, old, preferred || @default_preferred, preferred_sources || [])
    end
  end

  defp nil_baseline?(%{resolution: nil, size: nil, language: nil}), do: true
  defp nil_baseline?(_), do: false

  defp language_decides?(new, old, target) do
    cond do
      is_nil(target) ->
        :tie

      not Language.satisfies_lang?(old.language, target) and
          Language.satisfies_lang?(new.language, target) ->
        :upgrade

      Language.satisfies_lang?(old.language, target) and
          not Language.satisfies_lang?(new.language, target) ->
        :downgrade

      true ->
        :tie
    end
  end

  # Lexicographic over {resolution rank, source rank, -size}: lower is better — better resolution,
  # then more-preferred source, then larger size. Mirrors Scorer.sort_key. With preferred_sources []
  # the source rank ties at 0 for all, so this reduces to the prior resolution-then-size decision.
  defp quality_better?(new, old, preferred, sources) do
    rank(new, preferred, sources) < rank(old, preferred, sources)
  end

  defp rank(q, preferred, sources) do
    {Scorer.resolution_rank(q.resolution, preferred), Scorer.source_rank(q.source, sources),
     -(q.size || 0)}
  end
end
```

- [ ] **Step 4: Run the upgrade tests**

Run: `mix test test/cinder/library/upgrade_test.exs`
Expected: PASS — the four new source tests and all pre-existing tests (the existing 4-arg calls hit the defaulted `preferred_sources []`, so their behavior is unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/library/upgrade.ex test/cinder/library/upgrade_test.exs
git commit -m "feat(library): rank source between resolution and size in Upgrade"
```

---

### Task 4: Wire the movie pipeline (capture + persist + comparator call)

**Files:**
- Modify: `lib/cinder/library.ex` (movie `new_q`, `existing_quality`, `upgrade?`, new `preferred_sources/1` helper)
- Modify: `lib/cinder/download/poller.ex` (persist `imported_source`)
- Test: `test/cinder/library_test.exs` (movie fresh-capture, async)
- Test: `test/cinder/library_source_upgrade_test.exs` (new, `async: false` — movie source-decides collision)

**Interfaces:**
- Consumes: `Upgrade.better?/5` (Task 3); `Movie.imported_source` (Task 1).
- Produces: `import_movie/1`'s returned quality map carries `source`; the poller persists `imported_source: q.source`. New private `preferred_sources(kind)` reads `Application.get_env(:cinder, :"#{kind}_preferred_sources")`.

- [ ] **Step 1: Write the failing movie capture test (async)**

In `test/cinder/library_test.exs`, add this test (no collision — `ln` succeeds — so no env needed; proves `new_q` captures `source` and it flows to the return). Place it near the existing movie import tests:
```elixir
  test "import captures the parsed source into the returned quality" do
    movie = %Movie{
      title: "Inception",
      year: 2010,
      tmdb_id: 27_205,
      file_path: "/dl/Inception.2010.1080p.BluRay.x264-GRP.mkv"
    }

    dest = "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Inception.2010.1080p.BluRay.x264-GRP.mkv" ->
      {:ok, %File.Stat{size: 8 * @gb, inode: 7}}
    end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    assert {:ok, ^dest, %{resolution: "1080p", source: "bluray", language: nil}} =
             Library.import_movie(movie)
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder/library_test.exs`
Expected: FAIL — the returned quality map has no `:source` key, so the `%{... source: "bluray" ...}` pattern doesn't match (`MatchError`).

- [ ] **Step 3: Capture source in the movie quality maps**

In `lib/cinder/library.ex`:

`import_movie/1` `new_q` (line ~60) — add `source: parsed.source`:
```elixir
         new_q = %{
           resolution: parsed.resolution,
           source: parsed.source,
           size: size,
           language: parsed.language
         },
```

`existing_quality/2` (line ~93) — add `source:` to the else map:
```elixir
  defp existing_quality(movie, new_q) do
    if nil_q?(movie),
      do: new_q,
      else: %{
        resolution: movie.imported_resolution,
        size: movie.imported_size,
        language: movie.imported_language,
        source: movie.imported_source
      }
  end
```
(Leave `nil_q?/1` unchanged — a row with only `source` set never occurs.)

`upgrade?/2` (line ~106) — add `source:` to `old_q` and pass `preferred_sources(:movies)`:
```elixir
  defp upgrade?(movie, new_q) do
    old_q = %{
      resolution: movie.imported_resolution,
      size: movie.imported_size,
      language: movie.imported_language,
      source: movie.imported_source
    }

    target = Language.target(movie.preferred_language, movie.original_language)
    Upgrade.better?(new_q, old_q, target, preferred_resolutions(:movies), preferred_sources(:movies))
  end
```

Add the `preferred_sources/1` helper next to `preferred_resolutions/1` (line ~127):
```elixir
  defp preferred_sources(kind),
    do: Application.get_env(:cinder, :"#{kind}_preferred_sources")
```

- [ ] **Step 4: Run the capture test**

Run: `mix test test/cinder/library_test.exs`
Expected: PASS (the new capture test + all existing library tests — existing collision assertions are subset-pattern matches, so the extra `source` key doesn't break them).

- [ ] **Step 5: Persist `imported_source` in the movie poller**

In `lib/cinder/download/poller.ex`, the `Catalog.transition` map after `import_movie` (line ~185) — add `imported_source: q.source`:
```elixir
               Catalog.transition(movie, %{
                 status: :available,
                 file_path: dest,
                 imported_resolution: q.resolution,
                 imported_size: q.size,
                 imported_language: q.language,
                 imported_source: q.source
               }) do
```

- [ ] **Step 6: Write the failing movie source-decides collision test (async: false)**

Create `test/cinder/library_source_upgrade_test.exs`:
```elixir
defmodule Cinder.LibrarySourceUpgradeTest do
  # async: false — sets :cinder source-preference env to exercise the source axis end to end.
  use ExUnit.Case, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Catalog.Movie
  alias Cinder.Library

  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"
  @gb 1_000_000_000

  setup do
    prev = Application.get_env(:cinder, :movies_preferred_sources)
    Application.put_env(:cinder, :movies_preferred_sources, ["bluray", "webdl"])

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:cinder, :movies_preferred_sources)
        v -> Application.put_env(:cinder, :movies_preferred_sources, v)
      end
    end)

    :ok
  end

  test "same-resolution better source replaces the existing file and the quality carries source" do
    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imported_resolution: "1080p",
      imported_size: 9 * @gb,
      imported_language: nil,
      imported_source: "webdl",
      file_path: "/dl/Heat.1995.1080p.BluRay.x264.mkv"
    }

    dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.1995.1080p.BluRay.x264.mkv" ->
      {:ok, %File.Stat{size: 2 * @gb, inode: 7}}
    end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> {:error, :eexist} end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
    # replace path: sweep_temps, ln to tmp, rename
    expect(Cinder.Library.FilesystemMock, :find_files, fn _dir -> {:ok, []} end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, tmp ->
      assert String.contains?(tmp, ".cinder-tmp-")
      :ok
    end)
    expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    assert {:ok, ^dest, %{resolution: "1080p", source: "bluray"}} = Library.import_movie(movie)
  end

  test "same-resolution worse source keeps the existing file" do
    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imported_resolution: "1080p",
      imported_size: 1 * @gb,
      imported_language: nil,
      imported_source: "bluray",
      file_path: "/dl/Heat.1995.1080p.WEB-DL.x264.mkv"
    }

    dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.1995.1080p.WEB-DL.x264.mkv" ->
      {:ok, %File.Stat{size: 9 * @gb, inode: 7}}
    end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> {:error, :eexist} end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    log =
      capture_log(fn ->
        assert {:ok, ^dest, %{resolution: "1080p", source: "bluray"}} = Library.import_movie(movie)
      end)

    assert log =~ "kept existing"
  end
end
```

- [ ] **Step 7: Run the new collision test + full suite**

Run: `mix test test/cinder/library_source_upgrade_test.exs && mix test`
Expected: both PASS. The replace test proves bluray (size 2 GB) replaces the imported webdl (size 9 GB) — source outranking size — and persists; the keep test proves a webdl new file (size 9 GB) does NOT replace the imported bluray (size 1 GB). If `format --check-formatted` flags anything, run `mix format` and re-run.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder/library.ex lib/cinder/download/poller.ex test/cinder/library_test.exs test/cinder/library_source_upgrade_test.exs
git commit -m "feat(library): source-aware movie import upgrade + persist imported_source"
```

---

### Task 5: Wire the TV pipeline (capture + persist + comparator call + resets)

**Files:**
- Modify: `lib/cinder/library.ex` (episode `new_q`, `ep_upgrade?`)
- Modify: `lib/cinder/catalog.ex` (`finish_grab` persist; the episode/season delete reset sites)
- Test: `test/cinder/library_source_upgrade_test.exs` (TV collision, append)
- Test: `test/cinder/catalog_tv_pipeline_test.exs` (assert `imported_source` persisted by `finish_grab`)
- Test: `test/cinder/catalog_admin_test.exs` (assert `imported_source` cleared on delete)

**Interfaces:**
- Consumes: `Upgrade.better?/5` (Task 3); `Episode.imported_source` (Task 1); `preferred_sources/1` (Task 4).
- Produces: `import_episodes/2`'s per-episode quality carries `source`; `finish_grab` persists `imported_source`; the episode/season file-delete paths null `imported_source`.

- [ ] **Step 1: Write the failing TV finish_grab persistence assertion**

In `test/cinder/catalog_tv_pipeline_test.exs`, find the test that asserts `r.imported_resolution == "1080p"` (line ~172) and add a source assertion. The quality tuple the test passes to `finish_grab` must include `source`; update that quality map in the test setup to include `source: "bluray"` (find the `%{resolution: "1080p", size: 123, language: "FRENCH"}` literal in this test and add `source: "bluray"`), then assert:
```elixir
      assert r.imported_resolution == "1080p"
      assert r.imported_size == 123
      assert r.imported_language == "FRENCH"
      assert r.imported_source == "bluray"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: FAIL — `r.imported_source` is `nil` (finish_grab doesn't persist it yet).

- [ ] **Step 3: Persist `imported_source` in `finish_grab` and capture it in the episode quality map**

In `lib/cinder/catalog.ex` `finish_grab/2` (line ~1013), add `imported_source: q.source` to the per-episode `set`:
```elixir
        for {episode_id, dest, q} <- imported do
          Repo.update_all(from(e in Episode, where: e.id == ^episode_id),
            set: [
              file_path: dest,
              grab_id: nil,
              imported_resolution: q.resolution,
              imported_size: q.size,
              imported_language: q.language,
              imported_source: q.source,
              updated_at: ts
            ]
          )
        end
```

In `lib/cinder/library.ex` `link_all/3` `new_q` (line ~366) — add `source: parsed.source`:
```elixir
           new_q = %{
             resolution: parsed.resolution,
             source: parsed.source,
             size: size,
             language: parsed.language
           },
```

`ep_upgrade?/3` (line ~391) — add `source:` to `old_q` and pass `preferred_sources(:tv)`:
```elixir
  defp ep_upgrade?(ep, new_q, target) do
    old_q = %{
      resolution: ep.imported_resolution,
      size: ep.imported_size,
      language: ep.imported_language,
      source: ep.imported_source
    }

    Upgrade.better?(new_q, old_q, target, preferred_resolutions(:tv), preferred_sources(:tv))
  end
```

- [ ] **Step 4: Run the TV pipeline test**

Run: `mix test test/cinder/catalog_tv_pipeline_test.exs`
Expected: PASS.

- [ ] **Step 5: Null `imported_source` in the file-delete reset paths + assert it**

In `lib/cinder/catalog.ex`:

`do_delete_episode_file_txn/3` (line ~687) — add `imported_source: nil`:
```elixir
        |> Episode.transition_changeset(%{
          file_path: nil,
          imported_resolution: nil,
          imported_size: nil,
          imported_language: nil,
          imported_source: nil
        })
```

`do_delete_season_files_txn/4` (line ~753) — add `imported_source: nil` to the `sets`:
```elixir
        [
          file_path: nil,
          imported_resolution: nil,
          imported_size: nil,
          imported_language: nil,
          imported_source: nil,
          updated_at: now()
        ] ++ if(unmonitor?, do: [monitored: false], else: [])
```

In `test/cinder/catalog_admin_test.exs`, the test "clears imported_resolution, imported_size, imported_language on delete" (line ~625): add `imported_source: "bluray"` to the episode setup attrs (next to `imported_language: "en"`), and add an assertion after the existing `is_nil` checks:
```elixir
      assert is_nil(reloaded.imported_resolution)
      assert is_nil(reloaded.imported_size)
      assert is_nil(reloaded.imported_language)
      assert is_nil(reloaded.imported_source)
```

- [ ] **Step 6: Append the TV source-decides collision test**

In `test/cinder/library_source_upgrade_test.exs`, add `Episode`/`Season`/`Series` to the alias and set the TV env in `setup` alongside the movie one:
```elixir
  alias Cinder.Catalog.{Episode, Movie, Season, Series}
```
In the `setup` block, also set `:tv_preferred_sources` (snapshot + restore the same way as movies):
```elixir
    prev_tv = Application.get_env(:cinder, :tv_preferred_sources)
    Application.put_env(:cinder, :tv_preferred_sources, ["bluray", "webdl"])
    # ...and in on_exit, restore prev_tv (nil -> delete_env, else put_env) exactly like movies.
```
Append the TV test (`@tv_lib` is the configured TV root `/tmp/cinder-test-tv-library`). The mock sequence below is copied from the passing `test/cinder/library_test.exs` "TV re-import replaces an episode's file on a resolution upgrade" (~line 502) — `import_episodes("/dl/grab", …)` calls `dir?("/dl/grab")` → `find_files("/dl/grab")` → per-file `lstat` → collision → replace → `scan`; `media_info` is nil in test so no audio mock. The only changes vs that template: both files are 1080p, the existing is `imported_source: "webdl"` (9 GB), the new file is BluRay (2 GB), so **source** drives the replace despite the smaller size:
```elixir
  @tv_lib "/tmp/cinder-test-tv-library"

  test "same-resolution better source replaces an episode's file" do
    series = struct(%Series{title: "Show", year: 2008, tmdb_id: 1}, [])

    ep = %Episode{
      id: 5,
      episode_number: 1,
      imported_resolution: "1080p",
      imported_size: 9 * @gb,
      imported_language: nil,
      imported_source: "webdl",
      season: %Season{season_number: 1, series: series}
    }

    source = "/dl/grab/Show.S01E01.1080p.BluRay.x264.mkv"
    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/grab" -> true end)
    expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/grab" -> {:ok, [{source, 2 * @gb}]} end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn ^source -> {:ok, %File.Stat{size: 2 * @gb, inode: 7}} end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn ^source, ^dest -> {:error, :eexist} end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
    # sweep_temps
    expect(Cinder.Library.FilesystemMock, :find_files, fn _dir -> {:ok, []} end)
    expect(Cinder.Library.FilesystemMock, :ln, fn ^source, tmp ->
      assert String.contains?(tmp, ".cinder-tmp-")
      :ok
    end)
    expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    assert {:ok, [{5, ^dest, %{resolution: "1080p", source: "bluray"}}], []} =
             Library.import_episodes("/dl/grab", [ep])
  end
```

- [ ] **Step 7: Run the TV collision test + full suite**

Run: `mix test test/cinder/library_source_upgrade_test.exs && mix test`
Expected: PASS. Run `mix format` if the formatter flags anything, then re-run `mix test`.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder/library.ex lib/cinder/catalog.ex test/cinder/library_source_upgrade_test.exs test/cinder/catalog_tv_pipeline_test.exs test/cinder/catalog_admin_test.exs
git commit -m "feat(library): source-aware episode import upgrade + persist/reset imported_source"
```

---

### Task 6: Docs + graph refresh

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `graphify-out/` (regenerated)

**Interfaces:** none (docs only).

- [ ] **Step 1: CHANGELOG**

Under `## [Unreleased]` `### Changed` (create the subsection if absent; this is a behavior change, not a new user-facing setting — `preferred_sources` already shipped):
```markdown
### Changed
- The import-time upgrade decision now honors the per-kind **preferred sources** setting
  (`language → resolution → source → size`), consistent with release selection, so a
  same-resolution better-source release replaces an imported lesser-source file. Persists a new
  `imported_source` per movie/episode (additive migration; existing rows rank a missing source
  last).
```

- [ ] **Step 2: Verify the working tree is still green**

Run: `mix test`
Expected: PASS (docs don't affect the suite; confirms nothing else broke).

- [ ] **Step 3: Refresh the knowledge graph**

Run: `graphify update .`
Expected: completes (AST-only, no API cost).

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md graphify-out
git commit -m "docs(library): note source-aware import upgrade"
```

---

## Notes for the implementer

- The two persist sites mirror the existing `imported_resolution`/`imported_size`/`imported_language` handling exactly — add one key each, nothing more.
- There is intentionally **no movie-side `imported_*` reset** (none exists today); only the episode/season file-delete paths reset, and Task 5 extends them. Do not invent a movie reset.
- `nil_q?/1` and `nil_baseline?/1` are deliberately left keyed off resolution/size/language — do not add `source` to them (a row with only `source` set never occurs, and adding it would change the all-nil baseline semantics).
- Quality maps everywhere are now `%{resolution:, source:, size:, language:}`. Existing collision-test assertions are subset-pattern matches (`%{resolution: ...} = actual`), so the extra `source` key does not break them — do not "fix" them.
- The no-config invariant (`preferred_sources` unset ⇒ behavior unchanged) is guarded by the existing upgrade tests (which pass `[]` via the default) and the "empty preferred_sources" test in Task 3 — keep them green.
