defmodule Cinder.Library.KeptFileSidecarsTest do
  @moduledoc """
  #784: an import whose destination already holds a better file keeps that file (the `:kept`
  outcome). The declined release's sidecars must not land next to it: they were timed for the
  release's video, and the kept file's recorded sidecar list would no longer match the disk. #291
  fixed the arbitrated TV decline; these cover the movie import and the plain TV import.

  Real temp directories throughout: what is under test is which subtitle files land on disk.
  """
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import ExUnit.CaptureLog
  import Mox

  alias Cinder.{Library, LibraryStubs}
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

    put_env(
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
      dest = Path.join([movies, "Movie (2020) {tmdb-7841}", "Movie (2020) {tmdb-7841}.mkv"])
      File.mkdir_p!(Path.dirname(dest))
      File.ln!(Path.join(folder, "Movie.2020.720p.WEB-GRP.mkv"), dest)

      movie =
        movie_fixture(%{
          tmdb_id: 7841,
          title: "Movie",
          year: 2020,
          status: :downloaded,
          content_path: folder,
          release_title: "Movie.2020.720p.WEB-GRP",
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

  # A release folder: one video named after the folder, and its French sidecar.
  defp release_folder(downloads, name) do
    folder = Path.join(downloads, name)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, name <> ".mkv"), "release")
    File.write!(Path.join(folder, name <> ".fr.srt"), "1")
    folder
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

  # Sets `:cinder` env for the test, restoring what was there on exit.
  defp put_env(pairs) do
    saved = Map.new(pairs, fn {key, _value} -> {key, Application.get_env(:cinder, key)} end)
    Enum.each(pairs, fn {key, value} -> Application.put_env(:cinder, key, value) end)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)
  end
end
