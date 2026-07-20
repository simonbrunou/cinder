defmodule Mix.Tasks.Cinder.MediaInfo.BackfillTest do
  use Cinder.DataCase, async: false
  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog.Episode
  alias Cinder.Library.Backfill
  alias Cinder.Subtitles.Manifest

  setup :verify_on_exit!

  # Every backfilled row now also gets its sidecars re-registered in the subtitle manifest
  # (issue #128), which recomputes the moviehash fresh from the file.
  setup do
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    :ok
  end

  test "fills media info on an available movie from probe + sidecar scan" do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    on_exit(fn -> Application.put_env(:cinder, :media_info, nil) end)

    movie = movie_fixture(%{status: :available, file_path: "/lib/M (2020)/M (2020).mkv"})

    stub(Cinder.Library.MediaInfoMock, :probe, fn _ ->
      {:ok, %{audio: ["eng"], subtitles: ["eng"]}}
    end)

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/lib/M (2020)/M (2020).fr.srt", 10}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{}} end)
    stub(Cinder.Library.FilesystemMock, :read, fn _ -> {:error, :enoent} end)
    stub(Cinder.Library.FilesystemMock, :write, fn _, _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _, _ -> :ok end)

    Backfill.run()

    m = Cinder.Catalog.get_movie_by_id(movie.id)
    assert m.imported_audio_languages == ["eng"]
    assert m.imported_embedded_subtitles == ["eng"]
    assert m.imported_sidecar_subtitles == ["fr"]
  end

  test "fills media info on an episode with a file_path" do
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    on_exit(fn -> Application.put_env(:cinder, :media_info, nil) end)

    series = series_fixture()
    season = season_fixture(series)

    episode =
      episode_fixture(season, %{file_path: "/tv/S (2020)/Season 01/S (2020) - S01E01.mkv"})

    stub(Cinder.Library.MediaInfoMock, :probe, fn _ ->
      {:ok, %{audio: ["ja"], subtitles: ["en"]}}
    end)

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/tv/S (2020)/Season 01/S (2020) - S01E01.fr.srt", 10}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{}} end)
    stub(Cinder.Library.FilesystemMock, :read, fn _ -> {:error, :enoent} end)
    stub(Cinder.Library.FilesystemMock, :write, fn _, _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _, _ -> :ok end)

    Backfill.run()

    e = Repo.get!(Episode, episode.id)
    assert e.imported_audio_languages == ["ja"]
    assert e.imported_embedded_subtitles == ["en"]
    assert e.imported_sidecar_subtitles == ["fr"]
  end

  test "re-registers an existing damaged row's sidecars as managed in the subtitle manifest (issue #128)" do
    movie = movie_fixture(%{status: :available, file_path: "/lib/D (2020)/D (2020).mkv"})
    sidecar = "/lib/D (2020)/D (2020).fr.srt"

    # A row imported before sidecar bookkeeping existed (or damaged by the adopt-path bug): the
    # sidecar is genuinely on disk, but the manifest never recorded it as Cinder-managed.
    fs = start_supervised!({Agent, fn -> %{sidecar => "existing SRT"} end})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, [{sidecar, 10}]} end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      if Agent.get(fs, &Map.has_key?(&1, path)), do: {:ok, %File.Stat{}}, else: {:error, :enoent}
    end)

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      case Agent.get(fs, &Map.get(&1, path)) do
        content when is_binary(content) -> {:ok, content}
        _ -> {:error, :enoent}
      end
    end)

    stub(Cinder.Library.FilesystemMock, :write, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rename, fn source, dest ->
      Agent.get_and_update(fs, fn files ->
        {:ok, files |> Map.delete(source) |> Map.put(dest, Map.fetch!(files, source))}
      end)
    end)

    refute movie.file_path |> Manifest.read() |> Manifest.managed?("fr")

    Backfill.run()

    assert movie.file_path |> Manifest.read() |> Manifest.managed?("fr")
  end

  test "a re-run keeps a hash-verified manifest entry instead of downgrading it" do
    movie = movie_fixture(%{status: :available, file_path: "/lib/V (2020)/V (2020).mkv"})
    sidecar = "/lib/V (2020)/V (2020).fr.srt"
    en_sidecar = "/lib/V (2020)/V (2020).en.srt"
    moviehash = "aaaabbbbccccdddd"

    manifest_json =
      Jason.encode!(%{
        "video_moviehash" => moviehash,
        "tracks" => %{"fr" => %{"origin" => "opensubtitles_hash"}}
      })

    # The sweeper already verified fr by hash; the moviehash_data stub means Backfill can't
    # compute a current hash, so it must keep the entry rather than downgrade it to
    # release_sidecar. The unverified en sidecar found next to it registers normally — and that
    # sibling write must preserve the stored video_moviehash fr's stability rides on, not wipe
    # it with the uncomputable nil.
    fs =
      start_supervised!(
        {Agent,
         fn ->
           %{
             sidecar => "existing SRT",
             en_sidecar => "existing EN SRT",
             Manifest.path(movie.file_path) => manifest_json
           }
         end}
      )

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{sidecar, 10}, {en_sidecar, 10}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      if Agent.get(fs, &Map.has_key?(&1, path)), do: {:ok, %File.Stat{}}, else: {:error, :enoent}
    end)

    stub(Cinder.Library.FilesystemMock, :read, fn path ->
      case Agent.get(fs, &Map.get(&1, path)) do
        content when is_binary(content) -> {:ok, content}
        _ -> {:error, :enoent}
      end
    end)

    stub(Cinder.Library.FilesystemMock, :write, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rename, fn source, dest ->
      Agent.get_and_update(fs, fn files ->
        {:ok, files |> Map.delete(source) |> Map.put(dest, Map.fetch!(files, source))}
      end)
    end)

    assert movie.file_path |> Manifest.read() |> Manifest.stable?(moviehash, "fr")

    Backfill.run()

    state = Manifest.read(movie.file_path)
    assert state.video_moviehash == moviehash
    assert Manifest.stable?(state, moviehash, "fr")
    assert state.tracks["en"] == %{origin: "release_sidecar"}
  end
end
