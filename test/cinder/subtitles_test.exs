defmodule Cinder.SubtitlesTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Subtitles
  alias Cinder.Subtitles.Manifest

  @video "/lib/M/M.mkv"
  setup :verify_on_exit!

  setup do
    saved_provider = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])
    saved_media_info = Application.get_env(:cinder, :media_info)

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved_provider)
      Application.put_env(:cinder, :media_info, saved_media_info)
    end)

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "fr")
    Application.put_env(:cinder, :media_info, nil)

    fs = start_supervised!({Agent, fn -> %{} end})

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      send(self(), {:read, path})

      Agent.get(fs, fn files ->
        case files do
          %{^path => content} -> {:ok, content}
          _ -> {:error, :enoent}
        end
      end)
    end)

    stub(Cinder.Library.FilesystemMock, :write, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rename, fn source, dest ->
      Agent.get_and_update(fs, fn files ->
        {{:ok, Map.fetch!(files, source)},
         files |> Map.delete(source) |> Map.put(dest, Map.fetch!(files, source))}
      end)
      |> elem(0)
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      if Agent.get(fs, &Map.has_key?(&1, path)), do: {:ok, %File.Stat{}}, else: {:error, :enoent}
    end)

    {:ok, fs: fs}
  end

  test "wanted_languages/0 parses csv and is [] when blank" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en, FR")
    assert Subtitles.wanted_languages() == ["en", "fr"]

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "  ")
    assert Subtitles.wanted_languages() == []
  end

  test "sidecar_path/2 preserves the normal video.lang.srt name" do
    assert Subtitles.sidecar_path(@video, "fr") == "/lib/M/M.fr.srt"
  end

  test "an ID result is provisional and a later hash result replaces it", %{fs: fs} do
    video = @video
    target = "/lib/M/M.fr.srt"
    zeros = <<0::size(65_536 * 8)>>

    expect(Cinder.Library.FilesystemMock, :moviehash_data, 2, fn ^video ->
      case Agent.get_and_update(fs, fn files ->
             count = Map.get(files, :hash_reads, 0)
             {count, Map.put(files, :hash_reads, count + 1)}
           end) do
        0 -> :too_small
        1 -> {:ok, {131_072, zeros, zeros}}
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, 2, fn %{languages: ["fr"]} ->
      case Agent.get_and_update(fs, fn files ->
             count = Map.get(files, :searches, 0)
             {count, Map.put(files, :searches, count + 1)}
           end) do
        0 ->
          {:ok,
           [
             %{
               file_id: 1,
               language: "fr",
               downloads: 1,
               hearing_impaired: false,
               ai_translated: false,
               moviehash_match: false
             }
           ]}

        1 ->
          {:ok,
           [
             %{
               file_id: 2,
               language: "fr",
               downloads: 1,
               hearing_impaired: false,
               ai_translated: false,
               moviehash_match: true
             }
           ]}
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, 2, fn
      1 -> {:ok, "ID SRT"}
      2 -> {:ok, "HASH SRT"}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, 2, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert %{tracks: %{"fr" => %{origin: "opensubtitles_id"}}} = Manifest.read(@video)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert %{tracks: %{"fr" => %{origin: "opensubtitles_hash"}}} = Manifest.read(@video)
    assert Agent.get(fs, &Map.fetch!(&1, target)) == "HASH SRT"
  end

  test "a provider failure does not call an embedded source or LibreTranslate" do
    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:error, :down} end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
  end

  test "an empty provider result extracts an exact embedded target track", %{fs: fs} do
    video = @video
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 2, language: "fr", default?: false, forced?: false}]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 2 -> {:ok, "FR SRT"} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.fetch!(&1, "/lib/M/M.fr.srt")) == "FR SRT"
    assert %{tracks: %{"fr" => %{origin: "embedded"}}} = Manifest.read(@video)
  end

  test "a default embedded track translates each still-missing target", %{fs: fs} do
    video = @video
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok, [%{index: 3, language: "en", default?: true, forced?: false}]}
    end)

    expect(Cinder.Library.MediaInfoMock, :extract_subtitle, fn ^video, 3 ->
      {:ok, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"}
    end)

    expect(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
      {:ok, ["Bonjour"]}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.fetch!(&1, "/lib/M/M.fr.srt")) =~ "Bonjour"
    assert %{tracks: %{"fr" => %{origin: "translated"}}} = Manifest.read(@video)
  end

  test "an SRT sidecar supplies the translation source when no embedded track is usable", %{
    fs: fs
  } do
    video = @video
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    source = "/lib/M/M.en.srt"

    Agent.update(fs, &Map.put(&1, source, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n"))

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)
    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video -> {:ok, []} end)
    expect(Cinder.Library.FilesystemMock, :dir?, fn "/lib/M" -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/lib/M" ->
      {:ok, [{@video, 1}, {source, 1}]}
    end)

    expect(Cinder.Subtitles.TranslatorMock, :translate, fn ["Hello"], "fr" ->
      {:ok, ["Bonjour"]}
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert_received {:read, ^source}
    assert Agent.get(fs, &Map.fetch!(&1, "/lib/M/M.fr.srt")) =~ "Bonjour"
  end

  test "an unmarked target sidecar is never overwritten even when a provider candidate exists", %{
    fs: fs
  } do
    target = "/lib/M/M.fr.srt"
    Agent.update(fs, &Map.put(&1, target, "manual"))

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.fetch!(&1, target)) == "manual"
  end

  test "fetch_missing/2 remains a movies wrapper" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")
    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video)
  end

  test "fetch_missing/3 stops after the provider reports quota" do
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en,fr")

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["en"]} ->
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

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:error, :quota_exceeded} end)

    assert :quota_exceeded = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
  end
end
