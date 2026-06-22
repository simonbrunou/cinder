defmodule Cinder.Download.TvPollerTest do
  use Cinder.DataCase, async: false

  import Mox

  # The poller logs warnings/errors on the park/retry paths exercised below; capture them so
  # test output stays pristine (they print on failure).
  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, Season, Series}
  alias Cinder.Download.TvPoller
  alias Cinder.Repo

  # The poller runs in its own process (and a fresh pid after a crash), so the mock must be
  # global. Shared Sandbox (async: false) lets those processes use the test-owned DB connection.
  setup :set_mox_global

  @past ~D[2001-01-01]

  defp series_tree do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        tvdb_id: 99,
        title: "Show",
        year: 2008,
        monitored: true,
        monitor_strategy: :all
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
    {series, season}
  end

  defp episode(season, ep_num, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Episode{
          season_id: season.id,
          episode_number: ep_num,
          monitored: true,
          air_date: @past
        },
        attrs
      )
    )
  end

  defp await_restart(name, old_pid) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ -> Process.sleep(10) && await_restart(name, old_pid)
    end
  end

  # A successful single-file import (content_path is the file itself).
  defp stub_single_file_import do
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)
  end

  test "advances a completed single-file grab through download to import in one tick" do
    {_series, season} = series_tree()
    e1 = episode(season, 3)
    {:ok, grab} = Catalog.create_grab("hash-a", :torrent, [e1.id])
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-a" ->
      {:ok, %{state: :completed, content_path: "/dl/Show.S01E03.1080p.mkv"}}
    end)

    stub_single_file_import()

    assert :ok = TvPoller.poll()

    # advance marked it downloaded, then import (same tick) hardlinked + finalized.
    assert Repo.get(Grab, grab.id) == nil
    imported = Repo.get!(Episode, e1.id)

    assert imported.file_path ==
             "/tmp/cinder-test-library/Show (2008)/Season 01/Show (2008) - S01E03.mkv"

    assert is_nil(imported.grab_id)
  end

  test "imports a downloaded season pack, mapping each file to its episode, then finalizes" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    e2 = episode(season, 2)
    {:ok, grab} = Catalog.create_grab("hash-p", :torrent, [e1.id, e2.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/pack" -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl/pack" ->
      {:ok,
       [
         {"/dl/pack/Show.S01E01.1080p.mkv", 3_000_000_000},
         {"/dl/pack/Show.S01E02.1080p.mkv", 3_000_000_000}
       ]}
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert :ok = TvPoller.poll()

    assert Repo.get(Grab, grab.id) == nil
    assert Repo.get!(Episode, e1.id).file_path =~ "S01E01"
    assert Repo.get!(Episode, e2.id).file_path =~ "S01E02"
  end

  test "parks a downloaded grab whose content matches no episode; its episode re-searches" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-u", :torrent, [e1.id])
    {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    # The file clearly names E09, which the grab does not want — never mislabel it as E01.
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/pack/Show.S01E09.1080p.mkv", 3_000_000_000}]}
    end)

    assert :ok = TvPoller.poll()

    assert Repo.get(Grab, grab.id) == nil
    parked = Repo.get!(Episode, e1.id)
    assert is_nil(parked.file_path)
    assert is_nil(parked.grab_id)
    assert parked.search_attempts >= 1
  end

  test "searches a wanted episode and grabs the matching release" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    # Patterns confirm the series' tvdb_id, title, and season number are passed through.
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01E01.1080p.WEB-DL-GRP",
           size: 2_000_000_000,
           download_url: "u",
           seeders: 5
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-new"} end)

    assert :ok = TvPoller.poll()

    linked = Repo.get!(Episode, e1.id)
    assert linked.grab_id
    grab = Repo.get!(Grab, linked.grab_id)
    assert grab.download_id == "hash-new"
    assert grab.download_protocol == :torrent
  end

  test "rejects a same-season release of a different series (does not grab)" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    # A different series at the same season number: its name does not contain "Show",
    # so the title guard drops it before scoring (no client.add — nothing is grabbed).
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season ->
      {:ok,
       [
         %{
           title: "Parks.and.Recreation.S01E01.1080p.WEB-DL-GRP",
           size: 2_000_000_000,
           download_url: "u"
         }
       ]}
    end)

    assert :ok = TvPoller.poll()

    e1 = Repo.get!(Episode, e1.id)
    assert is_nil(e1.grab_id)
    assert e1.search_attempts == 1
  end

  test "recovers from a crash and still advances + imports, with no double-grab (OTP payoff)" do
    {_series, season} = series_tree()
    e1 = episode(season, 3)
    {:ok, grab} = Catalog.create_grab("hash-c", :torrent, [e1.id])
    pid = start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-c" ->
      {:ok, %{state: :completed, content_path: "/dl/Show.S01E03.1080p.mkv"}}
    end)

    stub_single_file_import()

    Process.exit(pid, :kill)
    new_pid = await_restart(TvPoller, pid)
    assert new_pid != pid

    assert :ok = TvPoller.poll(new_pid)

    assert Repo.get(Grab, grab.id) == nil
    recovered = Repo.get!(Episode, e1.id)
    assert recovered.file_path
    assert is_nil(recovered.grab_id)
  end

  test "parks a persistently failing download after max attempts; the episode re-searches" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    {:ok, grab} = Catalog.create_grab("hash-z", :torrent, [e1.id])
    # Default search_retry_after (60s): the freed episode is not re-attempted the same tick.
    start_supervised!({TvPoller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-z" -> {:ok, %{state: :error}} end)

    # Bounded: retried each tick (still downloading), then parked.
    Enum.each(1..9, fn _ -> TvPoller.poll() end)
    assert Repo.get(Grab, grab.id)

    assert :ok = TvPoller.poll()
    assert Repo.get(Grab, grab.id) == nil
    parked = Repo.get!(Episode, e1.id)
    assert is_nil(parked.grab_id)
    assert parked.search_attempts >= 1
  end

  test "a wanted episode that never finds a release search-parks after max attempts" do
    {_series, season} = series_tree()
    e1 = episode(season, 1)
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season -> {:ok, []} end)

    Enum.each(1..10, fn _ -> TvPoller.poll() end)
    assert Repo.get!(Episode, e1.id).search_attempts == 10

    # Search-parked now (search_attempts >= max): further ticks no longer attempt it.
    assert :ok = TvPoller.poll()
    assert Repo.get!(Episode, e1.id).search_attempts == 10
  end

  test "a late-dated monitored episode becomes wanted after a refresh and grabs (M6 Done-when)" do
    series =
      Repo.insert!(%Series{
        tmdb_id: System.unique_integer([:positive]),
        tvdb_id: 99,
        title: "Show",
        year: 2008,
        monitored: true,
        monitor_strategy: :future
      })

    season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})

    # Announced but undated → monitored under :future, yet NOT wanted (air_date is nil).
    ep =
      Repo.insert!(%Episode{
        season_id: season.id,
        tmdb_episode_id: 700,
        episode_number: 1,
        monitored: true,
        air_date: nil
      })

    assert Catalog.wanted_episodes() == []

    # TMDB now carries a (past) air_date for the same episode.
    stub(Cinder.Catalog.TMDBMock, :get_series, fn _ ->
      {:ok,
       %{
         tmdb_id: series.tmdb_id,
         tvdb_id: 99,
         title: "Show",
         year: 2008,
         poster_path: nil,
         seasons: [%{season_number: 1}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn _, 1 ->
      {:ok,
       %{
         season_number: 1,
         episodes: [%{tmdb_episode_id: 700, episode_number: 1, title: "Aired", air_date: @past}]
       }}
    end)

    assert {:ok, _} = Catalog.refresh_series(series)
    assert [%Episode{id: id}] = Catalog.wanted_episodes()
    assert id == ep.id

    # The poller now finds and grabs it.
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 ->
      {:ok,
       [
         %{
           title: "Show.S01E01.1080p.WEB-DL-GRP",
           size: 2_000_000_000,
           download_url: "u",
           seeders: 5
         }
       ]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-m6"} end)

    assert :ok = TvPoller.poll()

    linked = Repo.get!(Episode, ep.id)
    assert linked.grab_id
    assert Repo.get!(Grab, linked.grab_id).download_id == "hash-m6"
  end
end
