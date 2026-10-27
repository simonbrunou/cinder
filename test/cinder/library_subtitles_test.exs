defmodule Cinder.LibrarySubtitlesTest do
  # async: false — this test opts the subtitles feature ON by mutating the shared
  # Cinder.Subtitles.Provider.OpenSubtitles :languages config (blank by default in
  # config/test.exs specifically so the async:true library_test.exs suite is unaffected). That
  # global mutation would race concurrently-running async tests, so this file — like
  # subtitles_test.exs — stays async: false and merges (not replaces) the config to preserve
  # base_url/api_key/req_options for anything else reading it.
  #
  # The import-time fetch now runs on a supervised Task (off the poller tick), so the provider call
  # happens in a *different* process than the test: set_mox_from_context puts Mox in global mode so
  # that task can use these expectations, and each test blocks on assert_receive until the task has
  # actually dispatched the fetch.
  # DataCase (not bare ExUnit.Case): stage_movie now writes an ImportStage journal row.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.{Library, LibraryStubs, Subtitles}
  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.StagedImport

  setup :set_mox_from_context
  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"
  @tv_lib "/tmp/cinder-test-tv-library"
  @gb 1_000_000_000

  # Stands in for an earlier module's fire-and-forget import that leaves a task in the shared
  # Fetcher: the task reads the wanted languages only once its criteria thunk returns, i.e. late
  # enough to land after this module's setup has switched subtitles on (see the drain below).
  setup context do
    if context[:stale_fetcher_job] do
      Subtitles.fetch_after_import(
        fn ->
          Process.sleep(300)
          %{tmdb_id: 1, season: 1, episode: 1}
        end,
        "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv",
        :tv,
        []
      )
    end

    :ok
  end

  # #685: the Fetcher is one process shared by the whole suite and most import tests enqueue onto
  # it without waiting. A task left over from an earlier test or module can still be in flight
  # when the setup below switches subtitles on and the test installs its expectations; its provider
  # search then consumes one of THIS test's expected calls and the test's own fetch never reaches
  # the provider. Let every previously-enqueued task finish first, while subtitles are still off
  # and no expectations exist.
  setup do
    LibraryStubs.await_subtitle_tasks()
    :ok
  end

  setup do
    saved = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])
    subtitle_fs = start_supervised!({Agent, fn -> %{} end})

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved)
    end)

    Application.put_env(
      :cinder,
      Cinder.Subtitles.Provider.OpenSubtitles,
      Keyword.put(saved, :languages, "en")
    )

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      case Agent.get(subtitle_fs, &Map.get(&1, path)) do
        content when is_binary(content) -> {:ok, content}
        _ -> {:error, :enoent}
      end
    end)

    write = fn path, content ->
      content = IO.iodata_to_binary(content)

      Agent.update(subtitle_fs, fn files ->
        files
        |> Map.put(path, content)
        |> Map.update(:writes, [{path, content}], &[{path, content} | &1])
      end)

      :ok
    end

    stub(Cinder.Library.FilesystemMock, :write, write)
    stub(Cinder.Library.FilesystemMock, :chmod, fn _path, _mode -> :ok end)
    stub(Cinder.Library.FilesystemMock, :write_exclusive, write)

    stub(Cinder.Library.FilesystemMock, :rename, fn source, dest ->
      Agent.get_and_update(subtitle_fs, fn files ->
        {:ok, files |> Map.delete(source) |> Map.put(dest, Map.fetch!(files, source))}
      end)
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      if Agent.get(subtitle_fs, &Map.has_key?(&1, path)) do
        {:ok, %File.Stat{type: :regular, size: 1}}
      else
        {:error, :enoent}
      end
    end)

    # An import now looks for the video's own track first (spec 069): these files carry none.
    stub(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn _video -> {:ok, []} end)

    {:ok, subtitle_fs: subtitle_fs}
  end

  test "blank languages and nil or empty release sidecars skip asynchronous filesystem work" do
    saved = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    Application.put_env(
      :cinder,
      Cinder.Subtitles.Provider.OpenSubtitles,
      Keyword.put(saved, :languages, "")
    )

    parent = self()
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> send(parent, :moviehash) end)
    stub(Cinder.Subtitles.ProviderMock, :search, fn _ -> send(parent, :provider_search) end)

    for sidecars <- [[languages: nil, placed: []], [languages: []], []] do
      assert :ok = Subtitles.fetch_after_import(fn -> %{} end, "/lib/M/M.mkv", :movies, sidecars)
      refute_receive :moviehash, 100
      refute_receive :provider_search
    end
  end

  # #918: a bare language list cannot say which sidecars the import placed, so it never reaches
  # the marking.
  test "release sidecars that are not the import's keyword list raise at dispatch" do
    for sidecars <- [["fr"], [languages: ["fr"], paths: []]] do
      assert_raise ArgumentError, fn ->
        Subtitles.fetch_after_import(fn -> %{} end, "/lib/M/M.mkv", :movies, sidecars)
      end
    end
  end

  defp commit!(staged), do: LibraryStubs.commit_staged(staged)

  defp commit_episodes!(staged), do: :ok = LibraryStubs.commit_staged(staged)

  # A manifest that tracks each of `languages`' canonical sidecars, with an origin an import
  # re-marks (`"translated"`), so the re-mark shows.
  defp tracked_manifest(video, languages),
    do:
      LibraryStubs.subtitle_manifest_json(
        video,
        Map.new(languages, &{&1, %{"origin" => "translated"}})
      )

  # The subtitle half of an import against a real library under `tmp`: the sidecar a download
  # replaces is published through real descriptors (`AtomicFile`), so the filesystem mock
  # delegates to `Disk`, and only the staged video keeps its stubs. Manifest writes are still
  # recorded in `fs`'s `:writes`.
  defp real_subtitle_library!(tmp, root_key, fs) do
    library = Path.join(tmp, "library")
    saved = Application.fetch_env!(:cinder, root_key)
    on_exit(fn -> Application.put_env(:cinder, root_key, saved) end)
    Application.put_env(:cinder, root_key, library)

    stub_with(Cinder.Library.FilesystemMock, Disk)
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    stub(Cinder.Library.FilesystemMock, :backing_identity, fn _ -> {:error, :outside_roots} end)

    stub(Cinder.Library.FilesystemMock, :rm, fn path ->
      if LibraryStubs.staging_path?(path), do: :ok, else: Disk.rm(path)
    end)

    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
      Agent.update(fs, fn files ->
        Map.update(files, :writes, [{path, content}], &[{path, content} | &1])
      end)

      Disk.write_exclusive(path, content)
    end)

    library
  end

  defp staged_video_lstat(path, size) do
    if LibraryStubs.candidate_path?(path),
      do: {:ok, %File.Stat{size: size, inode: 2, major_device: 1}},
      else: Disk.lstat(path)
  end

  defp stub_release_sidecar_link(source_sidecar, dest_sidecar) do
    stub(Cinder.Library.FilesystemMock, :ln, fn
      ^source_sidecar, ^dest_sidecar ->
        File.mkdir_p!(Path.dirname(dest_sidecar))
        File.write!(dest_sidecar, "release SRT")

      _src, _dest ->
        :ok
    end)
  end

  test "stage_movie dispatches the subtitle fetch off the import path, best-effort" do
    parent = self()

    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imdb_id: "tt0113277",
      file_path: "/dl/Heat.mkv"
    }

    dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"

    LibraryStubs.stub_import_ok(1 * @gb)

    # The subtitle fetch runs in the Task (global Mox). It signals the test so we can prove the
    # dispatch happened and that the provider error stayed off the import path.
    expect(Cinder.Subtitles.ProviderMock, :search, fn %{imdb_id: "tt0113277", languages: ["en"]} ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    log =
      capture_log(fn ->
        assert {:ok, stage} = Library.stage_movie(movie)
        assert %{file_path: ^dest, quality: quality} = StagedImport.record(stage)
        assert quality.sidecar_subtitles == []
        assert :ok = commit!(stage)
        assert_receive :subtitle_search
        LibraryStubs.await_subtitle_tasks()
      end)

    assert log =~ "subtitle fetch for #{dest} (en) failed: :down"
  end

  test "a staged episode dispatches its subtitle fetch at commit, off the import path, best-effort" do
    parent = self()
    series = %Series{title: "Show", year: 2008, tmdb_id: 1}

    episode = %Episode{
      id: 7,
      episode_number: 3,
      season: %Season{season_number: 1, series: series}
    }

    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"

    LibraryStubs.stub_import_ok(9 * @gb)
    stub(Cinder.Library.FilesystemMock, :dir?, fn path -> path == "/dl" end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl" ->
      {:ok, [{"/dl/Show.S01E03.1080p.mkv", 9 * @gb}]}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{
                                                        tmdb_id: 1,
                                                        season: 1,
                                                        episode: 3,
                                                        languages: ["en"]
                                                      } ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    log =
      capture_log(fn ->
        assert {:ok, staged, []} = Library.stage_episodes("/dl", [episode])
        assert [{7, ^dest, quality, true}] = StagedImport.record(staged)

        assert quality.sidecar_subtitles == []
        commit_episodes!(staged)
        assert_receive :subtitle_search
        LibraryStubs.await_subtitle_tasks()
      end)

    assert log =~ "subtitle fetch for #{dest} (en) failed: :down"
  end

  test "a combined-episode file dispatches ONE subtitle fetch for its shared sidecar (issue #141)" do
    parent = self()
    series = %Series{title: "Show", year: 2008, tmdb_id: 1}
    season = %Season{season_number: 1, series: series}

    episodes = [
      %Episode{id: 7, episode_number: 1, season: season},
      %Episode{id: 8, episode_number: 2, season: season}
    ]

    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01-E02.mkv"

    LibraryStubs.stub_import_ok(9 * @gb)
    stub(Cinder.Library.FilesystemMock, :dir?, fn path -> path == "/dl" end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl" ->
      {:ok, [{"/dl/Show.S01E01-E02.1080p.mkv", 9 * @gb}]}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)

    # Both episodes share one physical file, so exactly one fetch may target the shared
    # sidecar path — a second one would race/overwrite it with the other part's subtitles.
    stub(Cinder.Subtitles.ProviderMock, :search, fn criteria ->
      send(parent, {:subtitle_search, criteria})
      {:error, :down}
    end)

    capture_log(fn ->
      assert {:ok, staged, []} = Library.stage_episodes("/dl", episodes)

      assert LibraryStubs.episode_dests(staged) == [{7, dest}, {8, dest}]

      commit_episodes!(staged)
      assert_receive {:subtitle_search, %{season: 1, episode: 1}}
      LibraryStubs.await_subtitle_tasks()
      refute_received {:subtitle_search, _}
    end)
  end

  @tag :tmp_dir
  test "folder movie import passes linked sidecars to the movies subtitle task", %{
    subtitle_fs: fs,
    tmp_dir: tmp
  } do
    parent = self()
    library = real_subtitle_library!(tmp, :movies_library_path, fs)

    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imdb_id: "tt0113277",
      file_path: "/dl/Heat"
    }

    source = "/dl/Heat/Movie.mkv"
    source_sidecar = "/dl/Heat/Movie.en.srt"
    dest = "#{library}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"
    dest_sidecar = Path.rootname(dest) <> ".en.srt"

    # Probed both during staging (resolve_source) and again at commit (the sidecar scan
    # re-checks the source dir); stubbed rather than pinned to an exact count.
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl/Heat" ->
      {:ok, [{source, 1 * @gb}, {source_sidecar, 1_000}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^source -> {:ok, %File.Stat{size: 1 * @gb, inode: 1}}
      path -> staged_video_lstat(path, 1 * @gb)
    end)

    stub_release_sidecar_link(source_sidecar, dest_sidecar)

    expect(Cinder.Library.MediaServerMock, :scan, 2, fn :movies ->
      send(parent, :movie_scan)
      :ok
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{imdb_id: "tt0113277", languages: ["en"]} ->
      send(parent, :subtitle_search)

      {:ok,
       [
         %{
           file_id: 7,
           language: "en",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 7 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nreplacement SRT\n\n"}
    end)

    assert {:ok, stage} = Library.stage_movie(movie)
    assert %{file_path: ^dest, quality: quality} = StagedImport.record(stage)
    assert quality.sidecar_subtitles == ["en"]
    assert :ok = commit!(stage)

    assert_receive :movie_scan
    assert_receive :subtitle_search
    assert_receive :movie_scan

    assert Enum.any?(Agent.get(fs, &Map.get(&1, :writes, [])), fn {_path, content} ->
             content =~ "release_sidecar"
           end)
  end

  test "multipart folder movie import fetches subtitles for each part with one movie scan" do
    parent = self()

    movie = %Movie{
      title: "Movie",
      year: 1995,
      tmdb_id: 949,
      imdb_id: "tt0113277",
      file_path: "/dl/Movie"
    }

    cd1 = "/dl/Movie/Movie.cd1.mkv"
    cd2 = "/dl/Movie/Movie.cd2.mkv"
    dest1 = "#{@lib}/Movie (1995) {tmdb-949}/Movie (1995) {tmdb-949}-cd1.mkv"
    dest2 = "#{@lib}/Movie (1995) {tmdb-949}/Movie (1995) {tmdb-949}-cd2.mkv"

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl/Movie" ->
      {:ok, [{cd2, 4 * @gb}, {cd1, 3 * @gb}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^cd1 ->
        {:ok, %File.Stat{size: 3 * @gb, inode: 11, major_device: 1}}

      ^cd2 ->
        {:ok, %File.Stat{size: 4 * @gb, inode: 12, major_device: 1}}

      path ->
        cond do
          LibraryStubs.candidate_path?(path) ->
            {:ok, %File.Stat{size: 1 * @gb, inode: 20, major_device: 1}}

          String.ends_with?(path, ".en.srt") ->
            send(parent, {:subtitle_path, path})
            {:error, :enoent}

          true ->
            {:error, :enoent}
        end
    end)

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn path ->
      send(parent, {:subtitle_path, path})
      :too_small
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _source, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _source, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies ->
      send(parent, :movie_scan)
      :ok
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, 2, fn %{
                                                           imdb_id: "tt0113277",
                                                           languages: ["en"]
                                                         } ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    assert {:ok, stage} = Library.stage_movie(movie)
    assert %{file_path: ^dest1, part_file_paths: [^dest2]} = StagedImport.record(stage)
    assert :ok = commit!(stage)

    assert_receive :movie_scan
    assert_receive :subtitle_search
    assert_receive :subtitle_search
    LibraryStubs.await_subtitle_tasks()

    assert_receive {:subtitle_path, ^dest1}
    assert_receive {:subtitle_path, ^dest2}
    refute_received :movie_scan
  end

  # #685: the shared Fetcher can still hold a task an earlier test or module enqueued without
  # waiting for it. Run late, that task's provider search used to eat one of THIS test's expected
  # calls, so the test's own fetch (here, and in the multipart test above) never reached the
  # provider and no :subtitle_search ever arrived.
  @tag :stale_fetcher_job
  test "a Fetcher job left by an earlier test cannot consume this test's provider expectation" do
    parent = self()

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{imdb_id: "tt0113277", languages: ["en"]} ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    capture_log(fn ->
      assert :ok =
               Subtitles.fetch_after_import(
                 fn -> %{imdb_id: "tt0113277"} end,
                 "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv",
                 :movies,
                 []
               )

      LibraryStubs.await_subtitle_tasks()
    end)

    assert_received :subtitle_search
  end

  @tag :tmp_dir
  test "folder episode import passes linked sidecars to the TV subtitle task", %{
    subtitle_fs: fs,
    tmp_dir: tmp
  } do
    parent = self()
    library = real_subtitle_library!(tmp, :tv_library_path, fs)
    series = %Series{title: "Show", year: 2008, tmdb_id: 1}

    episode = %Episode{
      id: 7,
      episode_number: 3,
      season: %Season{season_number: 1, series: series}
    }

    source = "/dl/Show.S01E03.1080p.mkv"
    source_sidecar = "/dl/Show.S01E03.1080p.en.srt"
    dest = "#{library}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
    dest_sidecar = Path.rootname(dest) <> ".en.srt"

    # Walked at staging (the episode match and the sidecar languages) and again at commit (the
    # sidecar link); stubbed rather than pinned to an exact count.
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl" ->
      {:ok, [{source, 9 * @gb}, {source_sidecar, 1_000}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^source -> {:ok, %File.Stat{size: 9 * @gb, inode: 1}}
      path -> staged_video_lstat(path, 9 * @gb)
    end)

    stub_release_sidecar_link(source_sidecar, dest_sidecar)

    expect(Cinder.Library.MediaServerMock, :scan, 2, fn :tv ->
      send(parent, :tv_scan)
      :ok
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{
                                                        tmdb_id: 1,
                                                        season: 1,
                                                        episode: 3,
                                                        languages: ["en"]
                                                      } ->
      send(parent, :subtitle_search)

      {:ok,
       [
         %{
           file_id: 9,
           language: "en",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 9 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nreplacement SRT\n\n"}
    end)

    assert {:ok, staged, []} = Library.stage_episodes("/dl", [episode])
    assert [{7, ^dest, quality, true}] = StagedImport.record(staged)

    assert quality.sidecar_subtitles == ["en"]
    commit_episodes!(staged)
    assert_receive :tv_scan
    assert_receive :subtitle_search
    assert_receive :tv_scan

    assert Enum.any?(Agent.get(fs, &Map.get(&1, :writes, [])), fn {_path, content} ->
             content =~ "release_sidecar"
           end)
  end

  # issue #128: deleting a series (keeping files) and re-adding it recreates a never-imported
  # episode row (its quality unrecorded) whose computed dest already holds the old file. The import
  # "adopts" the existing dest (same inode as the download's content — e.g. the client re-served an
  # already-complete download) rather than placing fresh bytes, so it must scan dest's own
  # directory for cinder-named sidecars instead of recording "no sidecars".
  #
  # The delete keeps the manifest dotfile beside the files, so the sidecars it tracked stay
  # managed. One the user put there stays theirs (#918).
  test "adopt path (pre-existing dest, same inode) scans dest's sidecars and keeps the tracked ones managed",
       %{subtitle_fs: fs} do
    parent = self()
    series = %Series{title: "Show", year: 2008, tmdb_id: 1}

    episode = %Episode{
      id: 7,
      episode_number: 3,
      season: %Season{season_number: 1, series: series}
    }

    source = "/dl/grab/Show.S01E03.1080p.mkv"
    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
    season_dir = Path.dirname(dest)
    dest_en = Path.rootname(dest) <> ".en.srt"
    dest_fr = Path.rootname(dest) <> ".fr.srt"
    dest_it = Path.rootname(dest) <> ".it.srt"

    # The video (at both its download-side and library-side paths), its two already-linked
    # sidecars and their manifest are all genuinely on disk — this is what "delete series, keep
    # files" leaves behind — and so is an Italian sidecar the user added by hand.
    Agent.update(
      fs,
      &Map.merge(&1, %{
        source => "video",
        dest => "video",
        dest_en => "SRT en",
        dest_fr => "SRT fr",
        dest_it => "hand SRT it",
        Subtitles.Manifest.path(dest) => tracked_manifest(dest, ["en", "fr"])
      })
    )

    # Walked at staging (the episode match, then dest's own sidecars) and again at commit (the
    # source's sidecars, of which there are none); stubbed rather than pinned to an exact count.
    stub(Cinder.Library.FilesystemMock, :dir?, fn path -> path in ["/dl/grab", season_dir] end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn
      "/dl/grab" ->
        {:ok, [{source, 9 * @gb}]}

      ^season_dir ->
        {:ok, [{dest, 9 * @gb}, {dest_en, 1_000}, {dest_fr, 1_000}, {dest_it, 1_000}]}
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :tv ->
      send(parent, :tv_scan)
      :ok
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{
                                                        tmdb_id: 1,
                                                        season: 1,
                                                        episode: 3,
                                                        languages: ["en"]
                                                      } ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    log =
      capture_log(fn ->
        assert {:ok, staged, []} = Library.stage_episodes("/dl/grab", [episode])
        assert [{7, ^dest, quality, true}] = StagedImport.record(staged)

        assert quality.sidecar_subtitles == ["en", "fr", "it"]
        commit_episodes!(staged)
        assert_receive :tv_scan
        assert_receive :subtitle_search
        LibraryStubs.await_subtitle_tasks()
      end)

    assert log =~ "subtitle fetch for #{dest} (en) failed: :down"

    state = Subtitles.Manifest.read(dest)
    # The import re-marked the tracked ones, so they are release sidecars now, not the seed's.
    assert state.tracks["en"].origin == "release_sidecar"
    assert state.tracks["fr"].origin == "release_sidecar"
    refute Subtitles.Manifest.managed?(state, "it")
  end

  test "adopt path does not register a foreign-named sidecar belonging to a different episode",
       %{subtitle_fs: fs} do
    parent = self()
    series = %Series{title: "Show", year: 2008, tmdb_id: 1}

    episode = %Episode{
      id: 7,
      episode_number: 3,
      season: %Season{season_number: 1, series: series}
    }

    source = "/dl/grab/Show.S01E03.1080p.mkv"
    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
    season_dir = Path.dirname(dest)
    dest_en = Path.rootname(dest) <> ".en.srt"

    # A batch sibling sitting in the same season folder: another episode's video + its own
    # sidecar, breaking the "lone video in folder" heuristic so a stem mismatch is what's
    # actually being exercised, not an accident of there being only one video present.
    sibling_video =
      "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E04.mkv"

    sibling_sub = Path.rootname(sibling_video) <> ".en.srt"

    # The episode's own sidecar is tracked, as the delete-and-re-add case above leaves it (#918).
    Agent.update(
      fs,
      &Map.merge(&1, %{
        source => "video",
        dest => "video",
        dest_en => "SRT en",
        Subtitles.Manifest.path(dest) => tracked_manifest(dest, ["en"]),
        sibling_video => "video",
        sibling_sub => "foreign SRT"
      })
    )

    stub(Cinder.Library.FilesystemMock, :dir?, fn path -> path in ["/dl/grab", season_dir] end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn
      "/dl/grab" ->
        {:ok, [{source, 9 * @gb}]}

      ^season_dir ->
        {:ok,
         [
           {dest, 9 * @gb},
           {dest_en, 1_000},
           {sibling_video, 9 * @gb},
           {sibling_sub, 1_000}
         ]}
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["en"]} ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    capture_log(fn ->
      assert {:ok, staged, []} = Library.stage_episodes("/dl/grab", [episode])
      assert [{7, ^dest, quality, true}] = StagedImport.record(staged)

      assert quality.sidecar_subtitles == ["en"]
      commit_episodes!(staged)
      assert_receive :subtitle_search
      LibraryStubs.await_subtitle_tasks()
    end)

    # Re-marked from the seed's origin: the marking ran for the episode's own video.
    assert Subtitles.Manifest.read(dest).tracks["en"].origin == "release_sidecar"

    refute sibling_video
           |> Subtitles.Manifest.read()
           |> Subtitles.Manifest.managed?("en")
  end
end
