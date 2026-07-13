# A2 Anime Acquisition Implementation Plan

Council review: 3 rounds - approved; all material findings resolved, no residual disagreement

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bounded anime-aware movie and episodic release acquisition, stable-ID selection, preferred-group waiting, and restart-safe intent snapshots while keeping standard movie/TV behavior unchanged and episodic anime out of Library until A3.

**Architecture:** Keep `Cinder.Acquisition` as the public context. Add one pure parser and one focused anime acquisition helper, reuse the existing scorer's greedy cover, let Catalog build plain identity contexts, and enforce the A2/A3 hold at the existing Download intent choke-points.

**Tech Stack:** Elixir, Phoenix/Ecto with SQLite, Req, ExUnit, Mox, Jason, existing `Cinder.Catalog.AnimeResolver`, and the repository's `mix test` quality alias.

## Global Constraints

- Work only on roadmap phase A2; do not activate episodic anime polling or import behavior.
- Anime remains a handling profile, not a third media type, context, or pipeline.
- Existing `Indexer.search/1`, `Indexer.search_tv/3`, `Acquisition.best_release/2`, `Acquisition.best_releases/4`, and standard scorer result shapes remain compatible.
- External services are reached only through the existing Indexer and Download Client behaviours; tests never use a network service.
- Every production behavior change follows red-green-refactor: run the focused test and observe the expected failure before implementation.
- Add no dependency, setting, preference column, UI, or long-lived feature flag.
- Free-text searches use category 5070; at most seven aliases, four wanted seasons, three schemes, 24 episodic requests, nine movie requests, 200 title codepoints, 32 coordinate codepoints, and 100 expanded range values.
- Snapshot-bearing episodic intents and marked releases must produce no downloader, grab, import, deletion, or counter side effect until A3.
- Run `mix format` before every commit; `mix test` is the final source of truth.

---

### Task 1: Add bounded free-text Indexer callbacks and safe Prowlarr normalization

**Files:**
- Modify: `lib/cinder/acquisition/indexer.ex:1-21`
- Modify: `lib/cinder/acquisition/indexer/prowlarr.ex:20-115`
- Modify: `test/cinder/acquisition/indexer/prowlarr_test.exs:1-177`

**Interfaces:**
- Consumes: the existing runtime-selected `Cinder.Acquisition.Indexer` behaviour.
- Produces: `search_movie_query/2`, `search_tv_query/2`, and normalized maps carrying `category_ids`, `indexer_id`, and `published_at`.

- [ ] **Step 1: Write failing callback and wire-contract tests**

Add tests that exercise the real Req adapter, including a valid sibling beside malformed entries:

```elixir
test "search_movie_query/2 sends the measured movie/category contract and retains anime metadata" do
  Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
    assert conn.params["query"] == "Kimi no Na wa 2016"
    assert conn.params["type"] == "moviesearch"
    assert conn.params["categories"] == "5070"

    Req.Test.json(conn, [
      nil,
      %{"title" => nil, "downloadUrl" => "http://prowlarr:9696/bad"},
      %{
        "title" => "[Group] Kimi no Na wa (2016) [1080p]",
        "size" => 8_000_000_000,
        "downloadUrl" => "http://prowlarr:9696/movie/1",
        "protocol" => "torrent",
        "categories" => [%{"id" => 5070}, %{"id" => "not-an-integer"}],
        "indexerId" => 12,
        "publishDate" => "2026-07-13T10:00:00Z"
      }
    ])
  end)

  assert {:ok, [result]} =
           Prowlarr.search_movie_query("Kimi no Na wa 2016", categories: [5070])

  assert result.category_ids == [5070]
  assert result.indexer_id == 12
  assert result.published_at == ~U[2026-07-13 10:00:00Z]
end

test "search_tv_query/2 uses tvsearch and drops entries without a usable URL" do
  Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
    assert conn.params["query"] == "ワンピース 1122"
    assert conn.params["type"] == "tvsearch"
    assert conn.params["categories"] == "5070"

    Req.Test.json(conn, [
      %{"title" => "No URL", "downloadUrl" => 42},
      %{
        "title" => "[Group] ワンピース - 1122 [1080p]",
        "size" => "unknown",
        "downloadUrl" => "   ",
        "magnetUrl" => "magnet:?xt=urn:btih:onepiece",
        "protocol" => %{"bad" => true},
        "categories" => "bad",
        "indexerId" => "bad",
        "publishDate" => "bad"
      }
    ])
  end)

  assert {:ok, [result]} = Prowlarr.search_tv_query("ワンピース 1122", categories: [5070])
  assert result.size == nil
  assert result.protocol == :torrent
  assert result.category_ids == []
  assert result.indexer_id == nil
  assert result.published_at == nil
end
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `mix test test/cinder/acquisition/indexer/prowlarr_test.exs`

Expected: compilation fails because the two callbacks/functions do not exist.

- [ ] **Step 3: Add the behaviour callbacks and the smallest shared request path**

Add to the behaviour:

```elixir
@callback search_movie_query(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
@callback search_tv_query(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
```

Implement both callbacks through one private function in Prowlarr:

```elixir
@impl true
def search_movie_query(query, opts), do: search_query(query, "moviesearch", opts)

@impl true
def search_tv_query(query, opts), do: search_query(query, "tvsearch", opts)

defp search_query(query, type, opts) do
  params = [query: query, type: type] ++ category_params(opts)

  case request(url: "/api/v1/search", params: params) do
    {:ok, %{status: 200, body: results}} when is_list(results) ->
      {:ok, Enum.flat_map(results, &normalize_result/1)}

    {:ok, %{status: 200}} ->
      {:error, :unexpected_response}

    other ->
      error(other)
  end
end

defp category_params(opts) do
  case Keyword.get(opts, :categories, []) do
    [] -> []
    ids -> [categories: Enum.join(ids, ",")]
  end
end
```

Replace direct `Enum.map(results, &normalize/1)` in all three existing search paths with the same per-entry `Enum.flat_map(results, &normalize_result/1)`. `normalize_result/1` must return `[]` for a non-map, blank/non-binary title, or no usable URL, and a singleton normalized result list otherwise. A usable URL is a non-blank binary `downloadUrl`, falling back to a non-blank binary `magnetUrl` when the former is nil, blank, or malformed. Parse category maps with integer `"id"`, accept only integer `indexerId`, and parse `publishDate` through `DateTime.from_iso8601/1`, returning `nil` on any error. Keep the existing unknown-protocol-to-torrent behavior. Update existing exact result assertions with `category_ids: []`, `indexer_id: nil`, and `published_at: nil`.

- [ ] **Step 4: Verify GREEN and standard regressions**

Run: `mix format && mix test test/cinder/acquisition/indexer/prowlarr_test.exs test/cinder/acquisition_test.exs`

Expected: both files pass; existing IMDb/TVDB parameter assertions remain unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/indexer.ex lib/cinder/acquisition/indexer/prowlarr.ex test/cinder/acquisition/indexer/prowlarr_test.exs
git commit -m "feat: add anime indexer queries"
```

### Task 2: Parse anime coordinates without changing the standard parser

**Files:**
- Create: `lib/cinder/acquisition/anime_parser.ex`
- Create: `test/cinder/acquisition/anime_parser_test.exs`
- Modify: `lib/cinder/acquisition/release.ex:1-45`
- Modify: `test/cinder/acquisition/release_test.exs:1-42`
- Create: `test/support/fixtures/anime/acquisition-v1.json`

**Interfaces:**
- Consumes: `%{kind: :movie | :series, titles: [String.t()], year: integer() | nil}`.
- Produces: `AnimeParser.parse/2` returning `%{coordinates: [%{scheme: String.t(), values: [String.t()]}], role: :story | :extra | :unknown, group: String.t() | nil}`.

- [ ] **Step 1: Create the explicit A2 fixture and failing parser tests**

The fixture starts with this stable shape and provides a context for every A0 A2 ID:

```json
{
  "version": 1,
  "parser_contexts": {
    "ordinary-cour-sxxeyy": {"kind": "series", "titles": ["Demon Slayer"], "year": 2019},
    "absolute-over-99": {"kind": "series", "titles": ["Bleach"], "year": 2004},
    "absolute-over-999-v2-crc": {"kind": "series", "titles": ["One Piece", "ワンピース"], "year": 1999},
    "split-cour-absolute-range": {"kind": "series", "titles": ["Re Zero"], "year": 2016},
    "cross-season-batch": {"kind": "series", "titles": ["Attack on Titan"], "year": 2013},
    "dual-audio-dub-ass-markers": {"kind": "series", "titles": ["Demon Slayer"], "year": 2019},
    "ova-typed-special": {"kind": "series", "titles": ["Show"], "year": 2020},
    "ona-not-automatically-special": {"kind": "series", "titles": ["Show"], "year": 2020},
    "recap-is-story-candidate": {"kind": "series", "titles": ["Show"], "year": 2020},
    "episode-zero": {"kind": "series", "titles": ["Show"], "year": 2020},
    "ncop-extra": {"kind": "series", "titles": ["Show"], "year": 2020},
    "nced-extra": {"kind": "series", "titles": ["Show"], "year": 2020},
    "trailer-extra": {"kind": "series", "titles": ["Show"], "year": 2020},
    "ambiguous-bare-number": {"kind": "series", "titles": ["86"], "year": 2021},
    "anime-movie-release": {"kind": "movie", "titles": ["Your Name", "Kimi no Na wa"], "year": 2016}
  }
}
```

In `anime_parser_test.exs`, load both JSON files with `Jason.decode!/1`, join the 15 A2 contracts by ID, atomize only the trusted `kind`, call `AnimeParser.parse/2`, and compare coordinates/role after converting atoms to fixture strings. Add direct tests for native title matching and `Show - 1-101` returning unmatched.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `mix test test/cinder/acquisition/anime_parser_test.exs`

Expected: compilation fails because `Cinder.Acquisition.AnimeParser` is undefined.

- [ ] **Step 3: Implement one bounded pure parser**

Create `Cinder.Acquisition.AnimeParser` with `@max_range 100` and this public seam:

```elixir
def parse(title, %{kind: :movie}) when is_binary(title) do
  %{coordinates: [], role: :story, group: prefix_group(title)}
end

def parse(title, %{kind: :series} = context) when is_binary(title) do
  cond do
    extra?(title) -> result([], :extra, title)
    coordinates = standard_coordinates(title) -> result(coordinates, :story, title)
    coordinates = typed_special(title) -> result(coordinates, :unknown, title)
    title_match?(title, context.titles) and coordinates = absolute_coordinates(title, context) ->
      result(coordinates, :story, title)
    true -> result([], :unknown, title)
  end
end

def parse(_title, _context), do: %{coordinates: [], role: :unknown, group: nil}
```

Implement standard batches before typed specials, and typed specials before bare absolute numbers. Each coordinate helper returns `nil` when it finds no coordinate so the `cond` falls through. Strip leading group, resolutions, CRCs, the context year, and `vN` suffixes before accepting an absolute scalar. Treat any four-digit scalar from 1900 through `Date.utc_today().year + 1` as a year, so `2024` is rejected while absolute `1122` remains valid. Expand only ascending ranges whose inclusive width is at most 100. Use Unicode regexes and `String.normalize(:nfkc)`; do not reuse the ASCII-only standard TV guard. Extract `[Group]` only from the leading bracket pair.

Add these fields to `Release.defstruct`: `category_ids`, `indexer_id`, `published_at`, `query_origins`, `coordinates`, `role`, `resolved_episode_ids`, `resolution_evidence`, and `mapping_snapshot`. Extend `Release.new/1` to copy only normalized indexer metadata; anime parsing remains outside `Release.new/1`.

- [ ] **Step 4: Verify GREEN and unchanged standard parsing**

Run: `mix format && mix test test/cinder/acquisition/anime_parser_test.exs test/cinder/acquisition/parser_test.exs test/cinder/acquisition/release_test.exs`

Expected: all A2 parser contracts and all legacy parser/release tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/anime_parser.ex lib/cinder/acquisition/release.ex test/cinder/acquisition/anime_parser_test.exs test/cinder/acquisition/release_test.exs test/support/fixtures/anime/acquisition-v1.json
git commit -m "feat: parse anime release coordinates"
```

### Task 3: Reuse the scorer's greedy cover for stable IDs

**Files:**
- Modify: `lib/cinder/acquisition/scorer.ex:67-205`
- Modify: `test/cinder/acquisition/scorer_test.exs:150-330`

**Interfaces:**
- Consumes: `%Release{resolved_episode_ids: [integer()]}` and wanted stable IDs.
- Produces: `Scorer.select_for_ids/3 :: {:ok, [{%Release{}, [integer()]}]} | :no_match` without changing `select_for/4`.

- [ ] **Step 1: Write failing stable-ID cover tests**

```elixir
describe "select_for_ids/3" do
  test "greedily assigns disjoint stable IDs and keeps the per-episode size band" do
    pack = release(resolved_episode_ids: [11, 12], resolution: "1080p", size: 4 * @gb)
    single = release(resolved_episode_ids: [13], resolution: "1080p", size: 2 * @gb)

    assert {:ok, [{^pack, [11, 12]}, {^single, [13]}]} =
             Scorer.select_for_ids([single, pack], [11, 12, 13], max_size: 3 * @gb)
  end

  test "rejects a candidate with no wanted stable IDs" do
    release = release(resolved_episode_ids: [99], resolution: "1080p", size: @gb)
    assert :no_match = Scorer.select_for_ids([release], [11])
  end

  test "preserves non-monotonic resolved membership order" do
    release = release(resolved_episode_ids: [20, 10], resolution: "1080p", size: 2 * @gb)
    assert {:ok, [{^release, [20, 10]}]} = Scorer.select_for_ids([release], [10, 20])
  end
end
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `mix test test/cinder/acquisition/scorer_test.exs`

Expected: undefined function `Scorer.select_for_ids/3`.

- [ ] **Step 3: Parameterize the existing private cover once**

Add:

```elixir
def select_for_ids(releases, wanted_ids, opts \\ []) do
  {min_size, max_size, preferred, sources, release_blocklist} = rules(opts)
  band = {min_size, max_size, preferred, sources}

  releases
  |> Enum.reject(&title_blocked?(&1, release_blocklist))
  |> Enum.filter(&(allowed_resolution?(&1, preferred) and allowed_source?(&1, sources)))
  |> cover(MapSet.new(wanted_ids), [], band, &id_coverage/2)
end

defp id_coverage(release, needed) do
  ids = MapSet.new(release.resolved_episode_ids || [])
  if MapSet.size(ids) > 0 and MapSet.subset?(ids, needed), do: ids, else: MapSet.new()
end
```

Change the existing TV call to pass `&coverage/2`, and add the coverage function as the last argument to the recursive private `cover/5` and `take_best/5` calls. A stable-ID release is selectable only while every ID it claims remains needed, so greedy assignment never truncates a release's meaning. After a successful stable-ID cover, replace each internal MapSet-derived coverage list with that release's already ordered-deduplicated `resolved_episode_ids`; do not numerically sort stable IDs. Keep the existing sorted standard-TV return shape unchanged. Add regressions where `[11, 12]` is selected first and an overlapping `[12, 13]` candidate is not later assigned only `[13]`, and where membership `[20, 10]` remains `[20, 10]` in the public result.

- [ ] **Step 4: Verify GREEN and standard scorer regressions**

Run: `mix format && mix test test/cinder/acquisition/scorer_test.exs test/cinder/acquisition_test.exs`

Expected: the new stable-ID tests and every existing movie/TV scorer test pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/scorer.ex test/cinder/acquisition/scorer_test.exs
git commit -m "refactor: reuse scorer cover for stable ids"
```

### Task 4: Build plain anime acquisition contexts in Catalog

**Files:**
- Modify: `lib/cinder/catalog.ex:120-165`
- Create: `test/cinder/catalog/anime_acquisition_context_test.exs`

**Interfaces:**
- Produces: `Catalog.anime_movie_acquisition_context/1` and `Catalog.anime_series_acquisition_context/1` as Repo-free plain maps for Acquisition.
- Consumes later: `Anime.search_movie/4`, `Anime.best_episodes/4`, and `Anime.build_mapping_snapshot/3`.

- [ ] **Step 1: Write failing context tests with real SQLite rows**

Create a movie with native/manual aliases and a two-season series with standard plus absolute mappings. Assert exact essentials:

```elixir
assert %{
         kind: :movie,
         title: "Your Name",
         year: 2016,
         aliases: aliases
       } = Catalog.anime_movie_acquisition_context(movie)

assert Enum.map(aliases, & &1.title) == ["君の名は。"]

assert %{
         kind: :series,
         title: "Show",
         year: 2008,
         tvdb_id: 99,
         aliases: series_aliases,
         episodes: episodes,
         mappings: mappings
       } =
         Catalog.anime_series_acquisition_context(series)

assert Enum.map(series_aliases, & &1.title) == ["ショー"]
assert Enum.map(episodes, &Map.take(&1, [:id, :season_number, :episode_number])) == [
         %{id: first.id, season_number: 1, episode_number: 25},
         %{id: second.id, season_number: 2, episode_number: 1}
       ]

assert Enum.any?(mappings, &(&1.identity.scheme == "standard" and &1.episode_ids == [first.id]))
assert Enum.any?(mappings, &(&1.identity.scheme == "absolute" and &1.episode_ids == [first.id, second.id]))
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `mix test test/cinder/catalog/anime_acquisition_context_test.exs`

Expected: both Catalog context functions are undefined.

- [ ] **Step 3: Implement two read-only builders in Catalog**

Use `Repo.preload/2`, `Identity.list_aliases/1`, and `Identity.list_coordinates/1`; do not add another context module. The series map must carry `kind`, canonical `title`, `year`, `tvdb_id`, aliases, episodes, and mappings; the movie map carries `kind`, title, year, aliases, and profile summary. Return aliases as plain maps with title/kind/precedence/normalized_title. Build canonical standard mappings from every episode with:

```elixir
%{
  identity: %{
    source: "cinder",
    scheme: "standard",
    namespace: "canonical",
    canonical_value: Episode.code(season.season_number, episode.episode_number)
  },
  precedence: :manual,
  episode_ids: [episode.id],
  evidence: %{"kind" => "canonical_standard"}
}
```

Convert persisted coordinates to the same shape while preserving membership position and full episode ID lists. Sort episodes by `{season_number, episode_number, id}` and mappings by the structured identity tuple so snapshots are deterministic.

- [ ] **Step 4: Verify GREEN and A1 identity regressions**

Run: `mix format && mix test test/cinder/catalog/anime_acquisition_context_test.exs test/cinder/catalog/anime_identity_test.exs test/cinder/catalog/anime_resolver_test.exs`

Expected: context and A1 identity tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog.ex test/cinder/catalog/anime_acquisition_context_test.exs
git commit -m "feat: build anime acquisition contexts"
```

### Task 5: Add bounded additive search, Unicode title guards, and provenance-preserving deduplication

**Files:**
- Create: `lib/cinder/acquisition/anime.ex`
- Create: `test/cinder/acquisition/anime_search_test.exs`

**Interfaces:**
- Produces: `Anime.search_movie/4` and `Anime.search_episodes/4`, returning `{:ok, releases, failed?}` or `{:error, term()}`.
- Consumes: an Indexer module, IMDb ID or series context, plain Catalog context, and selection opts.

- [ ] **Step 1: Write failing aggregation and guard tests**

Use Mox expectations to prove: IMDb/TVDB calls with non-nil IDs remain ID-scoped; a `search_tv(nil, title, season)` result is tagged free-text and a wrong/spinoff title from that result is rejected; canonical plus seven aliases are deterministic; movie requests stop at nine; episodic requests stop at 24/four seasons/three schemes; partial failures set `failed?`; URL dedup unions `query_origins` and category IDs; a free-text native alias passes; embedded/spinoff titles and wrong/missing movie years fail.

Exercise both scalar trust-boundary limits with exact outgoing-query assertions. A 200-codepoint native alias is queried and an otherwise-valid 201-codepoint alias is omitted; a 32-codepoint coordinate scalar is queried and a 33-codepoint scalar is omitted. Make at least one boundary value use decomposed Unicode with combining codepoints so a grapheme count would give the wrong answer. Count codepoints with `value |> String.codepoints() |> length()`, not `String.length/1` (graphemes) or bytes. Overlong values fail closed by dropping only that free-text/coordinate query—never truncate a semantic title or coordinate—and the bounded ID-scoped queries still run.

The central assertions for provenance and ID-scoped TV propagation are:

```elixir
assert {:ok, [release], false} = Anime.search_movie(IndexerMock, "tt1", context, [])
assert Enum.sort(release.query_origins) == [:free_text, :id_scoped]
assert release.category_ids == [5070]

assert_receive {:search_tv, 99, "Show", 1}
```

The worst-case Mox test increments an Agent counter from each callback and asserts `count <= 9` for movie and `count <= 24` for episodic search.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `mix test test/cinder/acquisition/anime_search_test.exs`

Expected: `Cinder.Acquisition.Anime` is undefined.

- [ ] **Step 3: Implement the bounded query planner and aggregator**

Define constants in `Anime`:

```elixir
@anime_category 5070
@max_aliases 7
@max_seasons 4
@max_queries 24
@queryable_schemes ~w(standard absolute scene)
@max_title_codepoints 200
@max_coordinate_codepoints 32
```

Expose:

```elixir
def search_movie(indexer, imdb_id, context, _opts) do
  queries =
    [{:id_scoped, fn -> indexer.search(imdb_id) end}] ++
      Enum.map(movie_titles(context), fn query ->
        {:free_text, fn -> indexer.search_movie_query(query, categories: [@anime_category]) end}
      end)

  run_queries(queries, context)
end


def search_episodes(indexer, context, wanted_ids, _opts) do
  context
  |> episode_queries(wanted_ids)
  |> Enum.take(@max_queries)
  |> run_queries(context)
end
```

`episode_queries/2` begins with one `search_tv(context.tvdb_id, context.title, season_number)` per selected wanted season. Tag that origin `:id_scoped` only when `context.tvdb_id` is non-nil; Prowlarr's nil-ID form is a free-text title/season query and must be tagged `:free_text` so the Unicode title guard applies. Then add canonical/alias category queries and earliest-coordinate queries within the fixed budget. Before constructing any free-text request, retain title scalars only when `length(String.codepoints(title)) <= @max_title_codepoints` and coordinate scalars only when `length(String.codepoints(coordinate)) <= @max_coordinate_codepoints`; omit overlong values rather than truncating them. `run_queries/2` tags each normalized map with an origin before `Release.new/1`, applies the free-text guard only when no ID-scoped duplicate exists, drops rejected candidates, and returns `{:error, first_reason}` only when every query failed. Deduplicate by `{protocol, download_url}` or `{protocol, normalized_title, size}`; merge category/origin lists with `Enum.uniq/1` and retain the first non-nil optional value in plan order.

Implement the title guard by stripping one leading `[Group]`, NFKC-normalizing/downcasing, and requiring a known title at the start with a legal trailing boundary. For free-text movies, also require exactly the context year. Keep Unicode letters; do not call the standard ASCII folding helper.

- [ ] **Step 4: Verify GREEN**

Run: `mix format && mix test test/cinder/acquisition/anime_search_test.exs test/cinder/acquisition/indexer/prowlarr_test.exs`

Expected: all bounds, failure, identity, deduplication, and Prowlarr tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/anime.ex test/cinder/acquisition/anime_search_test.exs
git commit -m "feat: add bounded anime search"
```

### Task 6: Resolve episodic candidates, select stable IDs, wait by coverage component, and freeze snapshots

**Files:**
- Modify: `lib/cinder/acquisition/anime.ex`
- Modify: `lib/cinder/acquisition.ex:60-115`
- Create: `test/cinder/acquisition/anime_selection_test.exs`
- Modify: `test/cinder/acquisition_test.exs`
- Modify: `test/support/fixtures/anime/acquisition-v1.json`

**Interfaces:**
- Produces: `Anime.best_episodes/4`, `Anime.select_episodes/4`, `Anime.build_mapping_snapshot/3`, and public `Acquisition.best_anime_releases/3`.
- Result: `{:ok, %{assignments: [map()], waiting: map() | nil}}`, `{:waiting_for_preferred_group, map()}`, `:no_match`, or `{:error, :incomplete_search}`.

- [ ] **Step 1: Add versioned end-to-end selection cases and failing tests**

Add fixture cases for:

- a standard `S01E03` single;
- absolute `25-28` resolving each value independently;
- cross-season `S01E25-S02E01` preserving order;
- one coordinate mapping to two IDs;
- an ambiguity and an outside-wanted mapping producing no automatic candidate;
- a typed-special `:unknown` and an `:extra` candidate carrying otherwise resolvable coordinates, both rejected before resolution;
- wrong-protocol and wrong-explicit-language candidates, both excluded before scoring;
- a preferred E01 single overlapping a delayed E01-E12 pack, where the full component waits;
- a complete stable-ID assignment with expected release titles and ID lists.

Each selection case contains `context`, `wanted_episode_ids`, normalized `candidates`, and `expect` with exact titles/IDs. The test converts fixture maps to the Task 4 context shape and asserts exact assignment output.

Add explicit no-op preference regressions: with `preferred_groups` absent and with `preferred_groups: []`, a hard-valid episodic candidate that has `published_at: nil` is immediately selectable and returns an assignment rather than waiting or `:no_match`.

Add direct snapshot assertions:

```elixir
assert {:ok, %{assignments: [assignment]}} =
         Anime.select_episodes([release], context, [11, 12], [])

snapshot = assignment.mapping_snapshot

assert snapshot["version"] == 1
assert snapshot["reserved_episode_ids"] == [11, 12]
assert snapshot["selected_resolution"]["episode_ids"] == [11, 12]
assert Enum.any?(snapshot["mappings"], fn mapping -> mapping["episode_ids"] == [11, 12, 13] end)
assert assignment.release.mapping_snapshot == snapshot
```

Add a separate exact full-closure builder test. Its Catalog context contains, in deterministic context order, a canonical standard mapping with membership `[11, 12]`, an absolute mapping with `[12, 13]`, a scene mapping with `[11, 14]`, a provider mapping with `[12, 15]`, and an irrelevant mapping with `[99]`. Build a snapshot for reserved IDs `[11, 12]` from a release whose selected coordinate resolves through the canonical mapping. Assert that `snapshot["mappings"]` equals the first four mappings exactly—including their structured identities, original membership order, and outside members `13`, `14`, and `15`—and excludes only the `[99]` mapping. Also assert that `selected_resolution` references only the mapping identities actually used to resolve the release coordinate. This comparison is the proof that the builder freezes the complete Catalog closure rather than only selected mappings.

Use `now: ~U[2026-07-13 12:00:00Z]` and assert the overlapping component returns all IDs and the earliest concrete `retry_at`.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `mix test test/cinder/acquisition/anime_selection_test.exs`

Expected: the selection/snapshot functions are undefined.

- [ ] **Step 3: Implement per-value resolution and stable-ID selection**

Augment each release with `AnimeParser.parse/2` and immediately retain only `role == :story`; typed specials, extras, and unknowns never reach resolution even if a matching mapping exists. Apply `opts[:protocols]` before parsing. Apply the existing `Language.filter/3` semantics before scoring: a strict explicit-language wipe yields no candidates, while a soft Original/Any wipe falls back to the protocol-filtered pool. Resolve every story value separately through `Catalog.AnimeResolver.resolve/3`; standard values receive only the canonical mapping, other values receive every same-scheme/value namespace mapping. Reject the entire release on any unmatched/ambiguous value, then ordered-deduplicate successful IDs and reject candidates containing IDs outside the wanted set.

Use the existing language module rather than creating policy in Anime:

```elixir
defp language_pool(candidates, opts) do
  preferred = Keyword.get(opts, :preferred_language)
  original = Keyword.get(opts, :original_language)

  case Language.filter(candidates, preferred, original) do
    [] when candidates != [] -> if Language.strict?(preferred), do: [], else: candidates
    filtered -> filtered
  end
end
```

Call `Scorer.select_for_ids/3` for eligible candidates. `build_mapping_snapshot/3` filters the complete, deterministically ordered `context.mappings` universe by non-empty intersection with the reserved-ID set; it copies every retained mapping's full ordered membership and structured identity, including alternative schemes and outside members, while constructing `selected_resolution` solely from the mappings referenced during release-coordinate resolution. Convert tuples to assignments by building one snapshot per assigned release and setting the same snapshot on both the assignment and release struct:

```elixir
snapshot = build_mapping_snapshot(release, assigned_ids, context)
marked = %{release | mapping_snapshot: snapshot}
%{release: marked, episode_ids: assigned_ids, mapping_snapshot: snapshot}
```

If `failed?` is true and assignments plus protected waiting IDs do not cover the entire wanted set, return `{:error, :incomplete_search}`.

Expose the feature through the existing public context without wiring the TV poller:

```elixir
def best_anime_releases(context, wanted_episode_ids, opts \\ []) do
  Anime.best_episodes(indexer(), context, wanted_episode_ids, opts)
end
```

- [ ] **Step 4: Implement component-aware preferred-group waiting**

Normalize preferred groups with `String.trim/1` and `String.downcase/1`. When the normalized preferred-group list is empty—whether the option is absent or explicitly `[]`—disable waiting policy and make every hard-valid candidate immediately eligible, including candidates with missing `published_at`. Only when at least one preferred group is configured are preferred candidates eligible now, non-preferred candidates with valid `published_at` eligible at `DateTime.add(published_at, fallback_delay, :second)`, and missing timestamps excluded from automatic selection and waiting.

Build the hard-valid pool by retaining candidates for which `Scorer.select_for_ids([candidate], wanted_ids, opts)` returns `{:ok, _}`. Build overlap components with a small MapSet flood-fill over that pool. For each component, call `Scorer.select_for_ids/3` on eligible candidates and compare the union of assigned IDs with the entire component. If eligible assignments do not cover the component and a delayed candidate overlaps an uncovered ID, protect the full component and use the earliest delayed eligibility. Keep independent complete components assignable.

Return exactly:

```elixir
{:ok, %{assignments: assignments, waiting: nil}}
{:ok, %{assignments: assignments, waiting: %{episode_ids: ids, retry_at: retry_at}}}
{:waiting_for_preferred_group, %{episode_ids: ids, retry_at: retry_at}}
```

- [ ] **Step 5: Verify GREEN and corpus coverage**

Run: `mix format && mix test test/cinder/acquisition/anime_selection_test.exs test/cinder/acquisition/anime_parser_test.exs test/cinder/acquisition/scorer_test.exs`

Expected: every versioned parser/selection case, waiting case, and scorer regression passes.

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/acquisition/anime.ex lib/cinder/acquisition.ex test/cinder/acquisition/anime_selection_test.exs test/cinder/acquisition_test.exs test/support/fixtures/anime/acquisition-v1.json
git commit -m "feat: select anime episodes by stable id"
```

### Task 7: Activate anime movie selection only

**Files:**
- Modify: `lib/cinder/acquisition.ex:28-63`
- Modify: `lib/cinder/download.ex:624-666`
- Modify: `test/cinder/acquisition_test.exs:1-290`
- Modify: `test/cinder/download_test.exs:1-220`

**Interfaces:**
- Produces: `Acquisition.best_anime_movie/3` and the anime branch in `Download.start/1`.
- Keeps: production movie selection passes no preferred groups; episodic `TvPoller` still calls standard `best_releases/4`.

- [ ] **Step 1: Write failing movie integration and Standard regression tests**

Create an Anime movie with a stored alias. Expect one IMDb search plus category queries, return only the alias result, and assert `Download.start/1` submits it through the existing client path. Add a Standard movie test with `reject/3` for both free-text callbacks and one expected `search/1` call.

Add a pure movie waiting test:

```elixir
assert {:waiting_for_preferred_group, %{retry_at: ~U[2026-07-14 12:00:00Z]}} =
         Anime.select_movie([fallback], preferred_groups: ["Trusted"], fallback_delay: 86_400,
           now: ~U[2026-07-13 12:00:00Z])

assert Repo.reload(movie).search_attempts == 0
```

Also assert that the same hard-valid movie fallback with `published_at: nil` is selected immediately both when `preferred_groups` is absent and when it is explicitly `[]`; production intentionally supplies no preferred groups.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `mix test test/cinder/acquisition_test.exs test/cinder/download_test.exs`

Expected: anime movie API/branch is missing and the alias-only candidate is not selected.

- [ ] **Step 3: Share standard movie pooling and add the anime wrapper**

Extract the existing raw-results-to-language-pool logic in `Acquisition` into a private helper used by both paths. Add:

```elixir
def best_anime_movie(imdb_id, context, opts \\ []) do
  with {:ok, releases, failed?} <- Anime.search_movie(indexer(), imdb_id, context, opts) do
    case movie_pool(releases, opts) do
      :no_language_match -> :no_language_match
      pool -> Anime.select_movie(pool, Keyword.put(opts, :incomplete_search?, failed?))
    end
  end
end
```

`Anime.select_movie/2` first retains candidates whose `Scorer.verdict/2` is `:ok`, then applies preferred-group eligibility and calls `Scorer.select/2`. An unusable fallback therefore cannot create waiting. It returns `{:error, :incomplete_search}` instead of `:no_match` when the flag is true.

In `Download.do_start/1`, compute the same scorer opts as today and choose only the selector:

```elixir
result =
  case Catalog.media_profile_summary(movie).effective do
    :anime ->
      context = Catalog.anime_movie_acquisition_context(movie)
      Acquisition.best_anime_movie(imdb_id, context, opts)

    :standard ->
      Acquisition.best_release(imdb_id, opts)
  end
```

Keep the existing success/no-match/language/error handling below the selection call unchanged. Do not add `Download.start/2`, scheduler state, or preferred-group production options.

- [ ] **Step 4: Verify GREEN and movie poller regressions**

Run: `mix format && mix test test/cinder/acquisition_test.exs test/cinder/download_test.exs test/cinder/download/poller_test.exs`

Expected: Anime alias selection works, Standard uses only IMDb, advisory waiting writes no attempts, and existing poller tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition.ex lib/cinder/download.ex test/cinder/acquisition_test.exs test/cinder/download_test.exs
git commit -m "feat: select anime movie releases"
```

### Task 8: Persist and validate immutable episodic mapping snapshots

**Files:**
- Create: `priv/repo/migrations/20260713120000_add_mapping_snapshot_to_download_intents.exs`
- Modify: `lib/cinder/download/intent.ex:8-47`
- Modify: `lib/cinder/download.ex:30-65`
- Modify: `test/cinder/download/intent_test.exs`

**Interfaces:**
- Produces: nullable `Intent.mapping_snapshot`, `Intent.reservation_changeset/2`, and snapshot-preserving `Download.reserve_intent/1`.
- Standard intents continue to store `nil`.

- [ ] **Step 1: Write failing migration, structural validation, restart, and immutability tests**

Reserve an episodic marked release with a valid snapshot, reload the Intent from Repo, mutate/delete the Catalog coordinate, reload again, and assert the snapshot is byte-for-byte equal. Assert the episode links remain authoritative. Add invalid cases for movie snapshots, reserved-ID mismatch, non-integer IDs, an empty `mapping_identities` list for a selected value, missing identity references, duplicate identity references, a mapping with no reserved intersection, missing closure coverage, selected scheme/value/precedence/ordered-ID mismatch against its referenced mapping, an omitted parsed coordinate value, a duplicated selected coordinate value, a selected coordinate not present in `release.coordinates`, and concatenated selected values not equalling `selected_resolution.episode_ids`. Assert an update through either `Intent.changeset/2` or `Intent.reservation_changeset/2` cannot replace a persisted snapshot.

The valid reservation call is:

```elixir
assert {:ok, intent} =
         Download.reserve_intent(%{
           kind: :season_pack,
           target_id: first.id,
           episode_ids: [first.id, second.id],
           protocol: :torrent,
           release: marked_release,
           mapping_snapshot: snapshot
         })

assert Repo.reload(intent).mapping_snapshot == snapshot
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `mix test test/cinder/download/intent_test.exs`

Expected: the column/field/reservation validation does not exist.

- [ ] **Step 3: Add the migration and reservation-only changeset**

Migration:

```elixir
defmodule Cinder.Repo.Migrations.AddMappingSnapshotToDownloadIntents do
  use Ecto.Migration

  def change do
    alter table(:download_intents) do
      add :mapping_snapshot, :map
    end
  end
end
```

Add `field :mapping_snapshot, :map` to Intent. Keep `changeset/2` from casting it. Add `reservation_changeset/2` that starts with `changeset/2`, casts only `:mapping_snapshot`, and validates the exact version-1 structure and ownership invariants from the spec. The validator may prove structural closure only; completeness against Catalog is already tested at `Anime.build_mapping_snapshot/3`.

Use this changeset seam and return `{:error, :invalid_mapping_snapshot}` from `Download.reserve_intent/1` when marker equality or structure fails:

```elixir
def reservation_changeset(%__MODULE__{id: nil} = intent, attrs) do
  changeset = intent |> changeset(attrs) |> cast(attrs, [:mapping_snapshot])
  kind = get_field(changeset, :kind)
  episode_ids = get_field(changeset, :episode_ids)

  validate_change(changeset, :mapping_snapshot, fn :mapping_snapshot, snapshot ->
    if valid_snapshot?(snapshot, kind, episode_ids),
      do: [],
      else: [mapping_snapshot: "is invalid"]
  end)
end

def reservation_changeset(%__MODULE__{} = intent, _attrs) do
  intent
  |> changeset(%{})
  |> add_error(:mapping_snapshot, "is immutable")
end
```

Implement `valid_snapshot?/3` with pattern matching plus `Enum.all?/2`/`MapSet`: version equals 1; reserved IDs are non-empty positive integers and exactly equal the intent IDs and selected-resolution IDs; every mapping has a structured identity and non-empty positive integer IDs intersecting the reservation; and the union of mapping IDs covers every reserved ID. For every selected value, require a non-empty list of unique structured `mapping_identities`; require its scheme/value/precedence/ordered IDs to equal every referenced mapping; and require every structured identity to exist in `mappings`. Expand `release.coordinates` in parser order to the ordered list of every `{scheme, value}` pair and require exact equality with the full ordered `{scheme, value}` sequence in `selected_resolution.values`; membership-only checking is insufficient because it permits omitted or duplicated coordinate values. Finally, require the ordered first-seen union of per-value IDs to equal `selected_resolution.episode_ids`. Return false for movie snapshots and malformed containers. Outside mapping members remain valid evidence.

Change only `insert_reserved_intent/1` to use `Intent.reservation_changeset/2`. In `reserve_intent/1`, require `Map.get(attrs, :mapping_snapshot) == release.mapping_snapshot`, copy it into `intent_attrs`, and return `{:error, :invalid_mapping_snapshot}` before Repo/client work when the marker is missing or differs. Extend `normalize_reservation/1` so a changeset carrying a `:mapping_snapshot` error becomes the same explicit error instead of `:download_intent_busy`. Standard nil/nil reservations remain valid.

- [ ] **Step 4: Verify GREEN and standard intent regressions**

Run: `mix format && mix test test/cinder/download/intent_test.exs test/cinder/download_test.exs`

Expected: snapshot validation/reload/immutability tests pass and every standard intent test remains green.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260713120000_add_mapping_snapshot_to_download_intents.exs lib/cinder/download/intent.ex lib/cinder/download.ex test/cinder/download/intent_test.exs
git commit -m "feat: persist anime intent snapshots"
```

### Task 9: Enforce the A2/A3 safety hold at every Download side-effect entry point

**Files:**
- Modify: `lib/cinder/download.ex:88-220`
- Modify: `test/cinder/download/intent_test.exs`
- Modify: `test/cinder/download/tv_poller_test.exs`

**Interfaces:**
- Produces: `{:error, :anime_import_not_ready}` from marked `grab_episodes/2`, snapshot-bearing `submit_intent/1`, and `reconcile_intent/1`.
- Cleanup intents remain operable; `reconcile_pending_intents/1` excludes held episodic intents.

- [ ] **Step 1: Write failing direct-entry and real-poller safety tests**

For a release carrying any non-nil mapping marker, assert `grab_episodes/2` returns the hold before any Intent row exists. Create a matching existing snapshot-free intent, pass a same-release struct with a malformed non-map marker such as `"invalid"`, and prove the hold occurs before intent reconciliation with zero client calls. For a reserved snapshot intent, expect zero `find_by_operation_key/1` and `add/1` client calls, then assert both direct public calls return the hold and the row/links are unchanged.

Start a real `TvPoller` test process with the reserved intent, stub the standard `search_tv/3` path, run `TvPoller.poll/1`, and assert:

```elixir
assert Repo.get!(Intent, intent.id).mapping_snapshot == snapshot
assert Repo.aggregate(Grab, :count) == 0
assert Repo.reload(first).grab_id == nil
assert Repo.reload(first).search_attempts == 0
```

Also mark the intent `:cleanup_pending` with a remote ID, expect the client removal callback, and prove cleanup still deletes it.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `mix test test/cinder/download/intent_test.exs test/cinder/download/tv_poller_test.exs`

Expected: at least one marked entry point reaches client/grab work or loses the snapshot.

- [ ] **Step 3: Add one shared guard plus the two necessary outer guards**

Add the earliest `grab_episodes/2` clause. It must hold every non-nil marker, including malformed markers, before looking up an overlapping intent:

```elixir
def grab_episodes(%Release{mapping_snapshot: snapshot}, _episode_ids) when not is_nil(snapshot),
  do: {:error, :anime_import_not_ready}
```

Place the cleanup clause first in reconciliation, then the snapshot hold. Place the snapshot hold before the already-submitted clause in `do_submit_intent/1` so direct submission cannot bypass it:

```elixir
defp do_submit_intent(%Intent{mapping_snapshot: snapshot, kind: kind})
     when kind in [:episode, :season_pack] and not is_nil(snapshot),
     do: {:error, :anime_import_not_ready}

defp do_reconcile_intent(%Intent{status: :cleanup_pending} = intent), do: do_cleanup(intent)

defp do_reconcile_intent(%Intent{mapping_snapshot: snapshot, kind: kind})
     when kind in [:episode, :season_pack] and not is_nil(snapshot),
     do: {:error, :anime_import_not_ready}
```

Filter held rows out of `reconcile_pending_intents/1` at the query boundary while retaining cleanup rows and nil-snapshot intents:

```elixir
intents =
  Repo.all(
    from i in Intent,
      where:
        i.kind in ^kinds and
          (i.status == :cleanup_pending or is_nil(i.mapping_snapshot)),
      order_by: [asc: i.id]
  )
```

Do not add a status, flag, scheduler, or A3 grab column.

- [ ] **Step 4: Verify GREEN and all Download regressions**

Run: `mix format && mix test test/cinder/download/intent_test.exs test/cinder/download/tv_poller_test.exs test/cinder/download_test.exs test/cinder/download/poller_test.exs`

Expected: all safety paths stop before side effects, cleanup works, and standard movie/TV downloading remains green.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/download.ex test/cinder/download/intent_test.exs test/cinder/download/tv_poller_test.exs
git commit -m "feat: hold anime intents until safe import"
```

### Task 10: Prove the phase gate, update the roadmap, and refresh the graph

**Files:**
- Modify: `ROADMAP.md:796-802`
- Update mechanically: `graphify-out/`

**Interfaces:**
- Consumes: every A2 task and its focused regression tests.
- Produces: the A2 completion record and a current knowledge graph.

- [ ] **Step 1: Run the complete repository gate before claiming A2**

Run: `mix format && mix test`

Expected: exit 0 with compile warnings-as-errors, formatting, Credo strict, and the complete ExUnit suite passing.

- [ ] **Step 2: Re-read the spec Done-when list against tests**

Run:

```bash
rg -n "A2|Done when|phase == \"A2\"|acquisition-v1|anime_import_not_ready|waiting_for_preferred_group" ROADMAP.md docs/superpowers/specs/2026-07-13-a2-anime-acquisition-design.md test lib
```

Expected: each design requirement has a production seam and a focused test; no A3 import activation exists.

- [ ] **Step 3: Refresh graphify and inspect the resulting diff**

Run: `graphify update . && git status --short && git diff --stat`

Expected: graph update exits 0 and only A2-related graph output is modified.

- [ ] **Step 4: Mark A2 complete only after the gate is green**

Append beneath the A2 roadmap paragraph:

```markdown
**[done 2026-07-13]** Added bounded provider-ID plus alias/category anime searches, Unicode-safe
context parsing, stable-ID set cover, Anime movie activation, options-only preferred-group waiting,
and immutable episodic intent snapshots. Snapshot-bearing episodic work remains held before every
downloader/grab side effect until A3 provides exact preflight and mapping recovery. The versioned A2
acquisition corpus and full `mix test` gate pass without changing Standard movie/TV selection.
```

- [ ] **Step 5: Run the final fresh verification after roadmap/graph changes**

Run: `mix test && git diff --check && git status --short`

Expected: exit 0, no whitespace errors, and only the intended roadmap/graph changes remain.

- [ ] **Step 6: Commit the phase boundary**

```bash
git add ROADMAP.md graphify-out
git commit -m "docs: complete A2 anime acquisition"
```

## Execution Choice

The user delegated execution strategy. Use inline execution with `superpowers:executing-plans` in this branch because implementation subagent delegation was not requested. Keep each task's red/green evidence in the running commentary, and stop if a test exposes a spec contradiction rather than silently changing the contract.
