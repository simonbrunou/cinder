defmodule Cinder.LibrarySourceUpgradeTest do
  # async: false — sets :cinder source-preference env to exercise the source axis end to end.
  use ExUnit.Case, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Catalog.Movie
  alias Cinder.Library

  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"
  @gb 1_000_000_000

  setup do
    prev = Application.get_env(:cinder, :movies_preferred_sources)
    Application.put_env(:cinder, :movies_preferred_sources, ["bluray", "webdl"])

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:cinder, :movies_preferred_sources)
        v -> Application.put_env(:cinder, :movies_preferred_sources, v)
      end
    end)

    :ok
  end

  test "same-resolution better source replaces the existing file and the quality carries source" do
    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imported_resolution: "1080p",
      imported_size: 9 * @gb,
      imported_language: nil,
      imported_source: "webdl",
      file_path: "/dl/Heat.1995.1080p.BluRay.x264.mkv"
    }

    dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.1995.1080p.BluRay.x264.mkv" ->
      {:ok, %File.Stat{size: 2 * @gb, inode: 7}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> {:error, :eexist} end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
    # replace path: sweep_temps, ln to tmp, rename
    expect(Cinder.Library.FilesystemMock, :find_files, fn _dir -> {:ok, []} end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, tmp ->
      assert String.contains?(tmp, ".cinder-tmp-")
      :ok
    end)

    expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    assert {:ok, ^dest, %{resolution: "1080p", source: "bluray"}} = Library.import_movie(movie)
  end

  test "same-resolution worse source keeps the existing file" do
    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imported_resolution: "1080p",
      imported_size: 1 * @gb,
      imported_language: nil,
      imported_source: "bluray",
      file_path: "/dl/Heat.1995.1080p.WEB-DL.x264.mkv"
    }

    dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.1995.1080p.WEB-DL.x264.mkv" ->
      {:ok, %File.Stat{size: 9 * @gb, inode: 7}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> {:error, :eexist} end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    log =
      capture_log(fn ->
        assert {:ok, ^dest, %{resolution: "1080p", source: "bluray"}} =
                 Library.import_movie(movie)
      end)

    assert log =~ "kept existing"
  end
end
