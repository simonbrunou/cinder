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
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.{Library, Subtitles}

  setup :set_mox_from_context
  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"
  @tv_lib "/tmp/cinder-test-tv-library"
  @gb 1_000_000_000

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

    stub(Cinder.Library.FilesystemMock, :write, fn path, content ->
      content = IO.iodata_to_binary(content)

      Agent.update(subtitle_fs, fn files ->
        files
        |> Map.put(path, content)
        |> Map.update(:writes, [{path, content}], &[{path, content} | &1])
      end)

      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rename, fn source, dest ->
      Agent.get_and_update(subtitle_fs, fn files ->
        {:ok, files |> Map.delete(source) |> Map.put(dest, Map.fetch!(files, source))}
      end)
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      if Agent.get(subtitle_fs, &Map.has_key?(&1, path)) do
        {:ok, %File.Stat{}}
      else
        {:error, :enoent}
      end
    end)

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

    for sidecars <- [nil, []] do
      assert :ok = Subtitles.fetch_after_import(fn -> %{} end, "/lib/M/M.mkv", :movies, sidecars)
      refute_receive :moviehash, 100
      refute_receive :provider_search
    end
  end

  test "import_movie dispatches the subtitle fetch off the import path, best-effort" do
    parent = self()

    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imdb_id: "tt0113277",
      file_path: "/dl/Heat.mkv"
    }

    dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.mkv" ->
      {:ok, %File.Stat{size: 1 * @gb, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    # The subtitle fetch runs in the Task (global Mox). It signals the test so we can prove the
    # dispatch happened and that the provider error stayed off the import path.
    expect(Cinder.Subtitles.ProviderMock, :search, fn %{imdb_id: "tt0113277", languages: ["en"]} ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    log =
      capture_log(fn ->
        assert {:ok, ^dest, quality} = Library.import_movie(movie)
        assert quality.sidecar_subtitles == []
        assert_receive :subtitle_search, 2_000
        await_subtitle_tasks()
      end)

    assert log =~ "subtitle fetch for #{dest} (en) failed: :down"
  end

  test "import_episodes dispatches the subtitle fetch off the import path, best-effort" do
    parent = self()
    series = %Series{title: "Show", year: 2008, tmdb_id: 1}

    episode = %Episode{
      id: 7,
      episode_number: 3,
      season: %Season{season_number: 1, series: series}
    }

    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl" -> true end)

    # The sidecar scan after the placed file re-checks the source dir; fall through to "not a dir".
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl" ->
      {:ok, [{"/dl/Show.S01E03.1080p.mkv", 9 * @gb}]}
    end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Show.S01E03.1080p.mkv" ->
      {:ok, %File.Stat{size: 9 * @gb, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

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
        assert {:ok, [{7, ^dest, quality}], []} = Library.import_episodes("/dl", [episode])
        assert quality.sidecar_subtitles == []
        assert_receive :subtitle_search, 2_000
        await_subtitle_tasks()
      end)

    assert log =~ "subtitle fetch for #{dest} (en) failed: :down"
  end

  test "folder movie import passes linked sidecars to the movies subtitle task", %{
    subtitle_fs: fs
  } do
    parent = self()

    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imdb_id: "tt0113277",
      file_path: "/dl/Heat"
    }

    source = "/dl/Heat/Movie.mkv"
    source_sidecar = "/dl/Heat/Movie.en.srt"
    dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"
    dest_sidecar = Path.rootname(dest) <> ".en.srt"

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Heat" -> true end)
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, 2, fn "/dl/Heat" ->
      {:ok, [{source, 1 * @gb}, {source_sidecar, 1_000}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^source ->
        {:ok, %File.Stat{size: 1 * @gb, inode: 1}}

      path ->
        if Agent.get(fs, &Map.has_key?(&1, path)),
          do: {:ok, %File.Stat{}},
          else: {:error, :enoent}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, 2, fn
      ^source, ^dest ->
        :ok

      ^source_sidecar, ^dest_sidecar ->
        Agent.update(fs, &Map.put(&1, dest_sidecar, "release SRT"))
        :ok
    end)

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

    expect(Cinder.Subtitles.ProviderMock, :download, fn 7 -> {:ok, "replacement SRT"} end)

    assert {:ok, ^dest, quality} = Library.import_movie(movie)
    assert quality.sidecar_subtitles == ["en"]
    assert_receive :movie_scan
    assert_receive :subtitle_search, 2_000
    assert_receive :movie_scan, 2_000

    assert Enum.any?(Agent.get(fs, &Map.get(&1, :writes, [])), fn {_path, content} ->
             content =~ "release_sidecar"
           end)
  end

  test "folder episode import passes linked sidecars to the TV subtitle task", %{subtitle_fs: fs} do
    parent = self()
    series = %Series{title: "Show", year: 2008, tmdb_id: 1}

    episode = %Episode{
      id: 7,
      episode_number: 3,
      season: %Season{season_number: 1, series: series}
    }

    source = "/dl/Show.S01E03.1080p.mkv"
    source_sidecar = "/dl/Show.S01E03.1080p.en.srt"
    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
    dest_sidecar = Path.rootname(dest) <> ".en.srt"

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl" -> true end)
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, 2, fn "/dl" ->
      {:ok, [{source, 9 * @gb}, {source_sidecar, 1_000}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^source ->
        {:ok, %File.Stat{size: 9 * @gb, inode: 1}}

      path ->
        if Agent.get(fs, &Map.has_key?(&1, path)),
          do: {:ok, %File.Stat{}},
          else: {:error, :enoent}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, 2, fn
      ^source, ^dest ->
        :ok

      ^source_sidecar, ^dest_sidecar ->
        Agent.update(fs, &Map.put(&1, dest_sidecar, "release SRT"))
        :ok
    end)

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

    expect(Cinder.Subtitles.ProviderMock, :download, fn 9 -> {:ok, "replacement SRT"} end)

    assert {:ok, [{7, ^dest, quality}], []} = Library.import_episodes("/dl", [episode])
    assert quality.sidecar_subtitles == ["en"]
    assert_receive :tv_scan
    assert_receive :subtitle_search, 2_000
    assert_receive :tv_scan, 2_000

    assert Enum.any?(Agent.get(fs, &Map.get(&1, :writes, [])), fn {_path, content} ->
             content =~ "release_sidecar"
           end)
  end

  # issue #128: deleting a series (keeping files) and re-adding it recreates a never-imported
  # (nil_q?) episode row whose computed dest already holds the old file. The import "adopts" the
  # existing dest (same inode as the download's content — e.g. the client re-served an
  # already-complete download) rather than placing fresh bytes, so it must scan dest's own
  # directory for cinder-named sidecars instead of recording "no sidecars".
  test "adopt path (pre-existing dest, same inode) scans dest's sidecars and registers them as managed",
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

    # The video (at both its download-side and library-side paths) and its two already-linked
    # sidecars are all genuinely on disk — this is what "delete series, keep files" leaves behind.
    Agent.update(
      fs,
      &Map.merge(&1, %{
        source => "video",
        dest => "video",
        dest_en => "SRT en",
        dest_fr => "SRT fr"
      })
    )

    expect(Cinder.Library.FilesystemMock, :dir?, 2, fn
      "/dl/grab" -> true
      ^season_dir -> true
    end)

    expect(Cinder.Library.FilesystemMock, :find_files, 2, fn
      "/dl/grab" -> {:ok, [{source, 9 * @gb}]}
      ^season_dir -> {:ok, [{dest, 9 * @gb}, {dest_en, 1_000}, {dest_fr, 1_000}]}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn ^source, ^dest -> {:error, :eexist} end)

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
        assert {:ok, [{7, ^dest, quality}], []} = Library.import_episodes("/dl/grab", [episode])
        assert quality.sidecar_subtitles == ["en", "fr"]
        assert_receive :tv_scan
        assert_receive :subtitle_search, 2_000
        await_subtitle_tasks()
      end)

    assert log =~ "subtitle fetch for #{dest} (en) failed: :down"

    assert dest |> Subtitles.Manifest.read() |> Subtitles.Manifest.managed?("en")
    assert dest |> Subtitles.Manifest.read() |> Subtitles.Manifest.managed?("fr")
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

    Agent.update(
      fs,
      &Map.merge(&1, %{
        source => "video",
        dest => "video",
        dest_en => "SRT en",
        sibling_video => "video",
        sibling_sub => "foreign SRT"
      })
    )

    expect(Cinder.Library.FilesystemMock, :dir?, 2, fn
      "/dl/grab" -> true
      ^season_dir -> true
    end)

    expect(Cinder.Library.FilesystemMock, :find_files, 2, fn
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

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn ^source, ^dest -> {:error, :eexist} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["en"]} ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    capture_log(fn ->
      assert {:ok, [{7, ^dest, quality}], []} = Library.import_episodes("/dl/grab", [episode])
      assert quality.sidecar_subtitles == ["en"]
      assert_receive :subtitle_search, 2_000
      await_subtitle_tasks()
    end)

    assert dest |> Subtitles.Manifest.read() |> Subtitles.Manifest.managed?("en")

    refute sibling_video
           |> Subtitles.Manifest.read()
           |> Subtitles.Manifest.managed?("en")
  end

  # The Fetcher processes casts one at a time in mailbox order, so a synchronous round-trip after
  # dispatch only returns once every previously-enqueued fetch has finished.
  defp await_subtitle_tasks do
    :sys.get_state(Cinder.Subtitles.Fetcher)
  end
end
