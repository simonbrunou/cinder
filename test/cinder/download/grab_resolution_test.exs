defmodule Cinder.Download.GrabResolutionTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, GrabFile, Grabs, Identity}
  alias Cinder.Download.TvPoller
  alias Cinder.Library
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :set_mox_global

  @tag :tmp_dir
  test "Fold binds provider evidence, drops the extra source, and closes", %{tmp_dir: tmp} do
    %{grab: grab, episode: episode, files: [file], release_dir: release_dir, tv: tv} =
      mixed_grab(tmp, ["Show.S01E99.mkv"])

    assert {:ok, :decided, _file} = TvPoller.resolve_grab_file(file.id, episode.id, :fold)
    refute Repo.get(Grab, grab.id)
    refute File.exists?(release_dir)

    assert [coordinate] =
             episode.season.series
             |> Identity.list_coordinates()
             |> Enum.filter(&(&1.canonical_value == "S01E99"))

    assert coordinate.precedence == :manual
    assert Enum.map(coordinate.memberships, & &1.episode_id) == [episode.id]
    assert length(Path.wildcard(Path.join([tv, "**", "*.mkv"]))) == 1
  end

  @tag :tmp_dir
  test "Keep as part stages a canonical part, appends it atomically, and closes", %{
    tmp_dir: tmp
  } do
    %{grab: grab, episode: episode, files: [file], release_dir: release_dir} =
      mixed_grab(tmp, ["Show.S01E99.mkv"])

    assert {:ok, :decided, _file} = TvPoller.resolve_grab_file(file.id, episode.id, :part)
    refute Repo.get(Grab, grab.id)
    refute File.exists?(release_dir)

    assert %Episode{part_file_paths: [part]} = Repo.reload!(episode)
    assert part =~ "-part-"
    assert File.read!(part) == "extra-1"
  end

  @tag :tmp_dir
  test "Hold mutates nothing and keeps cleanup fenced", %{tmp_dir: tmp} do
    %{grab: grab, files: [file], release_dir: release_dir} =
      mixed_grab(tmp, ["Show.S01E99.mkv"])

    assert {:ok, :open} = TvPoller.finalize_residual_grab(grab)
    assert Repo.get(Grab, grab.id)
    assert Repo.get!(GrabFile, file.id).decision == nil
    assert File.exists?(release_dir)
  end

  @tag :tmp_dir
  test "two residuals close only after the second decision and resubmission is a no-op", %{
    tmp_dir: tmp
  } do
    %{grab: grab, episode: episode, files: [first, second], release_dir: release_dir} =
      mixed_grab(tmp, ["Show.S01E98.mkv", "Show.S01E99.mkv"])

    assert {:ok, :decided, _file} =
             TvPoller.resolve_grab_file(first.id, episode.id, :fold)

    assert Repo.get(Grab, grab.id)
    assert File.exists?(release_dir)

    assert {:ok, :noop, _file} =
             TvPoller.resolve_grab_file(first.id, episode.id, :fold)

    assert Repo.get(Grab, grab.id)
    assert {:ok, :decided, _file} = TvPoller.resolve_grab_file(second.id, episode.id, :fold)
    refute Repo.get(Grab, grab.id)
    refute File.exists?(release_dir)
  end

  @tag :tmp_dir
  test "concurrent submissions claim one residual decision exactly once", %{tmp_dir: tmp} do
    %{episode: episode, files: [first, _second]} =
      mixed_grab(tmp, ["Show.S01E98.mkv", "Show.S01E99.mkv"])

    assert {:ok, :pending, file, selected} =
             Grabs.get_grab_file_resolution(first.id, episode.id)

    states =
      for _attempt <- 1..2 do
        Task.async(fn ->
          assert {:ok, state, _file} = Catalog.decide_grab_file(file, selected, :fold, nil)
          state
        end)
      end
      |> Task.await_many()
      |> Enum.sort()

    assert states == [:decided, :noop]
  end

  @tag :tmp_dir
  test "a committed decision is closed by the next poll after a crash boundary", %{tmp_dir: tmp} do
    %{grab: grab, episode: episode, files: [file], release_dir: release_dir} =
      mixed_grab(tmp, ["extra.mkv"])

    assert {:ok, :pending, pending, selected} =
             Grabs.get_grab_file_resolution(file.id, episode.id)

    assert {:ok, :decided, _file} = Catalog.decide_grab_file(pending, selected, :fold, nil)
    assert Repo.get(Grab, grab.id)
    assert File.exists?(release_dir)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()
    refute Repo.get(Grab, grab.id)
    refute File.exists?(release_dir)
  end

  defp mixed_grab(tmp, residual_names) do
    %{downloads: downloads, tv: tv} = use_real_tv_library(tmp)
    release_dir = Path.join(downloads, "Show.S01")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, "Show.S01E01.mkv"), "primary")

    residual_names
    |> Enum.with_index(1)
    |> Enum.each(fn {name, index} ->
      File.write!(Path.join(release_dir, name), "extra-#{index}")
    end)

    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season, %{episode_number: 1, tmdb_episode_id: 101})
    {:ok, grab} = Catalog.create_grab("mixed-#{System.unique_integer()}", :usenet, [episode.id])
    {:ok, _grab} = Catalog.mark_grab_downloaded(grab, release_dir)
    grab = Enum.find(Catalog.list_grabs_downloaded(), &(&1.id == grab.id))

    assert {:ok, [{episode_id, stage}], unmatched} =
             Library.stage_episodes(grab.content_path, grab.episodes)

    assert episode_id == episode.id
    assert {:ok, residuals} = Library.inventory_grab_files(release_dir, unmatched, grab.episodes)

    assert {:ok, :open, _grab} =
             Catalog.commit_grab_imports(
               grab,
               [{episode_id, stage.dest, stage.quality}],
               residuals,
               Library.stage_ids([stage])
             )

    assert :ok = Library.commit_stage(stage)

    grab = Enum.find(Catalog.list_grabs(), &(&1.id == grab.id))

    %{
      grab: grab,
      episode: hd(grab.episodes),
      files: Enum.sort_by(grab.grab_files, & &1.relative_path),
      release_dir: release_dir,
      tv: tv
    }
  end

  defp use_real_tv_library(tmp) do
    downloads = Path.join(tmp, "downloads")
    tv = Path.join(tmp, "tv")
    File.mkdir_p!(downloads)
    File.mkdir_p!(tv)

    keys = [
      :filesystem,
      :path_policy,
      :import_roots,
      :explicit_import_roots,
      :tv_library_path,
      :move_on_import
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])
    Application.put_env(:cinder, :tv_library_path, tv)
    Application.put_env(:cinder, :move_on_import, true)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, delete_files: true -> :ok end)

    %{downloads: downloads, tv: tv}
  end
end
