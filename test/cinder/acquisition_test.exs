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

    test "rejects a same-season release of a different series (wrong-series guard)" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Parks.and.Recreation.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert :no_match = Acquisition.best_releases(series(), 1, [1])
    end

    test "title-match folds diacritics so an ASCII-ized release still matches" do
      expect(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
        {:ok, [raw_tv("Pokemon.S01E01.1080p.WEB-DL-GRP")]}
      end)

      assert {:ok, [{%Release{episodes: [1]}, [1]}]} =
               Acquisition.best_releases(series(title: "Pokémon"), 1, [1])
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
  end
end
