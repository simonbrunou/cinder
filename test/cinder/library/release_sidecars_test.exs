defmodule Cinder.Library.ReleaseSidecarsTest do
  @moduledoc """
  #1413: a staged video's release sidecars are listed once, and that one list feeds both the
  commit's links and the record. For each stage outcome, for a movie, an episode and a movie
  stacked in parts, these tests check the sidecar languages the import records against the
  sidecars on disk next to the file once the commit ran:

  - `:placed` and `:replaced`: the release's sidecars, all linked.
  - `:same_file`: the languages already next to the file, then the release's, linked. The
    exception is a replay that is not forced over a recorded row: it keeps the row's own list
    while the commit links the release's sidecars.
  - `:kept`: the row's own list. The commit links none of the release's sidecars (#784).

  A single-file release has no sidecars to link, so on a forced `:same_file` it records none,
  even of the ones already next to the file.

  Real temp directories throughout: what is under test is which subtitle files land on disk.
  """
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import ExUnit.CaptureLog
  import Mox

  alias Cinder.{ConfigCase, Library, LibraryStubs}
  alias Cinder.Library.{MediaServerMock, StagedImport}

  @moduletag :tmp_dir
  @gb 1_000_000_000
  @release "Movie.2020.720p.WEB-GRP"
  @episode_release "Show.S01E01.720p.WEB-GRP"

  # The row's own recorded quality on a `:kept` stage: better than the 720p release, with a
  # sidecar list the import must keep as it is.
  @better %{
    imported_resolution: "1080p",
    imported_source: "BLURAY",
    imported_size: 9 * @gb,
    imported_sidecar_subtitles: ["en"]
  }

  # A recorded quality the release replaces when forced.
  @worse %{imported_resolution: "720p", imported_size: 7}

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    downloads = Path.join(tmp, "downloads")
    movies = Path.join(tmp, "movies")
    tv = Path.join(tmp, "tv")
    Enum.each([downloads, movies, tv], &File.mkdir_p!/1)

    ConfigCase.put_env(
      filesystem: Cinder.Library.Filesystem.Disk,
      path_policy: Cinder.Library.PathPolicy,
      import_roots: [downloads],
      explicit_import_roots: [downloads],
      movies_library_path: movies,
      tv_library_path: tv,
      move_on_import: false
    )

    {:ok, downloads: downloads, movies: movies, tv: tv}
  end

  describe "a movie" do
    test ":placed records and links the release's sidecars", ctx do
      folder = release_folder(ctx.downloads, "#{@release}-14130")
      dest = movie_dest(ctx.movies, 14_130)
      movie = movie_row(14_130, folder, %{})

      quality = import_movie(movie, [])

      assert File.read!(dest) == "release"
      assert quality.sidecar_subtitles == ["fr"]
      assert sidecars_on_disk(dest) == ["fr"]
    end

    test ":replaced records and links the release's sidecars", ctx do
      folder = release_folder(ctx.downloads, "#{@release}-14131")
      dest = held_file(movie_dest(ctx.movies, 14_131))
      movie = movie_row(14_131, folder, Map.put(@worse, :file_path, dest))

      quality = import_movie(movie, replace: true)

      assert File.read!(dest) == "release"
      assert quality.sidecar_subtitles == ["fr"]
      assert sidecars_on_disk(dest) == ["fr"]
    end

    test ":same_file records the languages already there, then the release's", ctx do
      folder = release_folder(ctx.downloads, "#{@release}-14132")
      dest = release_video_at(folder_video(folder), movie_dest(ctx.movies, 14_132))
      hand_placed!(dest, "en")
      movie = movie_row(14_132, folder, Map.put(@worse, :file_path, dest))

      quality = import_movie(movie, replace: true)

      assert quality.sidecar_subtitles == ["en", "fr"]
      assert sidecars_on_disk(dest) == ["en", "fr"]
    end

    # The one cell where the record and the links differ, kept on purpose: a replay that is not
    # forced keeps the row's recorded quality, sidecar list included, while the commit links the
    # release's sidecars (`tv_upgrade_arbitration_test.exs` pins the same for a declined keep).
    test "an unforced :same_file over a recorded row keeps its list and links the release's",
         ctx do
      folder = release_folder(ctx.downloads, "#{@release}-14135")
      dest = release_video_at(folder_video(folder), movie_dest(ctx.movies, 14_135))
      movie = movie_row(14_135, folder, Map.put(@better, :file_path, dest))

      quality = import_movie(movie, [])

      assert quality.resolution == "1080p"
      assert quality.sidecar_subtitles == ["en"]
      assert sidecars_on_disk(dest) == ["fr"]
    end

    test ":kept keeps the row's list and links none of the release's sidecars", ctx do
      folder = release_folder(ctx.downloads, "#{@release}-14133")
      dest = held_file(movie_dest(ctx.movies, 14_133))
      movie = movie_row(14_133, folder, Map.put(@better, :file_path, dest))

      {quality, log} = with_log(fn -> import_movie(movie, []) end)

      assert log =~ "kept existing"
      assert File.read!(dest) == "held"
      assert quality.sidecar_subtitles == ["en"]
      assert sidecars_on_disk(dest) == []
    end

    # The one list: a sidecar that lands in the release folder after staging is neither recorded
    # nor linked.
    test "a sidecar added to the release after staging is neither recorded nor linked", ctx do
      folder = release_folder(ctx.downloads, "#{@release}-14134")
      dest = movie_dest(ctx.movies, 14_134)
      movie = movie_row(14_134, folder, %{})

      expect_scan(:movies)
      assert {:ok, staged} = Library.stage_movie(movie)
      File.write!(Path.join(folder, "#{Path.basename(folder)}.de.srt"), "1")
      assert :ok = LibraryStubs.commit_staged(staged)
      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()

      assert StagedImport.record(staged).quality.sidecar_subtitles == ["fr"]
      assert sidecars_on_disk(dest) == ["fr"]
    end
  end

  describe "an episode" do
    test ":placed records and links the release's sidecars", ctx do
      folder = release_folder(ctx.downloads, "#{@episode_release}-14140")
      dest = episode_dest(ctx.tv, 14_140)
      episode = show_episode(14_140, %{})

      assert {quality, true} = import_episode(folder, episode)

      assert File.read!(dest) == "release"
      assert quality.sidecar_subtitles == ["fr"]
      assert sidecars_on_disk(dest) == ["fr"]
    end

    # A held `file_path` keeps the default `:force` collision, which swaps the file.
    test ":replaced records and links the release's sidecars", ctx do
      folder = release_folder(ctx.downloads, "#{@episode_release}-14141")
      dest = held_file(episode_dest(ctx.tv, 14_141))
      episode = show_episode(14_141, Map.put(@worse, :file_path, dest))

      assert {quality, true} = import_episode(folder, episode)

      assert File.read!(dest) == "release"
      assert quality.sidecar_subtitles == ["fr"]
      assert sidecars_on_disk(dest) == ["fr"]
    end

    test ":same_file records the languages already there, then the release's", ctx do
      folder = release_folder(ctx.downloads, "#{@episode_release}-14142")
      dest = release_video_at(folder_video(folder), episode_dest(ctx.tv, 14_142))
      hand_placed!(dest, "en")
      episode = show_episode(14_142, Map.put(@worse, :file_path, dest))

      assert {quality, true} = import_episode(folder, episode)

      assert quality.sidecar_subtitles == ["en", "fr"]
      assert sidecars_on_disk(dest) == ["en", "fr"]
    end

    # With no `file_path` the default `:force` collision falls back to `:adopt`: the release's own
    # video at the canonical path is an unforced `:same_file` over the recorded row, which keeps
    # its list while the commit links the release's sidecars (as for a movie above).
    test "an unforced :same_file over a recorded row keeps its list and links the release's",
         ctx do
      folder = release_folder(ctx.downloads, "#{@episode_release}-14144")
      dest = release_video_at(folder_video(folder), episode_dest(ctx.tv, 14_144))
      episode = show_episode(14_144, @better)

      assert {quality, true} = import_episode(folder, episode)

      assert quality.resolution == "1080p"
      assert quality.sidecar_subtitles == ["en"]
      assert sidecars_on_disk(dest) == ["fr"]
    end

    # With no `file_path` the default `:force` collision falls back to `:adopt`, which keeps the
    # better file at the canonical path.
    test ":kept keeps the row's list and links none of the release's sidecars", ctx do
      folder = release_folder(ctx.downloads, "#{@episode_release}-14143")
      dest = held_file(episode_dest(ctx.tv, 14_143))
      episode = show_episode(14_143, @better)

      {{quality, _placed?}, log} = with_log(fn -> import_episode(folder, episode) end)

      assert log =~ "kept existing"
      assert File.read!(dest) == "held"
      assert quality.sidecar_subtitles == ["en"]
      assert sidecars_on_disk(dest) == []
    end
  end

  # Each part brings its own language, so the merged record shows each part's link.
  describe "a movie stacked in parts" do
    test ":placed records and links each part's sidecars", ctx do
      folder = stacked_release(ctx.downloads, 14_150)
      [dest1, dest2] = part_dests(ctx.movies, 14_150)
      movie = movie_row(14_150, folder, %{})

      quality = import_movie(movie, [])

      assert File.read!(dest2) == "release cd2"
      assert Enum.sort(quality.sidecar_subtitles) == ["de", "fr"]
      assert sidecars_on_disk(dest1) == ["fr"]
      assert sidecars_on_disk(dest2) == ["de"]
    end

    test ":replaced records and links each part's sidecars", ctx do
      folder = stacked_release(ctx.downloads, 14_151)
      [dest1, dest2] = ctx.movies |> part_dests(14_151) |> Enum.map(&held_file/1)

      movie =
        movie_row(
          14_151,
          folder,
          Map.merge(@worse, %{file_path: dest1, part_file_paths: [dest2]})
        )

      quality = import_movie(movie, replace: true)

      assert File.read!(dest2) == "release cd2"
      assert Enum.sort(quality.sidecar_subtitles) == ["de", "fr"]
      assert sidecars_on_disk(dest1) == ["fr"]
      assert sidecars_on_disk(dest2) == ["de"]
    end

    test ":same_file records the languages already there, then each part's", ctx do
      folder = stacked_release(ctx.downloads, 14_152)

      [dest1, dest2] =
        ctx.movies
        |> part_dests(14_152)
        |> Enum.zip(["cd1", "cd2"])
        |> Enum.map(fn {dest, part} -> release_video_at(part_video(folder, part), dest) end)

      hand_placed!(dest2, "en")

      movie =
        movie_row(
          14_152,
          folder,
          Map.merge(@worse, %{file_path: dest1, part_file_paths: [dest2]})
        )

      quality = import_movie(movie, replace: true)

      assert Enum.sort(quality.sidecar_subtitles) == ["de", "en", "fr"]
      assert sidecars_on_disk(dest1) == ["fr"]
      assert sidecars_on_disk(dest2) == ["de", "en"]
    end

    test ":kept keeps the row's list and links none of the parts' sidecars", ctx do
      folder = stacked_release(ctx.downloads, 14_153)
      [dest1, dest2] = ctx.movies |> part_dests(14_153) |> Enum.map(&held_file/1)

      movie =
        movie_row(
          14_153,
          folder,
          Map.merge(@better, %{file_path: dest1, part_file_paths: [dest2]})
        )

      {quality, log} = with_log(fn -> import_movie(movie, []) end)

      assert log =~ "kept existing"
      assert File.read!(dest2) == "held"
      assert quality.sidecar_subtitles == ["en"]
      assert sidecars_on_disk(dest1) == []
      assert sidecars_on_disk(dest2) == []
    end
  end

  # A release with no sidecar list (a single file) and a release folder with an empty one differ
  # on a forced `:same_file`: the first records the incoming quality as it is, the second the
  # languages already next to the file.
  describe "no release sidecars against an empty list, on a forced :same_file" do
    test "a single-file release records none of the languages already there", ctx do
      file = Path.join(ctx.downloads, "#{@release}-14160.mkv")
      File.write!(file, "release")
      dest = release_video_at(file, movie_dest(ctx.movies, 14_160))
      hand_placed!(dest, "en")
      movie = movie_row(14_160, file, Map.put(@worse, :file_path, dest))

      quality = import_movie(movie, replace: true)

      assert quality.sidecar_subtitles == []
      assert sidecars_on_disk(dest) == ["en"]
    end

    test "a release folder with no sidecars records the languages already there", ctx do
      folder = release_folder(ctx.downloads, "#{@release}-14161", [])
      dest = release_video_at(folder_video(folder), movie_dest(ctx.movies, 14_161))
      hand_placed!(dest, "en")
      movie = movie_row(14_161, folder, Map.put(@worse, :file_path, dest))

      quality = import_movie(movie, replace: true)

      assert quality.sidecar_subtitles == ["en"]
      assert sidecars_on_disk(dest) == ["en"]
    end
  end

  # Stages and commits `movie`'s download, and returns the quality the record holds.
  defp import_movie(movie, opts) do
    expect_scan(:movies)
    assert {:ok, staged} = Library.stage_movie(movie, opts)
    assert :ok = LibraryStubs.commit_staged(staged)
    assert_receive {:scanned, :movies}
    LibraryStubs.await_subtitle_tasks()
    StagedImport.record(staged).quality
  end

  # Stages and commits `episode`'s file from `folder`, and returns its recorded quality and
  # placement flag.
  defp import_episode(folder, episode) do
    expect_scan(:tv)
    assert {:ok, staged, []} = Library.stage_episodes(folder, [episode])
    assert [{_id, _dest, quality, placed?}] = StagedImport.record(staged)
    assert :ok = LibraryStubs.commit_staged(staged)
    assert_receive {:scanned, :tv}
    LibraryStubs.await_subtitle_tasks()
    {quality, placed?}
  end

  # A release folder: one video named after the folder, and its sidecars (French by default).
  defp release_folder(downloads, name, sidecars \\ ["fr.srt"]) do
    folder = Path.join(downloads, name)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, name <> ".mkv"), "release")
    Enum.each(sidecars, &File.write!(Path.join(folder, "#{name}.#{&1}"), "1"))
    folder
  end

  # A release stacked in two parts: cd1 with a French sidecar, cd2 with a German one.
  defp stacked_release(downloads, tmdb_id) do
    folder = Path.join(downloads, "#{@release}-#{tmdb_id}")
    File.mkdir_p!(folder)

    for {part, language} <- [{"cd1", "fr"}, {"cd2", "de"}] do
      File.write!(part_video(folder, part), "release #{part}")
      File.write!(Path.join(folder, "#{@release}.#{part}.#{language}.srt"), "1")
    end

    folder
  end

  defp folder_video(folder), do: Path.join(folder, Path.basename(folder) <> ".mkv")

  defp part_video(folder, part), do: Path.join(folder, "#{@release}.#{part}.mkv")

  # The release's own video at `dest`, one inode: what a replay or a forced re-import finds there.
  defp release_video_at(video, dest) do
    File.mkdir_p!(Path.dirname(dest))
    File.ln!(video, dest)
    dest
  end

  # `part` is a stack part's suffix (`Naming.movie_part_dest/4`).
  defp movie_dest(movies, tmdb_id, part \\ "") do
    name = "Movie (2020) {tmdb-#{tmdb_id}}"
    Path.join([movies, name, name <> part <> ".mkv"])
  end

  defp part_dests(movies, tmdb_id),
    do: Enum.map(["-cd1", "-cd2"], &movie_dest(movies, tmdb_id, &1))

  defp episode_dest(tv, tmdb_id) do
    show = "Show (2008) {tmdb-#{tmdb_id}}"
    Path.join([tv, show, "Season 01", show <> " - S01E01.mkv"])
  end

  defp movie_row(tmdb_id, content_path, attrs) do
    %{
      tmdb_id: tmdb_id,
      title: "Movie",
      year: 2020,
      status: :downloaded,
      content_path: content_path,
      release_title: @release
    }
    |> Map.merge(attrs)
    |> movie_fixture()
  end

  defp show_episode(tmdb_id, attrs) do
    %{tmdb_id: tmdb_id, title: "Show", year: 2008}
    |> series_fixture()
    |> season_fixture()
    |> episode_fixture(attrs)
    |> Repo.preload(season: :series)
  end

  # The file the library already holds at `dest`.
  defp held_file(dest) do
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, "held")
    dest
  end

  # The user's own `<video>.<language>.srt`.
  defp hand_placed!(video, language),
    do: File.write!(Path.rootname(video) <> ".#{language}.srt", "hand #{language}")

  # The languages of the `<video stem>.<language>.srt` files next to `video`, sorted. No glob: the
  # `{tmdb-N}` in a library name is a wildcard alternation.
  defp sidecars_on_disk(video) do
    prefix = Path.basename(Path.rootname(video)) <> "."

    video
    |> Path.dirname()
    |> File.ls!()
    |> Enum.filter(&(String.starts_with?(&1, prefix) and Path.extname(&1) == ".srt"))
    |> Enum.map(&(&1 |> String.replace_prefix(prefix, "") |> Path.rootname()))
    |> Enum.sort()
  end

  # The commit's media-server scan runs in this process; it is the proof the effects ran.
  defp expect_scan(kind) do
    parent = self()

    expect(MediaServerMock, :scan, fn ^kind ->
      send(parent, {:scanned, kind})
      :ok
    end)
  end
end
