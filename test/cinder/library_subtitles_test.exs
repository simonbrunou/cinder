defmodule Cinder.LibrarySubtitlesTest do
  # async: false — this test opts the subtitles feature ON by mutating the shared
  # Cinder.Subtitles.Provider.OpenSubtitles :languages config (blank by default in
  # config/test.exs specifically so the async:true library_test.exs suite is unaffected). That
  # global mutation would race concurrently-running async tests, so this file — like
  # subtitles_test.exs — stays async: false and merges (not replaces) the config to preserve
  # base_url/api_key/req_options for anything else reading it.
  use ExUnit.Case, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Library

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

  test "import_movie fetches subtitles best-effort and still succeeds when the provider errors" do
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

    # The sidecar-existence check inside Subtitles.fetch_missing/2 (a *different* lstat call, on
    # the sidecar path, not the source file above). A stub — not another expect — so it doesn't
    # have to slot into the precise FIFO sequence above; only one lstat expect is queued (the
    # source lstat), so this second call falls through to the stub once that expect is consumed.
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:error, :enoent} end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{imdb_id: "tt0113277", languages: ["en"]} ->
      {:error, :down}
    end)

    log =
      capture_log(fn ->
        assert {:ok, ^dest, _quality} = Library.import_movie(movie)
      end)

    refute log =~ "subtitle fetch failed"
  end

  test "import_episodes fetches subtitles best-effort and still succeeds when the provider errors" do
    series = %Series{title: "Show", year: 2008, tmdb_id: 1}

    episode = %Episode{
      id: 7,
      episode_number: 3,
      season: %Season{season_number: 1, series: series}
    }

    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl" -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl" ->
      {:ok, [{"/dl/Show.S01E03.1080p.mkv", 9 * @gb}]}
    end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Show.S01E03.1080p.mkv" ->
      {:ok, %File.Stat{size: 9 * @gb, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    # Sidecar-existence check for the one imported episode file — see the movie test above.
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:error, :enoent} end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{
                                                        tmdb_id: 1,
                                                        season: 1,
                                                        episode: 3,
                                                        languages: ["en"]
                                                      } ->
      {:error, :down}
    end)

    log =
      capture_log(fn ->
        assert {:ok, [{7, ^dest, _quality}], []} = Library.import_episodes("/dl", [episode])
      end)

    refute log =~ "subtitle fetch failed"
  end
end
