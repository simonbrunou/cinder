defmodule Cinder.SubtitlesTest do
  # async: false — mutates and restores the shared Cinder.Subtitles.Provider.OpenSubtitles app env,
  # which also carries base_url/api_key/req_options that Provider.OpenSubtitlesTest depends on.
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Subtitles

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, original)
    end)

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")
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
end
