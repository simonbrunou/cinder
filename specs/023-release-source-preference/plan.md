# Release Source Preference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users prefer a release *source* (Blu-ray / WEB-DL / HDTV / …) per library kind, mirroring the existing `preferred_resolutions` allow-list.

**Architecture:** Add a `source` field to the parser and `Release` struct; add a `preferred_sources` filter + ranking dimension to the scorer; surface a per-kind setting that overlays `:cinder, :<kind>_preferred_sources` through the existing `band_opts/2` seam (reaching both pollers unchanged). No migration, no new machinery.

**Tech Stack:** Elixir / Phoenix 1.8, ExUnit. Spec: `docs/specs/2026-06-26-release-source-preference-design.md`.

## Global Constraints

- `mix test` (the alias) must stay green: `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite.
- Every external service stays behind its behaviour; tests never hit the network. This feature touches none of that.
- Canonical source tokens (downcased): `remux`, `bluray`, `webrip`, `webdl`, `hdtv`, `dvd`, `cam`.
- Untagged (`nil`) source **passes** the filter; only a recognized-but-unlisted source is rejected. Empty list = accept any.
- Ranking priority: resolution → source → size.
- Run `graphify update .` after the code is final (AST-only).

---

### Task 1: Parser `source` field

**Files:**
- Modify: `lib/cinder/acquisition/release.ex` (defstruct)
- Modify: `lib/cinder/acquisition/parser.ex`
- Test: `test/cinder/acquisition/parser_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `%Cinder.Acquisition.Release{source: String.t() | nil}`; `Parser.parse/1` returns a map that now includes `source:` (one of the seven canonical tokens, or `nil`).

- [ ] **Step 1: Update the existing exact-map parser tests (they will break on the new key)**

Four assertions use exact `==` on the parse map and must gain a `source:` key. In `test/cinder/acquisition/parser_test.exs`:

Test "parses a standard p2p release name" (`Inception.2010.1080p.BluRay.x264-RARBG`) — add `source: "bluray",`:
```elixir
    assert Parser.parse("Inception.2010.1080p.BluRay.x264-RARBG") ==
             %{
               resolution: "1080p",
               source: "bluray",
               codec: "x264",
               group: "RARBG",
               language: nil,
               season: nil,
               episodes: nil
             }
```

Test "parses 2160p x265 with a language tag" (`Dune.2021.MULTI.2160p.UHD.BluRay.x265-TERMiNAL`) — add `source: "bluray",`:
```elixir
    assert Parser.parse("Dune.2021.MULTI.2160p.UHD.BluRay.x265-TERMiNAL") ==
             %{
               resolution: "2160p",
               source: "bluray",
               codec: "x265",
               group: "TERMiNAL",
               language: "MULTI",
               season: nil,
               episodes: nil
             }
```

Test "unknown fields are nil" (`Just A Title`) — add `source: nil,`:
```elixir
    assert Parser.parse("Just A Title") ==
             %{
               resolution: nil,
               source: nil,
               codec: nil,
               group: nil,
               language: nil,
               season: nil,
               episodes: nil
             }
```

Test "a non-string title yields all-nil attrs instead of raising" (`Parser.parse(nil)`) — add `source: nil,`:
```elixir
    assert Parser.parse(nil) ==
             %{
               resolution: nil,
               source: nil,
               codec: nil,
               group: nil,
               language: nil,
               season: nil,
               episodes: nil
             }
```

- [ ] **Step 2: Add the new source-parsing tests**

Append inside the top-level `describe`-less area (before the `describe "TV season/episode parsing"` block) in `parser_test.exs`:
```elixir
  describe "source parsing" do
    test "BluRay and its rip variants map to bluray" do
      for name <- ["M.2020.1080p.BluRay.x264", "M.2020.720p.BRRip", "M.2020.BDRip.x264"] do
        assert %{source: "bluray"} = Parser.parse(name)
      end
    end

    test "remux wins over bluray" do
      assert %{source: "remux"} = Parser.parse("M.2020.2160p.BluRay.REMUX.x265")
    end

    test "webrip is distinguished from webdl, and bare WEB is webdl" do
      assert %{source: "webrip"} = Parser.parse("M.2020.1080p.WEBRip.x264")
      assert %{source: "webdl"} = Parser.parse("M.2020.1080p.WEB-DL.x264")
      assert %{source: "webdl"} = Parser.parse("M.2020.1080p.WEB.x264")
    end

    test "hdtv, dvd, and cam tokens" do
      assert %{source: "hdtv"} = Parser.parse("M.2020.720p.HDTV.x264")
      assert %{source: "dvd"} = Parser.parse("M.2019.DVDRip.x264")
      assert %{source: "cam"} = Parser.parse("M.2021.CAM.x264")
    end

    test "an untagged source is nil" do
      assert %{source: nil} = Parser.parse("Inception.2010.x264-GRP")
    end
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/cinder/acquisition/parser_test.exs`
Expected: FAIL — the new `source:` key is absent from `Parser.parse/1` output (exact-map tests fail; `%{source: ...}` partial matches fail).

- [ ] **Step 4: Add `:source` to the Release struct**

In `lib/cinder/acquisition/release.ex`, add `:source` to `defstruct` right after `:resolution`:
```elixir
  defstruct [
    :title,
    :size,
    :download_url,
    :seeders,
    :protocol,
    :resolution,
    :source,
    :codec,
    :group,
    :language,
    :season,
    :episodes
  ]
```

- [ ] **Step 5: Add the `@sources` table, `source/1`, and wire it into `parse/1`**

In `lib/cinder/acquisition/parser.ex`, add the table just after `@resolutions` (line 24):
```elixir
  # Release source, most-specific-first (same first_match/2 mechanism as @codecs). Collision-prone
  # 2-letter abbreviations (ts, tc, bd, scr, dsr) are excluded on purpose — same discipline as the
  # language registry's "vf is the lone 2-letter token" note.
  # ponytail: bare `web` also tags webdl. A title word "web" with no real source token can
  # mis-tag webdl; low-frequency and only bites when a list excludes webdl. Tighten to `web-dl`
  # only if it bites in practice.
  @sources [
    {~r/\bremux\b/i, "remux"},
    {~r/\bblu-?ray\b|\bbdremux\b|\bbrrip\b|\bbdrip\b/i, "bluray"},
    {~r/\bweb-?rip\b/i, "webrip"},
    {~r/\bweb-?dl\b|\bwebdl\b|\bweb\b/i, "webdl"},
    {~r/\bhdtv\b|\bpdtv\b/i, "hdtv"},
    {~r/\bdvd-?rip\b|\bdvd\b/i, "dvd"},
    {~r/\bcam\b|\btelesync\b|\btelecine\b|\bscreener\b/i, "cam"}
  ]
```

Add `source: source(name),` to the `parse/1` returned map (after `resolution:`):
```elixir
    %{
      resolution: resolution(name),
      source: source(name),
      codec: first_match(name, @codecs),
      group: group(name),
      language: language(name),
      season: season,
      episodes: episodes
    }
```

Add `source: nil` to the non-binary `parse/1` fallback:
```elixir
  def parse(_name),
    do: %{
      resolution: nil,
      source: nil,
      codec: nil,
      group: nil,
      language: nil,
      season: nil,
      episodes: nil
    }
```

Add the private helper near `resolution/1`:
```elixir
  defp source(name), do: first_match(name, @sources)
```

Update the parser `@moduledoc` opening line to list `source` among the extracted attributes (change "Extracts release attributes (`resolution`, `codec`, …" to include "`source`").

- [ ] **Step 6: Run the parser tests to verify they pass**

Run: `mix test test/cinder/acquisition/parser_test.exs`
Expected: PASS (all, including the updated exact-map tests and the new `describe "source parsing"`).

- [ ] **Step 7: Commit**

```bash
git add lib/cinder/acquisition/release.ex lib/cinder/acquisition/parser.ex test/cinder/acquisition/parser_test.exs
git commit -m "feat(parser): extract release source (bluray/webdl/hdtv/…)"
```

---

### Task 2: Scorer `preferred_sources` filter + ranking

**Files:**
- Modify: `lib/cinder/acquisition/scorer.ex`
- Test: `test/cinder/acquisition/scorer_test.exs`

**Interfaces:**
- Consumes: `Release.source` (Task 1).
- Produces: `Scorer.select/2` and `Scorer.select_for/4` honour a `preferred_sources:` opt (list of canonical tokens). New public `Scorer.source_rank/2`. Filtering: empty list accepts all; `nil` source passes; recognized-but-unlisted rejected. Ranking: resolution → source → size.

- [ ] **Step 1: Write the failing scorer tests**

Append to `test/cinder/acquisition/scorer_test.exs`, inside the `describe "select/2"` block (before its closing `end`):
```elixir
    test "a recognized but unlisted source is rejected" do
      assert :no_match =
               Scorer.select([release(resolution: "1080p", source: "hdtv", size: 4 * @gb)],
                 preferred_sources: ["bluray", "webdl"]
               )
    end

    test "an untagged (nil) source passes the source filter" do
      assert {:ok, %Release{source: nil}} =
               Scorer.select([release(resolution: "1080p", source: nil, size: 4 * @gb)],
                 preferred_sources: ["bluray"]
               )
    end

    test "prefers the higher-ranked source within the same resolution and size" do
      releases = [
        release(resolution: "1080p", source: "webdl", size: 8 * @gb),
        release(resolution: "1080p", source: "bluray", size: 8 * @gb)
      ]

      assert {:ok, %Release{source: "bluray"}} =
               Scorer.select(releases, preferred_sources: ["bluray", "webdl"])
    end

    test "empty preferred_sources accepts any source" do
      assert {:ok, %Release{source: "cam"}} =
               Scorer.select([release(resolution: "1080p", source: "cam", size: 4 * @gb)])
    end

    test "resolution outranks source: a 1080p webdl beats a 720p bluray" do
      releases = [
        release(resolution: "720p", source: "bluray", size: 8 * @gb),
        release(resolution: "1080p", source: "webdl", size: 8 * @gb)
      ]

      assert {:ok, %Release{resolution: "1080p"}} =
               Scorer.select(releases, preferred_sources: ["bluray", "webdl"])
    end
```

Append a `select_for/4` source test inside the `describe "select_for/4"` block (before its closing `end`):
```elixir
    test "honours the source filter and tiebreak per episode" do
      releases = [
        release(season: 1, episodes: [1], resolution: "1080p", source: "webdl", size: 2 * @gb),
        release(season: 1, episodes: [1], resolution: "1080p", source: "bluray", size: 2 * @gb),
        release(season: 1, episodes: [2], resolution: "1080p", source: "hdtv", size: 2 * @gb)
      ]

      assert {:ok, picks} =
               Scorer.select_for(releases, 1, [1, 2],
                 preferred_sources: ["bluray", "webdl"],
                 max_size: 5 * @gb
               )

      sources = Enum.map(picks, fn {release, _covered} -> release.source end)
      # ep1 prefers bluray over webdl; ep2's only release (hdtv) is unlisted → rejected, stays wanted.
      assert sources == ["bluray"]
    end
```

- [ ] **Step 2: Run the scorer tests to verify they fail**

Run: `mix test test/cinder/acquisition/scorer_test.exs`
Expected: FAIL — `preferred_sources` is unknown (no filtering/ranking applied yet).

- [ ] **Step 3: Thread `sources` through `rules/1`**

In `lib/cinder/acquisition/scorer.ex`, change `rules/1` to a 5-tuple:
```elixir
  defp rules(opts) do
    rules = Keyword.merge(config(), opts)

    {
      Keyword.get(rules, :min_size),
      Keyword.get(rules, :max_size),
      Keyword.get(rules, :preferred_resolutions, @default_preferred),
      Keyword.get(rules, :preferred_sources, []),
      rules |> Keyword.get(:blocklist, []) |> Enum.map(&String.downcase/1)
    }
  end
```

- [ ] **Step 4: Apply the source filter + ranking in `select/2`**

```elixir
  def select(releases, opts \\ []) do
    {min_size, max_size, preferred, sources, blocklist} = rules(opts)

    releases
    |> Enum.filter(&within_band?(&1, min_size, max_size))
    |> Enum.reject(&blocked?(&1, blocklist))
    |> Enum.filter(&allowed_resolution?(&1, preferred))
    |> Enum.filter(&allowed_source?(&1, sources))
    |> pick_best(preferred, sources)
  end
```

Update `pick_best`/`sort_key` to carry `sources`:
```elixir
  defp pick_best([], _preferred, _sources), do: :no_match

  defp pick_best(releases, preferred, sources),
    do: {:ok, Enum.min_by(releases, &sort_key(&1, preferred, sources))}

  defp sort_key(%Release{} = release, preferred, sources) do
    {resolution_rank(release, preferred), source_rank(release, sources), -(release.size || 0)}
  end
```

- [ ] **Step 5: Apply the source filter + tiebreak in `select_for/4`**

```elixir
  def select_for(releases, season, wanted_episodes, opts \\ []) do
    {min_size, max_size, preferred, sources, blocklist} = rules(opts)
    band = {min_size, max_size, preferred, sources}

    releases
    |> Enum.filter(&(&1.season == season))
    |> Enum.reject(&blocked?(&1, blocklist))
    |> Enum.filter(&allowed_resolution?(&1, preferred))
    |> Enum.filter(&allowed_source?(&1, sources))
    |> cover(MapSet.new(wanted_episodes), [], band)
  end
```

Update `cover/4`'s band destructure (the per-episode band ignores source; `greedy_key` reads it):
```elixir
  defp cover(candidates, needed, chosen, band) do
    {min_size, max_size, _preferred, _sources} = band
```

Update `greedy_key/3` to slot source after resolution:
```elixir
  defp greedy_key(%Release{} = release, cov, {_min, _max, preferred, sources}) do
    {MapSet.size(cov), -resolution_rank(release, preferred), -source_rank(release, sources),
     release.size || 0}
  end
```

- [ ] **Step 6: Add `source_rank/2` and `allowed_source?/2`**

Add next to `resolution_rank/2`:
```elixir
  @doc "Index of a source string in the preference list (lower = better); nil/unlisted sorts last."
  def source_rank(source, preferred) when is_binary(source) or is_nil(source),
    do: Enum.find_index(preferred, &(&1 == source)) || length(preferred)

  def source_rank(%Release{} = release, preferred),
    do: source_rank(release.source, preferred)
```

Add next to `allowed_resolution?/2`:
```elixir
  # Source allow-list, but LENIENT on untagged (unlike resolution): empty list keeps all;
  # a nil source passes (a parser miss must not strand a grab); only a recognized but unlisted
  # source is rejected.
  defp allowed_source?(_release, []), do: true
  defp allowed_source?(%Release{source: nil}, _preferred), do: true
  defp allowed_source?(%Release{source: source}, preferred), do: source in preferred
```

Update the `@moduledoc` to note the `preferred_sources` allow-list alongside resolution, including the untagged-passes divergence.

- [ ] **Step 7: Run the scorer tests to verify they pass**

Run: `mix test test/cinder/acquisition/scorer_test.exs`
Expected: PASS (new source tests + all pre-existing resolution/band/blocklist tests).

- [ ] **Step 8: Commit**

```bash
git add lib/cinder/acquisition/scorer.ex test/cinder/acquisition/scorer_test.exs
git commit -m "feat(scorer): preferred_sources allow-list + source ranking"
```

---

### Task 3: Settings overlay, band_opts, and UI field

**Files:**
- Modify: `lib/cinder/settings.ex`
- Modify: `lib/cinder/acquisition.ex` (`band_opts/2`)
- Modify: `lib/cinder_web/components/settings_components.ex`
- Test: `test/cinder/settings_test.exs`

**Interfaces:**
- Consumes: `preferred_sources:` scorer opt (Task 2).
- Produces: a per-kind `<kind>_preferred_sources` setting that overlays `:cinder, :<kind>_preferred_sources` (a downcased list, or `nil`); `Acquisition.band_opts/2` forwards it to the scorer for both pollers.

- [ ] **Step 1: Write the failing settings round-trip test**

In `test/cinder/settings_test.exs`, add `:movies_preferred_sources` and `:tv_preferred_sources` to the `@env_keys` snapshot list (so on_exit restores them), after their `preferred_resolutions` siblings:
```elixir
    :movies_min_size,
    :movies_max_size,
    :movies_preferred_resolutions,
    :movies_preferred_sources,
    :tv_library_path,
    :tv_min_size,
    :tv_max_size,
    :tv_preferred_resolutions,
    :tv_preferred_sources,
    :move_on_import
```

Add this test inside the `describe "load_into_env/0 overlay"` block (near the `*_library_path` overlay tests):
```elixir
    test "a saved movies_preferred_sources overlays the env as a downcased list; clearing reverts to nil" do
      Settings.put("movies_preferred_sources", "BluRay, WEBDL")
      assert Application.get_env(:cinder, :movies_preferred_sources) == ["bluray", "webdl"]

      Settings.delete("movies_preferred_sources")
      assert Application.get_env(:cinder, :movies_preferred_sources) == nil
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cinder/settings_test.exs`
Expected: FAIL — `movies_preferred_sources` is not applied (`get_env` returns `nil` after the put, not `["bluray", "webdl"]`).

- [ ] **Step 3: Register the new band suffix and key helper**

In `lib/cinder/settings.ex`, extend `@band_suffixes` (this alone grows `flat_keys/0`, so form load + save handle the key):
```elixir
  @band_suffixes ["min_size", "max_size", "preferred_resolutions", "preferred_sources"]
```

Add the key helper after `preferred_resolutions_key/1`:
```elixir
  def preferred_sources_key(kind), do: "#{kind}_preferred_sources"
```

- [ ] **Step 4: Apply the source list in `apply_kind_config/2` (reusing the csv parser)**

Rename the existing `parse_resolutions/1` to the generic `parse_csv_list/1` (csv → trimmed/downcased list, blank → nil) — same body, two call sites. Update its doc comment to drop the resolution-specific wording:
```elixir
  # "1080p, 720P" → ["1080p", "720p"] / "BluRay, web" → ["bluray", "web"]. Downcased to match the
  # parser's lower-case tokens; blank/empty ⇒ nil so the scorer's per-field default applies.
  defp parse_csv_list(nil), do: nil

  defp parse_csv_list(value) do
    case value
         |> String.split(",")
         |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      list -> list
    end
  end
```

In `apply_kind_config/2`, change the resolutions line to call the renamed fn and add the sources line + put_env:
```elixir
    min_size = parse_gb(decoded_for(rows, "#{kind}_min_size"))
    max_size = parse_gb(decoded_for(rows, "#{kind}_max_size"))
    preferred = parse_csv_list(decoded_for(rows, "#{kind}_preferred_resolutions"))
    sources = parse_csv_list(decoded_for(rows, "#{kind}_preferred_sources"))

    Application.put_env(:cinder, root_env, root)
    Application.put_env(:cinder, :"#{kind}_min_size", min_size)
    Application.put_env(:cinder, :"#{kind}_max_size", max_size)
    Application.put_env(:cinder, :"#{kind}_preferred_resolutions", preferred)
    Application.put_env(:cinder, :"#{kind}_preferred_sources", sources)
```

- [ ] **Step 5: Run the settings test to verify it passes**

Run: `mix test test/cinder/settings_test.exs`
Expected: PASS.

- [ ] **Step 6: Forward `preferred_sources` through `band_opts/2`**

In `lib/cinder/acquisition.ex`, add the key to `band_opts/2`:
```elixir
  def band_opts(kind) do
    [
      min_size: Application.get_env(:cinder, :"#{kind}_min_size"),
      max_size: Application.get_env(:cinder, :"#{kind}_max_size"),
      preferred_resolutions: Application.get_env(:cinder, :"#{kind}_preferred_resolutions"),
      preferred_sources: Application.get_env(:cinder, :"#{kind}_preferred_sources")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
```

Update its `@doc` to mention `preferred_sources` alongside the resolution note.

- [ ] **Step 7: Add the `/settings` UI field**

In `lib/cinder_web/components/settings_components.ex`, inside the per-kind `:releases` loop, add a field block right after the `preferred_resolutions` `form-control` div (after line ~142):
```heex
          <div class="form-control">
            <label class="label" for={Settings.preferred_sources_key(kind)}>
              <span class="label-text">{gettext("Preferred sources (comma-separated)")}</span>
            </label>
            <input
              type="text"
              id={Settings.preferred_sources_key(kind)}
              name={Settings.preferred_sources_key(kind)}
              value={@form.values[Settings.preferred_sources_key(kind)]}
              placeholder={gettext("bluray, webdl")}
              autocomplete="off"
              class="input w-full"
            />
          </div>
```

Extend the help `<p>` at the bottom of the group with a source sentence:
```heex
        <p class="mt-1 text-xs opacity-70">
          {gettext("Sizes are decimal GB (1 GB = 1,000,000,000 bytes). For TV they apply")} <strong>{gettext("per episode")}</strong>{gettext(
            ": a season pack of N episodes is allowed up to N× the max. Leave blank for no limit."
          )}
          {gettext(
            "Sources: remux, bluray, webrip, webdl, hdtv, dvd, cam. Leave blank to accept any; untagged releases are always kept."
          )}
        </p>
```

- [ ] **Step 8: Run the full suite + checks**

Run: `mix test`
Expected: PASS (the alias: compile-warnings-as-errors, format, credo --strict, suite). If `format --check-formatted` flags the HEEx/code, run `mix format` and re-run.

- [ ] **Step 9: Commit**

```bash
git add lib/cinder/settings.ex lib/cinder/acquisition.ex lib/cinder_web/components/settings_components.ex test/cinder/settings_test.exs
git commit -m "feat(settings): per-kind preferred_sources field wired through band_opts"
```

---

### Task 4: Docs + graph refresh

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `docs/operating.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: CHANGELOG**

Under `## [Unreleased]`, add (additive, non-breaking — no `BREAKING` marker):
```markdown
### Added
- Per-kind **preferred sources** setting (Blu-ray / WEB-DL / HDTV / …) in `/settings` → Release
  size bands, mirroring preferred resolutions. Empty = accept any source; untagged releases are
  always kept; only a recognized-but-unlisted source is rejected.
```
(If an `### Added` subsection already exists under `[Unreleased]`, append the bullet there.)

- [ ] **Step 2: README + operating.md band-tuning sections**

Find the existing preferred-resolutions / size-band tuning passage in each of `README.md` and `docs/operating.md` (search for "preferred resolutions" / "size band"). Add a parallel sentence describing preferred sources and the valid tokens:
> **Preferred sources** (per kind): a comma-separated allow-list of `remux, bluray, webrip, webdl, hdtv, dvd, cam`. Leave blank to accept any source. A listed-but-untagged release is kept; only a release whose detected source is recognized and *not* in your list is rejected. Within a resolution, earlier-listed sources rank higher.

- [ ] **Step 3: Verify docs render and nothing else broke**

Run: `mix test`
Expected: PASS (docs don't affect the suite, but this confirms the working tree is still green).

- [ ] **Step 4: Refresh the knowledge graph**

Run: `graphify update .`
Expected: completes (AST-only, no API cost).

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md README.md docs/operating.md graphify-out
git commit -m "docs(acquisition): document preferred sources setting"
```

---

## Notes for the implementer

- The two pollers (`lib/cinder/download.ex:36` movies, `lib/cinder/download/tv_poller.ex:177` TV) already append `Acquisition.band_opts(kind)` to their scorer opts — Task 3 Step 6 is the only change needed for the new key to reach both. Do **not** edit the pollers.
- `Settings.put/2` auto-runs `load_into_env/0`, so the round-trip test needs no explicit load call.
- Keep the movie scorer path (`select/2`, `best_release/2`) and the TV path byte-compatible except for the source additions — no behaviour change when `preferred_sources` is unset (it resolves to `[]` → `allowed_source?/2` keeps everything, `source_rank` ties at `length([]) = 0` for all, so ranking is unchanged).
