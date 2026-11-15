defmodule Cinder.Download.TvPollerLibraryCheckTest do
  # #720: the TV sweep adopts the files a requested season already has under the TV root before
  # it first searches the season, so it downloads only the episodes that are missing.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox
  import Cinder.AccountsFixtures
  import Cinder.BoundedWalkHelpers
  import Cinder.ConfigCase, only: [put_env: 2]
  import Cinder.PollerHelpers, only: [stub_clean_content: 0]

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season}
  alias Cinder.Download.{Poller, TvPoller}
  alias Cinder.Library.Adoption
  alias Cinder.Repo
  alias Cinder.Requests

  @moduletag :capture_log

  setup :set_mox_global

  @root "/tmp/cinder-test-tv-library"
  @folder "/tmp/cinder-test-tv-library/Show (2001) {tmdb-1399}"

  setup do
    on_exit(fn ->
      :persistent_term.erase({Poller, :last_run})
      :persistent_term.erase({TvPoller, :last_run})
    end)

    stub_clean_content()
    stub_tmdb(1399, 99)
    :ok
  end

  defp stub_tmdb(tmdb_id, tvdb_id) do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         tvdb_id: if(id == tmdb_id, do: tvdb_id, else: id),
         title: "Show",
         year: 2001,
         poster_path: nil,
         seasons: [%{season_number: 1, episode_count: 3}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn _id, 1, _locale ->
      {:ok,
       %{
         season_number: 1,
         episodes:
           for(
             n <- 1..3,
             do: %{
               tmdb_episode_id: n,
               episode_number: n,
               title: "E#{n}",
               air_date: ~D[2001-01-01]
             }
           )
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _id -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _id -> {:ok, []} end)
  end

  defp approve_season!(tmdb_id \\ 1399) do
    assert {:ok, %{status: :approved}} =
             Requests.create_request(admin_fixture(), %{
               target_type: "season",
               target_id: tmdb_id,
               season_number: 1
             })

    series = Catalog.get_series_by_tmdb_id(tmdb_id)

    episodes =
      Map.new(
        Repo.all(
          from e in Episode,
            join: s in assoc(e, :season),
            where: s.series_id == ^series.id,
            preload: :season
        ),
        &{&1.episode_number, &1}
      )

    {series, episodes}
  end

  defp stub_folder(files) do
    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:ok, [Path.basename(@folder)]} end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn @folder ->
      {:ok, Enum.map(files, &{Path.join(@folder, &1), 1_000_000_000})}
    end)
  end

  # One single-episode release per episode, so a grab shows exactly which episodes were searched.
  defp stub_releases do
    releases =
      for n <- 1..3,
          do: %{
            title: "Show.S01E0#{n}.1080p.WEB.x264-GRP",
            size: 2_000_000_000,
            download_url: "e#{n}"
          }

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Show", 1 -> {:ok, releases} end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, releases} end)

    adds = start_supervised!({Agent, fn -> [] end})

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      Agent.update(adds, &[release.download_url | &1])
      {:ok, "grab-#{release.download_url}"}
    end)

    adds
  end

  defp added(adds), do: adds |> Agent.get(& &1) |> Enum.sort()

  defp poll! do
    case Process.whereis(TvPoller) do
      nil -> start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
      _pid -> :ok
    end

    assert :ok = TvPoller.poll()
  end

  defp armed_at(episode), do: Repo.get!(Season, episode.season_id).library_check_armed_at

  test "an approved season adopts the files already under the TV root and grabs only the rest" do
    {_series, eps} = approve_season!()
    stub_folder(["Season 01/Show.S01E01.mkv", "Season 01/Show.S01E02.mkv"])
    adds = stub_releases()

    poll!()

    # An adopted episode leaves the search: no grab, and no search attempt spent on it.
    assert %Episode{file_path: path1, grab_id: nil, search_attempts: 0} = Repo.reload!(eps[1])
    assert path1 == Path.join(@folder, "Season 01/Show.S01E01.mkv")
    assert %Episode{file_path: path2, grab_id: nil, search_attempts: 0} = Repo.reload!(eps[2])
    assert path2 == Path.join(@folder, "Season 01/Show.S01E02.mkv")
    assert %Episode{file_path: nil, grab_id: grab_id} = Repo.reload!(eps[3])
    assert is_integer(grab_id)
    assert added(adds) == ["e3"]
    assert armed_at(eps[1]) == nil
  end

  test "two files claiming one episode adopt neither; the episode is grabbed and stays on /library/adopt" do
    {_series, eps} = approve_season!()
    stub_folder(["Show.S01E01.mkv", "Copy/Show.S01E01.mkv", "Show.S01E02.mkv"])
    adds = stub_releases()

    poll!()

    assert Repo.reload!(eps[1]).file_path == nil
    assert Repo.reload!(eps[2]).file_path == Path.join(@folder, "Show.S01E02.mkv")
    assert added(adds) == ["e1", "e3"]

    # The scan of /library/adopt still offers both claimants for the operator to choose.
    stub(Cinder.Library.FilesystemMock, :find_files, fn
      "/tmp/cinder-test-library" ->
        {:ok, []}

      @root ->
        {:ok,
         [
           {Path.join(@folder, "Show.S01E01.mkv"), 10},
           {Path.join(@folder, "Copy/Show.S01E01.mkv"), 10}
         ]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      {:ok, %File.Stat{type: :regular, size: 10, major_device: 1, inode: :erlang.phash2(path)}}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn 1399, 1, _locale ->
      {:ok,
       %{
         season_number: 1,
         episodes: for(n <- 1..3, do: %{tmdb_episode_id: n, episode_number: n, title: "E#{n}"})
       }}
    end)

    assert [%{kind: :series, files: files}] = Adoption.scan()

    assert files |> Enum.map(&{&1.path, &1.status}) |> Enum.sort() == [
             {Path.join(@folder, "Copy/Show.S01E01.mkv"), :unmatched},
             {Path.join(@folder, "Show.S01E01.mkv"), :unmatched}
           ]
  end

  test "a wedged TV root holds the season unsearched, and a later tick adopts and searches it" do
    test_pid = self()
    {_series, eps} = approve_season!()
    put_env(:season_adoption_timeout_ms, 300)

    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> hang_walk(test_pid) end)
    adds = stub_releases()

    poll!()

    assert_receive {:walking, walk}
    release_walk_on_exit(walk)
    assert added(adds) == []
    assert %Episode{file_path: nil, grab_id: nil, search_attempts: 0} = Repo.reload!(eps[1])
    assert %DateTime{} = armed_at(eps[1])

    # While the walk stays stuck the guard refuses the root at once: still held, nothing searched.
    poll!()
    assert added(adds) == []

    release_walk(walk)
    put_env(:season_adoption_timeout_ms, 10_000)
    stub_folder(["Show.S01E01.mkv"])

    poll!()

    assert Repo.reload!(eps[1]).file_path == Path.join(@folder, "Show.S01E01.mkv")
    assert added(adds) == ["e2", "e3"]
    assert armed_at(eps[1]) == nil
  end

  test "a TMDB error on a title-only folder holds the season" do
    {_series, eps} = approve_season!()
    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:ok, ["Show (2001)"]} end)
    stub(Cinder.Catalog.TMDBMock, :search_tv, fn "Show", _locale -> {:error, :timeout} end)
    adds = stub_releases()

    log = capture_log(fn -> poll!() end)

    assert added(adds) == []
    assert %DateTime{} = armed_at(eps[1])
    assert log =~ "tv library check for series"
    assert log =~ "held"
  end

  test "a check that raises holds the season and says it raised" do
    {_series, eps} = approve_season!()
    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> raise "mount gone" end)
    adds = stub_releases()

    log = capture_log(fn -> poll!() end)

    assert added(adds) == []
    assert %DateTime{} = armed_at(eps[1])
    assert log =~ "held: :check_raised"
  end

  test "an hour after the approval a check that still holds gives up and the season is searched" do
    {_series, eps} = approve_season!()

    Repo.update_all(from(s in Season, where: s.id == ^eps[1].season_id),
      set: [library_check_armed_at: DateTime.add(DateTime.utc_now(:second), -3_600)]
    )

    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:error, :eio} end)
    adds = stub_releases()

    log = capture_log(fn -> poll!() end)

    assert added(adds) == ["e1", "e2", "e3"]
    assert armed_at(eps[1]) == nil
    assert log =~ "gave up"
  end

  test "a season with no armed check is searched without reading the library" do
    {_series, eps} = approve_season!()
    Catalog.clear_library_check(Repo.get!(Season, eps[1].season_id))
    # No FilesystemMock stub: a library read would raise inside the sweep and skip the search.
    adds = stub_releases()

    poll!()

    assert added(adds) == ["e1", "e2", "e3"]
  end

  test "clearing a check leaves one an approval armed again meanwhile" do
    {_series, eps} = approve_season!()
    read = Repo.get!(Season, eps[1].season_id)
    rearmed = DateTime.add(read.library_check_armed_at, 5)

    Repo.update_all(from(s in Season, where: s.id == ^read.id),
      set: [library_check_armed_at: rearmed]
    )

    assert :ok = Catalog.clear_library_check(read)
    assert armed_at(eps[1]) == rearmed
  end

  test "at most two series run a library check per tick; the third waits unsearched" do
    for tmdb_id <- [1399, 1400, 1401], do: approve_season!(tmdb_id)
    lists = start_supervised!({Agent, fn -> 0 end}, id: :lists)

    stub(Cinder.Library.FilesystemMock, :ls, fn @root ->
      Agent.update(lists, &(&1 + 1))
      {:ok, []}
    end)

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb, _title, _season -> {:ok, []} end)
    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, []} end)

    poll!()
    assert Agent.get(lists, & &1) == 2

    assert [waiting] =
             Repo.all(from s in Season, where: not is_nil(s.library_check_armed_at), select: s.id)

    # The waiting season was not searched: no attempt spent on its episodes.
    assert Repo.all(from e in Episode, where: e.season_id == ^waiting, select: e.search_attempts) ==
             [0, 0, 0]

    poll!()
    assert Agent.get(lists, & &1) == 3

    assert Repo.aggregate(from(s in Season, where: not is_nil(s.library_check_armed_at)), :count) ==
             0
  end
end
