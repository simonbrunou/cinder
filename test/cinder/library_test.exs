defmodule Cinder.LibraryTest do
  # In-test-process unit tests: expect + verify_on_exit!, no DB, no disk.
  use ExUnit.Case, async: true

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Catalog.Movie
  alias Cinder.Library

  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"

  test "single-file source: hardlinks to Title (Year)/Title (Year).ext and scans" do
    movie = %Movie{title: "Inception", year: 2010, file_path: "/dl/Inception.2010.1080p.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Inception.2010.1080p.mkv" -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/Inception (2010)" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Inception.2010.1080p.mkv",
                                                  "#{@lib}/Inception (2010)/Inception (2010).mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, "#{@lib}/Inception (2010)/Inception (2010).mkv"} = Library.import_movie(movie)
  end

  test "folder source: picks the largest video file and skips the sample" do
    movie = %Movie{title: "Dune", year: 2021, file_path: "/dl/Dune.2021"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Dune.2021" -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/Dune.2021" ->
      {:ok,
       [
         {"/dl/Dune.2021/sample.mkv", 50_000_000},
         {"/dl/Dune.2021/Dune.2021.1080p.mkv", 9_000_000_000},
         {"/dl/Dune.2021/readme.nfo", 2_000}
       ]}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Dune.2021/Dune.2021.1080p.mkv",
                                                  "#{@lib}/Dune (2021)/Dune (2021).mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end

  test "treats :eexist from ln as success (idempotent re-run)" do
    movie = %Movie{title: "Heat", year: 1995, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end

  test "scan failure is best-effort: import still succeeds once the file is linked" do
    movie = %Movie{title: "Heat", year: 1995, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn -> {:error, :econnrefused} end)

    log =
      capture_log(fn ->
        assert {:ok, "#{@lib}/Heat (1995)/Heat (1995).mkv"} = Library.import_movie(movie)
      end)

    assert log =~ "media-server scan failed"
  end

  test "folder with no video file → {:error, :no_video_file}, no scan" do
    movie = %Movie{title: "X", year: 2000, file_path: "/dl/X"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/X/a.nfo", 10}, {"/dl/X/b.rar", 9_999}]}
    end)

    # No mkdir_p / ln / scan expected — verify_on_exit! fails if any is called.
    assert {:error, :no_video_file} = Library.import_movie(movie)
  end

  test "nil file_path → {:error, :no_file_path}, no FS calls" do
    assert {:error, :no_file_path} =
             Library.import_movie(%Movie{title: "X", year: 2000, file_path: nil})
  end

  test "sanitizes filesystem-illegal characters in the title" do
    movie = %Movie{title: "Face/Off", year: 1997, file_path: "/dl/FaceOff.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/FaceOff (1997)" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src,
                                                  "#{@lib}/FaceOff (1997)/FaceOff (1997).mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end

  test "year: nil falls back to a bare Title (no empty parens)" do
    movie = %Movie{title: "Untitled", year: nil, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/Untitled" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/Untitled/Untitled.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, "#{@lib}/Untitled/Untitled.mkv"} = Library.import_movie(movie)
  end

  test "a title that sanitizes to empty falls back to a tmdb-based folder" do
    movie = %Movie{title: "???", year: 2010, tmdb_id: 555, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/tmdb-555" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/tmdb-555/tmdb-555.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, "#{@lib}/tmdb-555/tmdb-555.mkv"} = Library.import_movie(movie)
  end

  test "a whitespace-only title also falls back to a tmdb-based folder" do
    movie = %Movie{title: "   ", year: 2010, tmdb_id: 777, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/tmdb-777" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/tmdb-777/tmdb-777.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn -> :ok end)

    assert {:ok, "#{@lib}/tmdb-777/tmdb-777.mkv"} = Library.import_movie(movie)
  end
end
