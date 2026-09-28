# Per-item Preferred Language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user choose a preferred audio language (Original / French / Any) per movie and per series; the acquisition pipeline strictly grabs a release that satisfies it, or parks the item visibly instead of silently grabbing the wrong language.

**Architecture:** A pure `Cinder.Acquisition.Language` predicate filters parsed releases *before* the existing scorer (no scorer ranking change). The preference + the title's TMDB `original_language` are stored on the `movies` / `series` rows (carried through the request→approval gate for movies), read fresh by the pollers, and threaded as opts into `Acquisition.best_release/best_releases`. A release satisfies a target language when it is `MULTI`, exact-tagged, or untagged-and-the-target-is-the-title's-original. The parser is widened to tag French dubs. Changing an item's language re-searches it.

**Tech Stack:** Elixir / Phoenix 1.8 LiveView, Ecto + `ecto_sqlite3`, ExUnit + Mox, daisyUI, gettext (en/fr).

## Global Constraints

- `mix test` (the alias) is the gate: it runs `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Every task ends green.
- External services are reached only through behaviours resolved from config; tests use Mox and never hit the network.
- **Every movie status change goes through `Catalog.transition/2`.** `preferred_language` is **not** pipeline state — it has its own `language_changeset/2` and never goes through `transition_changeset/2`.
- **Filter-only:** do **not** modify `Cinder.Acquisition.Scorer` ranking (`select/2`, `select_for/4`, `sort_key`, `greedy_key`). Language is filtered in `Cinder.Acquisition`, before the scorer.
- All user-facing strings go through `gettext/1` (en/fr). New strings are extracted with `mix gettext.extract --merge` at the end.
- Match model (verbatim): a release satisfies target `T` for a title with original language `O` when `release.language == "MULTI"`, **or** `release.language == tag(T)` (where `tag("fr")="FRENCH"`, `"de"→"GERMAN"`, `"es"→"SPANISH"`, `"it"→"ITALIAN"`, `"en"`/other → `nil`), **or** `release.language == nil and T == O`. Pick resolves to `T`: `"any"`→none(off), `"original"`→`O` (off when `O` blank/nil), `"french"`→`"fr"`.
- After code changes land, run `graphify update .` (AST-only) to keep the graph current.
- Spec: `docs/specs/2026-06-25-per-item-language-preference-design.md`.

---

## Task 1: Parser — tag French dub markers

**Files:**
- Modify: `lib/cinder/acquisition/parser.ex:32-38` (`@languages`)
- Test: `test/cinder/acquisition/parser_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Parser.parse/1` now returns `language: "FRENCH"` for `TRUEFRENCH`/`VFF`/`VFQ`/`VFI`/`VF`; `VOSTFR`/`SUBFRENCH` stay `nil`.

- [ ] **Step 1: Write the failing tests**

In `test/cinder/acquisition/parser_test.exs`, add (mirror the existing `assert Parser.parse(...) == %{...}` style):

```elixir
describe "language: French dub markers (M-language)" do
  test "TRUEFRENCH tags FRENCH" do
    assert Parser.parse("Movie.2021.TRUEFRENCH.1080p.BluRay.x264-GRP").language == "FRENCH"
  end

  test "VFF / VFQ / VFI / VF tag FRENCH" do
    for marker <- ~w(VFF VFQ VFI VF) do
      assert Parser.parse("Movie.2021.#{marker}.1080p.WEB-DL.x264-GRP").language == "FRENCH",
             "expected #{marker} to tag FRENCH"
    end
  end

  test "MULTI still wins over a French dub marker" do
    assert Parser.parse("Movie.2021.MULTI.VFF.1080p.BluRay.x264-GRP").language == "MULTI"
  end

  test "VOSTFR and SUBFRENCH stay nil (subtitles = original audio, not a French audio tag)" do
    assert Parser.parse("Movie.2021.VOSTFR.1080p.BluRay.x264-GRP").language == nil
    assert Parser.parse("Movie.2021.SUBFRENCH.1080p.BluRay.x264-GRP").language == nil
  end
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/acquisition/parser_test.exs`
Expected: FAIL — the new French markers currently parse to `nil`.

- [ ] **Step 3: Add the marker entry**

In `lib/cinder/acquisition/parser.ex`, change `@languages` (keep `MULTI` first so it still wins; add the dub-marker row after the `FRENCH` row):

```elixir
@languages [
  {~r/\bmulti\b/i, "MULTI"},
  {~r/\bfrench\b/i, "FRENCH"},
  {~r/\b(?:truefrench|vff|vfq|vfi|vf)\b/i, "FRENCH"},
  {~r/\bgerman\b/i, "GERMAN"},
  {~r/\bspanish\b/i, "SPANISH"},
  {~r/\bitalian\b/i, "ITALIAN"}
]
```

(`\bfrench\b` cannot match inside `TRUEFRENCH`/`SUBFRENCH` — no word boundary before `french` — so those need the explicit entry / stay `nil` respectively. `\bvf\b` does not match inside `VOSTFR` either.)

- [ ] **Step 4: Run the tests, verify they pass**

Run: `mix test test/cinder/acquisition/parser_test.exs`
Expected: PASS (all, including pre-existing language tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/parser.ex test/cinder/acquisition/parser_test.exs
git commit -m "feat(parser): tag French dub markers (TRUEFRENCH/VFF/VFQ/VFI/VF)"
```

---

## Task 2: `Cinder.Acquisition.Language` predicate module

**Files:**
- Create: `lib/cinder/acquisition/language.ex`
- Test: `test/cinder/acquisition/language_test.exs`

**Interfaces:**
- Consumes: `Cinder.Acquisition.Release` (has `:language`).
- Produces:
  - `Language.filter(releases, preferred, original) :: [Release.t()]` — keeps satisfying releases; returns all unchanged when inactive.
  - `Language.active?(preferred, original) :: boolean`
  - `Language.target(preferred, original) :: String.t() | nil`
  - `Language.satisfies?(%Release{}, target, original) :: boolean`

- [ ] **Step 1: Write the failing test**

Create `test/cinder/acquisition/language_test.exs`:

```elixir
defmodule Cinder.Acquisition.LanguageTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{Language, Release}

  defp rel(language), do: struct(%Release{title: "fixture"}, language: language)

  describe "satisfies?/3" do
    test "MULTI satisfies any target" do
      assert Language.satisfies?(rel("MULTI"), "fr", "en")
      assert Language.satisfies?(rel("MULTI"), "en", "fr")
    end

    test "french target: exact tag and MULTI satisfy; other tags do not" do
      assert Language.satisfies?(rel("FRENCH"), "fr", "en")
      refute Language.satisfies?(rel("GERMAN"), "fr", "en")
    end

    test "french target on an English-original title: untagged is rejected" do
      refute Language.satisfies?(rel(nil), "fr", "en")
    end

    test "french target on a French-original title: untagged is accepted (untagged = original audio)" do
      assert Language.satisfies?(rel(nil), "fr", "fr")
    end

    test "english/original target: untagged accepted, a foreign tag rejected" do
      assert Language.satisfies?(rel(nil), "en", "en")
      refute Language.satisfies?(rel("FRENCH"), "en", "en")
    end
  end

  describe "target/2 and active?/2" do
    test "any disables the filter" do
      assert Language.target("any", "en") == nil
      refute Language.active?("any", "en")
    end

    test "original resolves to the title's original language, off when unknown" do
      assert Language.target("original", "fr") == "fr"
      assert Language.target("original", nil) == nil
      assert Language.target("original", "") == nil
    end

    test "french always resolves to fr" do
      assert Language.target("french", "en") == "fr"
      assert Language.active?("french", nil)
    end
  end

  describe "filter/3" do
    test "inactive filter returns releases unchanged" do
      releases = [rel("FRENCH"), rel(nil), rel("GERMAN")]
      assert Language.filter(releases, "any", "en") == releases
      assert Language.filter(releases, "original", nil) == releases
    end

    test "french filter keeps FRENCH + MULTI, drops the rest" do
      keep_fr = rel("FRENCH")
      keep_multi = rel("MULTI")
      releases = [keep_fr, rel(nil), rel("GERMAN"), keep_multi]
      assert Language.filter(releases, "french", "en") == [keep_fr, keep_multi]
    end
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder/acquisition/language_test.exs`
Expected: FAIL with "module Cinder.Acquisition.Language is not available".

- [ ] **Step 3: Create the module**

Create `lib/cinder/acquisition/language.ex`:

```elixir
defmodule Cinder.Acquisition.Language do
  @moduledoc """
  Per-item preferred-language filtering for release selection.

  A user picks `"original"` / `"french"` / `"any"` per movie/series. This resolves
  the pick to a concrete target language code — using the title's TMDB
  `original_language` for `"original"` — then keeps only releases whose parsed
  `language` satisfies it: a `MULTI` release, an exact-tag match, or, for the
  title's original language, an untagged (`nil`) release (untagged = original
  audio). `"any"` / an unknown original disables the filter. Filter-only: the
  scorer's ranking is untouched.
  """
  alias Cinder.Acquisition.Release

  @tags %{"fr" => "FRENCH", "de" => "GERMAN", "es" => "SPANISH", "it" => "ITALIAN"}

  @doc """
  Keeps only releases satisfying the resolved target. Returns the list unchanged
  when the filter is inactive (`"any"`, or `"original"` with a blank/nil original).
  """
  def filter(releases, preferred, original) do
    case target(preferred, original) do
      nil -> releases
      t -> Enum.filter(releases, &satisfies?(&1, t, original))
    end
  end

  @doc "Whether a language filter is active for this preference + original language."
  def active?(preferred, original), do: not is_nil(target(preferred, original))

  @doc "Resolves a preference + the title's original language to a target code, or nil (filter off)."
  def target("french", _original), do: "fr"
  def target("original", original), do: presence(original)
  def target(_other, _original), do: nil

  @doc "Whether a single release satisfies the target language for a title with original language `original`."
  def satisfies?(%Release{language: "MULTI"}, _target, _original), do: true
  def satisfies?(%Release{language: nil}, target, original), do: target == presence(original)
  def satisfies?(%Release{language: language}, target, _original), do: language == tag(target)

  defp tag(code), do: Map.get(@tags, code)

  defp presence(code) when code in [nil, ""], do: nil
  defp presence(code), do: code
end
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder/acquisition/language_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/language.ex test/cinder/acquisition/language_test.exs
git commit -m "feat(acquisition): Language predicate (strict per-item language match model)"
```

---

## Task 3: Thread `original_language` through the TMDB layer

**Files:**
- Modify: `lib/cinder/catalog/tmdb/http.ex` (`normalize/1`, `normalize_tv/1`, `normalize_series/1`)
- Modify: `lib/cinder/catalog/tmdb.ex` (behaviour `@doc` map shapes)
- Test: `test/cinder/catalog/tmdb/http_test.exs` (follow the existing Req.Test stub pattern in that file)

**Interfaces:**
- Consumes: nothing.
- Produces: `search/1`, `search_tv/1`, `get_movie/1`, `get_series/1` normalized maps now include `:original_language` (TMDB ISO-639-1 code string or `nil`). The Mox mock (`Cinder.Catalog.TMDBMock`) is unchanged — callbacks still return `map()`; tests that need the field just include it in their stub returns.

- [ ] **Step 1: Write the failing test**

Open `test/cinder/catalog/tmdb/http_test.exs`. In the `get_movie/1` success test, add `"original_language" => "fr"` to the stubbed JSON body and assert it is normalized. Mirror the existing stub structure in that file; the new assertion:

```elixir
assert {:ok, %{original_language: "fr"}} = Cinder.Catalog.TMDB.HTTP.get_movie(603)
```

Add the same `"original_language"` key + `assert {:ok, %{original_language: "fr"}}` to the `get_series/1` success test (key `"original_language"` on the series body).

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder/catalog/tmdb/http_test.exs`
Expected: FAIL — `:original_language` not present in the normalized map.

- [ ] **Step 3: Add extraction to the three normalizers**

In `lib/cinder/catalog/tmdb/http.ex`:

```elixir
defp normalize(movie) do
  %{
    tmdb_id: movie["id"],
    title: movie["title"],
    year: year_from(movie["release_date"]),
    poster_path: movie["poster_path"],
    imdb_id: movie["imdb_id"],
    original_language: movie["original_language"]
  }
end
```

```elixir
defp normalize_tv(series) do
  %{
    tmdb_id: series["id"],
    title: series["name"],
    year: year_from(series["first_air_date"]),
    poster_path: series["poster_path"],
    original_language: series["original_language"]
  }
end
```

```elixir
defp normalize_series(body) do
  external = body["external_ids"] || %{}

  %{
    tmdb_id: body["id"],
    tvdb_id: external["tvdb_id"],
    title: body["name"],
    year: year_from(body["first_air_date"]),
    poster_path: body["poster_path"],
    original_language: body["original_language"],
    seasons: for(s <- body["seasons"] || [], do: %{season_number: s["season_number"]})
  }
end
```

Update the `@callback` `@doc` map shapes in `lib/cinder/catalog/tmdb.ex` to mention `original_language` (documentation only, e.g. add `original_language` to the `get_series` returned-map doc and a note on `search`/`get_movie`).

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder/catalog/tmdb/http_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog/tmdb/http.ex lib/cinder/catalog/tmdb.ex test/cinder/catalog/tmdb/http_test.exs
git commit -m "feat(tmdb): extract original_language for movies and series"
```

---

## Task 4: Migration + schema fields (movies, series, requests)

**Files:**
- Create: `priv/repo/migrations/20260625120000_add_preferred_language.exs`
- Modify: `lib/cinder/catalog/movie.ex` (schema, `changeset/2`, new `language_changeset/2`)
- Modify: `lib/cinder/catalog/series.ex` (schema, `create_changeset/1`, new `language_changeset/2`)
- Modify: `lib/cinder/requests/request.ex` (schema, `create_changeset/2`)
- Test: `test/cinder/catalog/movie_test.exs`, `test/cinder/catalog/series_test.exs`, `test/cinder/requests/request_test.exs` (create if absent; follow existing changeset-test style)

**Interfaces:**
- Produces: `movies` and `series` carry `original_language :: String.t() | nil` and `preferred_language :: String.t()` (default `"original"`); `requests` carry both (nullable). `Movie.language_changeset/2` and `Series.language_changeset/2` cast `:preferred_language` only.

- [ ] **Step 1: Write the failing tests**

`test/cinder/catalog/movie_test.exs` — add:

```elixir
test "changeset/2 casts original_language and preferred_language" do
  cs = Movie.changeset(%Movie{}, %{tmdb_id: 1, title: "X", original_language: "fr", preferred_language: "french"})
  assert cs.valid?
  assert get_change(cs, :original_language) == "fr"
  assert get_change(cs, :preferred_language) == "french"
end

test "language_changeset/2 casts only preferred_language" do
  cs = Movie.language_changeset(%Movie{}, %{preferred_language: "any", status: :available})
  assert get_change(cs, :preferred_language) == "any"
  assert get_change(cs, :status) == nil
end
```

(Use `import Ecto.Changeset` in the test if not already imported.)

`test/cinder/catalog/series_test.exs` — add:

```elixir
test "create_changeset/1 casts language fields; language_changeset/2 casts only preferred_language" do
  cs = Series.create_changeset(%{tmdb_id: 9, title: "S", original_language: "fr", preferred_language: "original"})
  assert get_change(cs, :original_language) == "fr"
  assert get_change(cs, :preferred_language) == "original"

  edit = Series.language_changeset(%Cinder.Catalog.Series{}, %{preferred_language: "french", monitored: false})
  assert get_change(edit, :preferred_language) == "french"
  assert get_change(edit, :monitored) == nil
end
```

`test/cinder/requests/request_test.exs` — add:

```elixir
test "create_changeset/2 casts preferred_language and original_language" do
  cs =
    Cinder.Requests.Request.create_changeset(%Cinder.Requests.Request{}, %{
      user_id: 1, target_type: "movie", target_id: 5, status: :pending,
      preferred_language: "french", original_language: "en"
    })

  assert get_change(cs, :preferred_language) == "french"
  assert get_change(cs, :original_language) == "en"
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/catalog/movie_test.exs test/cinder/catalog/series_test.exs test/cinder/requests/request_test.exs`
Expected: FAIL — fields/functions not defined.

- [ ] **Step 3: Write the migration**

Create `priv/repo/migrations/20260625120000_add_preferred_language.exs`:

```elixir
defmodule Cinder.Repo.Migrations.AddPreferredLanguage do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :original_language, :string
      add :preferred_language, :string, default: "original", null: false
    end

    alter table(:series) do
      add :original_language, :string
      add :preferred_language, :string, default: "original", null: false
    end

    alter table(:requests) do
      add :original_language, :string
      add :preferred_language, :string
    end
  end
end
```

- [ ] **Step 4: Add the schema fields + changesets**

`lib/cinder/catalog/movie.ex` — add to the schema (after `:search_attempts`):

```elixir
field :original_language, :string
field :preferred_language, :string, default: "original"
```

Extend `changeset/2`'s cast list and add `language_changeset/2`:

```elixir
def changeset(movie, attrs) do
  movie
  |> cast(attrs, [:tmdb_id, :imdb_id, :title, :year, :poster_path, :original_language, :preferred_language])
  |> validate_required([:tmdb_id, :title])
  |> unique_constraint(:tmdb_id)
end

@doc "Changeset for the in-app language edit (escape hatch). Not pipeline state — separate from transition_changeset/2."
def language_changeset(movie, attrs), do: cast(movie, attrs, [:preferred_language])
```

`lib/cinder/catalog/series.ex` — add to the schema (after `:monitor_strategy`):

```elixir
field :original_language, :string
field :preferred_language, :string, default: "original"
```

Extend `create_changeset/1`'s cast list (add `:original_language, :preferred_language`) and add `language_changeset/2`:

```elixir
@doc "Changeset for the in-app series language edit. Excluded from refresh/admin changesets so it survives a TMDB resync."
def language_changeset(series, attrs), do: cast(series, attrs, [:preferred_language])
```

(`refresh_changeset/2` and `admin_changeset/2` already cast only their explicit fields, so `preferred_language`/`original_language` are preserved across refresh/admin edits — leave them unchanged.)

`lib/cinder/requests/request.ex` — add to the schema:

```elixir
field :original_language, :string
field :preferred_language, :string
```

Add `:original_language, :preferred_language` to `create_changeset/2`'s cast list (do not add to `validate_required`).

- [ ] **Step 5: Run the tests, verify they pass**

Run: `mix test test/cinder/catalog/movie_test.exs test/cinder/catalog/series_test.exs test/cinder/requests/request_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260625120000_add_preferred_language.exs lib/cinder/catalog/movie.ex lib/cinder/catalog/series.ex lib/cinder/requests/request.ex test/cinder/catalog/movie_test.exs test/cinder/catalog/series_test.exs test/cinder/requests/request_test.exs
git commit -m "feat(catalog): add original_language + preferred_language to movies/series/requests"
```

---

## Task 5: Carry language through the request→approval gate (movies)

**Files:**
- Modify: `lib/cinder/requests.ex` (`movie_attrs_from/1` and `movie_attrs/1`)
- Test: `test/cinder/requests_test.exs` (follow existing style)

**Interfaces:**
- Consumes: `Movie.changeset/2` casting `:original_language`/`:preferred_language` (Task 4); request rows carrying them (Task 4).
- Produces: an approved/auto-approved movie request writes `original_language` + `preferred_language` onto the created Movie row.

- [ ] **Step 1: Write the failing test**

In `test/cinder/requests_test.exs`, add (adapt user/admin fixtures to the ones already used in that file):

```elixir
test "an approved movie request carries the language onto the movie row" do
  admin = user_fixture(role: :admin)

  attrs = %{
    target_type: "movie", target_id: 603, title: "The Matrix", year: 1999,
    poster_path: "/m.jpg", original_language: "en", preferred_language: "french"
  }

  assert {:ok, %{status: :approved}} = Cinder.Requests.create_request(admin, attrs)
  movie = Cinder.Catalog.get_movie_by_tmdb_id(603)
  assert movie.preferred_language == "french"
  assert movie.original_language == "en"
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder/requests_test.exs`
Expected: FAIL — the movie row's `preferred_language` is the default `"original"`, not `"french"`.

- [ ] **Step 3: Carry the fields in both movie-attrs builders**

In `lib/cinder/requests.ex`, `movie_attrs_from/1` (the `create_approved` path — builds from the attrs map):

```elixir
defp movie_attrs_from(attrs) do
  %{
    tmdb_id: attrs.target_id,
    title: attrs[:title],
    year: attrs[:year],
    poster_path: attrs[:poster_path],
    original_language: attrs[:original_language],
    preferred_language: attrs[:preferred_language] || "original"
  }
end
```

And `movie_attrs/1` (the `approve_request` path — builds from the `%Request{}` struct). Open it and add the two keys, reading from the request struct:

```elixir
original_language: request.original_language,
preferred_language: request.preferred_language || "original"
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `mix test test/cinder/requests_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/requests.ex test/cinder/requests_test.exs
git commit -m "feat(requests): carry preferred/original language onto the approved movie"
```

---

## Task 6: Filter language in movie acquisition + park visibly

**Files:**
- Modify: `lib/cinder/acquisition.ex` (`best_release/2`, alias `Language`)
- Modify: `lib/cinder/download.ex` (`start/1`: thread opts; handle `:no_language_match`; alias `Notifier`)
- Test: `test/cinder/acquisition_test.exs`

**Interfaces:**
- Consumes: `Language.filter/3`, `Language.active?/2` (Task 2); movie row fields (Task 4).
- Produces: `best_release/2` reads `:preferred_language`/`:original_language` opts; returns `:no_language_match` when a non-empty candidate set is fully filtered out by an active language filter, else `{:ok, release}` / `:no_match` / `{:error, _}` as before. `Download.start/1` parks `:no_language_match` at `:no_match` and emits `{:movie_failed, movie, :no_language_match}`.

- [ ] **Step 1: Write the failing tests**

In `test/cinder/acquisition_test.exs` (uses `raw/1` + `IndexerMock`, `@gb`):

```elixir
test "best_release filters by language: french pick keeps a FRENCH release" do
  expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
    {:ok,
     [
       raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb),
       raw(title: "Movie.2020.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)
     ]}
  end)

  assert {:ok, %Release{group: "FR", language: "FRENCH"}} =
           Acquisition.best_release("tt1", max_size: 20 * @gb, preferred_language: "french", original_language: "en")
end

test "best_release returns :no_language_match when nothing satisfies the pick" do
  expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
    {:ok, [raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb)]}
  end)

  assert :no_language_match =
           Acquisition.best_release("tt1", max_size: 20 * @gb, preferred_language: "french", original_language: "en")
end

test "best_release with original pick on an English title accepts untagged, rejects a FRENCH tag" do
  expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
    {:ok,
     [
       raw(title: "Movie.2020.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb),
       raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb)
     ]}
  end)

  assert {:ok, %Release{group: "EN"}} =
           Acquisition.best_release("tt1", max_size: 20 * @gb, preferred_language: "original", original_language: "en")
end

test "best_release with no language preference is unchanged (any/nil)" do
  expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
    {:ok, [raw(title: "Movie.2020.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)]}
  end)

  assert {:ok, %Release{group: "FR"}} =
           Acquisition.best_release("tt1", max_size: 20 * @gb, preferred_language: "any", original_language: "en")
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/acquisition_test.exs`
Expected: FAIL — language opts are ignored today.

- [ ] **Step 3: Wire the filter into `best_release/2`**

In `lib/cinder/acquisition.ex`, add `alias Cinder.Acquisition.Language` and rewrite `best_release/2`:

```elixir
def best_release(imdb_id, opts \\ []) do
  case indexer().search(imdb_id) do
    {:ok, raw_results} ->
      preferred = Keyword.get(opts, :preferred_language)
      original = Keyword.get(opts, :original_language)

      candidates =
        raw_results
        |> Enum.map(&Release.new/1)
        |> filter_protocols(Keyword.get(opts, :protocols))

      filtered = Language.filter(candidates, preferred, original)

      if candidates != [] and filtered == [] and Language.active?(preferred, original) do
        :no_language_match
      else
        Scorer.select(filtered, opts)
      end

    {:error, _reason} = error ->
      error
  end
end
```

- [ ] **Step 4: Handle the new result + thread opts in `download.ex`**

In `lib/cinder/download.ex`, add `alias Cinder.Notifier` (if absent) and update `start/1`:

```elixir
def start(%Movie{} = movie) do
  with {:ok, imdb_id} <- ensure_imdb_id(movie),
       {:ok, movie} <- Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id}) do
    opts =
      [
        protocols: available_protocols(),
        preferred_language: movie.preferred_language,
        original_language: movie.original_language
      ] ++ Acquisition.band_opts(:movies)

    case Acquisition.best_release(imdb_id, opts) do
      {:ok, release} ->
        add_to_client(movie, release)

      :no_match ->
        Catalog.transition(movie, %{status: :no_match})

      :no_language_match ->
        with {:ok, parked} <- Catalog.transition(movie, %{status: :no_match}) do
          Notifier.notify({:movie_failed, parked, :no_language_match})
          {:ok, parked}
        end

      {:error, _} = err ->
        err
    end
  else
    :no_imdb_id -> {:error, :no_imdb_id}
    {:error, _} = err -> err
  end
end
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `mix test test/cinder/acquisition_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the whole suite (movie pipeline must stay green)**

Run: `mix test`
Expected: PASS (the alias: compile/format/credo/test). Fix any format/credo nits before committing.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/acquisition.ex lib/cinder/download.ex test/cinder/acquisition_test.exs
git commit -m "feat(acquisition): strict language filter for movies + :no_language_match park"
```

---

## Task 7: Filter language in TV acquisition

**Files:**
- Modify: `lib/cinder/acquisition.ex` (`best_releases/4`)
- Modify: `lib/cinder/download/tv_poller.ex` (`search_group/1`: thread opts)
- Test: `test/cinder/acquisition_test.exs`

**Interfaces:**
- Consumes: `Language.filter/3` (Task 2); series row fields (Task 4); `best_releases/4` returns `{:ok, [{release, covered}]}` / `:no_match` unchanged.
- Produces: `best_releases/4` reads `:preferred_language`/`:original_language` opts and filters before the set-cover. A fully-filtered-out group yields `:no_match` (→ `tv_poller` bumps `search_attempts`, the existing no-match path); partial coverage is preserved. No notifier at TV search time (there is no grab yet — recovery is the series escape hatch in Task 9/10).

- [ ] **Step 1: Write the failing test**

In `test/cinder/acquisition_test.exs` (uses `series/1`, `raw_tv/2`):

```elixir
test "best_releases filters episodes by language: french pick covers only FRENCH/MULTI episodes" do
  expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
    {:ok,
     [
       raw_tv("The.Office.S01E01.FRENCH.1080p.WEB-DL-FR"),
       raw_tv("The.Office.S01E02.1080p.WEB-DL-EN")
     ]}
  end)

  assert {:ok, chosen} =
           Acquisition.best_releases(series(), 1, [1, 2], preferred_language: "french", original_language: "en")

  # E02 has only an English release -> not covered; E01 (FRENCH) is covered.
  assert chosen |> Enum.flat_map(fn {_r, cov} -> cov end) |> Enum.sort() == [1]
end

test "best_releases returns :no_match when no episode has a satisfying release" do
  expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
    {:ok, [raw_tv("The.Office.S01E01.1080p.WEB-DL-EN"), raw_tv("The.Office.S01E02.1080p.WEB-DL-EN")]}
  end)

  assert :no_match =
           Acquisition.best_releases(series(), 1, [1, 2], preferred_language: "french", original_language: "en")
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/acquisition_test.exs`
Expected: FAIL — language opts ignored for TV.

- [ ] **Step 3: Add the filter pipe to `best_releases/4`**

In `lib/cinder/acquisition.ex`, add one `Language.filter` pipe (after the title-match filter, before the scorer):

```elixir
def best_releases(series, season_number, wanted_numbers, opts \\ []) do
  case indexer().search_tv(series.tvdb_id, series.title, season_number) do
    {:ok, raw_results} ->
      raw_results
      |> Enum.map(&Release.new/1)
      |> filter_protocols(Keyword.get(opts, :protocols))
      |> Enum.filter(&title_matches?(&1, series.title))
      |> Language.filter(Keyword.get(opts, :preferred_language), Keyword.get(opts, :original_language))
      |> Scorer.select_for(season_number, wanted_numbers, opts)

    {:error, _reason} = error ->
      error
  end
end
```

(An empty filtered list flows into `Scorer.select_for/4`, which returns `:no_match` — the existing TV no-match path. No `:no_language_match` branch for TV: there is no grab at search time.)

- [ ] **Step 4: Thread opts in `tv_poller.ex`**

In `lib/cinder/download/tv_poller.ex`, `search_group/1`:

```elixir
defp search_group(episodes) do
  series = hd(episodes).season.series
  season_number = hd(episodes).season.season_number
  numbers = Enum.map(episodes, & &1.episode_number)

  opts =
    [
      protocols: Download.available_protocols(),
      preferred_language: series.preferred_language,
      original_language: series.original_language
    ] ++ Acquisition.band_opts(:tv)

  case Acquisition.best_releases(series, season_number, numbers, opts) do
    {:ok, assignments} ->
      grabbed = Enum.flat_map(assignments, &grab_assignment(&1, episodes))
      bump_not_grabbed(episodes, grabbed)

    :no_match ->
      bump_not_grabbed(episodes, [])

    {:error, reason} ->
      Logger.info(
        "tv search failed for series #{series.id} season #{season_number}: #{inspect(reason)}"
      )

      bump_not_grabbed(episodes, [])
  end
end
```

(`series.preferred_language` / `series.original_language` are present on the preloaded series struct after Task 4. Confirm `wanted_episodes/0`'s preload yields the full `series` row — it loads `season: {series: ...}`, so the columns are present.)

- [ ] **Step 5: Run the tests, verify they pass**

Run: `mix test test/cinder/acquisition_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/acquisition.ex lib/cinder/download/tv_poller.ex test/cinder/acquisition_test.exs
git commit -m "feat(acquisition): strict language filter for TV (partial coverage preserved)"
```

---

## Task 8: Movie inline language picker (DiscoverLive)

**Files:**
- Modify: `lib/cinder_web/live/discover_live.ex` (search-results mapping, `result_action/1`, `handle_event("add", ...)`, `add/2`)
- Test: `test/cinder_web/live/discover_live_test.exs` (follow existing LiveView-test style)

**Interfaces:**
- Consumes: TMDB results carrying `original_language` (Task 3); `Requests.create_request/2` accepting `preferred_language`/`original_language` in attrs (Task 4/5).
- Produces: each movie result renders an Original/French/Any `<select>` defaulted to Original; submitting carries the choice into the request.

- [ ] **Step 1: Thread `original_language` into the results assign**

In `lib/cinder_web/live/discover_live.ex`, find where search results are mapped into `@results` (the `%{tmdb_id:, title:, year:, poster_path:, type:}` maps). Add `original_language: r.original_language` to the **movie** result maps so `result_action/1` can read it. (TV results don't need it here — series language is chosen on the series page, Task 9.)

- [ ] **Step 2: Write the failing test**

In `test/cinder_web/live/discover_live_test.exs`, add (adapt login/mock helpers to the file's existing setup; stub `TMDBMock.search` to return a movie with `original_language: "en"`):

```elixir
test "adding a movie carries the chosen language", %{conn: conn} do
  expect(Cinder.Catalog.TMDBMock, :search, fn _q ->
    {:ok, [%{tmdb_id: 603, title: "The Matrix", year: 1999, poster_path: "/m.jpg", original_language: "en", type: :movie}]}
  end)

  {:ok, lv, _html} = live(conn, ~p"/")
  lv |> form("#search-form", query: "matrix") |> render_change()

  lv |> form("#add-form-603", %{"preferred_language" => "french"}) |> render_submit()

  movie = Cinder.Catalog.get_movie_by_tmdb_id(603)
  assert movie.preferred_language == "french"
  assert movie.original_language == "en"
end
```

(If the search handler shapes results differently, match its stub shape; the assertion on the persisted movie is the contract.)

- [ ] **Step 3: Run the test, verify it fails**

Run: `mix test test/cinder_web/live/discover_live_test.exs`
Expected: FAIL — no `#add-form-603`; language not stored.

- [ ] **Step 4: Replace the Add button with a form + select**

In `lib/cinder_web/live/discover_live.ex`, change `result_action/1` to take `original_language` and render a small form (daisyUI select, gettext labels):

```elixir
attr :state, :atom, required: true
attr :tmdb_id, :integer, required: true
attr :original_language, :string, default: nil

defp result_action(assigns) do
  ~H"""
  <.status_badge :if={@state != :none} kind={:request} status={@state} />
  <form
    :if={@state in [:none, :denied]}
    id={"add-form-#{@tmdb_id}"}
    phx-submit="add"
    class="flex flex-col gap-1"
  >
    <input type="hidden" name="tmdb_id" value={@tmdb_id} />
    <select
      name="preferred_language"
      class="select select-sm w-full"
      aria-label={gettext("Preferred language")}
    >
      <option value="original">{original_option_label(@original_language)}</option>
      <option value="french">{gettext("French")}</option>
      <option value="any">{gettext("Any language")}</option>
    </select>
    <button type="submit" class="btn btn-primary btn-sm w-full" phx-disable-with={gettext("Adding…")}>
      {gettext("Add")}
    </button>
  </form>
  """
end

# "Original (English)" etc. — a human label for the title's TMDB language code.
defp original_option_label(nil), do: gettext("Original")

defp original_option_label(code) do
  case code do
    "en" -> gettext("Original (English)")
    "fr" -> gettext("Original (French)")
    _ -> gettext("Original")
  end
end
```

Pass the new attr at the call site in `render/1`:

```elixir
<.result_action
  :if={r.type == :movie}
  state={title_state(r.tmdb_id, @request_status, @movie_status)}
  tmdb_id={r.tmdb_id}
  original_language={r.original_language}
/>
```

- [ ] **Step 5: Read the language in `handle_event` + `add`**

Update `handle_event("add", ...)` and `add/2` → `add/3`:

```elixir
def handle_event("add", %{"tmdb_id" => tmdb_id} = params, socket) when is_binary(tmdb_id) do
  preferred = normalize_language(params["preferred_language"])

  with {id, ""} <- Integer.parse(tmdb_id),
       movie when not is_nil(movie) <-
         Enum.find(socket.assigns.results, &(&1.type == :movie and &1.tmdb_id == id)) do
    {:noreply, add(socket, movie, preferred)}
  else
    _ -> {:noreply, socket}
  end
end

# phx-value is client-controlled; only accept the three known values, default Original.
defp normalize_language(lang) when lang in ["original", "french", "any"], do: lang
defp normalize_language(_), do: "original"
```

In `add/2`, rename to `add(socket, movie, preferred)` and add the two keys to `attrs`:

```elixir
attrs = %{
  target_type: "movie",
  target_id: movie.tmdb_id,
  title: movie.title,
  year: movie.year,
  poster_path: movie.poster_path,
  original_language: movie.original_language,
  preferred_language: preferred
}
```

- [ ] **Step 6: Run the test, verify it passes**

Run: `mix test test/cinder_web/live/discover_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/cinder_web/live/discover_live.ex test/cinder_web/live/discover_live_test.exs
git commit -m "feat(discover): inline per-movie language picker"
```

---

## Task 9: Series language picker (SeriesDiscoveryLive) + creation plumbing

**Files:**
- Modify: `lib/cinder/catalog.ex` (`add_series_to_watchlist/2`, `create_series/2→/3`, `series_attrs/3→/4`, `find_or_create_series_at_requested/2→/3`, `ensure_series/1→/2`)
- Modify: `lib/cinder_web/live/series_discovery_live.ex` (render a series language select; pass it into `request_season` attrs)
- Test: `test/cinder/catalog_test.exs` (or the series catalog test file)

**Interfaces:**
- Consumes: `Series.create_changeset/1` casting language fields (Task 4); TMDB `get_series` carrying `original_language` (Task 3).
- Produces: `add_series_to_watchlist(tmdb_id, opts)` accepts `:preferred_language` (default `"original"`); a created series stores `original_language` (from TMDB) + `preferred_language`. `find_or_create_series_at_requested(tmdb_id, season_number, preferred_language)` threads the requester's pick on first creation.

- [ ] **Step 1: Write the failing test**

In the series catalog test file, add (mock `TMDBMock.get_series`/`get_season` per the file's existing stub helper; the series body includes `original_language: "fr"`):

```elixir
test "add_series_to_watchlist stores original_language and the chosen preferred_language" do
  stub_tmdb_series(original_language: "fr")  # existing helper that stubs get_series/get_season

  {:ok, series} = Catalog.add_series_to_watchlist(42, monitor_strategy: :future, preferred_language: "french")

  assert series.original_language == "fr"
  assert series.preferred_language == "french"
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mix test test/cinder/catalog_test.exs`
Expected: FAIL — `add_series_to_watchlist` ignores `:preferred_language`; `original_language` not stored.

- [ ] **Step 3: Thread the fields through series creation**

In `lib/cinder/catalog.ex`:

```elixir
def add_series_to_watchlist(tmdb_id, opts \\ []) do
  strategy = Keyword.get(opts, :monitor_strategy, :future)
  preferred = Keyword.get(opts, :preferred_language, "original")

  if strategy in Series.monitor_strategies() do
    case get_series_by_tmdb_id(tmdb_id) do
      %Series{} = series -> {:ok, series}
      nil -> create_series(tmdb_id, strategy, preferred)
    end
  else
    {:error, :invalid_monitor_strategy}
  end
end

defp create_series(tmdb_id, strategy, preferred) do
  with {:ok, info} <- tmdb().get_series(tmdb_id),
       {:ok, seasons} <- fetch_seasons(tmdb_id, info.seasons) do
    insert_series(tmdb_id, series_attrs(info, seasons, strategy, preferred))
  end
end
```

Add the two keys to `series_attrs/4` (rename from `/3`):

```elixir
defp series_attrs(info, seasons, strategy, preferred) do
  today = Date.utc_today()

  %{
    tmdb_id: info.tmdb_id,
    tvdb_id: info.tvdb_id,
    title: info.title,
    year: info.year,
    poster_path: info.poster_path,
    original_language: info.original_language,
    preferred_language: preferred,
    monitored: strategy != :none,
    monitor_strategy: strategy,
    seasons:
      # ... unchanged season/episode tree ...
  }
end
```

Thread the requester's pick through the request path:

```elixir
def find_or_create_series_at_requested(tmdb_id, season_number, preferred \\ "original") do
  with {:ok, series} <- ensure_series(tmdb_id, preferred),
       %Season{} = season <- season_in(series, season_number),
       {:ok, _} <- set_season_monitored(season, true),
       {:ok, updated} <- mark_series_monitored(series) do
    {:ok, updated}
  else
    nil -> {:error, :season_not_found}
    {:error, _} = err -> err
  end
end

defp ensure_series(tmdb_id, preferred \\ "original"),
  do: add_series_to_watchlist(tmdb_id, monitor_strategy: :none, preferred_language: preferred)
```

(An existing series is returned as-is — its language was set on first add; later changes go through the escape hatch in Task 10.)

- [ ] **Step 4: Pass the pick from the request callers**

`lib/cinder/requests.ex` — the season approval clauses call `Catalog.find_or_create_series_at_requested(target_id, season_number)`. Add the request's language as the third arg in both `create_approved` (season clause, read `attrs[:preferred_language] || "original"`) and `approve_request` (season clause, read `request.preferred_language || "original"`).

- [ ] **Step 5: Add the series language select to the UI**

In `lib/cinder_web/live/series_discovery_live.ex`:
- In `mount/3`, add `|> assign(:preferred_language, "original")`.
- In `render/1`, add a series-level select near the header (daisyUI, gettext), bound via a `phx-change`:

```elixir
<form phx-change="set_language" class="mb-4 max-w-xs">
  <select name="preferred_language" class="select select-sm w-full" aria-label={gettext("Preferred language")}>
    <option value="original" selected={@preferred_language == "original"}>{gettext("Original")}</option>
    <option value="french" selected={@preferred_language == "french"}>{gettext("French")}</option>
    <option value="any" selected={@preferred_language == "any"}>{gettext("Any language")}</option>
  </select>
</form>
```

- Add the handler:

```elixir
def handle_event("set_language", %{"preferred_language" => lang}, socket)
    when lang in ["original", "french", "any"] do
  {:noreply, assign(socket, :preferred_language, lang)}
end
```

- In `handle_event("request_season", ...)`, add `preferred_language: socket.assigns.preferred_language` and `original_language: socket.assigns.info.original_language` to `attrs`. (Add `original_language` to the `Catalog.tmdb_series/1` map passed as `@info` if it isn't already surfaced — it comes from `normalize_series` after Task 3.)

- [ ] **Step 6: Run the tests, verify they pass**

Run: `mix test test/cinder/catalog_test.exs test/cinder_web/live/series_discovery_live_test.exs`
Expected: PASS.

- [ ] **Step 7: Run the whole suite + commit**

```bash
mix test
git add lib/cinder/catalog.ex lib/cinder/requests.ex lib/cinder_web/live/series_discovery_live.ex test/cinder/catalog_test.exs
git commit -m "feat(catalog): per-series language on add + season-request carry-through"
```

---

## Task 10: Escape hatch — change language to re-search

**Files:**
- Modify: `lib/cinder/catalog.ex` (`set_movie_language/2`, `set_series_language/2`)
- Modify: `lib/cinder_web/live/activity_live.ex` (movie row language select + handler)
- Modify: `lib/cinder_web/live/series_detail_live.ex` (admin `/series/:id` — series language select + handler)
- Test: `test/cinder/catalog_test.exs`

**Interfaces:**
- Consumes: `Movie.language_changeset/2`, `Series.language_changeset/2`, `retry_movie/1` (Tasks 4 + existing).
- Produces:
  - `set_movie_language(movie, lang)` writes `preferred_language`; if the movie is parked at `:no_match`/`:search_failed`, re-queues it via `retry_movie/1`; else updates + broadcasts.
  - `set_series_language(series, lang)` writes `preferred_language` and zeroes `search_attempts` on the series' still-wanted episodes (`file_path` and `grab_id` nil) so they re-enter the sweep; broadcasts on `"series"`.

- [ ] **Step 1: Write the failing tests**

In `test/cinder/catalog_test.exs`:

```elixir
test "set_movie_language re-queues a parked movie" do
  {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 7, title: "X"})
  {:ok, movie} = Catalog.transition(movie, %{status: :no_match})

  {:ok, updated} = Catalog.set_movie_language(movie, "french")

  assert updated.preferred_language == "french"
  assert updated.status == :requested
  assert updated.search_attempts == 0
end

test "set_movie_language on an available movie only updates the field" do
  {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 8, title: "Y"})
  {:ok, movie} = Catalog.transition(movie, %{status: :available})

  {:ok, updated} = Catalog.set_movie_language(movie, "any")

  assert updated.preferred_language == "any"
  assert updated.status == :available
end

test "set_series_language zeroes search_attempts on wanted episodes only" do
  series = Repo.insert!(%Series{tmdb_id: 5, title: "S"})
  season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
  wanted = Repo.insert!(%Episode{season_id: season.id, episode_number: 1, monitored: true, search_attempts: 9})
  filed = Repo.insert!(%Episode{season_id: season.id, episode_number: 2, monitored: true, search_attempts: 9, file_path: "/x.mkv"})

  {:ok, updated} = Catalog.set_series_language(series, "french")

  assert updated.preferred_language == "french"
  assert Repo.get!(Episode, wanted.id).search_attempts == 0
  assert Repo.get!(Episode, filed.id).search_attempts == 9
end
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `mix test test/cinder/catalog_test.exs`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Add the two Catalog functions**

In `lib/cinder/catalog.ex` (`Episode`/`Season`/`Series` are already aliased; `import Ecto.Query` is present):

```elixir
@language_retry_statuses [:no_match, :search_failed]

@doc """
Sets a movie's preferred language. If the movie is parked because a release in
that language wasn't found, re-queues it (the poller re-searches); otherwise just
updates the field. The download/import pipeline is not disturbed for in-flight or
available movies (no quality-upgrade re-grab in this slice).
"""
def set_movie_language(%Movie{} = movie, language) do
  {:ok, updated} = movie |> Movie.language_changeset(%{preferred_language: language}) |> Repo.update()

  if updated.status in @language_retry_statuses do
    retry_movie(updated)
  else
    broadcast({:movie_updated, updated})
    {:ok, updated}
  end
end

@doc """
Sets a series' preferred language and zeroes `search_attempts` on its still-wanted
episodes (no file, no grab) so a previously language-stranded season re-enters the
search sweep. Available / in-flight episodes are untouched.
"""
def set_series_language(%Series{} = series, language) do
  {:ok, updated} = series |> Series.language_changeset(%{preferred_language: language}) |> Repo.update()

  from(e in Episode,
    join: s in Season,
    on: e.season_id == s.id,
    where:
      s.series_id == ^series.id and is_nil(e.file_path) and is_nil(e.grab_id) and
        e.search_attempts > 0
  )
  |> Repo.update_all(set: [search_attempts: 0])

  broadcast_series(series.id)
  {:ok, updated}
end
```

- [ ] **Step 4: Wire the movie select into ActivityLive**

In `lib/cinder_web/live/activity_live.ex`, in the movie `<li>` (next to the Retry button), add a language select bound to a per-row change:

```elixir
<form phx-change="set_movie_language" class="ml-auto">
  <input type="hidden" name="id" value={m.id} />
  <select name="preferred_language" class="select select-xs" aria-label={gettext("Preferred language")}>
    <option value="original" selected={m.preferred_language == "original"}>{gettext("Original")}</option>
    <option value="french" selected={m.preferred_language == "french"}>{gettext("French")}</option>
    <option value="any" selected={m.preferred_language == "any"}>{gettext("Any")}</option>
  </select>
</form>
```

Add the handler (string-compare id like the existing `retry` handler):

```elixir
def handle_event("set_movie_language", %{"id" => id, "preferred_language" => lang}, socket)
    when lang in ["original", "french", "any"] do
  movie = Enum.find(socket.assigns.movies, &(to_string(&1.id) == id))
  if movie, do: Catalog.set_movie_language(movie, lang)
  {:noreply, socket}
end
```

- [ ] **Step 5: Wire the series select into SeriesDetailLive (admin)**

In `lib/cinder_web/live/series_detail_live.ex` (the admin `/series/:id` page with monitor toggles), add a series language select near the header and a handler:

```elixir
<form phx-change="set_series_language" class="mb-4 max-w-xs">
  <select name="preferred_language" class="select select-sm w-full" aria-label={gettext("Preferred language")}>
    <option value="original" selected={@series.preferred_language == "original"}>{gettext("Original")}</option>
    <option value="french" selected={@series.preferred_language == "french"}>{gettext("French")}</option>
    <option value="any" selected={@series.preferred_language == "any"}>{gettext("Any language")}</option>
  </select>
</form>
```

```elixir
def handle_event("set_series_language", %{"preferred_language" => lang}, socket)
    when lang in ["original", "french", "any"] do
  {:ok, series} = Catalog.set_series_language(socket.assigns.series, lang)
  {:noreply, assign(socket, :series, series)}
end
```

(Match the assign name used by the page — adjust `@series` / `socket.assigns.series` to the actual key.)

- [ ] **Step 6: Run the tests, verify they pass**

Run: `mix test test/cinder/catalog_test.exs`
Expected: PASS.

- [ ] **Step 7: Run the whole suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/cinder/catalog.ex lib/cinder_web/live/activity_live.ex lib/cinder_web/live/series_detail_live.ex test/cinder/catalog_test.exs
git commit -m "feat(catalog): change-language escape hatch re-searches movies and series"
```

---

## Task 11: Extract translations + final green

**Files:**
- Modify: `priv/gettext/**` (generated)

- [ ] **Step 1: Extract + merge new gettext strings**

Run: `mix gettext.extract --merge`
This adds the new `msgid`s (Preferred language, French, Any language, Original (English), Original (French), Original, Any) to `priv/gettext/{en,fr}/LC_MESSAGES/default.po`. Fill in the French `msgstr`s for the new strings (the existing fr translations are the model).

- [ ] **Step 2: Full suite**

Run: `mix test`
Expected: PASS (the alias, fully green).

- [ ] **Step 3: Refresh the knowledge graph**

Run: `graphify update .`

- [ ] **Step 4: Commit**

```bash
git add priv/gettext
git commit -m "chore(i18n): extract per-item language strings (en/fr)"
```

---

## Self-review notes (spec coverage)

- Match model → Tasks 1 (parser), 2 (`Language`). Strict semantics → Tasks 6/7. `nil = original-language` → `Language.satisfies?/3` clause 2.
- Data model (movies/series/requests + `original_language`) → Tasks 3, 4. Carry-through → Tasks 5 (movie), 9 (series).
- Acquisition filter, movies + TV, filter-only → Tasks 6, 7. `:no_language_match` visibility (movies) → Task 6; TV degrades to no-match by design (no grab at search) → noted in Task 7.
- Inline picker (movie + series) → Tasks 8, 9. Escape hatch (movie + series re-search) → Task 10.
- Non-goals honored: no scorer ranking change (constraint), no English pick (menu = Original/French/Any), no per-season language, no re-grab of `:available` (Task 10 only re-queues parked/wanted).

## Risks / verify-during-implementation

- **DiscoverLive results shape (Task 8):** confirm the search handler passes `original_language` into the movie result maps; the `result_action` form depends on it.
- **`wanted_episodes/0` preload (Task 7):** confirm the preloaded `series` carries the new columns (it loads the full `series` row, so it should).
- **SeriesDetailLive assign name (Task 10):** match the page's actual series assign key.
- **`movie_attrs/1` (Task 5):** confirm its exact name/body in `requests.ex`; add the two keys reading from the `%Request{}`.
