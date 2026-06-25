defmodule Cinder.LibraryTest do
  # In-test-process unit tests: expect + verify_on_exit!, no DB, no disk.
  use ExUnit.Case, async: true

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Library

  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"
  @tv_lib "/tmp/cinder-test-tv-library"
  @gb 1_000_000_000

  # An in-memory episode with its season/series preloaded (what wanted_episodes/the poller pass).
  defp ep(id, ep_num, season_num \\ 1, series_attrs \\ []) do
    series = struct(%Series{title: "Show", year: 2008, tmdb_id: 1}, series_attrs)

    %Episode{
      id: id,
      episode_number: ep_num,
      season: %Season{season_number: season_num, series: series}
    }
  end

  test "single-file source: hardlinks to Title (Year)/Title (Year).ext and scans" do
    movie = %Movie{title: "Inception", year: 2010, file_path: "/dl/Inception.2010.1080p.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Inception.2010.1080p.mkv" -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/Inception (2010)" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Inception.2010.1080p.mkv",
                                                  "#{@lib}/Inception (2010)/Inception (2010).mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

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

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end

  test "treats :eexist from ln as success when dest is the same file (idempotent re-run)" do
    movie = %Movie{title: "Heat", year: 1995, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
    # Same inode → dest is already our hardlink → idempotent success.
    expect(Cinder.Library.FilesystemMock, :lstat, 2, fn _ -> {:ok, %{inode: 42}} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end

  test ":eexist with a DIFFERENT file (two titles collide on the name) fails, no scan" do
    movie = %Movie{title: "Heat", year: 1995, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
    # Different inodes → dest belongs to another movie that collided on `Title (Year)` → don't
    # silently claim its file. No scan expected (verify_on_exit! fails if scan is called).
    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.mkv" -> {:ok, %{inode: 1}} end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn _dest -> {:ok, %{inode: 2}} end)

    assert {:error, :dest_exists} = Library.import_movie(movie)
  end

  test "scan failure is best-effort: import still succeeds once the file is linked" do
    movie = %Movie{title: "Heat", year: 1995, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> {:error, :econnrefused} end)

    log =
      capture_log(fn ->
        assert {:ok, "#{@lib}/Heat (1995)/Heat (1995).mkv"} = Library.import_movie(movie)
      end)

    assert log =~ "media-server scan failed"
  end

  test "a scan that RAISES is best-effort: import still succeeds once the file is linked" do
    movie = %Movie{title: "Heat", year: 1995, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    # A misconfigured media-server impl can raise (e.g. a malformed base URL or a
    # network error deep in the HTTP stack) — that must not crash an already-
    # hardlinked import.
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> raise "boom" end)

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

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, _dest} = Library.import_movie(movie)
  end

  test "year: nil falls back to a bare Title (no empty parens)" do
    movie = %Movie{title: "Untitled", year: nil, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/Untitled" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/Untitled/Untitled.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/Untitled/Untitled.mkv"} = Library.import_movie(movie)
  end

  test "a title that sanitizes to empty falls back to a tmdb-based folder" do
    movie = %Movie{title: "???", year: 2010, tmdb_id: 555, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/tmdb-555" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/tmdb-555/tmdb-555.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/tmdb-555/tmdb-555.mkv"} = Library.import_movie(movie)
  end

  test "a whitespace-only title also falls back to a tmdb-based folder" do
    movie = %Movie{title: "   ", year: 2010, tmdb_id: 777, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/tmdb-777" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/tmdb-777/tmdb-777.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/tmdb-777/tmdb-777.mkv"} = Library.import_movie(movie)
  end

  test "a dots-only title (path-traversal attempt) falls back to a tmdb-based folder" do
    # ".." would otherwise Path.join to escape the library root; route it to the tmdb fallback.
    movie = %Movie{title: "..", year: 2010, tmdb_id: 888, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/tmdb-888" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/tmdb-888/tmdb-888.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/tmdb-888/tmdb-888.mkv"} = Library.import_movie(movie)
  end

  describe "import_episodes/2" do
    # FS/media mocks stubbed (multiple, order-independent calls); assertions read the return value.
    defp stub_dir(files) do
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, files} end)
    end

    defp stub_link_ok do
      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
    end

    test "single episode matched by SxxEyy → Show (Year)/Season NN/Show (Year) - SxxEyy.ext" do
      stub_dir([{"/dl/Show.S01E03.1080p.mkv", 9 * @gb}, {"/dl/sample.mkv", 50_000_000}])
      stub_link_ok()

      assert {:ok, [{7, dest}], ["/dl/sample.mkv"]} = Library.import_episodes("/dl", [ep(7, 3)])
      assert dest == "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E03.mkv"
    end

    test "season pack: each file maps to its own episode and dest" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E02.mkv", 3 * @gb}])
      stub_link_ok()

      assert {:ok, imported, []} = Library.import_episodes("/dl", [ep(1, 1), ep(2, 2)])

      assert Enum.sort(imported) == [
               {1, "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E01.mkv"},
               {2, "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E02.mkv"}
             ]
    end

    test "a double-episode file hardlinks to both episodes" do
      stub_dir([{"/dl/Show.S01E01E02.1080p.mkv", 4 * @gb}])
      stub_link_ok()

      assert {:ok, imported, []} = Library.import_episodes("/dl", [ep(1, 1), ep(2, 2)])

      assert Enum.sort(imported) == [
               {1, "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E01.mkv"},
               {2, "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E02.mkv"}
             ]
    end

    test "two files parsing the same episode: largest imports, the rest log as unmatched" do
      # Both parse S01E01; only one source can own the episode's dest — keep the largest, route
      # the loser to unmatched (logged) rather than colliding two sources onto one dest.
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E01.REPACK.mkv", 5 * @gb}])
      stub_link_ok()

      log =
        capture_log(fn ->
          assert {:ok, [{1, dest}], ["/dl/Show.S01E01.mkv"]} =
                   Library.import_episodes("/dl", [ep(1, 1)])

          assert dest == "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E01.mkv"
        end)

      assert log =~ "unmatched"
    end

    test "an unmatchable file is logged and skipped; the rest still import" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E05.mkv", 3 * @gb}])
      stub_link_ok()

      log =
        capture_log(fn ->
          assert {:ok, [{1, dest}], ["/dl/Show.S01E05.mkv"]} =
                   Library.import_episodes("/dl", [ep(1, 1)])

          assert dest == "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E01.mkv"
        end)

      assert log =~ "unmatched"
    end

    test "single-file content_path with no SxxEyy → largest-wins for a lone-episode grab" do
      # Not a directory: the lone file is the source; the grab names the episode.
      stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/random.mkv" -> false end)
      stub_link_ok()

      assert {:ok, [{1, dest}], []} = Library.import_episodes("/dl/random.mkv", [ep(1, 4)])
      assert dest == "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E04.mkv"
    end

    test "video+sample with no SxxEyy: largest-wins assigns the episode, skips the sample" do
      stub_dir([{"/dl/show.finale.mkv", 9 * @gb}, {"/dl/sample.mkv", 50_000_000}])
      stub_link_ok()

      assert {:ok, [{1, dest}], ["/dl/sample.mkv"]} =
               Library.import_episodes("/dl", [ep(1, 3)])

      assert dest == "#{@tv_lib}/Show (2008)/Season 01/Show (2008) - S01E03.mkv"
    end

    test "lone-episode grab does NOT fall back when a file names a different specific episode" do
      # Show.S01E04 clearly names E04; the grab wants E03 — never mislabel E04 as E03.
      stub_dir([{"/dl/Show.S01E04.mkv", 3 * @gb}])

      assert {:ok, [], ["/dl/Show.S01E04.mkv"]} = Library.import_episodes("/dl", [ep(1, 3)])
    end

    test "no video file → {:ok, [], []} and no scan" do
      stub_dir([{"/dl/readme.nfo", 10}])

      assert {:ok, [], []} = Library.import_episodes("/dl", [ep(1, 1)])
    end

    test "ln :eexist is treated as success when dest is the same file (idempotent re-import)" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}])
      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
      # Same inode for source + dest → already our hardlink → idempotent.
      stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %{inode: 7}} end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

      assert {:ok, [{1, _dest}], []} = Library.import_episodes("/dl", [ep(1, 1)])
    end

    test "a transient hardlink error returns {:error, reason} so the grab retries" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}])
      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eacces} end)

      assert {:error, :eacces} = Library.import_episodes("/dl", [ep(1, 1)])
    end

    test "nil content_path → {:error, :no_content_path}" do
      assert {:error, :no_content_path} = Library.import_episodes(nil, [ep(1, 1)])
    end
  end
end
