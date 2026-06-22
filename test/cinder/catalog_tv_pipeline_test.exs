defmodule Cinder.CatalogTvPipelineTest do
  # async: false — create_grab/3 wraps a Repo.transaction; the SQLite sandbox needs shared
  # mode for nested transactions (same reason as catalog_series_test.exs).
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, Season, Series}

  @past ~D[2001-01-01]
  @future ~D[2099-01-01]

  defp series_with_season do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Show",
        year: 2008,
        monitored: true,
        monitor_strategy: :all
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
    {series, season}
  end

  defp episode(season, attrs) do
    Repo.insert!(
      struct(
        %Episode{
          season_id: season.id,
          episode_number: System.unique_integer([:positive]),
          monitored: true,
          air_date: @past
        },
        attrs
      )
    )
  end

  describe "transition_episode/2" do
    test "sets a pipeline field, persists, and broadcasts {:series_updated, series_id}" do
      {series, season} = series_with_season()
      ep = episode(season, %{})
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, ep} = Catalog.transition_episode(ep, %{file_path: "/library/x.mkv"})
      assert ep.file_path == "/library/x.mkv"
      assert_receive {:series_updated, ^series_id}
      assert Repo.get(Episode, ep.id).file_path == "/library/x.mkv"
    end
  end

  describe "grab lifecycle" do
    test "create_grab/3 links episodes, persists, and broadcasts" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      e2 = episode(season, %{})
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, grab} = Catalog.create_grab("HASH1", :torrent, [e1.id, e2.id])
      assert grab.download_id == "HASH1"
      assert grab.download_protocol == :torrent
      assert is_nil(grab.content_path)
      assert_receive {:series_updated, ^series_id}

      assert Repo.get(Episode, e1.id).grab_id == grab.id
      assert Repo.get(Episode, e2.id).grab_id == grab.id
    end

    test "mark_grab_downloaded/2 sets content_path, moves the grab between the lists, broadcasts" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      {:ok, grab} = Catalog.create_grab("HASH2", :usenet, [e1.id])
      series_id = series.id
      # Subscribe after create_grab so we assert mark's broadcast, not create's.
      Catalog.subscribe_series()

      assert [%Grab{id: id}] = Catalog.list_grabs_downloading()
      assert id == grab.id
      assert Catalog.list_grabs_downloaded() == []

      assert {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/pack")
      assert grab.content_path == "/downloads/pack"
      assert_receive {:series_updated, ^series_id}
      assert Catalog.list_grabs_downloading() == []
      assert [%Grab{id: ^id}] = Catalog.list_grabs_downloaded()
    end

    test "delete_grab/1 removes the grab and nilifies its episodes' grab_id" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      series_id = series.id
      {:ok, grab} = Catalog.create_grab("HASH3", :torrent, [e1.id])
      Catalog.subscribe_series()

      assert {:ok, _} = Catalog.delete_grab(grab)
      assert_receive {:series_updated, ^series_id}
      assert Repo.get(Grab, grab.id) == nil
      assert Repo.get(Episode, e1.id).grab_id == nil
    end

    test "create_grab/3 does not re-link an episode another grab already owns" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{})
      {:ok, first} = Catalog.create_grab("H1", :torrent, [e1.id])

      # e1 is already grabbed → nothing links → the whole grab rolls back (no orphan grab),
      # and e1 stays on the first grab.
      assert {:error, :no_episodes_linked} = Catalog.create_grab("H2", :torrent, [e1.id])
      assert Repo.get(Episode, e1.id).grab_id == first.id
      assert Repo.all(Grab) |> length() == 1
    end

    test "create_grab/3 links only the free episodes when some are already grabbed" do
      {_series, season} = series_with_season()
      taken = episode(season, %{})
      free = episode(season, %{})
      {:ok, _first} = Catalog.create_grab("H1", :torrent, [taken.id])

      # A partial set (one free, one taken) still succeeds, linking just the free episode.
      assert {:ok, second} = Catalog.create_grab("H2", :torrent, [taken.id, free.id])
      assert Repo.get(Episode, free.id).grab_id == second.id
      refute Repo.get(Episode, taken.id).grab_id == second.id
    end
  end

  describe "finish_grab/2" do
    test "sets each imported episode's own file_path, clears grab_id, deletes the grab, broadcasts" do
      {series, season} = series_with_season()
      e1 = episode(season, %{})
      e2 = episode(season, %{})
      {:ok, grab} = Catalog.create_grab("H", :torrent, [e1.id, e2.id])
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, _} =
               Catalog.finish_grab(grab, [{e1.id, "/lib/s01e01.mkv"}, {e2.id, "/lib/s01e02.mkv"}])

      assert_receive {:series_updated, ^series_id}

      r1 = Repo.get(Episode, e1.id)
      r2 = Repo.get(Episode, e2.id)
      # Distinct dests, not one path forced onto all.
      assert r1.file_path == "/lib/s01e01.mkv"
      assert r2.file_path == "/lib/s01e02.mkv"
      assert is_nil(r1.grab_id) and is_nil(r2.grab_id)
      assert Repo.get(Grab, grab.id) == nil
    end

    test "partial pack: bumps search_attempts on the non-imported episode, deletes the grab" do
      {_series, season} = series_with_season()
      got = episode(season, %{})
      missing = episode(season, %{search_attempts: 2})
      {:ok, grab} = Catalog.create_grab("H", :torrent, [got.id, missing.id])

      assert {:ok, _} = Catalog.finish_grab(grab, [{got.id, "/lib/got.mkv"}])

      assert Repo.get(Episode, got.id).file_path == "/lib/got.mkv"
      m = Repo.get(Episode, missing.id)
      assert is_nil(m.file_path)
      assert is_nil(m.grab_id)
      assert m.search_attempts == 3
      assert Repo.get(Grab, grab.id) == nil
    end
  end

  describe "park_grab/1" do
    test "deletes the grab and bumps every linked episode's search_attempts" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{search_attempts: 0})
      e2 = episode(season, %{search_attempts: 5})
      {:ok, grab} = Catalog.create_grab("H", :torrent, [e1.id, e2.id])

      assert {:ok, _} = Catalog.park_grab(grab)
      assert Repo.get(Episode, e1.id).search_attempts == 1
      assert Repo.get(Episode, e2.id).search_attempts == 6
      assert Repo.get(Grab, grab.id) == nil
    end
  end

  describe "grab/episode retry counters" do
    test "increment_grab_attempts/1 bumps download_attempts" do
      {_series, season} = series_with_season()
      {:ok, grab} = Catalog.create_grab("H", :torrent, [episode(season, %{}).id])

      assert :ok = Catalog.increment_grab_attempts(grab)
      assert Repo.get(Grab, grab.id).download_attempts == 1
    end

    test "mark_grab_downloaded/2 resets download_attempts to 0 at the download boundary" do
      {_series, season} = series_with_season()
      {:ok, grab} = Catalog.create_grab("H", :torrent, [episode(season, %{}).id])
      :ok = Catalog.increment_grab_attempts(grab)
      grab = Repo.get(Grab, grab.id)
      assert grab.download_attempts == 1

      assert {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/x")
      assert grab.download_attempts == 0
    end

    test "increment_search_attempts/1 bumps the given episodes; empty list is a no-op" do
      {_series, season} = series_with_season()
      e1 = episode(season, %{search_attempts: 0})
      e2 = episode(season, %{search_attempts: 3})

      assert :ok = Catalog.increment_search_attempts([e1.id, e2.id])
      assert Repo.get(Episode, e1.id).search_attempts == 1
      assert Repo.get(Episode, e2.id).search_attempts == 4

      assert :ok = Catalog.increment_search_attempts([])
    end
  end

  describe "wanted_episodes/0" do
    test "returns monitored, aired (incl. today), file-less, grab-less episodes only" do
      {_series, season} = series_with_season()
      past = episode(season, %{air_date: @past, monitored: true})
      today = episode(season, %{air_date: Date.utc_today(), monitored: true})
      unaired = episode(season, %{air_date: @future, monitored: true})
      tba = episode(season, %{air_date: nil, monitored: true})
      unmonitored = episode(season, %{air_date: @past, monitored: false})

      ids = Enum.map(Catalog.wanted_episodes(), & &1.id)
      assert Enum.sort(ids) == Enum.sort([past.id, today.id])
      refute unaired.id in ids
      refute tba.id in ids
      refute unmonitored.id in ids
    end

    test "excludes episodes with a file or an active grab" do
      {_series, season} = series_with_season()
      imported = episode(season, %{})
      grabbed = episode(season, %{})
      free = episode(season, %{})

      {:ok, _} = Catalog.transition_episode(imported, %{file_path: "/x.mkv"})
      {:ok, _} = Catalog.create_grab("H", :torrent, [grabbed.id])

      assert Enum.map(Catalog.wanted_episodes(), & &1.id) == [free.id]
    end

    test "preloads season and series for the poller" do
      {series, season} = series_with_season()
      episode(season, %{})

      assert [ep] = Catalog.wanted_episodes()
      assert ep.season.id == season.id
      assert ep.season.series.id == series.id
    end

    test "excludes season 0 (specials) — unaddressable by the parser/scorer in M5" do
      {series, season} = series_with_season()
      regular = episode(season, %{air_date: @past, monitored: true})
      specials = Repo.insert!(%Season{series_id: series.id, season_number: 0, monitored: true})
      special = episode(specials, %{air_date: @past, monitored: true})

      ids = Enum.map(Catalog.wanted_episodes(), & &1.id)
      assert regular.id in ids
      refute special.id in ids
    end
  end
end
