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

  test "single-file source: hardlinks to Title (Year) {tmdb-N}/… and scans" do
    movie = %Movie{
      title: "Inception",
      year: 2010,
      tmdb_id: 27_205,
      file_path: "/dl/Inception.2010.1080p.mkv"
    }

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Inception.2010.1080p.mkv" -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Inception.2010.1080p.mkv" ->
      {:ok, %File.Stat{size: 5_000_000_000, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/Inception (2010) {tmdb-27205}" ->
      :ok
    end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Inception.2010.1080p.mkv",
                                                  "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv",
            %{resolution: "1080p", size: 5_000_000_000, language: nil}} =
             Library.import_movie(movie)
  end

  test "single-file import with media_info off returns empty capture lists" do
    # media_info is nil (config/test.exs default) and the download is a single file, so the probe is
    # skipped and no sidecar scan runs — all three capture lists come back empty, never nil.
    movie = %Movie{
      title: "Solo",
      year: 2018,
      tmdb_id: 348_350,
      file_path: "/dl/Solo.2018.1080p.mkv"
    }

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Solo.2018.1080p.mkv" ->
      {:ok, %File.Stat{size: 4 * @gb, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, _dest, q} = Library.import_movie(movie)
    assert q.audio_languages == []
    assert q.embedded_subtitles == []
    assert q.sidecar_subtitles == []
  end

  test "import captures the parsed source into the returned quality" do
    movie = %Movie{
      title: "Inception",
      year: 2010,
      tmdb_id: 27_205,
      file_path: "/dl/Inception.2010.1080p.BluRay.x264-GRP.mkv"
    }

    dest = "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(
      Cinder.Library.FilesystemMock,
      :lstat,
      fn "/dl/Inception.2010.1080p.BluRay.x264-GRP.mkv" ->
        {:ok, %File.Stat{size: 8 * @gb, inode: 7}}
      end
    )

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    assert {:ok, ^dest, %{resolution: "1080p", source: "bluray", language: nil}} =
             Library.import_movie(movie)
  end

  test "folder source: picks the largest video file and skips the sample" do
    movie = %Movie{title: "Dune", year: 2021, tmdb_id: 438_631, file_path: "/dl/Dune.2021"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Dune.2021" -> true end)
    # After the real import consumes the dir? expect above, the sidecar scan re-checks the source
    # dir; fall through to "not a dir" so no sidecars are found (this test asserts no sidecar behaviour).
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/Dune.2021" ->
      {:ok,
       [
         {"/dl/Dune.2021/sample.mkv", 50_000_000},
         {"/dl/Dune.2021/Dune.2021.1080p.mkv", 9_000_000_000},
         {"/dl/Dune.2021/readme.nfo", 2_000}
       ]}
    end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Dune.2021/Dune.2021.1080p.mkv" ->
      {:ok, %File.Stat{size: 9_000_000_000, inode: 2}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Dune.2021/Dune.2021.1080p.mkv",
                                                  "#{@lib}/Dune (2021) {tmdb-438631}/Dune (2021) {tmdb-438631}.mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, _dest, _quality} = Library.import_movie(movie)
  end

  test "treats :eexist from ln as success when dest is the same file (idempotent re-run)" do
    movie = %Movie{title: "Heat", year: 1995, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    # lstat source first (main with-chain); same inode → idempotent success, no rename/find_files.
    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.mkv" ->
      {:ok, %File.Stat{size: 5 * @gb, inode: 7}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
    # lstat dest: same inode → already our hardlink → idempotent success.
    expect(Cinder.Library.FilesystemMock, :lstat, fn _dest -> {:ok, %File.Stat{inode: 7}} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, _dest, _quality} = Library.import_movie(movie)
  end

  test "re-import replaces the existing file on a language upgrade" do
    movie = %Movie{
      title: "Open Season",
      year: 2023,
      tmdb_id: 1_001_026,
      preferred_language: "french",
      original_language: "hu",
      imported_resolution: "1080p",
      imported_size: 9 * @gb,
      imported_language: "HUNGARIAN",
      file_path: "/dl/Chasse.Gardee.2023.FRENCH.mkv"
    }

    dest = "#{@lib}/Open Season (2023) {tmdb-1001026}/Open Season (2023) {tmdb-1001026}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Chasse.Gardee.2023.FRENCH.mkv" ->
      {:ok, %File.Stat{size: 2 * @gb, inode: 7}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Chasse.Gardee.2023.FRENCH.mkv", ^dest ->
      {:error, :eexist}
    end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
    # sweep_temps
    expect(Cinder.Library.FilesystemMock, :find_files, fn _dir -> {:ok, []} end)

    expect(Cinder.Library.FilesystemMock, :ln, fn "/dl/Chasse.Gardee.2023.FRENCH.mkv", tmp ->
      assert String.contains?(tmp, ".cinder-tmp-")
      :ok
    end)

    expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, ^dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    assert {:ok, ^dest, %{resolution: nil, size: 2_000_000_000, language: "FRENCH"}} =
             Library.import_movie(movie)
  end

  test "re-import keeps the existing file when the new release is not an upgrade" do
    movie = %Movie{
      title: "Heat",
      year: 1995,
      tmdb_id: 949,
      imported_resolution: "1080p",
      imported_size: 9 * @gb,
      imported_language: nil,
      file_path: "/dl/Heat.1995.720p.mkv"
    }

    dest = "#{@lib}/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.1995.720p.mkv" ->
      {:ok, %File.Stat{size: 1 * @gb, inode: 7}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, ^dest -> {:error, :eexist} end)
    expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

    log =
      capture_log(fn ->
        assert {:ok, ^dest, %{resolution: "1080p", size: 9_000_000_000, language: nil}} =
                 Library.import_movie(movie)
      end)

    assert log =~ "kept existing"
  end

  describe "scan/1" do
    test "returns the configured media server result" do
      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> {:error, :unavailable} end)

      assert :ok = Library.scan(:movies)
      assert {:error, :unavailable} = Library.scan(:tv)
    end
  end

  test "scan failure is best-effort: import still succeeds once the file is linked" do
    movie = %Movie{title: "Heat", year: 1995, tmdb_id: 9799, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.mkv" ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> {:error, :econnrefused} end)

    log =
      capture_log(fn ->
        assert {:ok, "#{@lib}/Heat (1995) {tmdb-9799}/Heat (1995) {tmdb-9799}.mkv", _quality} =
                 Library.import_movie(movie)
      end)

    assert log =~ "media-server scan failed"
  end

  test "a scan that RAISES is best-effort: import still succeeds once the file is linked" do
    movie = %Movie{title: "Heat", year: 1995, tmdb_id: 9799, file_path: "/dl/Heat.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/Heat.mkv" ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    # A misconfigured media-server impl can raise (e.g. a malformed base URL or a
    # network error deep in the HTTP stack) — that must not crash an already-
    # hardlinked import.
    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> raise "boom" end)

    log =
      capture_log(fn ->
        assert {:ok, "#{@lib}/Heat (1995) {tmdb-9799}/Heat (1995) {tmdb-9799}.mkv", _quality} =
                 Library.import_movie(movie)
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
    movie = %Movie{title: "Face/Off", year: 1997, tmdb_id: 9615, file_path: "/dl/FaceOff.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/FaceOff.mkv" ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/FaceOff (1997) {tmdb-9615}" ->
      :ok
    end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src,
                                                  "#{@lib}/FaceOff (1997) {tmdb-9615}/FaceOff (1997) {tmdb-9615}.mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, _dest, _quality} = Library.import_movie(movie)
  end

  test "year: nil falls back to a bare Title {tmdb-N} (no empty parens)" do
    movie = %Movie{title: "Untitled", year: nil, tmdb_id: 12_345, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/x.mkv" ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/Untitled {tmdb-12345}" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src,
                                                  "#{@lib}/Untitled {tmdb-12345}/Untitled {tmdb-12345}.mkv" ->
      :ok
    end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/Untitled {tmdb-12345}/Untitled {tmdb-12345}.mkv", _quality} =
             Library.import_movie(movie)
  end

  test "a title that sanitizes to empty falls back to a tmdb-based folder" do
    movie = %Movie{title: "???", year: 2010, tmdb_id: 555, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/x.mkv" ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/tmdb-555" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/tmdb-555/tmdb-555.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/tmdb-555/tmdb-555.mkv", _quality} = Library.import_movie(movie)
  end

  test "a whitespace-only title also falls back to a tmdb-based folder" do
    movie = %Movie{title: "   ", year: 2010, tmdb_id: 777, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/x.mkv" ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/tmdb-777" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/tmdb-777/tmdb-777.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/tmdb-777/tmdb-777.mkv", _quality} = Library.import_movie(movie)
  end

  test "a dots-only title (path-traversal attempt) falls back to a tmdb-based folder" do
    # ".." would otherwise Path.join to escape the library root; route it to the tmdb fallback.
    movie = %Movie{title: "..", year: 2010, tmdb_id: 888, file_path: "/dl/x.mkv"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/x.mkv" ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn "#{@lib}/tmdb-888" -> :ok end)

    expect(Cinder.Library.FilesystemMock, :ln, fn _src, "#{@lib}/tmdb-888/tmdb-888.mkv" -> :ok end)

    expect(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, "#{@lib}/tmdb-888/tmdb-888.mkv", _quality} = Library.import_movie(movie)
  end

  describe "cross-filesystem import (:exdev hardlink fallback)" do
    @source "/dl/Inception.2010.1080p.mkv"
    @dest "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv"

    defp cross_fs_movie(attrs \\ []) do
      struct(
        %Movie{title: "Inception", year: 2010, tmdb_id: 27_205, file_path: @source},
        attrs
      )
    end

    test "ln :exdev falls back to an atomic copy: cp into a temp, then rename onto dest" do
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn @source ->
        {:ok, %File.Stat{size: 5 * @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      # Both the fresh placement and the link into the temp cross filesystems.
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dst -> {:error, :exdev} end)
      # sweep_temps finds no stale temps.
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, []} end)

      # cp targets a temp in the dest dir (never dest directly); record it to prove rename uses it.
      expect(Cinder.Library.FilesystemMock, :cp, fn @source, tmp ->
        assert String.contains?(Path.basename(tmp), ".cinder-tmp-")
        assert Path.dirname(tmp) == Path.dirname(@dest)
        Process.put(:copied_tmp, tmp)
        :ok
      end)

      # rename moves that exact temp onto the real dest — never cp/rename straight to dest.
      expect(Cinder.Library.FilesystemMock, :rename, fn tmp, @dest ->
        assert tmp == Process.get(:copied_tmp)
        :ok
      end)

      expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

      assert {:ok, @dest, %{resolution: "1080p", size: 5_000_000_000, language: nil}} =
               Library.import_movie(cross_fs_movie())
    end

    test "ln :eperm (no-hardlink filesystem) also falls back to the atomic copy" do
      # FAT/exFAT/SMB-without-Unix-extensions on a single mount: link() fails with :eperm, not :exdev.
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn @source ->
        {:ok, %File.Stat{size: 5 * @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dst -> {:error, :eperm} end)
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, []} end)
      expect(Cinder.Library.FilesystemMock, :cp, fn @source, _tmp -> :ok end)
      expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, @dest -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

      assert {:ok, @dest, %{resolution: "1080p", size: 5_000_000_000}} =
               Library.import_movie(cross_fs_movie())
    end

    test "a copy failure removes the temp and surfaces the error (no rename)" do
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: 5 * @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dst -> {:error, :exdev} end)
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, []} end)
      expect(Cinder.Library.FilesystemMock, :cp, fn _src, _tmp -> {:error, :enospc} end)
      # The temp is cleaned up; no rename, no scan (verify_on_exit! fails if either is called).
      expect(Cinder.Library.FilesystemMock, :rm, fn tmp ->
        assert String.contains?(Path.basename(tmp), ".cinder-tmp-")
        :ok
      end)

      assert {:error, :enospc} = Library.import_movie(cross_fs_movie())
    end

    test "a non-:exdev ln error does NOT copy — it propagates unchanged" do
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: 5 * @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dst -> {:error, :eacces} end)

      # No cp stub/expectation: an unexpected cp call would raise, making "never copies" a real assertion.

      assert {:error, :eacces} = Library.import_movie(cross_fs_movie())
    end

    # The review-caught correctness fix: inode numbers collide across filesystems, so a cross-fs
    # re-import with the SAME inode but a DIFFERENT device must NOT take the idempotency short-circuit.
    test "same inode, different device: a better release still replaces (not the inode short-circuit)" do
      movie =
        cross_fs_movie(
          imported_resolution: "720p",
          imported_size: 1 * @gb,
          imported_language: nil
        )

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      # source: inode 7 on device 1. dest: SAME inode (7) but a DIFFERENT device (2) — a naive
      # inode-only check would short-circuit and silently skip the upgrade.
      stub(Cinder.Library.FilesystemMock, :lstat, fn
        @source -> {:ok, %File.Stat{size: 5 * @gb, inode: 7, major_device: 1}}
        @dest -> {:ok, %File.Stat{inode: 7, major_device: 2}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      # dest exists; the temp link crosses filesystems → copy.
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, dst ->
        if String.contains?(dst, ".cinder-tmp-"), do: {:error, :exdev}, else: {:error, :eexist}
      end)

      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, []} end)
      expect(Cinder.Library.FilesystemMock, :cp, fn _src, _tmp -> :ok end)
      expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, @dest -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

      # Returns the NEW (better) quality → the upgrade ran; the short-circuit would have returned 720p.
      # cp + rename below prove this cross-fs upgrade copies through the shared link_or_copy choke-point.
      assert {:ok, @dest, %{resolution: "1080p", size: 5_000_000_000}} =
               Library.import_movie(movie)
    end

    test "same inode, different device: an equal release is kept (still bypasses the short-circuit)" do
      movie =
        cross_fs_movie(
          imported_resolution: "1080p",
          imported_size: 5 * @gb,
          imported_language: nil
        )

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn
        @source -> {:ok, %File.Stat{size: 5 * @gb, inode: 7, major_device: 1}}
        @dest -> {:ok, %File.Stat{inode: 7, major_device: 2}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dst -> {:error, :eexist} end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

      # Equal quality → keep (logged), returns the existing 1080p, no cp/rename (none stubbed).
      log =
        capture_log(fn ->
          assert {:ok, @dest, %{resolution: "1080p", size: 5_000_000_000}} =
                   Library.import_movie(movie)
        end)

      assert log =~ "kept existing"
    end

    test "TV: import_episodes takes the identical :exdev → copy path and imports the episode" do
      Cinder.LibraryStubs.stub_import_exdev(3 * @gb)

      assert {:ok, [{7, dest, _q}], []} =
               Library.import_episodes("/dl/Show.S01E03.1080p.mkv", [ep(7, 3)])

      assert dest == "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
    end
  end

  describe "import_episodes/2" do
    # FS/media mocks stubbed (multiple, order-independent calls); assertions read the return value.
    defp stub_dir(files) do
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, files} end)
    end

    defp stub_link_ok do
      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
    end

    test "single episode matched by SxxEyy → Show (Year) {tmdb-N}/Season NN/Show (Year) {tmdb-N} - SxxEyy.ext" do
      stub_dir([{"/dl/Show.S01E03.1080p.mkv", 9 * @gb}, {"/dl/sample.mkv", 50_000_000}])
      stub_link_ok()

      assert {:ok, [{7, dest, _quality}], ["/dl/sample.mkv"]} =
               Library.import_episodes("/dl", [ep(7, 3)])

      assert dest == "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
    end

    test "season pack: each file maps to its own episode and dest" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E02.mkv", 3 * @gb}])
      stub_link_ok()

      assert {:ok, imported, []} = Library.import_episodes("/dl", [ep(1, 1), ep(2, 2)])

      assert Enum.map(Enum.sort_by(imported, &elem(&1, 0)), fn {id, dest, _q} -> {id, dest} end) ==
               [
                 {1,
                  "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"},
                 {2,
                  "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E02.mkv"}
               ]
    end

    test "a double-episode file links once at a range-named path shared by both episodes" do
      source = "/dl/Show.S01E01E02.1080p.mkv"

      dest =
        "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01-E02.mkv"

      stub_dir([{source, 4 * @gb}])
      parent = self()

      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

      stub(Cinder.Library.FilesystemMock, :ln, fn path, target ->
        send(parent, {:linked, path, target})
        :ok
      end)

      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

      assert {:ok, imported, []} = Library.import_episodes("/dl", [ep(1, 1), ep(2, 2)])

      assert Enum.map(Enum.sort_by(imported, &elem(&1, 0)), fn {id, dest, _q} -> {id, dest} end) ==
               [
                 {1, dest},
                 {2, dest}
               ]

      assert_received {:linked, ^source, ^dest}
      refute_received {:linked, _, _}
    end

    test "a non-contiguous multi-episode file keeps its distinct episode tokens" do
      source = "/dl/Show.S01E01E03.1080p.mkv"

      stub_dir([{source, 4 * @gb}])
      stub_link_ok()

      assert {:ok, imported, []} = Library.import_episodes("/dl", [ep(1, 1), ep(3, 3)])

      assert Enum.map(Enum.sort_by(imported, &elem(&1, 0)), fn {id, dest, _q} -> {id, dest} end) ==
               [
                 {1,
                  "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01E03.mkv"},
                 {3,
                  "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01E03.mkv"}
               ]
    end

    test "two files parsing the same episode: largest imports, the rest log as unmatched" do
      # Both parse S01E01; only one source can own the episode's dest — keep the largest, route
      # the loser to unmatched (logged) rather than colliding two sources onto one dest.
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E01.REPACK.mkv", 5 * @gb}])
      stub_link_ok()

      log =
        capture_log(fn ->
          assert {:ok, [{1, dest, _q}], ["/dl/Show.S01E01.mkv"]} =
                   Library.import_episodes("/dl", [ep(1, 1)])

          assert dest ==
                   "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"
        end)

      assert log =~ "unmatched"
    end

    test "an unmatchable file is logged and skipped; the rest still import" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E05.mkv", 3 * @gb}])
      stub_link_ok()

      log =
        capture_log(fn ->
          assert {:ok, [{1, dest, _q}], ["/dl/Show.S01E05.mkv"]} =
                   Library.import_episodes("/dl", [ep(1, 1)])

          assert dest ==
                   "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"
        end)

      assert log =~ "unmatched"
    end

    test "single-file content_path with no SxxEyy → largest-wins for a lone-episode grab" do
      # Not a directory: the lone file is the source; the grab names the episode.
      stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/random.mkv" -> false end)
      stub_link_ok()

      assert {:ok, [{1, dest, _q}], []} = Library.import_episodes("/dl/random.mkv", [ep(1, 4)])
      assert dest == "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E04.mkv"
    end

    test "video+sample with no SxxEyy: largest-wins assigns the episode, skips the sample" do
      stub_dir([{"/dl/show.finale.mkv", 9 * @gb}, {"/dl/sample.mkv", 50_000_000}])
      stub_link_ok()

      assert {:ok, [{1, dest, _q}], ["/dl/sample.mkv"]} =
               Library.import_episodes("/dl", [ep(1, 3)])

      assert dest == "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
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
      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: @gb, inode: 7}}
      end)

      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

      assert {:ok, [{1, _dest, _q}], []} = Library.import_episodes("/dl", [ep(1, 1)])
    end

    test "a transient hardlink error returns {:error, reason} so the grab retries" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}])

      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eacces} end)

      assert {:error, :eacces} = Library.import_episodes("/dl", [ep(1, 1)])
    end

    test "nil content_path → {:error, :no_content_path}" do
      assert {:error, :no_content_path} = Library.import_episodes(nil, [ep(1, 1)])
    end

    test "a vanished content_path folder surfaces {:error, reason}, not an empty import" do
      # dir? is false for a nonexistent path too (unmounted volume): without the lstat guard
      # the folder name would pass as a "lone file", filter to no videos, and park+blocklist.
      stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/gone" -> false end)
      expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/gone" -> {:error, :enoent} end)

      assert {:error, :enoent} = Library.import_episodes("/dl/gone", [ep(1, 1)])
    end

    test "TV re-import replaces an episode's file on a resolution upgrade" do
      series = struct(%Series{title: "Show", year: 2008, tmdb_id: 1}, [])

      ep = %Episode{
        id: 5,
        episode_number: 1,
        imported_resolution: "720p",
        imported_size: 1 * @gb,
        imported_language: nil,
        season: %Season{season_number: 1, series: series}
      }

      source = "/dl/Show.S01E01.1080p.mkv"
      dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"

      expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/grab" -> true end)

      # The sidecar scan after a placed file re-checks the source dir; fall through to "not a dir".
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/grab" ->
        {:ok, [{source, 3 * @gb}]}
      end)

      expect(Cinder.Library.FilesystemMock, :lstat, fn ^source ->
        {:ok, %File.Stat{size: 3 * @gb, inode: 7}}
      end)

      expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      expect(Cinder.Library.FilesystemMock, :ln, fn ^source, ^dest -> {:error, :eexist} end)
      expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
      # sweep_temps
      expect(Cinder.Library.FilesystemMock, :find_files, fn _dir -> {:ok, []} end)

      expect(Cinder.Library.FilesystemMock, :ln, fn ^source, tmp ->
        assert String.contains?(tmp, ".cinder-tmp-")
        :ok
      end)

      expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, ^dest -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

      assert {:ok, [{5, ^dest, %{resolution: "1080p", size: 3_000_000_000, language: nil}}], []} =
               Library.import_episodes("/dl/grab", [ep])
    end

    test "TV re-import keeps the existing episode file when the new release is not an upgrade" do
      series = struct(%Series{title: "Show", year: 2008, tmdb_id: 1}, [])

      ep = %Episode{
        id: 6,
        episode_number: 1,
        imported_resolution: "1080p",
        imported_size: 9 * @gb,
        imported_language: nil,
        season: %Season{season_number: 1, series: series}
      }

      source = "/dl/Show.S01E01.720p.mkv"
      dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"

      expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/grab" -> true end)

      expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/grab" ->
        {:ok, [{source, 1 * @gb}]}
      end)

      expect(Cinder.Library.FilesystemMock, :lstat, fn ^source ->
        {:ok, %File.Stat{size: 1 * @gb, inode: 7}}
      end)

      expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      expect(Cinder.Library.FilesystemMock, :ln, fn ^source, ^dest -> {:error, :eexist} end)
      expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
      expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

      log =
        capture_log(fn ->
          assert {:ok, [{6, ^dest, %{resolution: "1080p", size: 9_000_000_000, language: nil}}],
                  []} =
                   Library.import_episodes("/dl/grab", [ep])
        end)

      assert log =~ "kept existing"
    end
  end

  describe "delete_file/1" do
    test "nil/blank path is a no-op (no filesystem calls)" do
      assert :ok = Cinder.Library.delete_file(nil)
      assert :ok = Cinder.Library.delete_file("")
    end

    test "unlinks the file and prunes the now-empty movie folder, stopping at the root" do
      path = "#{@lib}/Inception (2010)/Inception (2010).mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)
      # parent "Inception (2010)" is empty -> removed; its parent is the root -> never attempted.
      expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@lib}/Inception (2010)" -> :ok end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "prunes Season + show folders for an episode, stopping at the tv root" do
      path = "#{@tv_lib}/Show (2010)/Season 01/Show (2010) - S01E01.mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)

      expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@tv_lib}/Show (2010)/Season 01" ->
        :ok
      end)

      expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@tv_lib}/Show (2010)" -> :ok end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "stops pruning at the first non-empty parent" do
      path = "#{@lib}/Inception (2010)/Inception (2010).mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)
      expect(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "a missing file is idempotent (:ok) and still prunes" do
      path = "#{@lib}/Gone (2000)/Gone (2000).mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> {:error, :enoent} end)
      expect(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enoent} end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "a real unlink error is surfaced and nothing is pruned" do
      path = "#{@lib}/Locked (2000)/Locked (2000).mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> {:error, :eacces} end)
      # no rmdir expectation -> verify_on_exit! fails if pruning is attempted.

      assert {:error, :eacces} = Cinder.Library.delete_file(path)
    end
  end
end
