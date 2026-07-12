# A0 Anime Corpus and Provider Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a versioned anime corpus and a read-only, sanitized probe that decides whether TMDB and the configured Prowlarr satisfy A0 before any anime schema or acquisition work begins.

**Architecture:** Keep A0 outside the production contexts. A development Mix task reads a source-controlled JSON corpus, calls raw TMDB/Prowlarr contract endpoints through a bounded Req helper using the existing in-app configuration, reduces responses to an explicit allowlist, and emits deterministic JSON plus Markdown evidence. A pure report module evaluates discovery, episode-group, specials, and Prowlarr-field requirements and records the provider gate for A1.

**Tech Stack:** Elixir, Mix, Req, Jason, `Cinder.HTTPPolicy`, ExUnit, Req.Test, SQLite-backed Settings bootstrap.

## Global Constraints

- Implement A0 only; do not add anime schemas, profile fields, provider behaviours, parser changes, scoring changes, or acquisition behavior.
- Add no dependency and no environment variable. Read the existing `Cinder.Catalog.TMDB.HTTP` and `Cinder.Acquisition.Indexer.Prowlarr` application configuration after `app.start`.
- The live probe is read-only: TMDB search/details/alternative-title/episode-group GETs and Prowlarr search GETs only.
- Tests never hit a network; route every provider call through Req.Test.
- Apply `redirect: false`, 15-second receive/connect bounds, and `Cinder.HTTPPolicy.bounded_request/2` with a 4 MiB response limit.
- Generated artifacts may contain release titles, sizes, protocols, category IDs/names, publication
  timestamps, a derived `has_indexer_identity` boolean, and fixed official-documentation links.
  They must never contain credentials, request headers, provider-returned download/magnet/source
  URLs, indexer IDs/names, cookies, or raw response bodies.
- TMDB group type `2` means Absolute. Prowlarr anime category `5070` is probed in addition to the uncategorized query.
- The corpus is versioned. Every must-support query has an exact TMDB ID and explicit capability assertions, and every future parser/resolver/preflight/snapshot behavior has an expected outcome recorded before implementation.
- A1 cannot begin until the generated report records `a0_status: pass`; metadata-provider choice alone is insufficient when Prowlarr contract gaps remain.
- End each implementation task with focused tests, `mix format`, and a repository-native commit. Run the full `mix test` gate and `graphify update .` before closing A0.

## File Structure

**Create**

- `test/support/fixtures/anime/corpus-v1.json` — versioned provider inputs plus exact future behavior and safe-stop contracts.
- `lib/mix/tasks/cinder.anime.probe/corpus.ex` — strict corpus loading and validation.
- `lib/mix/tasks/cinder.anime.probe/http.ex` — bounded, read-only TMDB/Prowlarr calls with allowlisted normalization.
- `lib/mix/tasks/cinder.anime.probe/report.ex` — pure requirement evaluation, provider recommendation, JSON/Markdown rendering.
- `lib/mix/tasks/cinder.anime.probe.ex` — CLI orchestration and atomic artifact writes.
- `test/mix/tasks/cinder_anime_probe/corpus_test.exs` — corpus contract coverage.
- `test/mix/tasks/cinder_anime_probe/http_test.exs` — provider request and sanitization coverage.
- `test/mix/tasks/cinder_anime_probe/report_test.exs` — deterministic gate/recommendation coverage.
- `test/mix/tasks/cinder_anime_probe_test.exs` — end-to-end CLI coverage with Req.Test.
- `docs/audits/data/anime-provider-contracts-v1.json` — generated sanitized live evidence.
- `docs/audits/2026-07-12-anime-provider-contracts.md` — generated human-readable gate report.

**Modify only after the live probe**

- `ROADMAP.md` — record the A0 result and the exact A1 gate.

---

### Task 1: Lock the versioned corpus contract

**Files:**
- Create: `test/support/fixtures/anime/corpus-v1.json`
- Create: `lib/mix/tasks/cinder.anime.probe/corpus.ex`
- Test: `test/mix/tasks/cinder_anime_probe/corpus_test.exs`

**Interfaces:**
- Produces: `Mix.Tasks.Cinder.Anime.Probe.Corpus.load!/1 :: map()`.
- Produces: a normalized map with atom keys `:version`, `:titles`, and `:behavior_contracts`; every title has atom keys `:slug`, `:kind`, `:tmdb_id`, `:discovery_queries`, `:prowlarr_queries`, and `:expect`; every behavior contract has `:id`, `:phase`, `:kind`, `:input`, and `:expect`.
- Raises: `ArgumentError` with `invalid anime corpus: <reason>` for malformed, duplicate, or incomplete inputs.

- [ ] **Step 1: Write failing corpus tests**

```elixir
defmodule Mix.Tasks.Cinder.Anime.Probe.CorpusTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cinder.Anime.Probe.Corpus

  @corpus "test/support/fixtures/anime/corpus-v1.json"

  test "loads the complete v1 must-support corpus" do
    corpus = Corpus.load!(@corpus)

    assert corpus.version == 1
    assert Enum.map(corpus.titles, & &1.slug) == [
             "one-piece",
             "bleach",
             "attack-on-titan",
             "re-zero",
             "pokemon",
             "demon-slayer",
             "your-name"
           ]

    assert Enum.find(corpus.titles, &(&1.slug == "one-piece")).expect == %{
             min_discovery_hits: 3,
             required_group_types: [2],
             min_absolute_entries: 1_000,
             require_specials: true
           }

    assert length(corpus.behavior_contracts) == 24
    assert Enum.any?(corpus.behavior_contracts, &(&1.id == "absolute-over-999-v2-crc"))
    assert Enum.any?(corpus.behavior_contracts, &(&1.id == "unknown-video-needs-mapping"))
    assert Enum.any?(corpus.behavior_contracts, &(&1.id == "provider-renumbering-preserves-active-work"))
  end

  @tag :tmp_dir
  test "rejects incomplete requirements", %{tmp_dir: tmp} do
    path = Path.join(tmp, "bad.json")
    corpus = @corpus |> File.read!() |> Jason.decode!()
    File.write!(path, Jason.encode!(%{corpus | "titles" => [%{"slug" => "x"}]}))

    assert_raise ArgumentError, ~r/invalid anime corpus/, fn -> Corpus.load!(path) end
  end

  @tag :tmp_dir
  test "rejects duplicate slugs", %{tmp_dir: tmp} do
    corpus = @corpus |> File.read!() |> Jason.decode!()
    title = hd(corpus["titles"])
    path = Path.join(tmp, "duplicate.json")
    File.write!(path, Jason.encode!(%{corpus | "titles" => [title, title]}))

    assert_raise ArgumentError, ~r/duplicate slug/, fn -> Corpus.load!(path) end
  end

  @tag :tmp_dir
  test "rejects a missing behavior contract", %{tmp_dir: tmp} do
    corpus = @corpus |> File.read!() |> Jason.decode!()
    path = Path.join(tmp, "missing-behavior.json")

    File.write!(
      path,
      Jason.encode!(%{corpus | "behavior_contracts" => tl(corpus["behavior_contracts"])})
    )

    assert_raise ArgumentError, ~r/missing, fn -> Corpus.load!(path) end
  end
end
```

- [ ] **Step 2: Run the test and prove the loader is absent**

Run: `direnv exec . mix test test/mix/tasks/cinder_anime_probe/corpus_test.exs`

Expected: FAIL because `Mix.Tasks.Cinder.Anime.Probe.Corpus` is undefined.

- [ ] **Step 3: Add the exact corpus**

Create `test/support/fixtures/anime/corpus-v1.json`:

```json
{
  "version": 1,
  "titles": [
    {
      "slug": "one-piece",
      "kind": "tv",
      "tmdb_id": 37854,
      "discovery_queries": ["One Piece", "ONE PIECE", "ワンピース"],
      "prowlarr_queries": ["One Piece", "One Piece 1122"],
      "expect": {"min_discovery_hits": 3, "required_group_types": [2], "min_absolute_entries": 1000, "require_specials": true}
    },
    {
      "slug": "bleach",
      "kind": "tv",
      "tmdb_id": 30984,
      "discovery_queries": ["Bleach", "BLEACH", "ブリーチ"],
      "prowlarr_queries": ["Bleach", "Bleach 366"],
      "expect": {"min_discovery_hits": 3, "required_group_types": [2], "min_absolute_entries": 366, "require_specials": true}
    },
    {
      "slug": "attack-on-titan",
      "kind": "tv",
      "tmdb_id": 1429,
      "discovery_queries": ["Attack on Titan", "Shingeki no Kyojin", "進撃の巨人"],
      "prowlarr_queries": ["Attack on Titan", "Shingeki no Kyojin"],
      "expect": {"min_discovery_hits": 3, "required_group_types": [], "min_absolute_entries": 0, "require_specials": true}
    },
    {
      "slug": "re-zero",
      "kind": "tv",
      "tmdb_id": 65942,
      "discovery_queries": ["Re:ZERO -Starting Life in Another World-", "Re Zero", "Re:ゼロから始める異世界生活"],
      "prowlarr_queries": ["Re Zero", "Re Zero Season 2"],
      "expect": {"min_discovery_hits": 3, "required_group_types": [], "min_absolute_entries": 0, "require_specials": true}
    },
    {
      "slug": "pokemon",
      "kind": "tv",
      "tmdb_id": 60572,
      "discovery_queries": ["Pokémon", "Pokemon", "ポケットモンスター"],
      "prowlarr_queries": ["Pokemon", "Pocket Monsters"],
      "expect": {"min_discovery_hits": 3, "required_group_types": [], "min_absolute_entries": 0, "require_specials": true}
    },
    {
      "slug": "demon-slayer",
      "kind": "tv",
      "tmdb_id": 85937,
      "discovery_queries": ["Demon Slayer: Kimetsu no Yaiba", "Kimetsu no Yaiba", "鬼滅の刃"],
      "prowlarr_queries": ["Demon Slayer", "Kimetsu no Yaiba"],
      "expect": {"min_discovery_hits": 3, "required_group_types": [], "min_absolute_entries": 0, "require_specials": false}
    },
    {
      "slug": "your-name",
      "kind": "movie",
      "tmdb_id": 372058,
      "discovery_queries": ["Your Name.", "Kimi no Na wa.", "君の名は。"],
      "prowlarr_queries": ["Your Name 2016", "Kimi no Na wa"],
      "expect": {"min_discovery_hits": 3, "required_group_types": [], "min_absolute_entries": 0, "require_specials": false}
    }
  ],
  "behavior_contracts": [
    {"id":"ordinary-cour-sxxeyy","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Demon Slayer - S01E03 [1080p]"},"expect":{"coordinates":[{"scheme":"standard","values":["S01E03"]}],"role":"story","outcome":"candidates"}},
    {"id":"absolute-over-99","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Bleach - 366 [1080p]"},"expect":{"coordinates":[{"scheme":"absolute","values":["366"]}],"role":"story","outcome":"candidates"}},
    {"id":"absolute-over-999-v2-crc","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[SubsPlease] One Piece - 1122v2 (1080p) [ABCDEF01]"},"expect":{"coordinates":[{"scheme":"absolute","values":["1122"]}],"role":"story","outcome":"candidates"}},
    {"id":"split-cour-absolute-range","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Re Zero - 25-28 [1080p]"},"expect":{"coordinates":[{"scheme":"absolute","values":["25","26","27","28"]}],"role":"story","outcome":"candidates"}},
    {"id":"cross-season-batch","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Attack on Titan S01E25-S02E01 [1080p]"},"expect":{"coordinates":[{"scheme":"standard","values":["S01E25","S02E01"]}],"role":"story","outcome":"candidates"}},
    {"id":"dual-audio-dub-ass-markers","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Demon Slayer - 07 [Dual Audio][ENG Dub][ASS][1080p]"},"expect":{"coordinates":[{"scheme":"absolute","values":["7"]}],"role":"story","outcome":"candidates"}},
    {"id":"ova-typed-special","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Show OVA 1 [1080p]"},"expect":{"coordinates":[{"scheme":"typed_special","values":["OVA:1"]}],"role":"unknown","outcome":"candidates"}},
    {"id":"ona-not-automatically-special","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Show ONA 1 [1080p]"},"expect":{"coordinates":[{"scheme":"typed_special","values":["ONA:1"]}],"role":"unknown","outcome":"candidates"}},
    {"id":"recap-is-story-candidate","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Show Recap [1080p]"},"expect":{"coordinates":[{"scheme":"typed_special","values":["RECAP"]}],"role":"unknown","outcome":"candidates"}},
    {"id":"episode-zero","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Show - Episode 0 [1080p]"},"expect":{"coordinates":[{"scheme":"typed_special","values":["EPISODE:0"]}],"role":"unknown","outcome":"candidates"}},
    {"id":"ncop-extra","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Show NCOP [1080p]"},"expect":{"coordinates":[],"role":"extra","outcome":"ignore_extra"}},
    {"id":"nced-extra","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Show NCED [1080p]"},"expect":{"coordinates":[],"role":"extra","outcome":"ignore_extra"}},
    {"id":"trailer-extra","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Show Trailer 2 [1080p]"},"expect":{"coordinates":[],"role":"extra","outcome":"ignore_extra"}},
    {"id":"ambiguous-bare-number","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] 86 - 2024 [1080p] [ABCDEF01]"},"expect":{"coordinates":[],"role":"unknown","outcome":"unmatched"}},
    {"id":"anime-movie-release","phase":"A2","kind":"release","input":{"media_profile":"anime","title":"[Group] Your Name (2016) [Dual Audio][1080p]"},"expect":{"coordinates":[],"role":"story","outcome":"movie_candidate"}},
    {"id":"coordinate-to-many","phase":"A1","kind":"resolver","input":{"coordinates":["fixture:absolute:12"],"memberships":{"fixture:absolute:12":["episode-a","episode-b"]}},"expect":{"episode_keys":["episode-a","episode-b"],"outcome":"resolved"}},
    {"id":"coordinates-to-one","phase":"A1","kind":"resolver","input":{"coordinates":["fixture:absolute:12","fixture:standard:S01E12"],"memberships":{"fixture:absolute:12":["episode-a"],"fixture:standard:S01E12":["episode-a"]}},"expect":{"episode_keys":["episode-a"],"outcome":"resolved"}},
    {"id":"unknown-video-needs-mapping","phase":"A3","kind":"preflight","input":{"videos":["mystery.mkv"],"reserved":["episode-a"],"mappings":{}},"expect":{"reason":"unknown_video","outcome":"needs_mapping"}},
    {"id":"duplicate-target-needs-mapping","phase":"A3","kind":"preflight","input":{"videos":["a.mkv","b.mkv"],"reserved":["episode-a"],"mappings":{"a.mkv":["episode-a"],"b.mkv":["episode-a"]}},"expect":{"reason":"duplicate_target","outcome":"needs_mapping"}},
    {"id":"outside-reservation-needs-mapping","phase":"A3","kind":"preflight","input":{"videos":["a.mkv"],"reserved":["episode-a"],"mappings":{"a.mkv":["episode-b"]}},"expect":{"reason":"outside_reservation","outcome":"needs_mapping"}},
    {"id":"explicit-extra-can-ignore","phase":"A3","kind":"preflight","input":{"videos":["story.mkv","NCOP.mkv"],"reserved":["episode-a"],"mappings":{"story.mkv":["episode-a"],"NCOP.mkv":"ignore_extra"}},"expect":{"outcome":"ready"}},
    {"id":"sidecar-does-not-count-as-video","phase":"A3","kind":"preflight","input":{"videos":["story.mkv"],"sidecars":["story.ass"],"reserved":["episode-a"],"mappings":{"story.mkv":["episode-a"]}},"expect":{"outcome":"ready"}},
    {"id":"ambiguous-coordinate-needs-mapping","phase":"A1","kind":"resolver","input":{"coordinates":["fixture:absolute:12","fixture:scene:12"],"memberships":{"fixture:absolute:12":["episode-a"],"fixture:scene:12":["episode-b"]}},"expect":{"outcome":"ambiguous"}},
    {"id":"provider-renumbering-preserves-active-work","phase":"A1","kind":"snapshot","input":{"coordinate":"fixture:absolute:12","snapshot_episode_keys":["episode-a"],"refreshed_episode_keys":["episode-b"]},"expect":{"active_episode_keys":["episode-a"],"future_episode_keys":["episode-b"]}}
  ]
}
```

These 24 contracts are expectation data, not executable anime logic in A0. Later phases consume the relevant `phase` subset and turn each record into a passing test. A0 validates and publishes the inventory without claiming those future behaviors are implemented.

- [ ] **Step 4: Implement strict loading**

In `corpus.ex`, decode with `Jason.decode!/1`, recursively atomize only the known keys above, and validate:

```elixir
defmodule Mix.Tasks.Cinder.Anime.Probe.Corpus do
  @moduledoc false

  @kinds ["tv", "movie"]
  @expect_keys ~w(min_discovery_hits required_group_types min_absolute_entries require_specials)
  @behavior_kinds ~w(release resolver preflight snapshot)
  @behavior_phases ~w(A1 A2 A3)
  @behavior_keys ~w(id phase kind input expect)
  @required_behavior_ids ~w(
    ordinary-cour-sxxeyy absolute-over-99 absolute-over-999-v2-crc
    split-cour-absolute-range cross-season-batch dual-audio-dub-ass-markers
    ova-typed-special ona-not-automatically-special recap-is-story-candidate episode-zero
    ncop-extra nced-extra trailer-extra ambiguous-bare-number anime-movie-release coordinate-to-many
    coordinates-to-one unknown-video-needs-mapping duplicate-target-needs-mapping
    outside-reservation-needs-mapping explicit-extra-can-ignore sidecar-does-not-count-as-video
    ambiguous-coordinate-needs-mapping provider-renumbering-preserves-active-work
  )

  def load!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> normalize!()
  rescue
    error in [Jason.DecodeError, KeyError, ArgumentError] ->
      raise ArgumentError, "invalid anime corpus: #{Exception.message(error)}"
  end

  defp normalize!(%{
         "version" => 1,
         "titles" => titles,
         "behavior_contracts" => behavior_contracts
       })
       when is_list(titles) and titles != [] and is_list(behavior_contracts) do
    normalized = Enum.map(titles, &title!/1)
    slugs = Enum.map(normalized, & &1.slug)
    if Enum.uniq(slugs) != slugs, do: raise(ArgumentError, "duplicate slug")

    behaviors = Enum.map(behavior_contracts, &behavior!/1)
    ids = Enum.map(behaviors, & &1.id)

    unless Enum.sort(ids) == Enum.sort(@required_behavior_ids),
      do: raise(ArgumentError, "missing, duplicate, or unknown behavior contract")

    %{version: 1, titles: normalized, behavior_contracts: behaviors}
  end

  defp normalize!(_),
    do: raise(ArgumentError, "expected v1 titles and behavior contracts")

  defp title!(%{
         "slug" => slug,
         "kind" => kind,
         "tmdb_id" => tmdb_id,
         "discovery_queries" => discovery,
         "prowlarr_queries" => prowlarr,
         "expect" => expect
       })
       when is_binary(slug) and kind in @kinds and is_integer(tmdb_id) and tmdb_id > 0 and
              is_list(discovery) and discovery != [] and is_list(prowlarr) and prowlarr != [] and
              is_map(expect) do
    unless Enum.all?(discovery ++ prowlarr, &(is_binary(&1) and &1 != "")),
      do: raise(ArgumentError, "blank query for #{slug}")

    unless Enum.sort(Map.keys(expect)) == Enum.sort(@expect_keys),
      do: raise(ArgumentError, "invalid expectations for #{slug}")

    min_discovery_hits = positive_integer!(expect["min_discovery_hits"])

    if min_discovery_hits > length(discovery),
      do: raise(ArgumentError, "min_discovery_hits exceeds queries for #{slug}")

    %{
      slug: slug,
      kind: kind_atom(kind),
      tmdb_id: tmdb_id,
      discovery_queries: discovery,
      prowlarr_queries: prowlarr,
      expect: %{
        min_discovery_hits: min_discovery_hits,
        required_group_types: integer_list!(expect["required_group_types"]),
        min_absolute_entries: non_negative_integer!(expect["min_absolute_entries"]),
        require_specials: boolean!(expect["require_specials"])
      }
    }
  end

  defp title!(_), do: raise(ArgumentError, "incomplete title")

  defp behavior!(%{
         "id" => id,
         "phase" => phase,
         "kind" => kind,
         "input" => input,
         "expect" => expect
       } = behavior)
       when is_binary(id) and phase in @behavior_phases and kind in @behavior_kinds and
              is_map(input) and map_size(input) > 0 and is_map(expect) and map_size(expect) > 0 do
    unless Enum.sort(Map.keys(behavior)) == Enum.sort(@behavior_keys),
      do: raise(ArgumentError, "invalid behavior contract #{id}")

    %{id: id, phase: phase, kind: kind, input: input, expect: expect}
  end

  defp behavior!(_), do: raise(ArgumentError, "incomplete behavior contract")

  defp kind_atom("tv"), do: :tv
  defp kind_atom("movie"), do: :movie
  defp positive_integer!(n) when is_integer(n) and n > 0, do: n
  defp positive_integer!(_), do: raise(ArgumentError, "expected positive integer")
  defp non_negative_integer!(n) when is_integer(n) and n >= 0, do: n
  defp non_negative_integer!(_), do: raise(ArgumentError, "expected non-negative integer")
  defp integer_list!(list) when is_list(list) do
    if Enum.all?(list, &is_integer/1), do: list, else: raise(ArgumentError, "expected integer list")
  end
  defp integer_list!(_), do: raise(ArgumentError, "expected integer list")
  defp boolean!(value) when is_boolean(value), do: value
  defp boolean!(_), do: raise(ArgumentError, "expected boolean")
end
```

- [ ] **Step 5: Verify and commit**

Run: `direnv exec . mix format lib/mix/tasks/cinder.anime.probe/corpus.ex test/mix/tasks/cinder_anime_probe/corpus_test.exs`

Run: `direnv exec . mix test test/mix/tasks/cinder_anime_probe/corpus_test.exs`

Expected: 4 tests, 0 failures.

Commit: `test: add anime provider corpus contract`

---

### Task 2: Add the bounded read-only provider client

**Files:**
- Create: `lib/mix/tasks/cinder.anime.probe/http.ex`
- Test: `test/mix/tasks/cinder_anime_probe/http_test.exs`

**Interfaces:**
- Produces: `HTTP.fetch_title/3 :: {:ok, map()} | {:error, term()}`.
- Consumes: one normalized corpus title and the existing TMDB/Prowlarr keyword configs.
- Returns only allowlisted TMDB IDs/titles/episode-group data and Prowlarr title/size/protocol/categories/publish-date data.

- [ ] **Step 1: Write failing Req.Test contracts**

Cover these exact requests:

```elixir
assert conn.request_path == "/3/search/tv"
assert conn.params["query"] == "One Piece"
assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tmdb-token"]

assert conn.request_path == "/3/tv/37854/alternative_titles"
assert conn.request_path == "/3/tv/37854/episode_groups"
assert conn.request_path == "/3/tv/episode_group/absolute-group"

assert conn.request_path == "/api/v1/search"
assert conn.params["query"] == "One Piece"
assert conn.params["type"] == "tvsearch"
assert conn.params["categories"] in [nil, "5070"]
assert Plug.Conn.get_req_header(conn, "x-api-key") == ["prowlarr-key"]
```

Stub one Prowlarr result containing `downloadUrl`, `magnetUrl`, `indexerId`, and `indexer`; assert the returned map is exactly:

```elixir
%{
  title: "[SubsPlease] One Piece - 1122 (1080p) [ABCDEF01]",
  size: 1_400_000_000,
  protocol: "torrent",
  categories: [%{id: 5070, name: "TV/Anime"}],
  published_at: "2026-07-01T12:00:00Z",
  has_indexer_identity: true
}
```

`has_indexer_identity` is true only when the response supplied a valid non-empty `indexer` name or
an integer `indexerId`. The normalizer never retains either raw field or value. Missing or
wrong-type identity evidence becomes `false` so the report can block A0 without leaking identity.

Stub one Absolute episode-group detail and assert its allowlisted entry retains enough identity to audit ordering safely:

```elixir
assert absolute_group.entries == [
         %{
           episode_id: 12_345,
           group_order: 0,
           order: 0,
           season_number: 1,
           episode_number: 1
         }
       ]
```

Also test non-200, oversized, and redirect responses return tagged errors without credentials or raw bodies.

- [ ] **Step 2: Run the test and prove the client is absent**

Run: `direnv exec . mix test test/mix/tasks/cinder_anime_probe/http_test.exs`

Expected: FAIL because `Mix.Tasks.Cinder.Anime.Probe.HTTP` is undefined.

- [ ] **Step 3: Implement bounded requests and allowlist normalization**

Implement `fetch_title/3` as follows:

```elixir
def fetch_title(title, tmdb_config, prowlarr_config) do
  with {:ok, searches} <- tmdb_searches(title, tmdb_config),
       {:ok, alternatives} <- tmdb_alternatives(title, tmdb_config),
       {:ok, details} <- tmdb_details(title, tmdb_config),
       {:ok, groups} <- tmdb_groups(title, tmdb_config),
       {:ok, prowlarr} <- prowlarr_searches(title, prowlarr_config) do
    {:ok,
     %{
       slug: title.slug,
       kind: title.kind,
       tmdb_id: title.tmdb_id,
       searches: searches,
       alternatives: alternatives,
       details: details,
       groups: groups,
       prowlarr: prowlarr
     }}
  end
end
```

Use `/3/search/tv` or `/3/search/movie`, the matching alternative-title endpoint, `/3/tv/:id` or `/3/movie/:id`, and for TV `/3/tv/:id/episode_groups`. Fetch detail only for group IDs whose type is required by the corpus or equals Absolute type `2`. Flatten each group detail to `%{id, type, name, entries}`, where every entry contains only `episode_id`, `group_order`, `order`, `season_number`, and `episode_number`. Movie `groups` is `[]`. This entry identity is required by the pure evaluator; a count-only normalization cannot prove coordinate integrity.

Issue Prowlarr searches twice per query: once without `categories`, once with `categories: 5070`; use `tvsearch` for TV and `moviesearch` for movies. Normalize at most 50 results per request through an allowlist function:

```elixir
defp normalize_release(result) do
  %{
    title: result["title"],
    size: result["size"],
    protocol: result["protocol"],
    categories:
      for(%{"id" => id, "name" => name} <- result["categories"] || [],
        do: %{id: id, name: name}
      ),
    published_at: result["publishDate"],
    has_indexer_identity:
      valid_bounded_non_empty_string?(result["indexer"]) or is_integer(result["indexerId"])
  }
end
```

Validate each retained scalar before returning it. Provider IDs, group types/orders, season/episode
coordinates, and category IDs are integers; sizes are non-negative integers; retained titles,
group names, protocols, and publication fields are bounded non-empty strings; category names are
optional display metadata and may be `nil` or a bounded non-empty string; and publication fields
parse as ISO-8601 timestamps. Blank or container-valued category names and any other malformed
successful payload return exactly `{:error, :unexpected_response}`.

Build both clients from the existing configs, merge `req_options`, force `redirect: false`, and call `HTTPPolicy.bounded_request(request, 4 * 1024 * 1024)`. Return only `{:error, {:tmdb_status, status}}`, `{:error, {:prowlarr_status, status}}`, or `{:error, atom}`; never embed the request/config/body in errors.

- [ ] **Step 4: Verify and commit**

Run: `direnv exec . mix format lib/mix/tasks/cinder.anime.probe/http.ex test/mix/tasks/cinder_anime_probe/http_test.exs`

Run: `direnv exec . mix test test/mix/tasks/cinder_anime_probe/http_test.exs`

Expected: request, normalization, redirect, status, and size-limit tests all pass with no network.

Commit: `feat: add read-only anime provider probe`

---

### Task 3: Evaluate requirements and generate the provider decision

**Files:**
- Create: `lib/mix/tasks/cinder.anime.probe/report.ex`
- Test: `test/mix/tasks/cinder_anime_probe/report_test.exs`

**Interfaces:**
- Produces: `Report.build/2 :: map()` from corpus plus allowlisted provider observations.
- Produces: `Report.markdown/1 :: String.t()`.
- Produces decisions: `tmdb_sufficient`, `anidb_required`, `tvdb_required`, or `provider_council_required`.
- Produces overall gate status: `pass` or `blocked` independently of the metadata-provider decision.

- [ ] **Step 1: Write failing pure evaluator tests**

Create synthetic observations proving:

1. every discovery query returns the expected TMDB ID, required group types exist, Absolute entry counts meet minima, specials exist, and the aggregate Prowlarr sample includes uncategorized and category-5070 results with complete required fields -> `tmdb_sufficient` plus `a0_status: pass`;
2. discovery aliases fail -> `anidb_required`;
3. only required absolute/order coverage fails -> `tvdb_required`;
4. both alias and order families fail -> `provider_council_required`;
5. metadata checks can select `tmdb_sufficient` while a missing Prowlarr contract field still sets `a0_status` to `blocked`;
6. no generated JSON or Markdown contains raw `downloadUrl`, `magnetUrl`, `api_key`, `token`,
   `indexerId`, or `indexer` keys/values; the derived `has_indexer_identity` boolean and its stable
   report check ID are allowed.

Representative assertion:

```elixir
report = Report.build(corpus, observations)

assert report.decision == "tmdb_sufficient"
assert report.a0_status == "pass"
assert report.summary == %{
         titles: 7,
         passed: 7,
         failed: 0,
         automatic_wrong_mappings: 0
       }
assert report.behavior_contracts == %{
         recorded: 24,
         by_phase: %{"A1" => 4, "A2" => 15, "A3" => 5},
         status: "recorded_for_future_phases"
       }

assert Report.markdown(report) =~ "Decision: `tmdb_sufficient`"
assert Report.markdown(report) =~ "A0 status: `pass`"
assert Report.markdown(report) =~ "Future behavior contracts: 24 recorded"
```

- [ ] **Step 2: Run the tests and prove the evaluator is absent**

Run: `direnv exec . mix test test/mix/tasks/cinder_anime_probe/report_test.exs`

Expected: FAIL because `Mix.Tasks.Cinder.Anime.Probe.Report` is undefined.

- [ ] **Step 3: Implement deterministic requirement checks**

For each title, emit checks with stable IDs:

- `discovery:<query>` passes only if that query's normalized TMDB IDs include `title.tmdb_id`;
- `discovery-hits` passes when successful discovery-query count is at least `min_discovery_hits`;
- `specials` passes when not required or TMDB details include season number `0`;
- `group-type:<n>` passes when the group list contains type `n`;
- `absolute-entries` passes when summed unique episode IDs across type-2 details meet `min_absolute_entries`;
- `group-integrity` passes when every fetched group entry has an integer TMDB episode ID and every `{group_order, order}` coordinate maps to exactly one episode ID inside one episode group;
- `prowlarr-results:<query>:<mode>` records a per-query count for evidence but does not fail a title merely because the configured indexers currently have no matching release;
- aggregate `prowlarr-sample` and `prowlarr-anime-category-sample` pass only when at least one result is observed overall and at least one came from a category-5070 request;
- aggregate `prowlarr-categories` and `prowlarr-published-at` record coverage counts and pass only when every sampled result contains a non-empty category list and publication timestamp.
- aggregate `prowlarr-indexer-identity` records availability coverage and passes only when every
  sampled result has `has_indexer_identity == true`; it is a blocking Prowlarr contract check and
  never changes metadata-provider selection.

Set `automatic_wrong_mappings` to the count of missing episode IDs plus coordinates that carry more than one distinct episode ID. Repeated identical observations are deduplicated and do not inflate the count. Any nonzero value fails the title regardless of other checks.

Choose the decision exactly:

```elixir
defp decision(failures) do
  alias_gap? = Enum.any?(failures, &(&1.family == :discovery))
  order_gap? = Enum.any?(failures, &(&1.family == :episode_order))

  case {alias_gap?, order_gap?} do
    {false, false} -> "tmdb_sufficient"
    {true, false} -> "anidb_required"
    {false, true} -> "tvdb_required"
    {true, true} -> "provider_council_required"
  end
end
```

Prowlarr aggregate sample/field failures are contract failures but do not select a metadata provider; list them under `blocking_prowlarr_gaps` so A2 can design a fallback before starting. Per-title zero-result observations remain visible inventory evidence and are not blockers.

Copy only the behavior contracts' IDs, phases, kinds, inputs, and expectations into the report, sorted by ID. Summarize them as recorded future-phase contracts; never mark them passing in A0. Set `a0_status` to `pass` only when all 24 required behavior contracts are recorded, every must-support title passes, `automatic_wrong_mappings` is zero, and `blocking_prowlarr_gaps` is empty; otherwise set it to `blocked`. This gate is deliberately independent from `decision`.

Render Markdown with: corpus version, fixed official reference links, per-title check table, Prowlarr field coverage, sanitized release-title appendix, decision, A0 status, recommended next action, and the future-phase behavior contract inventory. Do not include a generation timestamp. Sort titles/checks/results before encoding so identical observations produce byte-for-byte identical artifacts.

- [ ] **Step 4: Verify and commit**

Run: `direnv exec . mix format lib/mix/tasks/cinder.anime.probe/report.ex test/mix/tasks/cinder_anime_probe/report_test.exs`

Run: `direnv exec . mix test test/mix/tasks/cinder_anime_probe/report_test.exs`

Expected: all decision, integrity, ordering, and secret-scan tests pass.

Commit: `feat: evaluate anime provider coverage`

---

### Task 4: Add the operator CLI and atomic artifact writes

**Files:**
- Create: `lib/mix/tasks/cinder.anime.probe.ex`
- Test: `test/mix/tasks/cinder_anime_probe_test.exs`

**Interfaces:**
- Produces command:
  `mix cinder.anime.probe --corpus PATH --json PATH --markdown PATH`.
- Defaults:
  - corpus: `test/support/fixtures/anime/corpus-v1.json`
  - JSON: `docs/audits/data/anime-provider-contracts-v1.json`
  - Markdown: `docs/audits/2026-07-12-anime-provider-contracts.md`

- [ ] **Step 1: Write the failing CLI integration test**

Use `async: false`, `Cinder.ConfigCase`, Req.Test stubs, and `@tag :tmp_dir`. Configure the existing TMDB/Prowlarr clients with stub plugs and credentials, re-enable the Mix task, and run it against a one-title temporary corpus. Assert both outputs exist, decode the JSON, assert the Markdown decision matches, and refute forbidden keys/values.

```elixir
Mix.Task.reenable("cinder.anime.probe")

Mix.Tasks.Cinder.Anime.Probe.run([
  "--corpus", corpus,
  "--json", json,
  "--markdown", markdown
])

assert %{"decision" => "tmdb_sufficient", "a0_status" => "pass"} =
         json |> File.read!() |> Jason.decode!()
assert File.read!(markdown) =~ "Decision: `tmdb_sufficient`"
assert File.read!(markdown) =~ "A0 status: `pass`"
refute File.read!(json) =~ "downloadUrl"
refute File.read!(json) =~ "prowlarr-key"
```

Add tests that a missing TMDB token, missing Prowlarr API key, bad option, or provider error raises `Mix.Error` without writing either final artifact.

- [ ] **Step 2: Run the test and prove the task is absent**

Run: `direnv exec . mix test test/mix/tasks/cinder_anime_probe_test.exs`

Expected: FAIL because `Mix.Tasks.Cinder.Anime.Probe` is undefined.

- [ ] **Step 3: Implement the CLI**

```elixir
defmodule Mix.Tasks.Cinder.Anime.Probe do
  use Mix.Task

  alias Mix.Tasks.Cinder.Anime.Probe.{Corpus, HTTP, Report}

  @shortdoc "Probe anime metadata/indexer contracts without downloading"
  @switches [corpus: :string, json: :string, markdown: :string]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if rest != [] or invalid != [], do: Mix.raise("invalid anime probe options")

    Mix.Task.run("app.start")

    corpus_path = opts[:corpus] || "test/support/fixtures/anime/corpus-v1.json"
    json_path = opts[:json] || "docs/audits/data/anime-provider-contracts-v1.json"
    markdown_path = opts[:markdown] || "docs/audits/2026-07-12-anime-provider-contracts.md"
    corpus = Corpus.load!(corpus_path)

    tmdb = required_config!(Cinder.Catalog.TMDB.HTTP, :token)
    prowlarr = required_config!(Cinder.Acquisition.Indexer.Prowlarr, :api_key)

    observations =
      Enum.map(corpus.titles, fn title ->
        case HTTP.fetch_title(title, tmdb, prowlarr) do
          {:ok, value} -> value
          {:error, reason} -> Mix.raise("anime probe failed: #{Cinder.HTTPPolicy.sanitize_log(reason)}")
        end
      end)

    report = Report.build(corpus, observations)
    atomic_write!(json_path, Jason.encode_to_iodata!(report, pretty: true))
    atomic_write!(markdown_path, Report.markdown(report))
    Mix.shell().info("Anime provider decision: #{report.decision}")
    Mix.shell().info("A0 status: #{report.a0_status}")
  end

  defp required_config!(module, key) do
    config = Application.get_env(:cinder, module, [])
    if is_nil(config[key]) or config[key] == "", do: Mix.raise("#{inspect(module)} #{key} is not configured")
    config
  end

  defp atomic_write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, contents)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end
end
```

Render both artifacts fully before either write. Each final path is replaced atomically, and the `after` block removes a temporary file on success or failure. Config/provider/rendering failures occur before writes and must leave neither final nor temporary artifacts.

- [ ] **Step 4: Verify the complete offline probe suite and commit**

Run: `direnv exec . mix format lib/mix/tasks/cinder.anime.probe.ex test/mix/tasks/cinder_anime_probe_test.exs`

Run: `direnv exec . mix test test/mix/tasks/cinder_anime_probe/corpus_test.exs test/mix/tasks/cinder_anime_probe/http_test.exs test/mix/tasks/cinder_anime_probe/report_test.exs test/mix/tasks/cinder_anime_probe_test.exs`

Expected: all probe tests pass; Req.Test proves no network call and no sensitive output.

Commit: `feat: add anime provider probe task`

---

### Task 5: Capture live evidence and close the A0 gate

**Files:**
- Create: `docs/audits/data/anime-provider-contracts-v1.json` via the task.
- Create: `docs/audits/2026-07-12-anime-provider-contracts.md` via the task.
- Modify: `ROADMAP.md`

**Interfaces:**
- Consumes: the configured Settings-backed TMDB bearer token and Prowlarr URL/API key.
- Produces: one sanitized, versioned provider decision and an exact gate for A1.

- [ ] **Step 1: Run the live read-only probe**

Run:

```bash
direnv exec . mix cinder.anime.probe \
  --corpus test/support/fixtures/anime/corpus-v1.json \
  --json docs/audits/data/anime-provider-contracts-v1.json \
  --markdown docs/audits/2026-07-12-anime-provider-contracts.md
```

Expected: exit 0, one provider-decision line, and one status line. The provider-decision line is exactly one of:

- `Anime provider decision: tmdb_sufficient`
- `Anime provider decision: anidb_required`
- `Anime provider decision: tvdb_required`
- `Anime provider decision: provider_council_required`

The status line is exactly one of:

- `A0 status: pass`
- `A0 status: blocked`

- [ ] **Step 2: Prove the committed artifacts are sanitized and internally valid**

Run:

```bash
direnv exec . mix run -e '
report = "docs/audits/data/anime-provider-contracts-v1.json" |> File.read!() |> Jason.decode!()
valid_decision? = report["decision"] in ~w(tmdb_sufficient anidb_required tvdb_required provider_council_required)
unless report["version"] == 1 and valid_decision? and report["a0_status"] in ~w(pass blocked), do: System.halt(1)
'
```

Run:

```bash
rg -n 'downloadUrl|magnetUrl|api[_-]?key|authorization|cookie|"indexer(Id)?"[[:space:]]*:|https?://' \
  docs/audits/data/anime-provider-contracts-v1.json
```

Expected: the validation exits 0 and `rg` finds no matches.

- [ ] **Step 3: Apply the exact roadmap branch**

If `a0_status` is `pass`, append to A0:

```markdown
**[done 2026-07-12]** Corpus v1 passes with zero known incorrect automatic mappings; the A0 audit
records the metadata-provider decision, Prowlarr field coverage, and safe-stop fixtures.
```

If `a0_status` is `blocked`, append instead:

```markdown
**[evidence captured 2026-07-12]** Corpus v1 identified a blocking provider gap. A1 is gated on the
service-specific design named in `docs/audits/2026-07-12-anime-provider-contracts.md`; do not add a
generic mapping provider or start schema work first.
```

In the blocked branch, stop after committing A0 evidence and return to brainstorming for the audit's recommended metadata-provider or Prowlarr-contract action. Do not mark A0 done and do not write the A1 plan.

- [ ] **Step 4: Run repository gates**

Run: `direnv exec . mix test`

Expected: compile with warnings-as-errors, format check, Credo strict, migrations, and the full ExUnit suite all pass.

Run: `graphify update .`

Expected: graph update succeeds.

Run: `git status --short`

Expected: only the generated audit files and `ROADMAP.md` are modified/untracked.

- [ ] **Step 5: Commit A0 evidence**

```bash
git add ROADMAP.md \
  docs/audits/data/anime-provider-contracts-v1.json \
  docs/audits/2026-07-12-anime-provider-contracts.md
git commit -m "docs: record anime provider contracts"
```

Expected: the commit contains no secrets or provider-returned URLs. If `a0_status` is `pass`, A0 is complete and A1 may be brainstormed next. Otherwise the audit's blocking design action remains the only next step.
