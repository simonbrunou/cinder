defmodule Cinder.SubtitlesTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Subtitles
  alias Cinder.Subtitles.Manifest
  alias Cinder.Subtitles.Moviehash

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

  test "a current hash manifest re-searches when its target sidecar is missing", %{fs: fs} do
    zeros = <<0::size(65_536 * 8)>>
    moviehash = Moviehash.compute(131_072, zeros, zeros)
    manifest = Manifest.path(@video)

    Agent.update(fs, fn files ->
      Map.put(
        files,
        manifest,
        Jason.encode!(%{
          video_moviehash: moviehash,
          tracks: %{"fr" => %{origin: "opensubtitles_hash"}}
        })
      )
    end)

    expect(Cinder.Library.FilesystemMock, :moviehash_data, fn @video ->
      {:ok, {131_072, zeros, zeros}}
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["fr"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: true
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:ok, "HASH SRT"} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.get(&1, Subtitles.sidecar_path(@video, "fr"))) == "HASH SRT"
  end

  test "a malformed provider language does not hide a valid later candidate", %{fs: fs} do
    expect(Cinder.Subtitles.ProviderMock, :search, fn %{languages: ["fr"]} ->
      {:ok,
       [
         %{
           file_id: 1,
           language: nil,
           downloads: 10,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         },
         %{
           file_id: 2,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: false
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 2 -> {:ok, "FR SRT"} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.get(&1, Subtitles.sidecar_path(@video, "fr"))) == "FR SRT"
  end

  test "concurrent release-sidecar manifests serialize by video", %{fs: fs} do
    set_mox_global()
    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "")

    fr_target = Subtitles.sidecar_path(@video, "fr")
    en_target = Subtitles.sidecar_path(@video, "en")
    parent = self()

    Agent.update(fs, fn files ->
      files
      |> Map.put(fr_target, "FR SRT")
      |> Map.put(en_target, "EN SRT")
      |> Map.put(:manifest_read_barrier, true)
    end)

    manifest = Manifest.path(@video)

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      result =
        Agent.get(fs, fn files ->
          case files do
            %{^path => content} -> {:ok, content}
            _ -> {:error, :enoent}
          end
        end)

      if path == manifest and Agent.get(fs, &Map.get(&1, :manifest_read_barrier)) do
        waiter = self()

        Agent.update(fs, fn files ->
          Map.update(files, :manifest_waiters, [waiter], fn waiters -> [waiter | waiters] end)
        end)

        send(parent, {:manifest_read_ready, waiter})

        receive do
          :continue_manifest_read -> result
        end
      else
        result
      end
    end)

    try do
      assert :ok = Subtitles.fetch_after_import(fn -> %{} end, @video, :movies, ["fr"])
      assert :ok = Subtitles.fetch_after_import(fn -> %{} end, @video, :movies, ["en"])

      assert_receive {:manifest_read_ready, first}, 1_000
      refute_receive {:manifest_read_ready, _second}, 200

      first_ref = Process.monitor(first)
      send(first, :continue_manifest_read)

      assert_receive {:manifest_read_ready, second}, 1_000
      second_ref = Process.monitor(second)
      send(second, :continue_manifest_read)

      assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}, 1_000
      assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}, 1_000

      Agent.update(fs, &Map.delete(&1, :manifest_read_barrier))

      assert %{
               tracks: %{
                 "en" => %{origin: "release_sidecar"},
                 "fr" => %{origin: "release_sidecar"}
               }
             } = Manifest.read(@video)
    after
      fs
      |> Agent.get(&Map.get(&1, :manifest_waiters, []))
      |> Enum.each(&send(&1, :continue_manifest_read))
    end
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

  test "a manifest failure restores the previous managed sidecar", %{fs: fs} do
    target = Subtitles.sidecar_path(@video, "fr")
    manifest = Manifest.path(@video)

    Agent.update(fs, fn files ->
      files
      |> Map.put(target, "OLD SRT")
      |> Map.put(
        manifest,
        Jason.encode!(%{
          video_moviehash: nil,
          tracks: %{"fr" => %{origin: "opensubtitles_id"}}
        })
      )
    end)

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn @video ->
      {:ok, {131_072, <<0::size(65_536 * 8)>>, <<0::size(65_536 * 8)>>}}
    end)

    stub(Cinder.Library.FilesystemMock, :write, fn path, content ->
      if String.contains?(path, ".cinder-subtitle-manifest-") do
        {:error, :eio}
      else
        Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
        :ok
      end
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: true
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:ok, "NEW SRT"} end)
    deny(Cinder.Library.MediaServerMock, :scan, 1)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    assert Agent.get(fs, &Map.fetch!(&1, target)) == "OLD SRT"
    assert %{tracks: %{"fr" => %{origin: "opensubtitles_id"}}} = Manifest.read(@video)
  end

  test "a manifest failure removes a newly written sidecar", %{fs: fs} do
    target = Subtitles.sidecar_path(@video, "fr")

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn @video ->
      {:ok, {131_072, <<0::size(65_536 * 8)>>, <<0::size(65_536 * 8)>>}}
    end)

    stub(Cinder.Library.FilesystemMock, :write, fn path, content ->
      if String.contains?(path, ".cinder-subtitle-manifest-") do
        {:error, :eio}
      else
        Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
        :ok
      end
    end)

    expect(Cinder.Library.FilesystemMock, :rm, fn ^target ->
      Agent.update(fs, &Map.delete(&1, target))
      :ok
    end)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ ->
      {:ok,
       [
         %{
           file_id: 1,
           language: "fr",
           downloads: 1,
           hearing_impaired: false,
           ai_translated: false,
           moviehash_match: true
         }
       ]}
    end)

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:ok, "NEW SRT"} end)
    deny(Cinder.Library.MediaServerMock, :scan, 1)

    assert :ok = Subtitles.fetch_missing(%{imdb_id: "tt1"}, @video, :movies)
    refute Agent.get(fs, &Map.has_key?(&1, target))
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

  test "a forced exact embedded track falls through to a default non-forced translation", %{
    fs: fs
  } do
    video = @video
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    expect(Cinder.Subtitles.ProviderMock, :search, fn _ -> {:ok, []} end)

    expect(Cinder.Library.MediaInfoMock, :subtitle_tracks, fn ^video ->
      {:ok,
       [
         %{index: 2, language: "fr", default?: false, forced?: true},
         %{index: 3, language: "en", default?: true, forced?: false}
       ]}
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

    deny(Cinder.Library.FilesystemMock, :write, 2)
    deny(Cinder.Library.FilesystemMock, :rename, 2)

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

  @tag :tmp_dir
  test "subtitle rename rejects a library parent replaced by a symlink after the temp write", %{
    tmp_dir: tmp
  } do
    saved = configure_real_policy(tmp)
    on_exit(fn -> restore_env(saved) end)
    movies = Application.fetch_env!(:cinder, :movies_library_path)
    parent = Path.join(movies, "Movie")
    video = Path.join(parent, "Movie.mkv")
    outside = Path.join(tmp, "outside")
    target = Subtitles.sidecar_path(video, "fr")
    File.mkdir_p!(parent)
    File.mkdir_p!(outside)
    File.write!(video, "video")

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :write,
      contains: ".cinder-subtitle-",
      excludes: "manifest"
    })

    expect(Cinder.Subtitles.ProviderMock, :search, fn _criteria ->
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

    expect(Cinder.Subtitles.ProviderMock, :download, fn 1 -> {:ok, "subtitle"} end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    task = Task.async(fn -> Subtitles.fetch_missing(%{imdb_id: "tt1"}, video, :movies) end)

    assert_receive {:filesystem_barrier, pid, ref, :write, temporary}, 1_000
    replace_parent(parent, outside, temporary)
    send(pid, {ref, :continue})

    assert Task.await(task) == :ok
    refute File.exists?(Path.join(outside, Path.basename(target)))
  end

  defp configure_real_policy(tmp) do
    keys = [:filesystem, :path_policy, :movies_library_path, :tv_library_path]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, Path.join(tmp, "movies"))
    Application.put_env(:cinder, :tv_library_path, Path.join(tmp, "tv"))
    saved
  end

  defp restore_env(saved) do
    Application.delete_env(:cinder, :filesystem_barrier)

    Enum.each(saved, fn
      {key, nil} -> Application.delete_env(:cinder, key)
      {key, value} -> Application.put_env(:cinder, key, value)
    end)
  end

  defp replace_parent(parent, outside, temporary) do
    backup = parent <> ".old"
    File.rename!(parent, backup)
    File.ln_s!(outside, parent)

    File.rename!(
      Path.join(backup, Path.basename(temporary)),
      Path.join(outside, Path.basename(temporary))
    )
  end
end
