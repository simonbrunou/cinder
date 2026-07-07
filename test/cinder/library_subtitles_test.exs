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

  import Mox

  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Library

  setup :set_mox_from_context
  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"
  @tv_lib "/tmp/cinder-test-tv-library"
  @gb 1_000_000_000

  setup do
    saved = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved)
    end)

    Application.put_env(
      :cinder,
      Cinder.Subtitles.Provider.OpenSubtitles,
      Keyword.put(saved, :languages, "en")
    )

    :ok
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

    # The async task's sidecar-existence lstat (a *different* lstat, on the sidecar path). A stub, so
    # it's handled after the single source-file lstat expect above is consumed.
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:error, :enoent} end)

    # The subtitle fetch runs in the Task (global Mox). It signals the test so we can prove the
    # dispatch happened and that the provider error stayed off the import path.
    expect(Cinder.Subtitles.ProviderMock, :search, fn %{imdb_id: "tt0113277", languages: ["en"]} ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    assert {:ok, ^dest, _quality} = Library.import_movie(movie)
    assert_receive :subtitle_search, 2000
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

    # Sidecar-existence check for the imported episode file — see the movie test above.
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:error, :enoent} end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{
                                                        tmdb_id: 1,
                                                        season: 1,
                                                        episode: 3,
                                                        languages: ["en"]
                                                      } ->
      send(parent, :subtitle_search)
      {:error, :down}
    end)

    assert {:ok, [{7, ^dest, _quality}], []} = Library.import_episodes("/dl", [episode])
    assert_receive :subtitle_search, 2000
  end
end
