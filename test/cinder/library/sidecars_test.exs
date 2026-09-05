defmodule Cinder.Library.SidecarsTest do
  use Cinder.DataCase, async: false
  import ExUnit.CaptureLog
  import Mox
  setup :verify_on_exit!

  alias Cinder.Library.FilesystemMock
  alias Cinder.Library.Sidecars

  # Models a mid-stream write failure during `cp_exclusive`'s exclusive-copy fallback: the
  # first three bytes reach disk, then the write reports `:enospc` — the exact byte-level fault
  # from issue #515, distinct from `write` failing outright before any bytes land.
  defmodule TruncatingWriteFile do
    @moduledoc false

    def open(path, modes) do
      case :file.open(path, modes) do
        {:ok, io} = opened ->
          if :write in modes, do: Process.put({__MODULE__, :output}, io)
          opened

        error ->
          error
      end
    end

    defdelegate read(io, count), to: :file
    defdelegate read_file_info(io), to: :file
    defdelegate close(io), to: :file

    def write(io, bytes) do
      if io == Process.get({__MODULE__, :output}) do
        Process.delete({__MODULE__, :output})
        truncated = binary_part(IO.iodata_to_binary(bytes), 0, 3)
        :ok = :file.write(io, truncated)
        {:error, :enospc}
      else
        :file.write(io, bytes)
      end
    end
  end

  test "language/1 maps filename tokens to iso codes; flags ignored; unknown -> und" do
    assert Sidecars.language("Movie (2020).en.srt") == "en"
    assert Sidecars.language("Movie (2020).eng.forced.srt") == "en"
    assert Sidecars.language("Movie (2020).fre.srt") == "fr"
    assert Sidecars.language("subs.srt") == "und"
    assert Sidecars.language("Movie (2020).forced.srt") == "und"
    assert Sidecars.language("The.Italian.Job.2003.srt") == "und"
    assert Sidecars.language("Movie (2020).sdh.srt") == "und"
  end

  # Issue #201: `hi` is ISO-639-1 Hindi as well as the hearing-impaired flag. Stripping it
  # unconditionally left `Movie.hi.srt` — the exact convention this module writes — unable to
  # express Hindi at all, and undetectable afterwards since the result was a plain "und".
  test "language/1 reads a lone hi as Hindi but keeps it a flag beside a real language" do
    assert Sidecars.language("Movie (2020).hi.srt") == "hi"
    assert Sidecars.language("Movie (2020).hin.srt") == "hi"
    assert Sidecars.language("Movie (2020).hi.forced.srt") == "hi"

    assert Sidecars.language("Movie (2020).fr.hi.srt") == "fr"
    assert Sidecars.language("Movie (2020).hi.fr.srt") == "fr"
  end

  test "files/1 returns stem-matching sidecars with languages" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok,
       [
         {"#{dir}/Movie (2020).mkv", 900},
         {"#{dir}/Movie (2020).en.srt", 10},
         {"#{dir}/Movie (2020).fr.srt", 10},
         {"#{dir}/other.txt", 1}
       ]}
    end)

    assert Sidecars.files(src) == [
             {"#{dir}/Movie (2020).en.srt", "en"},
             {"#{dir}/Movie (2020).fr.srt", "fr"}
           ]
  end

  test "srt_files/1 excludes ASS sidecars while retaining matching SRT sidecars" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"
    srt = "#{dir}/Movie (2020).en.srt"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok,
       [
         {src, 900},
         {srt, 10},
         {"#{dir}/Movie (2020).fr.ass", 10}
       ]}
    end)

    assert Sidecars.srt_files(src) == [{srt, "en"}]
  end

  test "link/2 hardlinks each sidecar next to the dest, renamed, returns languages" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"
    dest = "/lib/Movie (2020)/Movie (2020).mkv"
    sub_src = "#{dir}/Movie (2020).en.srt"
    sub_dest = "/lib/Movie (2020)/Movie (2020).en.srt"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok, [{src, 900}, {sub_src, 10}]}
    end)

    expect(FilesystemMock, :ln, fn ^sub_src, ^sub_dest -> :ok end)

    assert Sidecars.link(src, dest) == ["en"]
  end

  test "files/1 requires a separator boundary so an unpadded E10 sidecar isn't matched to E1" do
    dir = "/dl/Show S01"
    src = "#{dir}/Show.S01E1.mkv"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok,
       [
         {"#{dir}/Show.S01E1.mkv", 900},
         {"#{dir}/Show.S01E10.mkv", 900},
         {"#{dir}/Show.S01E1.en.srt", 10},
         {"#{dir}/Show.S01E10.fr.srt", 10}
       ]}
    end)

    assert Sidecars.files(src) == [{"#{dir}/Show.S01E1.en.srt", "en"}]
  end

  test "link/2 dedups reported languages but still hardlinks every distinct sidecar file" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"
    dest = "/lib/Movie (2020)/Movie (2020).mkv"
    sub1_src = "#{dir}/Movie (2020).en.srt"
    sub1_dest = "/lib/Movie (2020)/Movie (2020).en.srt"
    sub2_src = "#{dir}/Movie (2020).en.forced.srt"
    sub2_dest = "/lib/Movie (2020)/Movie (2020).en.forced.srt"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok, [{src, 900}, {sub1_src, 10}, {sub2_src, 10}]}
    end)

    expect(FilesystemMock, :ln, fn ^sub1_src, ^sub1_dest -> :ok end)
    expect(FilesystemMock, :ln, fn ^sub2_src, ^sub2_dest -> :ok end)

    assert Sidecars.link(src, dest) == ["en"]
  end

  # Issue #201: `hi` read as the language must not also be re-emitted as a flag, or the Hindi
  # sidecar lands as `Movie (2020).hi.hi.srt`. The French-HI file beside it still keeps its flag.
  test "link/2 doesn't duplicate hi when it was consumed as the language" do
    dir = "/dl/Movie (2020)"
    src = "#{dir}/Movie (2020).mkv"
    dest = "/lib/Movie (2020)/Movie (2020).mkv"
    hindi_src = "#{dir}/Movie (2020).hi.srt"
    hindi_dest = "/lib/Movie (2020)/Movie (2020).hi.srt"
    french_hi_src = "#{dir}/Movie (2020).fr.hi.srt"
    french_hi_dest = "/lib/Movie (2020)/Movie (2020).fr.hi.srt"

    expect(FilesystemMock, :dir?, fn ^dir -> true end)

    expect(FilesystemMock, :find_files, fn ^dir ->
      {:ok, [{src, 900}, {hindi_src, 10}, {french_hi_src, 10}]}
    end)

    expect(FilesystemMock, :ln, fn ^hindi_src, ^hindi_dest -> :ok end)
    expect(FilesystemMock, :ln, fn ^french_hi_src, ^french_hi_dest -> :ok end)

    assert Sidecars.link(src, dest) == ["hi", "fr"]
  end

  describe "real path-policy sinks" do
    setup do
      keys = [
        :filesystem,
        :filesystem_failure,
        :filesystem_failures,
        :path_policy,
        :import_roots,
        :movies_library_path,
        :tv_library_path
      ]

      saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

      Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
      Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)

      on_exit(fn ->
        Application.delete_env(:cinder, :filesystem_barrier)

        Enum.each(saved, fn
          {key, nil} -> Application.delete_env(:cinder, key)
          {key, value} -> Application.put_env(:cinder, key, value)
        end)
      end)

      :ok
    end

    @tag :tmp_dir
    test "cross-filesystem fallback copies a sidecar through the real path policy", %{
      tmp_dir: tmp
    } do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "subtitle")
      File.mkdir_p!(Path.dirname(dest))
      fail_sidecar_links(sidecar)

      assert Sidecars.link(video, dest) == ["en"]
      assert File.read!(sidecar_dest) == "subtitle"
    end

    @tag :tmp_dir
    test "a mount with no hardlink support lands the sidecar through the exclusive copy", %{
      tmp_dir: tmp
    } do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "subtitle")
      File.mkdir_p!(Path.dirname(dest))
      # No `source_contains` scope: FAT/exFAT/CIFS can't hardlink *anything*, so the temp-to-dest
      # link fails too — the branch the :exdev test never reaches.
      fail_all_links(:eopnotsupp)

      assert Sidecars.link(video, dest) == ["en"]
      assert File.read!(sidecar_dest) == "subtitle"
      assert Path.wildcard(Path.join(Path.dirname(sidecar_dest), ".cinder-tmp-*")) == []
    end

    @tag :tmp_dir
    test "an interrupted no-hardlink landing leaves no truncated sidecar behind", %{tmp_dir: tmp} do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "subtitle")
      File.mkdir_p!(Path.dirname(dest))
      fail_all_links(:eopnotsupp)
      # A pre-existing destination is the one case `cp_exclusive` refuses, standing in for any
      # failed landing on a no-hardlink mount.
      File.write!(sidecar_dest, "manual")

      log = capture_log(fn -> assert Sidecars.link(video, dest) == [] end)

      assert log =~ "sidecar link rejected: :eexist"

      # The existing file is untouched and no staging temp survives — a failed landing never leaves
      # a truncated .srt that later imports would :eexist-skip forever.
      assert File.read!(sidecar_dest) == "manual"
      assert Path.wildcard(Path.join(Path.dirname(sidecar_dest), ".cinder-tmp-*")) == []
    end

    @tag :tmp_dir
    test "a byte-truncating exclusive-copy failure reclaims its own partial file so a retry can land it",
         %{tmp_dir: tmp} do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "a complete subtitle")
      File.mkdir_p!(Path.dirname(dest))
      fail_all_links(:eopnotsupp)
      Application.put_env(:cinder, :exclusive_copy_file_module, TruncatingWriteFile)
      on_exit(fn -> Application.delete_env(:cinder, :exclusive_copy_file_module) end)

      # The destination did not exist before this call: `cp_exclusive` creates it, then a
      # write partway through the stream leaves only "a c" on disk — a truncated destination,
      # not a pre-existing one.
      log = capture_log(fn -> assert Sidecars.link(video, dest) == [] end)
      assert log =~ "sidecar link rejected: :enospc"

      # A failed landing never leaves a truncated .srt that a later retry would :eexist-skip
      # forever — the file `cp_exclusive` just created is reclaimed because it's provably ours.
      refute File.exists?(sidecar_dest)
      assert Path.wildcard(Path.join(Path.dirname(sidecar_dest), ".cinder-tmp-*")) == []

      Application.put_env(:cinder, :exclusive_copy_file_module, :file)
      assert Sidecars.link(video, dest) == ["en"]
      assert File.read!(sidecar_dest) == "a complete subtitle"
    end

    @tag :tmp_dir
    test "a concurrent replacement published during reclaim survives untouched", %{tmp_dir: tmp} do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "a complete subtitle")
      File.mkdir_p!(Path.dirname(dest))
      fail_all_links(:eopnotsupp)
      Application.put_env(:cinder, :exclusive_copy_file_module, TruncatingWriteFile)
      on_exit(fn -> Application.delete_env(:cinder, :exclusive_copy_file_module) end)

      # Pause right after the truncated destination is atomically grabbed onto its private
      # quarantine name (freeing the real name) but before its identity is checked and it's
      # discarded — the exact window another writer could win.
      barrier(:rename, ".cinder-sidecar-quarantine-")

      task = Task.async(fn -> Sidecars.link(video, dest) end)
      {pid, ref, _quarantine_path} = await_barrier(:rename)

      File.write!(sidecar_dest, "concurrent replacement")
      send(pid, {ref, :continue})

      log = capture_log(fn -> assert Task.await(task) == [] end)
      assert log =~ "sidecar link rejected: :enospc"

      # The reclaim only ever acts on the quarantined copy of *its own* truncated output; the
      # file that took over the real name in the interim is never inspected or removed.
      assert File.read!(sidecar_dest) == "concurrent replacement"
    end

    @tag :tmp_dir
    test "an identity check that fails to stat during reclaim never guesses restore or discard",
         %{tmp_dir: tmp} do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "a complete subtitle")
      File.mkdir_p!(Path.dirname(dest))
      fail_all_links(:eopnotsupp)
      Application.put_env(:cinder, :exclusive_copy_file_module, TruncatingWriteFile)
      on_exit(fn -> Application.delete_env(:cinder, :exclusive_copy_file_module) end)

      # The identity check itself can't be completed (a transient I/O error, say) — this must
      # neither discard the quarantined file as unowned nor guess it back onto the permanent
      # name (which would reproduce the original :eexist-forever bug if it really was ours).
      # The first lstat on the quarantine path is path_policy's own pre-existence check (the
      # quarantine name genuinely doesn't exist yet at that point, so :enoent there changes
      # nothing); the second is the reclaim's own identity check, the one this test targets.
      Application.put_env(:cinder, :filesystem_failures, [
        %{operation: :lstat, source_contains: ".cinder-sidecar-quarantine-", reason: :enoent},
        %{operation: :lstat, source_contains: ".cinder-sidecar-quarantine-", reason: :eio}
      ])

      log = capture_log(fn -> assert Sidecars.link(video, dest) == [] end)
      assert log =~ "sidecar reclaim identity check failed"

      refute File.exists?(sidecar_dest)

      assert [quarantine] =
               Path.wildcard(
                 Path.join(Path.dirname(sidecar_dest), ".cinder-sidecar-quarantine-*"),
                 match_dot: true
               )

      assert File.read!(quarantine) == "a c"
    end

    @tag :tmp_dir
    test "copy fallback preserves a sidecar created before landing", %{tmp_dir: tmp} do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "download")
      File.mkdir_p!(Path.dirname(dest))
      fail_sidecar_links(sidecar)
      barrier(:cp, ".cinder-tmp-")

      task = Task.async(fn -> Sidecars.link(video, dest) end)
      {pid, ref, _path} = await_barrier(:cp)
      File.write!(sidecar_dest, "manual")
      send(pid, {ref, :continue})

      log = capture_log(fn -> assert Task.await(task) == [] end)

      assert log =~ "sidecar link rejected: :eexist"
      assert File.read!(sidecar_dest) == "manual"
    end

    @tag :tmp_dir
    test "recursive sidecar discovery skips a directory symlink outside allowed roots", %{
      tmp_dir: tmp
    } do
      %{release: release} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      outside = Path.join(tmp, "outside")
      File.write!(video, "video")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "Movie.en.srt"), "secret")
      File.ln_s!(outside, Path.join(release, "escaped"))

      assert Sidecars.files(video) == []
    end

    @tag :tmp_dir
    test "sidecar hardlink rejects a source replaced by a symlink after traversal", %{
      tmp_dir: tmp
    } do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      database = Path.join(tmp, "cinder.db")
      dest = Path.join(movies, "Movie/Movie.mkv")
      sidecar_dest = Path.rootname(dest) <> ".en.srt"
      File.write!(video, "video")
      File.write!(sidecar, "subtitle")
      File.write!(database, "database")
      File.mkdir_p!(Path.dirname(dest))

      barrier(:find_files, release)
      task = Task.async(fn -> Sidecars.link(video, dest) end)
      {pid, ref, _path} = await_barrier(:find_files)
      File.rm!(sidecar)
      File.ln_s!(database, sidecar)
      send(pid, {ref, :continue})

      assert Task.await(task) == []
      refute File.exists?(sidecar_dest)
    end

    @tag :tmp_dir
    test "sidecar hardlink rejects a destination parent replaced after traversal", %{tmp_dir: tmp} do
      %{release: release, movies: movies} = configure_real_roots(tmp)
      video = Path.join(release, "Movie.mkv")
      sidecar = Path.join(release, "Movie.en.srt")
      dest = Path.join(movies, "Movie/Movie.mkv")
      parent = Path.dirname(dest)
      outside = Path.join(tmp, "outside")
      File.write!(video, "video")
      File.write!(sidecar, "subtitle")
      File.mkdir_p!(parent)
      File.mkdir_p!(outside)

      barrier(:find_files, release)
      task = Task.async(fn -> Sidecars.link(video, dest) end)
      {pid, ref, _path} = await_barrier(:find_files)
      File.rename!(parent, parent <> ".old")
      File.ln_s!(outside, parent)
      send(pid, {ref, :continue})

      log = capture_log(fn -> assert Task.await(task) == [] end)

      assert log =~ "sidecar link rejected: :unsafe_destination"
      refute File.exists?(Path.join(outside, "Movie.en.srt"))
    end
  end

  defp configure_real_roots(tmp) do
    downloads = Path.join(tmp, "downloads")
    release = Path.join(downloads, "release")
    movies = Path.join(tmp, "movies")
    tv = Path.join(tmp, "tv")
    Enum.each([release, movies, tv], &File.mkdir_p!/1)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :movies_library_path, movies)
    Application.put_env(:cinder, :tv_library_path, tv)
    %{release: release, movies: movies}
  end

  defp barrier(operation, contains) do
    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: operation,
      contains: contains
    })
  end

  defp fail_sidecar_links(sidecar) do
    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :ln,
      source_contains: sidecar,
      reason: :exdev
    })
  end

  # An unscoped `ln` failure: every hardlink fails, source-to-dest and temp-to-dest alike, the way
  # a FAT/exFAT/CIFS mount behaves.
  defp fail_all_links(reason) do
    Application.put_env(:cinder, :filesystem_failure, %{
      operation: :ln,
      source_contains: "",
      reason: reason
    })
  end

  defp await_barrier(operation) do
    assert_receive {:filesystem_barrier, pid, ref, ^operation, path}, 1_000
    {pid, ref, path}
  end
end
