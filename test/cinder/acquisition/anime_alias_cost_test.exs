defmodule Cinder.Acquisition.AnimeAliasCostTest do
  # `Cinder.CallTrace` sets a node-wide trace pattern on `TitleAlias.normalize/1`, so this module
  # does not run beside another module that traces it (its moduledoc). #1968: an anime search
  # normalized the series' aliases again, several times over, for each release it read, and a
  # parity compare replays the search over its recorded rows many times per try.
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{Anime, AnimeParser, IndexerMock, Release}
  alias Cinder.Acquisition.IndexerSource.{Prowlarr, Report}
  alias Cinder.CallTrace
  alias Cinder.Catalog.TitleAlias
  alias Cinder.Download.Intent
  alias Cinder.Indexers.Parity
  alias Cinder.Indexers.Parity.Picks
  alias Cinder.ProwlarrHistoryFixtures

  setup :verify_on_exit!

  @scene_alias "Koyomimonogatari"

  # An alias the parser leaves out, whose scene numbering scopes two mappings.
  @omitted_scope "Monogatari Series 18"

  # Monogatari's shape: more known aliases than the 7 the parser keeps, some of them a prefix of
  # a longer one, a scene title scoped to an arc, and mappings scoped to an alias the parser leaves
  # out. `alias_count` is 20 or more, so that "Bakemonogatari 2" prefixes "Bakemonogatari 20".
  defp context(alias_count) do
    aliases =
      for i <- 1..alias_count do
        title =
          case rem(i, 3) do
            0 -> "Monogatari Series #{i}"
            1 -> "Monogatari Series #{i} Second Season"
            2 -> "Bakemonogatari #{i}"
          end

        alias_record(title, Enum.at([:romaji, :alternative, :licensed], rem(i, 3)))
      end

    episodes = for n <- 1..12, do: %{id: n, season_number: 1, episode_number: n}

    %{
      kind: :series,
      title: "Monogatari",
      year: 2009,
      tvdb_id: 102_261,
      aliases: [alias_record(@scene_alias, :scene) | aliases],
      scene_titles: [
        %{title: @scene_alias, season: 11, source: "tmdb", namespace: "nisio-isin-order"}
      ],
      episodes: episodes,
      mappings:
        Enum.map(episodes, &canonical/1) ++
          for(
            e <- episodes,
            do:
              mapping("tmdb", "scene", "nisio-isin-order", "S11E#{pad(e.episode_number)}", [e.id])
              |> Map.put(:scope_title, @scene_alias)
          ) ++
          for(
            n <- 1..2,
            do:
              mapping("tmdb", "scene", "other-order", "S12E0#{n}", [n])
              |> Map.put(:scope_title, @omitted_scope)
          )
    }
  end

  defp alias_record(title, kind),
    do: %{
      title: title,
      kind: kind,
      precedence: :manual,
      normalized_title: TitleAlias.normalize(title)
    }

  defp canonical(e),
    do: mapping("cinder", "standard", "canonical", "S01E#{pad(e.episode_number)}", [e.id])

  defp mapping(source, scheme, namespace, value, ids),
    do: %{
      identity: %{source: source, scheme: scheme, namespace: namespace, canonical_value: value},
      precedence: :manual,
      episode_ids: ids,
      evidence: %{"kind" => "fixture"}
    }

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  # `count` rows, as every query of the search answers them: standard names under the title, the
  # alias that prefixes a longer one and the scene alias, the last scoped to its arc.
  defp rows(count) do
    for k <- 1..count do
      ep = pad(rem(k, 12) + 1)

      title =
        case rem(k, 3) do
          0 -> "Monogatari.S01E#{ep}.1080p.WEB-DL-G#{k}"
          1 -> "[G#{k}] Bakemonogatari 2 - S01E#{ep} [1080p]"
          2 -> "[G#{k}] #{@scene_alias} - #{ep} [1080p]"
        end

      %{
        title: title,
        size: 1_000_000_000 + k,
        download_url: "https://indexer.example/#{k}",
        download_url_origin: nil,
        protocol: :torrent,
        category_ids: [5070],
        indexer_id: 1,
        published_at: nil
      }
    end
  end

  # The series' own strings: its title, each alias, each scene title and each mapping's scope.
  defp series_strings(context) do
    [context.title] ++
      Enum.map(context.aliases, & &1.title) ++
      Enum.map(context.scene_titles, & &1.title) ++
      for(%{scope_title: scope} <- context.mappings, do: scope)
  end

  defp judge(context, row_count) do
    rows = rows(row_count)
    stub(IndexerMock, :search_tv, fn _tvdb_id, _title, _season -> {:ok, rows} end)
    stub(IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, rows} end)
    ids = Enum.map(context.episodes, & &1.id)
    Acquisition.judge_anime_episodes(context, ids, indexer_source: IndexerMock)
  end

  # A traced `fun`'s count of normalizes of each of `strings`, and its result.
  defp traced_normalizes(strings, fun) do
    {result, calls} = CallTrace.calls({TitleAlias, :normalize, 1}, fun)
    own = MapSet.new(strings)
    {for(%{args: [arg]} <- calls, arg in own, do: arg) |> Enum.frequencies(), result}
  end

  # How often one anime episode search normalizes each of the series' own strings, and its pick.
  defp normalizes(context, row_count),
    do: traced_normalizes(series_strings(context), fn -> judge(context, row_count) end)

  # The titles a release's parse and its mapping freeze read again for each release
  # (`AnimeParser.parse/2`, `Intent.valid_mapping_snapshot?/3`): those its snapshot lists.
  defp parser_strings(%{kept: [%{mapping_snapshot: %{"parser_context" => parser}} | _]}),
    do: [parser["title"] | parser["aliases"]] ++ parser["blocked_titles"]

  test "one search normalizes each title the parser does not read once, however many rows it reads" do
    context = context(20)

    {few, {:ok, few_judged, false}} = normalizes(context, 12)
    {many, {:ok, many_judged, false}} = normalizes(context, 60)

    # The rows reach the parse, the scene scope and the mapping freeze.
    assert length(few_judged.kept) == 12
    assert length(many_judged.kept) == 60
    assert Enum.any?(many_judged.kept, &match?(%{coordinates: [%{scope_title: _} | _]}, &1))
    assert Enum.all?(many_judged.kept, &is_map(&1.mapping_snapshot))

    parser = parser_strings(many_judged)
    assert parser_strings(few_judged) == parser
    assert @scene_alias in parser

    expected =
      for title <- series_strings(context), title not in parser, into: %{}, do: {title, 1}

    # Positive control: more than the parser's 8 titles are left to count.
    assert map_size(expected) > 8
    assert Map.drop(few, parser) == expected
    assert Map.drop(many, parser) == expected
  end

  test "the parser's titles cost the same per search whatever the alias count" do
    {twenty, {:ok, twenty_judged, false}} = normalizes(context(20), 60)
    {forty, {:ok, forty_judged, false}} = normalizes(context(40), 60)

    parser_total = fn counts, judged ->
      counts |> Map.take(parser_strings(judged)) |> Map.values() |> Enum.sum()
    end

    assert length(parser_strings(twenty_judged)) == length(parser_strings(forty_judged))
    assert parser_total.(twenty, twenty_judged) > 0
    assert parser_total.(twenty, twenty_judged) == parser_total.(forty, forty_judged)
  end

  test "a search normalizes the parser's titles once, beyond what the parse and its snapshot check do for each release" do
    context = context(20)
    {_, parses} = CallTrace.calls({AnimeParser, :parse, 2}, fn -> judge(context, 12) end)

    {_, checks} =
      CallTrace.calls({Intent, :valid_mapping_snapshot?, 3}, fn -> judge(context, 12) end)

    {counts, {:ok, judged, false}} = normalizes(context, 12)
    parser = parser_strings(judged)

    # The same parses and checks, called alone with the arguments the search gave them.
    {alone, _} =
      traced_normalizes(parser, fn ->
        Enum.each(parses, &apply(AnimeParser, :parse, &1.args))
        Enum.each(checks, &apply(Intent, :valid_mapping_snapshot?, &1.args))
      end)

    # Positive control: each release went through both, and they read the parser's titles.
    assert length(parses) >= 12
    assert length(checks) >= 12
    assert alone |> Map.values() |> Enum.sum() > 0

    assert Map.take(counts, parser) == Map.new(parser, &{&1, Map.get(alone, &1, 0) + 1})
  end

  test "the episode search alone, with no parse, normalizes each title once" do
    context = context(20)
    rows = rows(30)
    # Free-text rows only, so the search's own title guard reads each one.
    stub(IndexerMock, :search_tv, fn _tvdb_id, _title, _season -> {:ok, []} end)
    stub(IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, rows} end)
    ids = Enum.map(context.episodes, & &1.id)

    {counts, {:ok, releases, false}} =
      traced_normalizes(series_strings(context), fn ->
        Anime.search_episodes(IndexerMock, context, ids, [])
      end)

    assert length(releases) == 30
    assert counts == Map.new(series_strings(context), &{&1, 1})
  end

  defp movie_context do
    aliases =
      [alias_record("Kimi no Na wa", :romaji)] ++
        for i <- 1..20, do: alias_record("Your Name Edition #{i}", :alternative)

    %{
      kind: :movie,
      title: "Your Name",
      year: 2016,
      aliases: aliases,
      localized_titles: [],
      profile: %{effective: :anime}
    }
  end

  defp movie_rows(count) do
    for k <- 1..count do
      title =
        if rem(k, 2) == 0,
          do: "[G#{k}] Kimi no Na wa (2016) [1080p]",
          else: "Your.Name.2016.1080p.BluRay-G#{k}"

      %{hd(rows(1)) | title: title, download_url: "https://indexer.example/m#{k}"}
    end
  end

  for {name, entry} <- [judge: :judge_anime_movie, search: :search_movie] do
    test "the anime movie #{name} normalizes each title once, however many rows it reads" do
      context = movie_context()
      strings = [context.title | Enum.map(context.aliases, & &1.title)]
      expected = Map.new(strings, &{&1, 1})

      for count <- [4, 20] do
        rows = movie_rows(count)
        stub(IndexerMock, :search, fn "tt1" -> {:ok, Enum.take(rows, 2)} end)
        stub(IndexerMock, :search_movie_query, fn _query, _opts -> {:ok, rows} end)

        {counts, result} =
          traced_normalizes(strings, fn ->
            case unquote(entry) do
              :judge_anime_movie ->
                Acquisition.judge_anime_movie("tt1", context, indexer_source: IndexerMock)

              :search_movie ->
                Anime.search_movie(IndexerMock, "tt1", context, [])
            end
          end)

        # Positive control: the guard keeps every row, so it read each one.
        kept =
          case result do
            {:ok, %{kept: kept}, false} -> kept
            {:ok, releases, false} -> releases
          end

        assert length(kept) == count
        assert counts == expected
      end
    end
  end

  test "a context whose aliases changed after the search reads its new aliases" do
    {:ok, %{guard: {:anime_episodes, searched, _ids}}, false} = judge(context(20), 3)
    changed = %{searched | aliases: [alias_record("Hitagi Crab", :romaji)]}
    release = Release.new(%{hd(rows(1)) | title: "[G] Hitagi Crab - S01E02 [1080p]"})

    refute Anime.names_series?(release, searched)
    assert Anime.names_series?(release, changed)

    assert [%{resolved_episode_ids: nil}] = Anime.episode_candidates([release], searched, [2])
    assert [%{resolved_episode_ids: [2]}] = Anime.episode_candidates([release], changed, [2])
  end

  test "a context whose scene titles changed after the search reads its new scene titles" do
    {:ok, %{guard: {:anime_episodes, searched, _ids}}, false} = judge(context(20), 3)
    [scene_title] = searched.scene_titles
    changed = %{searched | scene_titles: [%{scene_title | namespace: "other-order"}]}
    release = Release.new(%{hd(rows(1)) | title: "[G] #{@scene_alias} - 05 [1080p]"})
    candidates = &Anime.episode_candidates([release], &1, [5])

    # The changed scene title changes the answer, and the search's titles give way to it: the
    # answer is the one a context that never carried them gets.
    refute candidates.(changed) == candidates.(searched)
    assert candidates.(changed) == candidates.(Map.delete(changed, :anime_titles))
  end

  describe "a parity compare of an anime search" do
    @t0 ~U[2026-11-25 10:00:00Z]

    # One anime episode search on one indexer (configured 1, Prowlarr's 11), recorded with
    # `row_count` rows on each call and one Native-only row on the first, so the compare also
    # replays the search under each set of known differences.
    defp anime_run(context, row_count) do
      ids = Enum.map(context.episodes, & &1.id)
      search = %{label: "anime", kind: :anime_episodes, first: :prowlarr, opts: [now: @t0]}
      search = Map.merge(search, %{target: %{context: context, wanted_ids: ids}, tries: []})
      search = %{search | tries: [recorded_try(search, recorded_calls(search), row_count)]}

      history =
        for {%{callback: callback, args: args}, n} <-
              Enum.with_index(hd(search.tries).prowlarr.calls, 1),
            request <- Prowlarr.requests(callback, args) do
          {term, ids} = ProwlarrHistoryFixtures.written(request.query, request.type)

          %{
            id: n,
            indexer_id: 11,
            date: DateTime.add(@t0, 2),
            successful: true,
            query_results: 1,
            cached: false,
            source: "Prowlarr",
            paging: %{},
            query: term,
            query_type: request.type,
            categories: request.categories,
            ids: ids
          }
        end

      %{
        seed: 1,
        window: {@t0, DateTime.add(@t0, 3600)},
        indexers: [%{id: 1, name: "One", kinds: [:anime_episodes], link_check: :passed}],
        prowlarr_map: %{11 => 1},
        history: history,
        statuses: [],
        searches: [search]
      }
    end

    # The search's seam calls, each found by a replay that asks it.
    defp recorded_calls(search, calls \\ []) do
      case Picks.replay(search, search.opts, calls) do
        {_key, %{not_recorded: []}} ->
          calls

        {_key, %{not_recorded: missing}} ->
          found = for {callback, args} <- missing, do: %{callback: callback, args: args}
          recorded_calls(search, calls ++ found)
      end
    end

    defp recorded_try(search, calls, row_count),
      do: %{
        prowlarr: recorded_side(search, calls, row_count, :prowlarr),
        native: recorded_side(search, calls, row_count, :native)
      }

    defp recorded_side(search, calls, row_count, side) do
      recorded =
        for {call, index} <- Enum.with_index(calls) do
          rows = side_rows(side, call.callback, index, row_count)
          Map.merge(call, %{outcome: side_outcome(side, rows), started_at: @t0})
        end

      record = %{calls: recorded, finished_at: DateTime.add(@t0, 10), stops: []}
      Map.put(record, :result, elem(Picks.replay(search, search.opts, recorded), 0))
    end

    # Each call's rows as the side returns them: Prowlarr tags only `search_tv/3`'s rows
    # (`Cinder.Acquisition.IndexerSource.Prowlarr`), Native tags each row.
    defp side_rows(side, callback, index, row_count) do
      origins = if callback == :search_tv, do: [:id_scoped], else: [:free_text]
      native_only = if side == :native and index == 0, do: [List.last(rows(row_count + 1))]

      for row <- rows(row_count) ++ List.wrap(native_only) do
        Map.merge(row, %{
          download_url: "#{row.download_url}/#{index}",
          indexer_id: if(side == :native, do: 1, else: 11),
          indexer_source: Atom.to_string(side),
          query_origins: if(side == :native or origins == [:id_scoped], do: origins)
        })
      end
    end

    defp side_outcome(:native, rows),
      do: {:ok, rows, Report.put(Report.new(), {"native", 1}, "One", :asked)}

    defp side_outcome(:prowlarr, rows), do: {:ok, rows}

    # How often the compare normalizes each of the series' strings the parser does not read, how
    # many anime searches it replays, and its result.
    defp compare_normalizes(context, row_count) do
      run = anime_run(context, row_count)
      {:ok, judged, false} = judge(context, row_count)

      own =
        MapSet.difference(MapSet.new(series_strings(context)), MapSet.new(parser_strings(judged)))

      {_, replays} =
        CallTrace.calls({Acquisition, :judge_anime_episodes, 3}, fn -> Parity.compare(run) end)

      {counts, result} = traced_normalizes(own, fn -> Parity.compare(run) end)
      {counts, length(replays), result}
    end

    test "normalizes each title the parser does not read once per replay, however many rows" do
      context = context(20)
      {few, few_replays, few_result} = compare_normalizes(context, 1)
      {many, many_replays, many_result} = compare_normalizes(context, 3)

      # Positive control: the Native-only row is a gap, and no known difference explains it, so
      # the compare replays the search under each set of known differences.
      assert few_result.retry == [0]
      assert many_result.retry == [0]
      assert few_replays > 10
      assert map_size(few) > 8

      assert few == Map.new(few, fn {title, _} -> {title, few_replays} end)
      assert many_replays == few_replays
      assert many == few
    end
  end
end
