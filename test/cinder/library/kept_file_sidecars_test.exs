defmodule Cinder.Library.KeptFileSidecarsTest do
  @moduledoc """
  #784: an import whose destination already holds a better file keeps that file (the `:kept`
  outcome). The declined release's sidecars must not land next to it: they were timed for the
  release's video, and the kept file's recorded sidecar list would no longer match the disk. #291
  fixed the arbitrated TV decline; these cover the movie import and the plain TV import.

  #822: when the file at the destination is the release's own video (the `:same_file` outcome), the
  commit links the release's sidecars next to it, and the record lists them.

  #918: the subtitle manifest takes over only the sidecars the commit placed, or ones it already
  tracks. A subtitle the user put next to the video stays theirs, so no fetch overwrites it.

  Real temp directories throughout: what is under test is which subtitle files land on disk.
  """
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Catalog.Grab
  alias Cinder.{ConfigCase, Library, LibraryStubs, Subtitles}
  alias Cinder.Library.{MediaServerMock, StagedImport}
  alias Cinder.Subtitles.{Manifest, ProviderMock}

  @moduletag :tmp_dir
  @gb 1_000_000_000

  # An in-progress replacement cleanup, which a re-mark must never erase.
  @cleanup_journal %{
    "status" => "aligned",
    "method" => "manual",
    "moviehash" => nil,
    "source_sha256" => String.duplicate("a", 64),
    "applied_sha256" => String.duplicate("b", 64),
    "offset_ms" => 1000,
    "rate" => 1.0
  }

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
      hand_placed!(dest, "en")

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

      # #918: the commit linked fr, so Cinder manages it; the en the user put there stays theirs.
      assert managed?(dest, "fr")
      refute managed?(dest, "en")
      assert hand_placed?(dest, "en")
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

  # #918: every stager hands the commit's subtitle task the sidecar languages it recorded next to
  # the file, and the task marks a language only when the commit placed its canonical
  # `<video>.<lang>.srt` or the manifest already tracks it. Each test puts the user's own canonical
  # sidecar for a recorded language at the destination. A sidecar the commit placed (French,
  # unless the test says otherwise) is the positive anchor: the marking ran.
  describe "the subtitle manifest after an import" do
    test "an episode import, forced or adopting, leaves a hand-placed sidecar unmanaged", %{
      downloads: downloads,
      tv: tv
    } do
      for {tmdb_id, row} <- [{9180, :recorded}, {9181, :unrecorded}] do
        folder = release_folder(downloads, "Show.S01E01.720p.WEB-GRP-#{tmdb_id}")
        dest = release_video_at(folder_video(folder), episode_dest(tv, tmdb_id))
        hand_placed!(dest, "en")
        episode = show_episode(tmdb_id, row_attrs(row, dest))

        expect_scan(:tv)

        assert {:ok, staged, []} = Library.stage_episodes(folder, [episode])
        assert [{_id, ^dest, quality, true}] = StagedImport.record(staged)
        assert :ok = LibraryStubs.commit_staged(staged)

        assert_receive {:scanned, :tv}
        LibraryStubs.await_subtitle_tasks()
        assert quality.sidecar_subtitles == ["en", "fr"]
        assert managed?(dest, "fr")
        refute managed?(dest, "en")
        assert hand_placed?(dest, "en")
      end
    end

    test "an anime import leaves a hand-placed sidecar unmanaged", %{downloads: downloads, tv: tv} do
      folder = release_folder(downloads, "Show.S01E01.720p.WEB-GRP")
      dest = release_video_at(folder_video(folder), episode_dest(tv, 9182))
      hand_placed!(dest, "en")
      episode = show_episode(9182, row_attrs(:recorded, dest))

      grab = %Grab{
        content_path: folder,
        episodes: [episode],
        release_title: Path.basename(folder)
      }

      expect_scan(:tv)

      assert {:ok, staged} = Library.stage_anime_episodes(grab, anime_preflight(folder, episode))
      assert [{_id, ^dest, quality, true}] = StagedImport.record(staged)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :tv}
      LibraryStubs.await_subtitle_tasks()
      assert quality.sidecar_subtitles == ["en", "fr"]
      assert managed?(dest, "fr")
      refute managed?(dest, "en")
    end

    # The held row ranks above the release, so the arbitrated import declines it and keeps the file
    # at `dest`, which is the release's own video: the decline links the release's sidecars there
    # and hands the row's recorded list to the marking.
    test "an arbitrated TV decline leaves a hand-placed sidecar unmanaged", %{
      downloads: downloads,
      tv: tv
    } do
      folder = release_folder(downloads, "Show.S01E01.720p.WEB-GRP")
      dest = release_video_at(folder_video(folder), episode_dest(tv, 9183))
      hand_placed!(dest, "en")

      episode =
        show_episode(9183, %{
          file_path: dest,
          imported_resolution: "1080p",
          imported_source: "BLURAY",
          imported_size: 9 * @gb,
          imported_sidecar_subtitles: ["en", "fr"]
        })

      expect_scan(:tv)

      assert {:ok, staged, []} =
               Library.stage_episodes(folder, [episode],
                 arbitrate: true,
                 release_title: Path.basename(folder)
               )

      assert [{_id, ^dest, quality, false}] = StagedImport.record(staged)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :tv}
      LibraryStubs.await_subtitle_tasks()
      assert quality.sidecar_subtitles == ["en", "fr"]
      assert managed?(dest, "fr")
      refute managed?(dest, "en")
    end

    test "a stacked movie import leaves a hand-placed sidecar next to a part unmanaged", %{
      downloads: downloads,
      movies: movies
    } do
      name = "Movie.2020.720p.WEB-GRP"
      folder = Path.join(downloads, name)
      File.mkdir_p!(folder)

      for part <- ["cd1", "cd2"] do
        File.write!(Path.join(folder, "#{name}.#{part}.mkv"), "release #{part}")
        File.write!(Path.join(folder, "#{name}.#{part}.fr.srt"), "1")
      end

      File.write!(Path.join(folder, "#{name}.cd2.en.srt"), "1")
      [dest1, dest2] = Enum.map(["-cd1", "-cd2"], &movie_dest(movies, 9184, &1))
      File.mkdir_p!(Path.dirname(dest2))
      hand_placed!(dest2, "en")
      movie = same_file_movie(9184, folder, %{})

      expect_scan(:movies)

      assert {:ok, staged} = Library.stage_movie(movie)

      assert %{file_path: ^dest1, part_file_paths: [^dest2], quality: quality} =
               StagedImport.record(staged)

      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()
      assert Enum.sort(quality.sidecar_subtitles) == ["en", "fr"]
      assert managed?(dest1, "fr")
      assert managed?(dest2, "fr")
      refute managed?(dest2, "en")
      assert hand_placed?(dest2, "en")
    end

    # `:replaced`: the release's own `.en.srt` loses to the one already at the destination, which
    # `Sidecars.link/2` never clobbers, yet the recorded list still names `en`.
    test "an upgrade leaves a hand-placed sidecar at the destination unmanaged", %{
      downloads: downloads,
      movies: movies
    } do
      folder = release_folder(downloads, "Movie.2020.1080p.BluRay-GRP", ["fr.srt", "en.srt"])
      dest = held_file(movie_dest(movies, 9185))
      hand_placed!(dest, "en")

      movie =
        same_file_movie(9185, folder, %{
          file_path: dest,
          imported_resolution: "720p",
          imported_source: "WEBDL",
          imported_size: 4
        })

      expect_scan(:movies)

      assert {:ok, staged} = Library.stage_movie(movie, replace: true)
      assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()
      assert File.read!(dest) == "release"
      assert Enum.sort(quality.sidecar_subtitles) == ["en", "fr"]
      assert managed?(dest, "fr")
      refute managed?(dest, "en")
      assert hand_placed?(dest, "en")
    end

    # A flagged or non-SRT sidecar shares its language with the canonical `<video>.fr.srt`, but the
    # commit placed a different file.
    test "a release's flagged or non-SRT sidecar does not make the canonical one managed", %{
      downloads: downloads,
      movies: movies
    } do
      folder =
        release_folder(downloads, "Movie.2020.720p.WEB-GRP", ["fr.forced.srt", "fr.ass", "en.srt"])

      dest = movie_dest(movies, 9186)
      File.mkdir_p!(Path.dirname(dest))
      hand_placed!(dest, "fr")
      movie = same_file_movie(9186, folder, %{})

      expect_scan(:movies)

      assert {:ok, staged} = Library.stage_movie(movie)
      assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()
      assert Enum.sort(quality.sidecar_subtitles) == ["en", "fr"]
      assert File.exists?(Path.rootname(dest) <> ".fr.forced.srt")
      assert File.exists?(Path.rootname(dest) <> ".fr.ass")
      assert managed?(dest, "en")
      refute managed?(dest, "fr")
      assert hand_placed?(dest, "fr")
    end

    # A tracked language is marked as before #918: re-marked as a release sidecar unless
    # `keep_registered?` protects it (a hash-verified track, an in-progress cleanup journal).
    test "an import keeps marking the sidecars the manifest already tracks", %{
      downloads: downloads,
      movies: movies
    } do
      folder = release_folder(downloads, "Movie.2020.720p.WEB-GRP")
      dest = release_video_at(folder_video(folder), movie_dest(movies, 9187))
      Enum.each(["de", "en", "fr", "it"], &hand_placed!(dest, &1))

      File.write!(
        Manifest.path(dest),
        LibraryStubs.subtitle_manifest_json(dest, %{
          "en" => %{"origin" => "translated"},
          "fr" => %{"origin" => "opensubtitles_hash"},
          "de" => %{
            "origin" => "opensubtitles_id",
            "managed_sha256" => String.duplicate("c", 64),
            "replacement_cleanup_sync" => @cleanup_journal
          }
        })
      )

      movie =
        same_file_movie(9187, folder, %{
          file_path: dest,
          imported_resolution: "720p",
          imported_source: "WEBDL",
          imported_size: 7
        })

      expect_scan(:movies)

      assert {:ok, staged} = Library.stage_movie(movie, replace: true)
      assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()
      assert Enum.sort(quality.sidecar_subtitles) == ["de", "en", "fr", "it"]

      tracks = Manifest.read(dest).tracks
      assert tracks["en"].origin == "release_sidecar"
      assert tracks["fr"].origin == "opensubtitles_hash"
      assert tracks["de"].origin == "opensubtitles_id"
      assert tracks["de"].replacement_cleanup_sync.source_sha256 == String.duplicate("a", 64)
      refute managed?(dest, "it")
    end

    # `:kept` links nothing (#784), and the row keeps its own recorded list, which names `en`.
    test "an import that keeps the better file leaves a hand-placed sidecar unmanaged", %{
      downloads: downloads,
      movies: movies
    } do
      folder = release_folder(downloads, "Movie.2020.720p.WEB-GRP")
      dest = held_file(movie_dest(movies, 9189))
      hand_placed!(dest, "en")
      File.write!(Path.rootname(dest) <> ".fr.srt", "tracked fr")

      File.write!(
        Manifest.path(dest),
        LibraryStubs.subtitle_manifest_json(dest, %{"fr" => %{"origin" => "translated"}})
      )

      movie =
        same_file_movie(9189, folder, %{
          file_path: dest,
          imported_resolution: "1080p",
          imported_source: "BLURAY",
          imported_size: 9 * @gb,
          imported_sidecar_subtitles: ["en", "fr"]
        })

      expect_scan(:movies)

      capture_log(fn ->
        assert {:ok, staged} = Library.stage_movie(movie)
        assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
        assert quality.sidecar_subtitles == ["en", "fr"]
        assert :ok = LibraryStubs.commit_staged(staged)
      end)

      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()
      # Positive anchor: the tracked fr was re-marked, so the marking ran.
      assert Manifest.read(dest).tracks["fr"].origin == "release_sidecar"
      refute managed?(dest, "en")
      assert hand_placed?(dest, "en")
    end

    # An unforced `:same_file`: a replay over an unrecorded row adopts the file and scans its
    # destination, where the user's subtitle sits.
    test "a movie replay over an unrecorded row leaves a hand-placed sidecar unmanaged", %{
      downloads: downloads,
      movies: movies
    } do
      folder = release_folder(downloads, "Movie.2020.720p.WEB-GRP")
      dest = release_video_at(folder_video(folder), movie_dest(movies, 9190))
      hand_placed!(dest, "en")
      movie = same_file_movie(9190, folder, %{})

      expect_scan(:movies)

      assert {:ok, staged} = Library.stage_movie(movie)
      assert %{file_path: ^dest, quality: quality} = StagedImport.record(staged)
      assert :ok = LibraryStubs.commit_staged(staged)

      assert_receive {:scanned, :movies}
      LibraryStubs.await_subtitle_tasks()
      assert quality.sidecar_subtitles == ["en", "fr"]
      assert managed?(dest, "fr")
      refute managed?(dest, "en")
      assert hand_placed?(dest, "en")
    end

    # The import's own subtitle task fetches right after the marking, so a hand-placed sidecar the
    # marking took over would be overwritten at once.
    test "the import's own subtitle fetch leaves a hand-placed sidecar's bytes unchanged", %{
      downloads: downloads,
      movies: movies
    } do
      # Earlier tasks run while subtitles are still off (#685).
      LibraryStubs.await_subtitle_tasks()
      ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")
      stub_en_provider()
      dest = forced_reimport_with_hand_placed_en!(downloads, movies, 9188)

      # Positive anchor: the fetch found an `en` candidate, so only the manifest kept it out.
      assert_received {:searched, "en"}
      refute_received {:downloaded, _file_id}
      assert hand_placed?(dest, "en")
      refute managed?(dest, "en")
    end

    # An import with subtitles off marks without fetching; a sweep's fetch then runs once they are
    # on.
    test "a later subtitle fetch leaves a hand-placed sidecar's bytes unchanged", %{
      downloads: downloads,
      movies: movies
    } do
      stub_en_provider()
      dest = forced_reimport_with_hand_placed_en!(downloads, movies, 9191)
      refute_received {:searched, _language}
      # Positive anchor: the marking ran and took the fr the commit linked.
      assert managed?(dest, "fr")

      ConfigCase.put_config(Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")
      assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, dest, :movies)

      assert_received {:searched, "en"}
      refute_received {:downloaded, _file_id}
      assert hand_placed?(dest, "en")
      refute managed?(dest, "en")
    end
  end

  # A forced re-import of a folder release onto its own video, next to which the user put an
  # `en` sidecar the row records; returns the destination once the commit's subtitle task ran.
  defp forced_reimport_with_hand_placed_en!(downloads, movies, tmdb_id) do
    folder = release_folder(downloads, "Movie.2020.720p.WEB-GRP")
    dest = release_video_at(folder_video(folder), movie_dest(movies, tmdb_id))
    hand_placed!(dest, "en")

    movie =
      same_file_movie(tmdb_id, folder, %{
        file_path: dest,
        imported_resolution: "720p",
        imported_source: "WEBDL",
        imported_size: 7,
        imported_sidecar_subtitles: ["en"]
      })

    assert {:ok, staged} = Library.stage_movie(movie, replace: true)
    assert :ok = LibraryStubs.commit_staged(staged)
    LibraryStubs.await_subtitle_tasks()
    dest
  end

  # A provider with an `en` candidate for any search, and a download that would replace the
  # sidecar. The commit's scan and a subtitle publication's scan both pass.
  defp stub_en_provider do
    parent = self()

    stub(MediaServerMock, :scan, fn kind ->
      send(parent, {:scanned, kind})
      :ok
    end)

    stub(ProviderMock, :search, fn %{languages: [language]} ->
      send(parent, {:searched, language})
      {:ok, [%{file_id: 1, language: language, downloads: 1}]}
    end)

    stub(ProviderMock, :download, fn file_id ->
      send(parent, {:downloaded, file_id})
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nPROVIDER\n\n"}
    end)
  end

  # A release folder: one video named after the folder, and its sidecars (French by default).
  defp release_folder(downloads, name, sidecars \\ ["fr.srt"]) do
    folder = Path.join(downloads, name)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, name <> ".mkv"), "release")
    Enum.each(sidecars, &File.write!(Path.join(folder, "#{name}.#{&1}"), "1"))
    folder
  end

  defp folder_video(folder), do: Path.join(folder, Path.basename(folder) <> ".mkv")

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

  defp managed?(video, language), do: video |> Manifest.read() |> Manifest.managed?(language)

  # The user's own `<video>.<language>.srt`, with bytes no release or provider writes.
  defp hand_placed!(video, language),
    do: File.write!(Path.rootname(video) <> ".#{language}.srt", "hand #{language}")

  defp hand_placed?(video, language),
    do: File.read!(Path.rootname(video) <> ".#{language}.srt") == "hand #{language}"

  # The persisted preflight `Library.stage_anime_episodes/2` revalidates: the folder's inventory as
  # it is now, its one video assigned to `episode`.
  defp anime_preflight(folder, episode) do
    {:ok, %{files: [file] = files, folder?: true}} = Library.inventory_anime_videos(folder)

    decisions =
      Enum.map(files, fn %{relative_path: path, identity: identity} ->
        identity
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put("relative_path", path)
      end)

    %{
      assignments: [%{relative_path: file.relative_path, episode_ids: [episode.id]}],
      decisions: %{"files" => decisions},
      folder?: true
    }
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
