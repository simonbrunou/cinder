defmodule Mix.Tasks.Cinder.MediaInfo.BackfillTest do
  use Cinder.DataCase, async: false
  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog.Episode
  alias Cinder.Library.{Backfill, Filesystem.Disk}
  alias Cinder.Subtitles.{Manifest, Moviehash, Sync}

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
    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> :ok end)
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
    primary = "/tv/S (2020)/Season 01/S (2020) - S01E15.mkv"
    part = "/tv/S (2020)/Season 01/S (2020) - S01E16.mkv"

    episode =
      episode_fixture(season, %{file_path: primary, part_file_paths: [part]})

    expect(Cinder.Library.MediaInfoMock, :probe, 2, fn
      ^primary -> {:ok, %{audio: ["ja"], subtitles: ["en"]}}
      ^part -> {:ok, %{audio: ["en"], subtitles: ["fr"]}}
    end)

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok,
       [
         {"/tv/S (2020)/Season 01/S (2020) - S01E15.fr.srt", 10},
         {"/tv/S (2020)/Season 01/S (2020) - S01E16.de.srt", 10}
       ]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{}} end)
    stub(Cinder.Library.FilesystemMock, :read, fn _ -> {:error, :enoent} end)
    stub(Cinder.Library.FilesystemMock, :write, fn _, _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _, _ -> :ok end)

    Backfill.run()

    e = Repo.get!(Episode, episode.id)
    assert e.imported_audio_languages == ["ja", "en"]
    assert e.imported_embedded_subtitles == ["en", "fr"]
    assert e.imported_sidecar_subtitles == ["fr", "de"]
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

    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
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

    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
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
    assert state.tracks["en"] == %{origin: "release_sidecar", file: "V (2020).en.srt"}
  end

  @tag :tmp_dir
  test "preserves an opensubtitles_id track's synchronization provenance across a re-run", %{
    tmp_dir: tmp
  } do
    keys = [:filesystem, :path_policy, :movies_library_path]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    movies = Path.join(tmp, "movies")
    File.mkdir_p!(movies)
    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, movies)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    video = Path.join(movies, "P (2020)/P (2020).mkv")
    File.mkdir_p!(Path.dirname(video))
    video_content = String.duplicate("v", 131_072)
    File.write!(video, video_content)
    chunk = String.duplicate("v", 65_536)
    moviehash = Moviehash.compute(131_072, chunk, chunk)

    sidecar = Path.rootname(video) <> ".fr.srt"
    original = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    corrected = "1\n00:00:02,000 --> 00:00:03,000\nOne\n\n"
    File.write!(sidecar, corrected)

    original_sha = digest(original)
    corrected_sha = digest(corrected)

    Jason.encode!(%{
      "video_moviehash" => moviehash,
      "tracks" => %{
        "fr" => %{
          "origin" => "opensubtitles_id",
          "file" => Path.basename(sidecar),
          "managed_sha256" => original_sha,
          "sync" => %{
            "status" => "aligned",
            "method" => "manual",
            "moviehash" => moviehash,
            "source_sha256" => original_sha,
            "applied_sha256" => corrected_sha,
            "offset_ms" => 1000,
            "rate" => 1.0
          }
        }
      }
    })
    |> then(&File.write!(Manifest.path(video), &1))

    # A real correction's backup is created through Backup.ensure/2, which records the backup
    # file's own identity as a tombstone so a later reset can prove it's discarding its own
    # immutable copy rather than an unrelated file — reproduce that here instead of a plain
    # `File.write!/2`.
    assert {:ok, bound} = Disk.create_bound(Sync.backup_path(sidecar), original)
    assert :ok = Manifest.put_backup_tombstone(video, "fr", bound.identity)
    assert :ok = Disk.close_bound(bound)

    movie_fixture(%{status: :available, file_path: video})

    Backfill.run()

    state = Manifest.read(video)
    assert state.tracks["fr"].origin == "opensubtitles_id"
    assert state.tracks["fr"].managed_sha256 == original_sha
    assert state.tracks["fr"].sync.applied_sha256 == corrected_sha
    assert File.read!(sidecar) == corrected

    assert [item] = Sync.discover(video)
    assert :ok = Sync.reset(item)
    assert File.read!(sidecar) == original
  end

  test "a re-run never erases an in-progress replacement cleanup journal" do
    movie = movie_fixture(%{status: :available, file_path: "/lib/J (2020)/J (2020).mkv"})
    sidecar = "/lib/J (2020)/J (2020).fr.srt"

    journal = %{
      "status" => "aligned",
      "method" => "manual",
      "moviehash" => nil,
      "source_sha256" => String.duplicate("a", 64),
      "applied_sha256" => String.duplicate("b", 64),
      "offset_ms" => 1000,
      "rate" => 1.0
    }

    manifest_json =
      Jason.encode!(%{
        "video_moviehash" => nil,
        "tracks" => %{
          "fr" => %{
            "origin" => "opensubtitles_id",
            "file" => "J (2020).fr.srt",
            "managed_sha256" => String.duplicate("c", 64),
            "replacement_cleanup_sync" => journal
          }
        }
      })

    fs =
      start_supervised!(
        {Agent,
         fn ->
           %{sidecar => "unrelated new bytes", Manifest.path(movie.file_path) => manifest_json}
         end}
      )

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

    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rename, fn source, dest ->
      Agent.get_and_update(fs, fn files ->
        {:ok, files |> Map.delete(source) |> Map.put(dest, Map.fetch!(files, source))}
      end)
    end)

    Backfill.run()

    state = Manifest.read(movie.file_path)
    assert state.tracks["fr"].origin == "opensubtitles_id"
    assert state.tracks["fr"].replacement_cleanup_sync.source_sha256 == String.duplicate("a", 64)
  end

  test "a re-run does not silently protect a provider track whose sidecar it fails to read" do
    movie = movie_fixture(%{status: :available, file_path: "/lib/R (2020)/R (2020).mkv"})
    sidecar = "/lib/R (2020)/R (2020).fr.srt"

    manifest_json =
      Jason.encode!(%{
        "video_moviehash" => nil,
        "tracks" => %{
          "fr" => %{
            "origin" => "opensubtitles_id",
            "file" => "R (2020).fr.srt",
            "managed_sha256" => String.duplicate("d", 64)
          }
        }
      })

    fs = start_supervised!({Agent, fn -> %{Manifest.path(movie.file_path) => manifest_json} end})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, [{sidecar, 10}]} end)

    # The sidecar genuinely exists (lstat succeeds) but its bytes can't currently be read (a
    # transient I/O error, say) — this track has no `sync`, so an unguarded comparison against
    # two absent values would wrongly "prove" the unreadable file unchanged.
    stub(Cinder.Library.FilesystemMock, :lstat, fn ^sidecar -> {:ok, %File.Stat{}} end)

    stub(Cinder.Library.FilesystemMock, :read, fn
      ^sidecar ->
        {:error, :eio}

      path ->
        case Agent.get(fs, &Map.get(&1, path)) do
          content when is_binary(content) -> {:ok, content}
          _ -> {:error, :enoent}
        end
    end)

    stub(Cinder.Library.FilesystemMock, :write, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, IO.iodata_to_binary(content)))
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rename, fn source, dest ->
      Agent.get_and_update(fs, fn files ->
        {:ok, files |> Map.delete(source) |> Map.put(dest, Map.fetch!(files, source))}
      end)
    end)

    Backfill.run()

    assert Manifest.read(movie.file_path).tracks["fr"].origin == "release_sidecar"
  end

  defp digest(content),
    do: content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
