defmodule Cinder.AcquisitionTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Acquisition
  alias Cinder.Acquisition.Release
  alias Cinder.Catalog.Series

  setup :verify_on_exit!

  @gb 1_000_000_000

  # A raw indexer result map with sensible defaults; override per case.
  defp raw(attrs) do
    Map.merge(
      %{title: "Movie.2020.1080p.BluRay.x264-GRP", size: 8 * @gb, download_url: "u", seeders: 10},
      Map.new(attrs)
    )
  end

  defp series(attrs \\ []), do: struct(%Series{tvdb_id: 123, title: "The Office"}, attrs)

  defp raw_tv(title, attrs \\ []),
    do: Map.merge(%{title: title, size: 2 * @gb, download_url: "u", seeders: 10}, Map.new(attrs))

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

  test "best_release/2 excludes releases whose protocol has no configured client" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ ->
      {:ok,
       [
         raw(title: "Movie.2020.1080p.WEB-DL-USE", protocol: :usenet, size: 9 * @gb),
         raw(title: "Movie.2020.720p.BluRay.x264-TOR", protocol: :torrent, size: 4 * @gb)
       ]}
    end)

    # Only torrent clients available: the 1080p Usenet release is filtered out
    # before scoring, so the 720p torrent wins despite the lower resolution.
    assert {:ok, %Release{resolution: "720p", protocol: :torrent}} =
             Acquisition.best_release("tt1", protocols: [:torrent], max_size: 20 * @gb)
  end

  test "best_release/2 with no :protocols opt keeps every protocol" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn _ ->
      {:ok, [raw(title: "Movie.2020.1080p.WEB-DL-USE", protocol: :usenet, size: 9 * @gb)]}
    end)

    assert {:ok, %Release{protocol: :usenet}} =
             Acquisition.best_release("tt1", max_size: 20 * @gb)
  end

  test "best_release filters by language: french pick keeps a FRENCH release" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb),
         raw(title: "Movie.2020.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{group: "FR", language: "FRENCH"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "french",
               original_language: "en"
             )
  end

  test "best_release: a french 480p is rejected, not grabbed, when 1080p was asked for" do
    # The reported bug: a French pick where the only in-band French release is 480p (the higher-res
    # French one is absent/too big) used to grab the 480p. With the resolution allow-list it parks.
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Movie.2020.FRENCH.480p.WEB-DL-FR", size: 2 * @gb),
         raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb)
       ]}
    end)

    assert :no_match =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "french",
               original_language: "en",
               preferred_resolutions: ["1080p", "720p"]
             )
  end

  test "best_release returns :no_language_match when nothing satisfies the pick" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok, [raw(title: "Movie.2020.1080p.BluRay.x264-EN", size: 8 * @gb)]}
    end)

    assert :no_language_match =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "french",
               original_language: "en"
             )
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
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "original",
               original_language: "en"
             )
  end

  test "best_release with no language preference is unchanged (any/nil)" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok, [raw(title: "Movie.2020.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)]}
    end)

    assert {:ok, %Release{group: "FR"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "any",
               original_language: "en"
             )
  end

  test "best_release with original pick falls back when a title-word collision tags every release" do
    # The parser tags `language` from the whole release name, so "The Italian Job" is tagged
    # ITALIAN. Under the soft default (original/en), nothing satisfies — but rather than parking,
    # best_release falls back to scoring the unfiltered candidates so the title isn't stranded.
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "The.Italian.Job.2003.720p.BluRay.x264-GRP", size: 6 * @gb),
         raw(title: "The.Italian.Job.2003.1080p.BluRay.x264-GRP", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{language: "ITALIAN", resolution: "1080p"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "original",
               original_language: "en"
             )
  end

  test "best_release with an explicit language pick still parks on a title-word collision (strict)" do
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "The.Italian.Job.2003.720p.BluRay.x264-GRP", size: 6 * @gb),
         raw(title: "The.Italian.Job.2003.1080p.BluRay.x264-GRP", size: 8 * @gb)
       ]}
    end)

    assert :no_language_match =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "french",
               original_language: "en"
             )
  end

  test "best_release: a recognised foreign dub never outranks the original-language release" do
    # The Hungarian bug: the dub used to parse to nil, was assumed 'original', and could outscore
    # the French release. Now it's tagged HUNGARIAN and dropped, so French wins despite being smaller.
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Chasse.Gardee.2024.HUNGARIAN.1080p.WEB-DL.x264-GRP", size: 12 * @gb),
         raw(title: "Chasse.Gardee.2024.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{language: "FRENCH"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "original",
               original_language: "fr"
             )
  end

  test "best_release: an untagged release is treated as English, not a non-English original" do
    # No language token → English by scene convention → dropped for a French 'original' pick,
    # so it can't masquerade as the French original and outscore the real French release.
    expect(Cinder.Acquisition.IndexerMock, :search, fn "tt1" ->
      {:ok,
       [
         raw(title: "Chasse.Gardee.2024.1080p.WEB-DL.x264-GRP", size: 12 * @gb),
         raw(title: "Chasse.Gardee.2024.FRENCH.1080p.BluRay.x264-FR", size: 8 * @gb)
       ]}
    end)

    assert {:ok, %Release{language: "FRENCH"}} =
             Acquisition.best_release("tt1",
               max_size: 20 * @gb,
               preferred_language: "original",
               original_language: "fr"
             )
  end

  describe "list_releases/2" do
    test "returns every release annotated with its verdict, acceptable first" do
      Cinder.Acquisition.IndexerMock
      |> expect(:search, fn "tt1" ->
        {:ok,
         [
           %{
             title: "Good 1080p",
             size: 5_000_000_000,
             seeders: 9,
             download_url: "u",
             protocol: :torrent
           },
           %{
             title: "Huge 1080p",
             size: 90_000_000_000,
             seeders: 9,
             download_url: "u",
             protocol: :torrent
           }
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
      |> expect(:search, fn _ ->
        {:ok, [%{title: "U", size: 1_000_000_000, protocol: :usenet, download_url: "u"}]}
      end)

      assert {:ok, [{_r, {:rejected, :wrong_protocol}}]} =
               Acquisition.list_releases("tt1", protocols: [:torrent])
    end

    test "passes through an indexer error" do
      Cinder.Acquisition.IndexerMock |> expect(:search, fn _ -> {:error, :down} end)
      assert Acquisition.list_releases("tt1", []) == {:error, :down}
    end
  end

  describe "best_releases/4 (TV)" do
    test "composes search_tv, parse, title-match, and set-cover scoring (release ⇒ coverage)" do
      # Patterns confirm the series' tvdb_id, title, and season number are passed through.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok,
         [
           raw_tv("The.Office.US.S01E01.1080p.WEB-DL-GRP"),
           raw_tv("The.Office.US.S01E02.1080p.WEB-DL-GRP")
         ]}
      end)

      assert {:ok, chosen} = Acquisition.best_releases(series(), 1, [1, 2])
      assert chosen |> Enum.map(fn {_r, cov} -> cov end) |> Enum.sort() == [[1], [2]]
    end

    test "rejects a same-season release of a different series on the free-text path" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Parks.and.Recreation.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(tvdb_id: nil), 1, [1])
    end

    test "does not title-filter a TvdbId-scoped search, so AKA-titled releases still grab" do
      # TMDB title "Money Heist", release under the original title — the TvdbId
      # token already scoped the search to the right show.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, _title, _season ->
        {:ok, [raw_tv("La.Casa.de.Papel.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(title: "Money Heist"), 1, [1])
    end

    test "a numeric title is token-anchored: a year in another show's name can't match" do
      # Regression: substring matching let series "24" accept "Other.Show.2024..." —
      # the scorer then matched on season number alone and imported the wrong show.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Other.Show.2024.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(tvdb_id: nil, title: "24"), 1, [5])
    end

    test "an all-numeric title still matches its own releases" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("24.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [5]}, [5]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "24"), 1, [5])
    end

    test "a tag-prefixed release name still matches a short title (token, not prefix, anchor)" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("[TGx] 24.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [5]}, [5]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "24"), 1, [5])
    end

    test "a franchise-prefixed release name still matches (series '1883' in 'Yellowstone.1883')" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Yellowstone.1883.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "1883"), 1, [1])
    end

    test "a title embedded inside another token is rejected ('Dark' vs 'Darkwing.Duck')" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Darkwing.Duck.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(tvdb_id: nil, title: "Dark"), 1, [5])
    end

    test "a title that folds to nothing (non-Latin) fails closed instead of matching everything" do
      # "Дом" tokenizes to [] — matching would accept EVERY same-season release. Those series
      # need the tvdb_id-scoped path (which skips the guard).
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Random.Show.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(tvdb_id: nil, title: "Дом"), 1, [5])
    end

    test "an '&' in a mostly-non-Latin title can't inflate the needle past the fail-closed guard" do
      # "&"→"and" expansion must count on BOTH sides of the ratio: otherwise "Дом & Сад"
      # folds to the needle "and", which matches half the releases on any indexer.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Law.and.Order.S01E05.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match =
               Acquisition.best_releases(series(tvdb_id: nil, title: "Дом & Сад"), 1, [5])
    end

    test "title-match folds diacritics so an ASCII-ized release still matches" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Pokemon.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "Pokémon"), 1, [1])
    end

    test "title-match equates '&' and 'and' so scene names match ampersand titles" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Law.and.Order.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(tvdb_id: nil, title: "Law & Order"), 1, [1])
    end

    test "drops releases whose protocol has no configured client before scoring" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok,
         [
           raw_tv("The.Office.US.S01E01.1080p.WEB-DL-USE", protocol: :usenet),
           raw_tv("The.Office.US.S01E02.720p.WEB-DL-TOR", protocol: :torrent)
         ]}
      end)

      assert {:ok, [{%Release{protocol: :torrent, episodes: [2]}, [2]}]} =
               Acquisition.best_releases(series(), 1, [1, 2], protocols: [:torrent])
    end

    test ":no_match when nothing survives; indexer error passes through" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _, _, _ -> {:ok, []} end)
      assert :no_match = Acquisition.best_releases(series(), 1, [1])

      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _, _, _ -> {:error, :timeout} end)
      assert {:error, :timeout} = Acquisition.best_releases(series(), 1, [1])
    end

    test "best_releases filters episodes by language: french pick covers only FRENCH/MULTI episodes" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok,
         [
           raw_tv("The.Office.S01E01.FRENCH.1080p.WEB-DL-FR"),
           raw_tv("The.Office.S01E02.1080p.WEB-DL-EN")
         ]}
      end)

      assert {:ok, chosen} =
               Acquisition.best_releases(series(), 1, [1, 2],
                 preferred_language: "french",
                 original_language: "en"
               )

      # E02 has only an English release -> not covered; E01 (FRENCH) is covered.
      assert chosen |> Enum.flat_map(fn {_r, cov} -> cov end) |> Enum.sort() == [1]
    end

    test "best_releases with original pick falls back when a title-word collision tags every episode" do
      # Same soft-default fallback as the movie path: every episode is tagged ITALIAN by the
      # release name, nothing satisfies original/en, so it covers via the unfiltered candidates.
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok,
         [
           raw_tv("The.Office.S01E01.ITALIAN.1080p.WEB-DL-GRP"),
           raw_tv("The.Office.S01E02.ITALIAN.1080p.WEB-DL-GRP")
         ]}
      end)

      assert {:ok, chosen} =
               Acquisition.best_releases(series(), 1, [1, 2],
                 preferred_language: "original",
                 original_language: "en"
               )

      assert chosen |> Enum.flat_map(fn {_r, cov} -> cov end) |> Enum.sort() == [1, 2]
    end

    test "best_releases returns :no_match when no episode has a satisfying release" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn 123, "The Office", 1 ->
        {:ok,
         [
           raw_tv("The.Office.S01E01.1080p.WEB-DL-EN"),
           raw_tv("The.Office.S01E02.1080p.WEB-DL-EN")
         ]}
      end)

      assert :no_match =
               Acquisition.best_releases(series(), 1, [1, 2],
                 preferred_language: "french",
                 original_language: "en"
               )
    end
  end
end
