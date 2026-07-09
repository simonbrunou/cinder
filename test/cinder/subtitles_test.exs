defmodule Cinder.SubtitlesTest do
  # async: false — mutates and restores the shared Cinder.Subtitles.Provider.OpenSubtitles app env,
  # which also carries base_url/api_key/req_options that Provider.OpenSubtitlesTest depends on.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Subtitles

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, original)
    end)

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    :ok
  end

  test "wanted_languages/0 parses csv, downcases, and is [] when blank" do
    assert Subtitles.wanted_languages() == ["en", "fr"]
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "  ")
    assert Subtitles.wanted_languages() == []
  end

  test "sidecar_path/2 swaps the video extension for .<lang>.srt" do
    dest = "/lib/Movie (2020) {tmdb-1}/Movie (2020) {tmdb-1}.mkv"

    assert Subtitles.sidecar_path(dest, "en") ==
             "/lib/Movie (2020) {tmdb-1}/Movie (2020) {tmdb-1}.en.srt"
  end

  test "fetch_missing/2 picks highest-downloads non-HI non-AI result and writes the sidecar" do
    dest = "/lib/M/M.mkv"

    # 'en' sidecar missing, 'fr' sidecar already present.
    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:lstat, fn "/lib/M/M.fr.srt" -> {:ok, %File.Stat{}} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{imdb_id: "tt1", languages: ["en"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "en",
           downloads: 10,
           hearing_impaired: false,
           ai_translated: false
         },
         %{
           file_id: 2,
           language: "en",
           downloads: 99,
           hearing_impaired: true,
           ai_translated: false
         },
         %{
           file_id: 3,
           language: "en",
           downloads: 50,
           hearing_impaired: false,
           ai_translated: false
         }
       ]}
    end)
    |> expect(:download, fn 3 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, dest)
  end

  test "fetch_missing/2 stops on quota (406) and doesn't attempt the next language" do
    # languages "en,fr" from setup; 'en' hits the daily download quota, so 'fr' is never searched.
    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{languages: ["en"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "en",
           downloads: 5,
           hearing_impaired: false,
           ai_translated: false
         }
       ]}
    end)
    |> expect(:download, fn 1 -> {:error, :quota_exceeded} end)

    # No 'fr' lstat/search/download expectations => verify_on_exit! proves 'fr' was never attempted.
    assert :quota_exceeded =
             Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 is a no-op when no languages are configured" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")
    # No provider/filesystem expectations => any call fails verify_on_exit!.
    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 swallows a provider error (best-effort) and writes nothing" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn _ -> {:error, :boom} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 swallows a provider raise (best-effort) and downloads nothing" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn _ -> raise "boom" end)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
      end)

    assert log =~ "subtitle fetch"
  end

  test "fetch_missing/2 swallows a filesystem raise from the sidecar-existence check itself" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    # lstat raising must be caught by fetch_one/3's rescue/catch, not escape fetch_missing/2 —
    # no search/download/write expectation is set, so any of those calls fails verify_on_exit!.
    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> raise "fs down" end)

    log =
      capture_log(fn ->
        assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
      end)

    assert log =~ "subtitle fetch"
  end

  test "fetch_missing/2 picks the correct candidate among AI/HI/nil-file_id/wrong-language noise" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    Cinder.Library.FilesystemMock
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{imdb_id: "tt1", languages: ["en"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "en",
           downloads: 900,
           hearing_impaired: false,
           ai_translated: true
         },
         %{
           file_id: 2,
           language: "en",
           downloads: 800,
           hearing_impaired: true,
           ai_translated: false
         },
         %{
           file_id: nil,
           language: "en",
           downloads: 700,
           hearing_impaired: false,
           ai_translated: false
         },
         %{
           file_id: 4,
           language: "FR",
           downloads: 1000,
           hearing_impaired: false,
           ai_translated: false
         },
         %{
           file_id: 5,
           language: "en",
           downloads: 42,
           hearing_impaired: false,
           ai_translated: false
         },
         %{
           file_id: 6,
           language: "en",
           downloads: 10,
           hearing_impaired: false,
           ai_translated: false
         }
       ]}
    end)
    |> expect(:download, fn 5 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 merges the file's moviehash into the search criteria" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")
    zeros = <<0::size(65_536 * 8)>>

    Cinder.Library.FilesystemMock
    |> expect(:moviehash_data, fn "/lib/M/M.mkv" -> {:ok, {131_072, zeros, zeros}} end)
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{imdb_id: "tt1", moviehash: "0000000000020000", languages: ["en"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "en",
           downloads: 10,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)
    |> expect(:download, fn 1 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 prefers a moviehash-matched candidate over a higher-downloads non-match" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")
    zeros = <<0::size(65_536 * 8)>>

    Cinder.Library.FilesystemMock
    |> expect(:moviehash_data, fn _ -> {:ok, {131_072, zeros, zeros}} end)
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn %{languages: ["en"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "en",
           downloads: 999,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         },
         %{
           file_id: 2,
           language: "en",
           downloads: 5,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: true
         }
       ]}
    end)
    |> expect(:download, fn 2 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end

  test "fetch_missing/2 still searches by id when the file is not hashable" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    Cinder.Library.FilesystemMock
    |> expect(:moviehash_data, fn _ -> :too_small end)
    |> expect(:lstat, fn "/lib/M/M.en.srt" -> {:error, :enoent} end)
    |> expect(:write, fn "/lib/M/M.en.srt", "SRT" -> :ok end)

    Cinder.Subtitles.ProviderMock
    |> expect(:search, fn criteria ->
      refute Map.has_key?(criteria, :moviehash)

      {:ok,
       [
         %{
           file_id: 1,
           language: "en",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)
    |> expect(:download, fn 1 -> {:ok, "SRT"} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1", tmdb_id: 1}, "/lib/M/M.mkv")
  end
end
