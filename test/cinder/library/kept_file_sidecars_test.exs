defmodule Cinder.Library.KeptFileSidecarsTest do
  @moduledoc """
  #784: an import whose destination already holds a better file keeps that file (the `:kept`
  outcome). The declined release's sidecars must not land next to it: they were timed for the
  release's video, and the kept file's recorded sidecar list would no longer match the disk. #291
  fixed the arbitrated TV decline; these cover the movie import and the plain TV import.

  #822: when the file at the destination is the release's own video (the `:same_file` outcome), the
  commit links the release's sidecars next to it, and the record lists them.

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

  describe "a movie import onto a file already at its destination" do
    test "links none of the release's sidecars when it keeps the better file", %{
      downloads: downloads,
      movies: movies
    } do
      folder = release_folder(downloads, "Movie.2020.720p.WEB-GRP")

      dest =
        held_file(Path.join([movies, "Movie (2020) {tmdb-7840}", "Movie (2020) {tmdb-7840}.mkv"]))

      movie =
        movie_fixture(%{
          tmdb_id: 7840,
          title: "Movie",
          year: 2020,
          status: :downloaded,
          content_path: folder,
          release_title: "Movie.2020.720p.WEB-GRP",
          file_path: dest,
          imported_resolution: "1080p",
          imported_source: "BLURAY",
          imported_size: 9 * @gb,
          imported_sidecar_subtitles: ["en"]
        })

      expect_scan(:movies)

      log =
        capture_log(fn ->
          assert {:ok, staged} = Library.stage_movie(movie)
          assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
          assert quality.resolution == "1080p"
          assert quality.sidecar_subtitles == ["en"]
          assert :ok = LibraryStubs.commit_staged(staged)
        end)

      # Positive anchors: the import declined the release and the commit ran its effects, so the
      # refutes below are not vacuous.
      assert log =~ "kept existing"
      assert_receive {:scanned, :movies}
      assert File.read!(dest) == "held"
      refute File.exists?(Path.rootname(dest) <> ".fr.srt")
    end

    # `:same_file` still links: the release's video IS the file at the destination (one inode), so
    # its subtitles were timed for it. A replay after a crash before the catalog write never ran
    # the first attempt's effects, and the download is removed after import.
    test "still links them when that file is the release's own video", %{
      downloads: downloads,
      movies: movies
    } do
      folder = release_folder(downloads, "Movie.2020.720p.WEB-GRP")
      dest = release_video_at(folder_video(folder), movie_dest(movies, 7841))

      movie =
        same_file_movie(7841, folder, %{
          file_path: dest,
          imported_resolution: "1080p",
          imported_source: "BLURAY",
          imported_size: 9 * @gb
        })

      expect_scan(:movies)

      assert {:ok, staged} = Library.stage_movie(movie)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :movies}
      assert File.read!(Path.rootname(dest) <> ".fr.srt") == "1"
    end
  end

  describe "a TV import that keeps the file at its destination" do
    # The episode records a better quality than the release, and a file sits at its canonical
    # path. With no `file_path` the default `:force` collision falls back to `:adopt`, which keeps
    # the better file: the non-arbitrated route to `:kept` (library_test.exs covers its quality).
    test "links none of the declined release's sidecars", %{downloads: downloads, tv: tv} do
      folder = release_folder(downloads, "Show.S01E01.720p.WEB-GRP")

      dest =
        held_file(
          Path.join([
            tv,
            "Show (2008) {tmdb-7842}",
            "Season 01",
            "Show (2008) {tmdb-7842} - S01E01.mkv"
          ])
        )

      series = series_fixture(%{tmdb_id: 7842, title: "Show", year: 2008})

      episode =
        series
        |> season_fixture()
        |> episode_fixture(%{
          imported_resolution: "1080p",
          imported_source: "BLURAY",
          imported_size: 9 * @gb,
          imported_sidecar_subtitles: ["en"]
        })
        |> Repo.preload(season: :series)

      expect_scan(:tv)

      log =
        capture_log(fn ->
          assert {:ok, staged, []} = Library.stage_episodes(folder, [episode])
          assert [{_id, ^dest, quality, _placed?}] = StagedImport.record(staged)
          assert quality.resolution == "1080p"
          assert quality.sidecar_subtitles == ["en"]
          assert :ok = LibraryStubs.commit_staged(staged)
        end)

      assert log =~ "kept existing"
      assert_receive {:scanned, :tv}
      assert File.read!(dest) == "held"
      refute File.exists?(Path.rootname(dest) <> ".fr.srt")
    end
  end

  # #822: the record is what the post-import subtitle fetch reads as the languages the release
  # brought, so it must list the sidecars the commit links next to the release's own video.
  describe "an import whose destination already holds the release's own video" do
    test "a forced movie re-import records the sidecars it links", %{
      downloads: downloads,
      movies: movies
    } do
      folder = release_folder(downloads, "Movie.2020.720p.WEB-GRP")
      dest = release_video_at(folder_video(folder), movie_dest(movies, 8220))
      File.write!(Path.rootname(dest) <> ".en.srt", "1")

      movie =
        same_file_movie(8220, folder, %{
          file_path: dest,
          imported_resolution: "720p",
          imported_source: "WEBDL",
          imported_size: 7,
          imported_sidecar_subtitles: ["en"]
        })

      expect_scan(:movies)

      assert {:ok, staged} = Library.stage_movie(movie, replace: true)
      assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()
      assert quality.sidecar_subtitles == ["en", "fr"]
      assert sidecars_on_disk(dest) == ["en", "fr"]
    end

    test "a movie replay over an unrecorded row records them too", %{
      downloads: downloads,
      movies: movies
    } do
      folder = release_folder(downloads, "Movie.2020.720p.WEB-GRP")
      dest = release_video_at(folder_video(folder), movie_dest(movies, 8221))
      movie = same_file_movie(8221, folder, %{})

      expect_scan(:movies)

      assert {:ok, staged} = Library.stage_movie(movie)
      assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()
      assert quality.resolution == "720p"
      assert quality.sidecar_subtitles == ["fr"]
      assert sidecars_on_disk(dest) == ["fr"]
    end

    # A held `file_path` keeps the default `:force` collision; none falls back to `:adopt`, the
    # replay of a crash between placement and the catalog write.
    test "an episode import records them, forced or replaying over an unrecorded row", %{
      downloads: downloads,
      tv: tv
    } do
      for {tmdb_id, row} <- [{8222, :recorded}, {8223, :unrecorded}] do
        folder = release_folder(downloads, "Show.S01E01.720p.WEB-GRP-#{tmdb_id}")
        dest = release_video_at(folder_video(folder), episode_dest(tv, tmdb_id))
        episode = show_episode(tmdb_id, row_attrs(row, dest))

        expect_scan(:tv)

        assert {:ok, staged, []} = Library.stage_episodes(folder, [episode])
        assert [{_id, ^dest, quality, true}] = StagedImport.record(staged)
        assert :ok = LibraryStubs.commit_staged(staged)

        assert_receive {:scanned, :tv}
        LibraryStubs.await_subtitle_tasks()
        assert quality.sidecar_subtitles == ["fr"]
        assert sidecars_on_disk(dest) == ["fr"]
      end
    end

    # A single-file download brings no sidecars: the subtitle beside it in the downloads folder
    # belongs to nothing this import knows about.
    test "a single-file download records and links none", %{
      downloads: downloads,
      movies: movies
    } do
      for {tmdb_id, opts, row} <- [{8224, [replace: true], :recorded}, {8225, [], :unrecorded}] do
        name = "Movie.2020.720p.WEB-GRP-#{tmdb_id}"
        file = Path.join(downloads, name <> ".mkv")
        File.write!(file, "release")
        File.write!(Path.join(downloads, name <> ".fr.srt"), "1")
        dest = release_video_at(file, movie_dest(movies, tmdb_id))
        movie = same_file_movie(tmdb_id, file, row_attrs(row, dest))

        expect_scan(:movies)

        assert {:ok, staged} = Library.stage_movie(movie, opts)
        assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
        assert :ok = LibraryStubs.commit_staged(staged)

        # Positive anchor: the commit ran its effects, so the empty lists are not vacuous.
        assert_receive {:scanned, :movies}
        assert quality.sidecar_subtitles == []
        assert sidecars_on_disk(dest) == []
      end
    end
  end

  # A release folder: one video named after the folder, and its French sidecar.
  defp release_folder(downloads, name) do
    folder = Path.join(downloads, name)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, name <> ".mkv"), "release")
    File.write!(Path.join(folder, name <> ".fr.srt"), "1")
    folder
  end

  defp folder_video(folder), do: Path.join(folder, Path.basename(folder) <> ".mkv")

  # The release's own video at `dest`, one inode: what a replay or a forced re-import finds there.
  defp release_video_at(video, dest) do
    File.mkdir_p!(Path.dirname(dest))
    File.ln!(video, dest)
    dest
  end

  defp movie_dest(movies, tmdb_id) do
    name = "Movie (2020) {tmdb-#{tmdb_id}}"
    Path.join([movies, name, name <> ".mkv"])
  end

  defp episode_dest(tv, tmdb_id) do
    show = "Show (2008) {tmdb-#{tmdb_id}}"
    Path.join([tv, show, "Season 01", show <> " - S01E01.mkv"])
  end

  defp same_file_movie(tmdb_id, content_path, attrs) do
    %{
      tmdb_id: tmdb_id,
      title: "Movie",
      year: 2020,
      status: :downloaded,
      content_path: content_path,
      release_title: "Movie.2020.720p.WEB-GRP"
    }
    |> Map.merge(attrs)
    |> movie_fixture()
  end

  # A row that holds `dest` with a recorded quality, or one that holds nothing and records nothing.
  defp row_attrs(:recorded, dest),
    do: %{file_path: dest, imported_resolution: "720p", imported_size: 7}

  defp row_attrs(:unrecorded, _dest), do: %{}

  defp show_episode(tmdb_id, attrs) do
    %{tmdb_id: tmdb_id, title: "Show", year: 2008}
    |> series_fixture()
    |> season_fixture()
    |> episode_fixture(attrs)
    |> Repo.preload(season: :series)
  end

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

  # The better file the library already holds at `dest`.
  defp held_file(dest) do
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, "held")
    dest
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
