# Phase 2 — Acquisition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `Cinder.Acquisition` library slice — search Prowlarr for a movie by IMDb id, parse release names, and pick the best release by configurable rules — with the one-line TMDB `imdb_id` enabler that feeds it.

**Architecture:** Four small, pure-where-possible units behind the existing `Cinder.Acquisition.Indexer` behaviour: a release-name `Parser`, a `Release` struct that merges indexer + parsed fields, a config-driven `Scorer`, and a `Prowlarr` HTTP impl (mirroring `Cinder.Catalog.TMDB.HTTP`). A thin context fn `best_release/2` composes them. No LiveView, no GenServer, no pipeline wiring (Phase 5).

**Tech Stack:** Elixir / Phoenix 1.8, `Req` (HTTP) + `Req.Test` (client tests), `Mox` (behaviour mocks), ExUnit, `credo --strict`.

**Design spec:** `docs/superpowers/specs/2026-06-18-phase-2-acquisition-design.md` (read it; this plan implements it).

Council review: 1 round (Opus Elixir-correctness + Sonnet test-mechanics; scope seat skipped —
settled at the spec stage). Consensus **SOUND-WITH-FIXES**, both high-confidence: the Opus seat
compiled the full module set under `--warnings-as-errors`, ran `credo --strict` + `format --check`,
and reproduced every assertion live (0 issues); the Sonnet seat traced `Req.Test`/Plug param
decoding, the `X-Api-Key` header, `Req.Test.json` array bodies, and Mox private-mode-with-`async`
correctness, and confirmed no regression from the `imdb_id` change. One material fix applied —
`retry: false` in the Prowlarr test seam (Req's default `:safe_transient` would retry the GET-on-500
test for a ~7s/run tax) — plus two cosmetic ones (refresh the now-stale `TMDB.HTTP` moduledoc in
Task 1; note the new `indexer/` subdir). No correctness flaws; no residual disagreement.

## Global Constraints

Every task's "done" implicitly includes all of these:

- `mix compile --warnings-as-errors` clean; `mix format` applied; `mix credo --strict` no issues; the relevant tests green. (`mix test` — the alias — is the final source of truth.)
- Every new module carries an `@moduledoc` (credo's default `Readability.ModuleDoc` fails otherwise).
- External services are reached only through behaviours, resolved at **runtime** via `Application.fetch_env!/get_env` — **never `compile_env!`** (the test Mox module is defined at runtime and warns under `--warnings-as-errors`).
- Tests never hit the network: behaviour callers use the Mox mock; the real `Req` client uses a `Req.Test` plug stub.
- `size` is taken from the indexer's reported bytes, never parsed from the name.
- Run focused tests with `mix test <file>` (this runs the project alias: compile + format-check + credo + that file). Per-step "expected FAIL/PASS" refers to the named test's result.

## File Structure

- Create `lib/cinder/acquisition/parser.ex` — `parse(name)` → name-derived attrs map. Pure.
- Create `lib/cinder/acquisition/release.ex` — `%Release{}` struct + `new/1` (merges indexer map + `Parser.parse/1`).
- Create `lib/cinder/acquisition/scorer.ex` — `select(releases, opts)` → `{:ok, %Release{}} | :no_match`.
- Create `lib/cinder/acquisition/indexer/prowlarr.ex` — `@behaviour Cinder.Acquisition.Indexer`; `search/1` via Prowlarr JSON.
- Create `lib/cinder/acquisition.ex` — context; `best_release/2` composes the above.
- Modify `lib/cinder/catalog/tmdb/http.ex` — add `imdb_id` to the shared `normalize/1`.
- Modify `config/config.exs` — add `indexer:` impl selection.
- Modify `config/test.exs` — add the Prowlarr `Req.Test` seam + a test `api_key`.
- Create tests mirroring each module (`test/cinder/acquisition/...`, `test/cinder/acquisition_test.exs`); modify `test/cinder/catalog/tmdb/http_test.exs`.

---

### Task 1: TMDB `imdb_id` enabler

The details endpoint already returns `"imdb_id"`; carry it through the shared normalizer. Search results omit it (→ `nil`), so the existing `search/1` assertion must gain `imdb_id: nil`.

**Files:**
- Modify: `lib/cinder/catalog/tmdb/http.ex` (the `normalize/1` private fn, ~lines 53-60)
- Test: `test/cinder/catalog/tmdb/http_test.exs` (update `search/1` and `get_movie/1` tests)

**Interfaces:**
- Produces: `Cinder.Catalog.TMDB.HTTP.get_movie/1` now returns a map including `imdb_id: String.t() | nil`; `search/1` results include `imdb_id: nil`.

- [ ] **Step 1: Update the two existing tests to expect `imdb_id`**

In `test/cinder/catalog/tmdb/http_test.exs`, change the `search/1` normalization assertion to include `imdb_id: nil` on each result:

```elixir
    assert results == [
             %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg", imdb_id: nil},
             %{tmdb_id: 1, title: "Obscure", year: nil, poster_path: nil, imdb_id: nil}
           ]
```

And in the `get_movie/1 normalizes a single (unwrapped) movie body` test, add `imdb_id` to the stubbed body and the assertion:

```elixir
      Req.Test.json(conn, %{
        "id" => 27_205,
        "title" => "Inception",
        "release_date" => "2010-07-16",
        "poster_path" => "/p.jpg",
        "imdb_id" => "tt1375666"
      })
    end)

    assert {:ok,
            %{
              tmdb_id: 27_205,
              title: "Inception",
              year: 2010,
              poster_path: "/p.jpg",
              imdb_id: "tt1375666"
            }} = HTTP.get_movie(27_205)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cinder/catalog/tmdb/http_test.exs`
Expected: FAIL — the normalized maps lack the `imdb_id` key (assertion mismatch).

- [ ] **Step 3: Add `imdb_id` to `normalize/1` (and refresh the stale moduledoc line)**

In `lib/cinder/catalog/tmdb/http.ex`, update the moduledoc's last sentence — it currently
promises the enrichment as future work:

```elixir
  Reads `base_url`, `token` (v4 bearer) and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Returns normalized movie maps
  (`%{tmdb_id, title, year, poster_path, imdb_id}`); search results carry `imdb_id: nil`
  (only the details endpoint returns it).
```

Then add one line to the `normalize/1` map:

```elixir
  defp normalize(movie) do
    %{
      tmdb_id: movie["id"],
      title: movie["title"],
      year: year_from(movie["release_date"]),
      poster_path: movie["poster_path"],
      imdb_id: movie["imdb_id"]
    }
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cinder/catalog/tmdb/http_test.exs`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/catalog/tmdb/http.ex test/cinder/catalog/tmdb/http_test.exs
git commit -m "Phase 2: TMDB get_movie carries imdb_id through normalize"
```

---

### Task 2: Release-name `Parser`

Pure extraction of `resolution`, `codec`, `group`, `language` from a release name. Table-driven (keeps credo `CyclomaticComplexity` happy). Guarded group rule so hyphenated titles and source tokens aren't misread as groups.

**Files:**
- Create: `lib/cinder/acquisition/parser.ex`
- Test: `test/cinder/acquisition/parser_test.exs`

**Interfaces:**
- Produces: `Cinder.Acquisition.Parser.parse(name :: String.t()) :: %{resolution: String.t() | nil, codec: String.t() | nil, group: String.t() | nil, language: String.t() | nil}`

- [ ] **Step 1: Write the failing test**

Create `test/cinder/acquisition/parser_test.exs`:

```elixir
defmodule Cinder.Acquisition.ParserTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Parser

  test "parses a standard p2p release name" do
    assert Parser.parse("Inception.2010.1080p.BluRay.x264-RARBG") ==
             %{resolution: "1080p", codec: "x264", group: "RARBG", language: nil}
  end

  test "parses 2160p x265 with a language tag" do
    assert Parser.parse("Dune.2021.MULTI.2160p.UHD.BluRay.x265-TERMiNAL") ==
             %{resolution: "2160p", codec: "x265", group: "TERMiNAL", language: "MULTI"}
  end

  test "a hyphen in the title is not mistaken for a group" do
    assert %{group: nil, resolution: "1080p", codec: "x264"} =
             Parser.parse("Spider-Man.2002.1080p.BluRay.x264")
  end

  test "a source-hyphen token with a trailing field is not a group" do
    # Note: ends on `.H264`, not on `WEB-DL` — a name ending exactly on `WEB-DL` would give "DL".
    assert %{group: nil, codec: "h264", resolution: "1080p"} =
             Parser.parse("Movie.2010.1080p.WEB-DL.H264")
  end

  test "a groupless scene name yields a nil group" do
    assert %{group: nil} = Parser.parse("Some.Movie.2015.720p.HDTV.x264")
  end

  test "unknown fields are nil" do
    assert Parser.parse("Just A Title") ==
             %{resolution: nil, codec: nil, group: nil, language: nil}
  end

  test "matching is case-insensitive" do
    assert %{codec: "x265", resolution: "1080p", group: "grp"} =
             Parser.parse("movie.2020.1080P.bluray.X265-grp")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/acquisition/parser_test.exs`
Expected: FAIL — `Cinder.Acquisition.Parser` is not available / undefined.

- [ ] **Step 3: Write the parser**

Create `lib/cinder/acquisition/parser.ex`:

```elixir
defmodule Cinder.Acquisition.Parser do
  @moduledoc """
  Extracts release attributes (`resolution`, `codec`, `group`, `language`) from a
  release name. Pure and best-effort: an unrecognized field is `nil`.

  `size` is intentionally not parsed here — it comes from the indexer's reported
  byte count (see `Cinder.Acquisition`).
  """

  @resolutions ["2160p", "1080p", "720p", "480p"]

  @codecs [
    {~r/x265/i, "x265"},
    {~r/h\.?265/i, "h265"},
    {~r/hevc/i, "h265"},
    {~r/x264/i, "x264"},
    {~r/h\.?264/i, "h264"},
    {~r/avc/i, "h264"},
    {~r/av1/i, "av1"},
    {~r/xvid/i, "xvid"}
  ]

  @languages [
    {~r/\bmulti\b/i, "MULTI"},
    {~r/\bfrench\b/i, "FRENCH"},
    {~r/\bgerman\b/i, "GERMAN"},
    {~r/\bspanish\b/i, "SPANISH"},
    {~r/\bitalian\b/i, "ITALIAN"}
  ]

  @doc """
  Parses `name` into `%{resolution, codec, group, language}`. Each value is `nil`
  when no known token matches.
  """
  def parse(name) when is_binary(name) do
    %{
      resolution: resolution(name),
      codec: first_match(name, @codecs),
      group: group(name),
      language: first_match(name, @languages)
    }
  end

  defp resolution(name) do
    down = String.downcase(name)
    Enum.find(@resolutions, &String.contains?(down, &1))
  end

  defp first_match(name, table) do
    Enum.find_value(table, fn {pattern, value} -> if Regex.match?(pattern, name), do: value end)
  end

  # The trailing "-TOKEN", but only when TOKEN is a single alphanumeric run (no
  # dots/spaces), after stripping a container extension. Otherwise nil — so a
  # hyphenated title ("Spider-Man") or a source token ("WEB-DL.H264") is never read
  # as a group. See the spec for the two accepted, bounded edge cases.
  defp group(name) do
    stripped = Regex.replace(~r/\.(mkv|mp4|avi|m4v|ts)$/i, name, "")

    case Regex.run(~r/-([A-Za-z0-9]+)$/, stripped) do
      [_, group] -> group
      nil -> nil
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cinder/acquisition/parser_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/parser.ex test/cinder/acquisition/parser_test.exs
git commit -m "Phase 2: release-name parser (resolution/codec/group/language)"
```

---

### Task 3: `Release` struct + `new/1`

The shared currency: indexer-reported fields + parsed name attributes.

**Files:**
- Create: `lib/cinder/acquisition/release.ex`
- Test: `test/cinder/acquisition/release_test.exs`

**Interfaces:**
- Consumes: `Cinder.Acquisition.Parser.parse/1`.
- Produces: `%Cinder.Acquisition.Release{title, size, download_url, seeders, resolution, codec, group, language}` and `Cinder.Acquisition.Release.new(indexer_map :: %{title: String.t(), size: integer | nil, download_url: String.t() | nil, seeders: integer | nil}) :: %Release{}`.

- [ ] **Step 1: Write the failing test**

Create `test/cinder/acquisition/release_test.exs`:

```elixir
defmodule Cinder.Acquisition.ReleaseTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Release

  test "new/1 merges indexer fields with parsed name attributes" do
    indexer_map = %{
      title: "Inception.2010.1080p.BluRay.x264-RARBG",
      size: 8_000_000_000,
      download_url: "http://prowlarr/download/1",
      seeders: 42
    }

    assert %Release{
             title: "Inception.2010.1080p.BluRay.x264-RARBG",
             size: 8_000_000_000,
             download_url: "http://prowlarr/download/1",
             seeders: 42,
             resolution: "1080p",
             codec: "x264",
             group: "RARBG",
             language: nil
           } = Release.new(indexer_map)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/acquisition/release_test.exs`
Expected: FAIL — `Cinder.Acquisition.Release` is not available.

- [ ] **Step 3: Write the struct + constructor**

Create `lib/cinder/acquisition/release.ex`:

```elixir
defmodule Cinder.Acquisition.Release do
  @moduledoc """
  A candidate release: the indexer-reported fields (`title`, `size`,
  `download_url`, `seeders`) plus the attributes parsed from its name. The shared
  shape passed between the indexer, parser, and scorer.

  `seeders` is carried for later phases; the Phase 2 scorer does not rank on it.
  """
  alias Cinder.Acquisition.Parser

  defstruct [:title, :size, :download_url, :seeders, :resolution, :codec, :group, :language]

  @doc """
  Builds a `Release` from an indexer result map, parsing name-derived attributes
  from the `:title`.
  """
  def new(%{title: title} = indexer_map) do
    %__MODULE__{
      title: title,
      size: Map.get(indexer_map, :size),
      download_url: Map.get(indexer_map, :download_url),
      seeders: Map.get(indexer_map, :seeders)
    }
    |> struct(Parser.parse(title))
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cinder/acquisition/release_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/release.ex test/cinder/acquisition/release_test.exs
git commit -m "Phase 2: Release struct + new/1 (indexer fields + parsed attrs)"
```

---

### Task 4: `Scorer`

The Phase 2 "Done when" centerpiece. Inclusive size band + group blocklist filters, then `min_by {resolution_rank, -size}`. Rules from config merged with per-call `opts`.

**Files:**
- Create: `lib/cinder/acquisition/scorer.ex`
- Test: `test/cinder/acquisition/scorer_test.exs`

**Interfaces:**
- Consumes: `%Cinder.Acquisition.Release{}`.
- Produces: `Cinder.Acquisition.Scorer.select(releases :: [%Release{}], opts :: keyword) :: {:ok, %Release{}} | :no_match`. Recognized `opts`/config keys: `:min_size`, `:max_size` (bytes, inclusive; absent = unbounded), `:blocklist` (group names, case-insensitive), `:preferred_resolutions` (ordered; default `["1080p", "720p"]`).

- [ ] **Step 1: Write the failing test**

Create `test/cinder/acquisition/scorer_test.exs`:

```elixir
defmodule Cinder.Acquisition.ScorerTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.Scorer

  @gb 1_000_000_000

  # Build a Release fixture from just the fields the scorer reads.
  defp release(attrs), do: struct(%Release{title: "fixture"}, attrs)

  describe "select/2" do
    test "happy path: picks the band-fitting 1080p from a mixed list" do
      releases = [
        release(resolution: "720p", group: "A", size: 4 * @gb),
        release(resolution: "1080p", group: "B", size: 9 * @gb),
        release(resolution: "2160p", group: "C", size: 40 * @gb)
      ]

      assert {:ok, %Release{group: "B", resolution: "1080p"}} =
               Scorer.select(releases, min_size: 1 * @gb, max_size: 20 * @gb)
    end

    test "all-too-large: every release exceeds max_size -> :no_match" do
      releases = [
        release(resolution: "1080p", group: "A", size: 30 * @gb),
        release(resolution: "720p", group: "B", size: 25 * @gb)
      ]

      assert :no_match = Scorer.select(releases, max_size: 20 * @gb)
    end

    test "blocklisted group is excluded even when it would otherwise win" do
      releases = [
        release(resolution: "1080p", group: "EVIL", size: 10 * @gb),
        release(resolution: "1080p", group: "GOOD", size: 8 * @gb)
      ]

      # EVIL out-ranks GOOD on size; the blocklist must drop it and pick GOOD.
      assert {:ok, %Release{group: "GOOD"}} =
               Scorer.select(releases, blocklist: ["evil"], max_size: 20 * @gb)

      # Negative control: with no blocklist, EVIL wins — proving the filter is load-bearing.
      assert {:ok, %Release{group: "EVIL"}} = Scorer.select(releases, max_size: 20 * @gb)
    end

    test "prefers 1080p over an equally-sized 720p" do
      releases = [
        release(resolution: "720p", group: "A", size: 8 * @gb),
        release(resolution: "1080p", group: "B", size: 8 * @gb)
      ]

      assert {:ok, %Release{resolution: "1080p"}} = Scorer.select(releases)
    end

    test "unlisted/nil resolutions rank last; size breaks the tie without crashing" do
      releases = [
        release(resolution: "2160p", group: "A", size: 30 * @gb),
        release(resolution: nil, group: "B", size: 5 * @gb)
      ]

      assert {:ok, %Release{group: "A", resolution: "2160p"}} = Scorer.select(releases)
    end

    test "empty input -> :no_match" do
      assert :no_match = Scorer.select([])
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/acquisition/scorer_test.exs`
Expected: FAIL — `Cinder.Acquisition.Scorer` is not available.

- [ ] **Step 3: Write the scorer**

Create `lib/cinder/acquisition/scorer.ex`:

```elixir
defmodule Cinder.Acquisition.Scorer do
  @moduledoc """
  Selects the best release from a list by explicit, configurable rules: an
  inclusive size band, a group blocklist, and an ordered resolution preference.

  Rules come from `config :cinder, #{inspect(__MODULE__)}` merged with per-call
  `opts`. Returns `{:ok, release}` or `:no_match` when none survive the filters.
  """
  alias Cinder.Acquisition.Release

  @default_preferred ["1080p", "720p"]

  @doc """
  Picks the best release from `releases`, or `:no_match` if none survive the
  size-band and blocklist filters.
  """
  def select(releases, opts \\ []) do
    rules = Keyword.merge(config(), opts)
    min_size = Keyword.get(rules, :min_size)
    max_size = Keyword.get(rules, :max_size)
    blocklist = rules |> Keyword.get(:blocklist, []) |> Enum.map(&String.downcase/1)
    preferred = Keyword.get(rules, :preferred_resolutions, @default_preferred)

    releases
    |> Enum.filter(&within_band?(&1, min_size, max_size))
    |> Enum.reject(&blocked?(&1, blocklist))
    |> pick_best(preferred)
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp within_band?(%Release{} = release, min_size, max_size) do
    size = release.size || 0
    (is_nil(min_size) or size >= min_size) and (is_nil(max_size) or size <= max_size)
  end

  defp blocked?(%Release{group: nil}, _blocklist), do: false
  defp blocked?(%Release{group: group}, blocklist), do: String.downcase(group) in blocklist

  defp pick_best([], _preferred), do: :no_match
  defp pick_best(releases, preferred), do: {:ok, Enum.min_by(releases, &sort_key(&1, preferred))}

  defp sort_key(%Release{} = release, preferred) do
    rank = Enum.find_index(preferred, &(&1 == release.resolution)) || length(preferred)
    {rank, -(release.size || 0)}
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cinder/acquisition/scorer_test.exs`
Expected: PASS (6 tests, covering the three mandated cases + preference + nil + empty).

- [ ] **Step 5: Commit**

```bash
git add lib/cinder/acquisition/scorer.ex test/cinder/acquisition/scorer_test.exs
git commit -m "Phase 2: scorer (size band + blocklist + resolution preference)"
```

---

### Task 5: `Prowlarr` indexer impl

Real `Cinder.Acquisition.Indexer` impl over Prowlarr's JSON search, mirroring `TMDB.HTTP`. Tested offline via a `Req.Test` plug. Includes the config wiring this needs.

**Files:**
- Create: `lib/cinder/acquisition/indexer/prowlarr.ex` (new `indexer/` subdir; coexists fine with the sibling `indexer.ex` behaviour)
- Modify: `config/config.exs` (add `indexer:` selection)
- Modify: `config/test.exs` (add the Prowlarr `Req.Test` seam + `api_key`)
- Test: `test/cinder/acquisition/indexer/prowlarr_test.exs`

**Interfaces:**
- Implements: `Cinder.Acquisition.Indexer.search(imdb_id :: String.t()) :: {:ok, [map()]} | {:error, term()}`, where each map is `%{title, size, download_url, seeders}`.

- [ ] **Step 1: Add the config wiring**

In `config/config.exs`, right below the existing `config :cinder, tmdb: ...` line:

```elixir
config :cinder, tmdb: Cinder.Catalog.TMDB.HTTP
config :cinder, indexer: Cinder.Acquisition.Indexer.Prowlarr
```

In `config/test.exs`, below the existing TMDB `req_options` line at the bottom, add the Prowlarr seam with a non-nil `api_key` (so the test can assert the auth header is sent):

```elixir
config :cinder, Cinder.Acquisition.Indexer.Prowlarr,
  req_options: [plug: {Req.Test, Cinder.ProwlarrStub}, retry: false],
  api_key: "test-key"
```

(The `:indexer` key in `test.exs` already points at `Cinder.Acquisition.IndexerMock` from Phase 0 — leave it; the line above configures only the real client's own test. `retry: false` matters: Req's default `retry: :safe_transient` would retry the GET-on-500 test three times with 1s/2s/4s backoff — a ~7s tax per suite run. The non-200 test uses 500, which *is* in Req's retry set, so this is required, not optional.)

- [ ] **Step 2: Write the failing test**

Create `test/cinder/acquisition/indexer/prowlarr_test.exs`:

```elixir
defmodule Cinder.Acquisition.Indexer.ProwlarrTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Prowlarr

  test "search/1 queries by IMDb id and normalizes results, falling back to magnetUrl" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      assert conn.request_path == "/api/v1/search"
      assert conn.params["query"] == "{ImdbId:tt1375666}"
      assert conn.params["type"] == "movie"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]

      Req.Test.json(conn, [
        %{
          "title" => "Inception.2010.1080p.BluRay.x264-RARBG",
          "size" => 8_000_000_000,
          "downloadUrl" => "http://prowlarr/file/1",
          "seeders" => 50
        },
        %{
          "title" => "Inception.2010.2160p.WEB-DL-GRP",
          "size" => 40_000_000_000,
          "downloadUrl" => nil,
          "magnetUrl" => "magnet:?xt=urn:btih:abc",
          "seeders" => 10
        }
      ])
    end)

    assert {:ok, results} = Prowlarr.search("tt1375666")

    assert results == [
             %{
               title: "Inception.2010.1080p.BluRay.x264-RARBG",
               size: 8_000_000_000,
               download_url: "http://prowlarr/file/1",
               seeders: 50
             },
             %{
               title: "Inception.2010.2160p.WEB-DL-GRP",
               size: 40_000_000_000,
               download_url: "magnet:?xt=urn:btih:abc",
               seeders: 10
             }
           ]
  end

  test "search/1 returns an error tuple on a non-200 status" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)

    assert {:error, {:prowlarr_status, 500}} = Prowlarr.search("tt1375666")
  end

  test "search/1 returns an error (not a raise) on a 200 that isn't a list" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      Req.Test.json(conn, %{"unexpected" => true})
    end)

    assert {:error, :unexpected_response} = Prowlarr.search("tt1375666")
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/cinder/acquisition/indexer/prowlarr_test.exs`
Expected: FAIL — `Cinder.Acquisition.Indexer.Prowlarr` is not available.

- [ ] **Step 4: Write the Prowlarr impl**

Create `lib/cinder/acquisition/indexer/prowlarr.ex`:

```elixir
defmodule Cinder.Acquisition.Indexer.Prowlarr do
  @moduledoc """
  Real `Cinder.Acquisition.Indexer` impl, backed by `Req`, against Prowlarr's
  unified JSON search (`GET /api/v1/search`).

  Reads `base_url`, `api_key` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Searches by IMDb id with
  Prowlarr's `{ImdbId:...}` query token (`type=movie`) and returns normalized
  release maps (`%{title, size, download_url, seeders}`). `download_url` falls back
  to a magnet link when no torrent-file URL is present.
  """
  @behaviour Cinder.Acquisition.Indexer

  @default_base_url "http://localhost:9696"

  @impl true
  def search(imdb_id) do
    params = [query: "{ImdbId:#{imdb_id}}", type: "movie"]

    case request(url: "/api/v1/search", params: params) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  defp request(opts) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [base_url: Keyword.get(config, :base_url, @default_base_url)]
    |> auth(Keyword.get(config, :api_key))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
    |> Req.request()
  end

  defp auth(opts, nil), do: opts
  defp auth(opts, api_key), do: Keyword.put(opts, :headers, [{"x-api-key", api_key}])

  defp error({:ok, %{status: status}}), do: {:error, {:prowlarr_status, status}}
  defp error({:error, reason}), do: {:error, reason}

  defp normalize(result) do
    %{
      title: result["title"],
      size: result["size"],
      download_url: result["downloadUrl"] || result["magnetUrl"],
      seeders: result["seeders"]
    }
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/cinder/acquisition/indexer/prowlarr_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/acquisition/indexer/prowlarr.ex config/config.exs config/test.exs test/cinder/acquisition/indexer/prowlarr_test.exs
git commit -m "Phase 2: Prowlarr JSON indexer impl + config wiring"
```

---

### Task 6: `Acquisition` context (`best_release/2`)

Composes indexer → `Release.new` → `Scorer.select`. Resolves the indexer at runtime (mock in test). Closes the slice.

**Files:**
- Create: `lib/cinder/acquisition.ex`
- Test: `test/cinder/acquisition_test.exs`

**Interfaces:**
- Consumes: the configured `Cinder.Acquisition.Indexer` impl (`Cinder.Acquisition.IndexerMock` in test), `Release.new/1`, `Scorer.select/2`.
- Produces: `Cinder.Acquisition.best_release(imdb_id :: String.t(), opts :: keyword) :: {:ok, %Release{}} | :no_match | {:error, term()}`. `opts` are forwarded to `Scorer.select/2` only.

- [ ] **Step 1: Write the failing test**

Create `test/cinder/acquisition_test.exs`:

```elixir
defmodule Cinder.AcquisitionTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.Release

  setup :verify_on_exit!

  @gb 1_000_000_000

  # A raw indexer result map with sensible defaults; override per case.
  defp raw(attrs) do
    Map.merge(
      %{title: "Movie.2020.1080p.BluRay.x264-GRP", size: 8 * @gb, download_url: "u", seeders: 10},
      Map.new(attrs)
    )
  end

  test "best_release/2 composes indexer search, parse, and scoring" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
      {:ok,
       [
         raw(title: "Movie.2020.720p.BluRay.x264-GOOD", size: 4 * @gb),
         raw(title: "Movie.2020.1080p.BluRay.x264-BEST", size: 9 * @gb)
       ]}
    end)

    assert {:ok, %Release{group: "BEST", resolution: "1080p"}} =
             Acquisition.best_release("tt1375666", max_size: 20 * @gb)
  end

  test "best_release/2 returns :no_match when nothing survives the rules" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ ->
      {:ok, [raw(title: "Movie.2020.1080p.BluRay.x264-GRP", size: 50 * @gb)]}
    end)

    assert :no_match = Acquisition.best_release("tt1375666", max_size: 20 * @gb)
  end

  test "best_release/2 returns :no_match on an empty indexer result" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:ok, []} end)

    assert :no_match = Acquisition.best_release("tt1375666")
  end

  test "best_release/2 passes an indexer error straight through" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Acquisition.best_release("tt1375666")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/acquisition_test.exs`
Expected: FAIL — `Cinder.Acquisition` is not available.

- [ ] **Step 3: Write the context**

Create `lib/cinder/acquisition.ex`:

```elixir
defmodule Cinder.Acquisition do
  @moduledoc """
  Release acquisition: search an indexer for a movie and pick the best release.

  The indexer is reached only through the `Cinder.Acquisition.Indexer` behaviour,
  resolved from config (`config :cinder, :indexer`) so tests use a Mox mock and
  never hit the network.
  """
  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.Scorer

  @doc """
  Searches the configured indexer for `imdb_id`, parses each result, and returns
  the best release per `Scorer` rules. `opts` are forwarded to `Scorer.select/2`.

  Returns `{:ok, %Release{}}`, `:no_match` (no results, or none survive the rules),
  or `{:error, term}` (indexer failure, passed through).
  """
  def best_release(imdb_id, opts \\ []) do
    case indexer().search(imdb_id) do
      {:ok, raw_results} ->
        raw_results
        |> Enum.map(&Release.new/1)
        |> Scorer.select(opts)

      {:error, _reason} = error ->
        error
    end
  end

  # Resolve the impl at runtime (not compile_env!) so the test Mox module — defined
  # at runtime — doesn't warn under --warnings-as-errors. fetch_env! fails fast if unset.
  defp indexer, do: Application.fetch_env!(:cinder, :indexer)
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cinder/acquisition_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite + conventions (the "Done when" gate)**

Run: `mix test`
Expected: PASS — compile `--warnings-as-errors` clean, format clean, `credo --strict` no issues, all tests green (Phase 1 + Phase 2).

- [ ] **Step 6: Commit**

```bash
git add lib/cinder/acquisition.ex test/cinder/acquisition_test.exs
git commit -m "Phase 2: Acquisition context — best_release composes search/parse/score"
```

---

## Self-Review

**1. Spec coverage:**
- Indexer behaviour real impl + mock → Task 5 (mock pre-exists from Phase 0). ✓
- Release parser (resolution/codec/group/language) → Task 2. ✓
- Scorer (1080p preference, size band, blocklist) → Task 4; the three mandated "Done when" cases + negative control + nil/2160p + empty are in `scorer_test`. ✓
- `best_release/2` seam → Task 6. ✓
- `size` from indexer not parser → `Release.new` (Task 3) + `Scorer.within_band?` use `release.size`; parser never emits size. ✓
- `imdb_id` enabler (normalize + both TMDB tests) → Task 1. ✓
- Config: `config.exs` `indexer:` + `test.exs` Prowlarr seam → Task 5. ✓
- Verified Prowlarr request shape (`{ImdbId:…}`, `type=movie`, `X-Api-Key`, array body, `downloadUrl||magnetUrl`) → Task 5 impl + test. ✓
- Runtime resolution (`fetch_env!`/`get_env`, never `compile_env!`) → Tasks 4, 5, 6. ✓
- `@moduledoc` on every new module → all of Parser/Release/Scorer/Prowlarr/Acquisition. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step has an exact command + expected result. ✓

**3. Type consistency:** `Release.new/1` (Task 3) consumes the `%{title, size, download_url, seeders}` map that `Prowlarr.normalize/1` (Task 5) produces and `raw/1` (Task 6) fakes. `Scorer.select/2` (Task 4) consumes `%Release{}` and returns `{:ok, %Release{}} | :no_match`; `best_release/2` (Task 6) relies on exactly that. `parse/1` returns the four-key map both `Release.new` and `parser_test` expect. Names align across tasks. ✓
