defmodule Cinder.Catalog.ParkStrikeTest do
  # #1588: a TV park that blocks nothing records a park strike; the third strike for one title in
  # one series blocks that title for the series, until a manual Search clears the strikes.
  use Cinder.DataCase, async: true

  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, BlockedReleases, Episode, EpisodeSearch, Grab}
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  @title "Show.S01E01.1080p.WEB-DL-GRP"

  defp strikes(series_id, title, count),
    do: Enum.each(1..count//1, fn _ -> BlockedReleases.record_park_strike!(series_id, title) end)

  defp strike_rows,
    do: Repo.all(from(b in BlockedRelease, where: b.reason == "park_strike"))

  describe "blocked_release_titles_for_series/2" do
    test "a title with two strikes stays grabbable, the third blocks it once, and a fourth keeps it blocked" do
      series = series_fixture()

      strikes(series.id, @title, 2)
      assert Catalog.blocked_release_titles_for_series(series.id) == []

      strikes(series.id, @title, 1)
      assert Catalog.blocked_release_titles_for_series(series.id) == [@title]

      strikes(series.id, @title, 1)
      assert Catalog.blocked_release_titles_for_series(series.id) == [@title]
    end

    test "strikes count per series: three in another series block nothing here" do
      series = series_fixture()
      other = series_fixture()

      strikes(other.id, @title, 3)
      strikes(series.id, @title, 2)

      assert Catalog.blocked_release_titles_for_series(series.id) == []
      assert Catalog.blocked_release_titles_for_series(other.id) == [@title]
    end

    test "strikes count per title: two and one for two titles block neither" do
      series = series_fixture()

      strikes(series.id, @title, 2)
      strikes(series.id, "Show.S01E01.720p-OTHER", 1)

      assert Catalog.blocked_release_titles_for_series(series.id) == []
    end

    test "naming the strike reason in :include_reasons surfaces no title under three strikes" do
      series = series_fixture()
      strikes(series.id, @title, 2)

      assert Catalog.blocked_release_titles_for_series(series.id,
               include_reasons: [:park_strike, :no_upgrade]
             ) == []
    end

    test "a struck-out title the upgrade sweep reads is blocked there too" do
      series = series_fixture()
      strikes(series.id, @title, 3)

      assert Catalog.blocked_release_titles_for_series(series.id, include_reasons: [:no_upgrade]) ==
               [@title]
    end

    test "a title both blocked and struck out is given once" do
      series = series_fixture()
      Catalog.block_series_release(series.id, @title, :no_files_matched)
      strikes(series.id, @title, 3)

      assert Catalog.blocked_release_titles_for_series(series.id) == [@title]
    end
  end

  describe "record_park_strike!/2" do
    test "records nothing for a nil series, a nil title or an empty title" do
      series = series_fixture()

      assert :ok = BlockedReleases.record_park_strike!(nil, @title)
      assert :ok = BlockedReleases.record_park_strike!(series.id, nil)
      assert :ok = BlockedReleases.record_park_strike!(series.id, "")

      assert Repo.all(BlockedRelease) == []
    end

    test "a park with strike: true records one strike for the grab's title in its series" do
      series = series_fixture()
      season = season_fixture(series)
      ep = episode_fixture(season)
      {:ok, grab} = Catalog.create_grab("h-strike", :torrent, [ep.id], @title)

      assert {:ok, _} = Catalog.park_grab(grab, strike: true)

      series_id = series.id

      assert [%BlockedRelease{series_id: ^series_id, release_title: @title, indexer_id: nil}] =
               strike_rows()
    end

    test "a park without strike: true records none" do
      series = series_fixture()
      season = season_fixture(series)
      ep = episode_fixture(season)
      {:ok, grab} = Catalog.create_grab("h-no-strike", :torrent, [ep.id], @title)

      assert {:ok, _} = Catalog.park_grab(grab)
      assert Repo.all(BlockedRelease) == []
    end

    # The strike is written in the park's own transaction, so a park that rolls back counts
    # nothing: the grab is still there and parks again next tick.
    test "a park whose transaction fails records no strike" do
      series = series_fixture()
      season = season_fixture(series)
      ep = episode_fixture(season)
      {:ok, grab} = Catalog.create_grab("h-fails", :torrent, [ep.id], @title)

      # A TEMP trigger lives on this test's sandbox connection only, and is dropped right after.
      Repo.query!("""
      CREATE TEMP TRIGGER park_strike_test_refuse_grab_delete BEFORE DELETE ON grabs
      BEGIN SELECT RAISE(ABORT, 'park_strike_test: grab delete refused'); END
      """)

      assert_raise Exqlite.Error, ~r/grab delete refused/, fn ->
        Catalog.park_grab(grab, strike: true)
      end

      Repo.query!("DROP TRIGGER park_strike_test_refuse_grab_delete")
      assert Repo.get(Grab, grab.id)
      assert strike_rows() == []
    end
  end

  describe "manual Search" do
    defp blocked_series do
      series = series_fixture()
      season = season_fixture(series)
      ep = episode_fixture(season, %{episode_number: 3, search_attempts: 10})
      strikes(series.id, @title, 3)
      Catalog.block_series_release(series.id, "Bad.S01E03", :no_files_matched)
      {series, season, ep}
    end

    test "an episode Search clears the series' strikes and keeps a no_files_matched block" do
      {series, _season, ep} = blocked_series()
      other = series_fixture()
      strikes(other.id, @title, 3)

      assert Catalog.blocked_release_titles_for_series(series.id) |> Enum.sort() ==
               ["Bad.S01E03", @title]

      Catalog.search_episode_now(ep)

      assert Catalog.blocked_release_titles_for_series(series.id) == ["Bad.S01E03"]
      # Cleared to zero: two more strikes still leave the title grabbable.
      strikes(series.id, @title, 2)
      assert Catalog.blocked_release_titles_for_series(series.id) == ["Bad.S01E03"]
      # Another series keeps its own strikes.
      assert Catalog.blocked_release_titles_for_series(other.id) == [@title]
    end

    test "a season Search clears the series' strikes and keeps a no_files_matched block" do
      {series, season, _ep} = blocked_series()

      Catalog.search_season_now(season)

      assert Catalog.blocked_release_titles_for_series(series.id) == ["Bad.S01E03"]
      strikes(series.id, @title, 2)
      assert Catalog.blocked_release_titles_for_series(series.id) == ["Bad.S01E03"]
    end

    # The Rehunter puts a search-parked episode back in the search, but keeps the strikes: it is
    # what restarted the loop this fix ends.
    test "the Rehunter re-queues the episode and keeps the title blocked" do
      {series, _season, ep} = blocked_series()

      Repo.update_all(from(e in Episode, where: e.id == ^ep.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(:second), -2, :day)]
      )

      assert EpisodeSearch.rehunt_parked_episodes(DateTime.add(DateTime.utc_now(), -1, :day)) == 1
      assert Repo.reload!(ep).search_attempts == 0

      assert Catalog.blocked_release_titles_for_series(series.id) |> Enum.sort() ==
               ["Bad.S01E03", @title]
    end
  end
end
