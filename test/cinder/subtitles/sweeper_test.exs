defmodule Cinder.Subtitles.SweeperTest do
  # async: false — the test mutates the shared Cinder.Subtitles.Provider.OpenSubtitles config,
  # which would race the async open_subtitles_test.exs; set_mox_from_context then runs in global
  # mode (matching an async: false context), which the Sweeper's own GenServer process needs to
  # see the per-test Mox expectations set up here.
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Subtitles.Sweeper

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    saved = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    Application.put_env(
      :cinder,
      Cinder.Subtitles.Provider.OpenSubtitles,
      Keyword.put(saved, :languages, "en")
    )

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved)
    end)

    :ok
  end

  test "poll/1 fetches a missing sidecar for an available movie" do
    _m = movie_fixture(status: :available, file_path: "/lib/M/M.mkv", imdb_id: "tt1", tmdb_id: 1)

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{imdb_id: "tt1", languages: ["en"]} ->
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
    |> expect(:download, fn 7 -> {:ok, "SRT"} end)

    {:ok, pid} = start_supervised({Sweeper, name: :sweeper_test})
    assert :ok = Sweeper.poll(pid)
  end

  test "poll/1 stops the tick when a download hits the daily quota (406)" do
    _a = movie_fixture(status: :available, file_path: "/lib/A/A.mkv", imdb_id: "tt1", tmdb_id: 1)
    _b = movie_fixture(status: :available, file_path: "/lib/B/B.mkv", imdb_id: "tt2", tmdb_id: 2)

    # Whichever movie is processed first: sidecar missing, search returns a candidate, download hits
    # quota → the sweep halts, so the OTHER movie is never searched. `expect(:search, 1, ...)` makes
    # a second search a verify failure, proving the halt regardless of DB row order.
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:error, :enoent} end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, 1, fn _ ->
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
    |> expect(:download, 1, fn 7 -> {:error, :quota_exceeded} end)

    {:ok, pid} = start_supervised({Sweeper, name: :sweeper_quota_test})
    assert :ok = Sweeper.poll(pid)
  end

  test "poll/1 skips an item whose sidecar already exists (no provider call)" do
    _m = movie_fixture(status: :available, file_path: "/lib/M/M.mkv", imdb_id: "tt1", tmdb_id: 1)

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:ok, %File.Stat{}} end)

    # No ProviderMock expectations => verify_on_exit! fails if search/download is called.
    {:ok, pid} = start_supervised({Sweeper, name: :sweeper_test})
    assert :ok = Sweeper.poll(pid)
  end

  test "poll/1 is a no-op when no languages are configured" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")
    _m = movie_fixture(status: :available, file_path: "/lib/M/M.mkv", imdb_id: "tt1", tmdb_id: 1)
    # No FilesystemMock/ProviderMock expectations at all.
    {:ok, pid} = start_supervised({Sweeper, name: :sweeper_test})
    assert :ok = Sweeper.poll(pid)
  end

  test "poll/1 fetches a missing sidecar for an imported episode" do
    series = series_fixture(tmdb_id: 42)
    season = season_fixture(series, %{season_number: 2})
    _ep = episode_fixture(season, %{episode_number: 5, file_path: "/lib/S/S02E05.mkv"})

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/S/S02E05.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/S/S02E05.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{tmdb_id: 42, season: 2, episode: 5, languages: ["en"]} ->
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
    |> expect(:download, fn 9 -> {:ok, "SRT"} end)

    {:ok, pid} = start_supervised({Sweeper, name: :sweeper_test})
    assert :ok = Sweeper.poll(pid)
  end
end
