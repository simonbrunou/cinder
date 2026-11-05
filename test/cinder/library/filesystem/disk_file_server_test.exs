defmodule Cinder.Library.Filesystem.DiskFileServerTest do
  @moduledoc """
  Calls on mount paths answer without the VM's one file server (`:file_server_2`), so one hung on
  a wedged mount pins only its own process (#779, #944, #1114, #1146). Covered here, each with the
  file server suspended:

    * reads outside the library roots: `Cinder.Library.Filesystem.Disk.dir?/1`, `Disk.read/1`,
      `Disk.open_bound/2` (the lstat of the path and the stat of its descriptor path),
      `Disk.moviehash_data/1` (the same bind, then the stat and the open of the descriptor path)
      and `Cinder.Download.PathMapping.validate_local_prefix/2` (the stat of the local prefix);
    * writes and other changes outside the library roots: `Disk.write/2`, `chmod/2`,
      `mkdir_p/1`, `mkdir_exclusive/2`, `rm/1`, `rmdir/1`, `rm_rf/1`, `ln/2`, `cp/2`,
      `rename/2`, `rename_exclusive/2`, `exchange/2`, and `create_bound/2` with `write_bound/2`,
      `discard_bound/1` and `close_bound/1`;
    * under a library root, through the `python3` lookup and the rooted helper: `Disk.read/1`,
      `write/2` and `chmod/2`, and the staged file's chmod in the create and the exchange of
      `Cinder.Subtitles.SidecarTransaction.AtomicFile`;
    * under an import root: the scratch directory's reset and removal in
      `Cinder.Library.BookArchive.extract_and_resolve/3`, and in `BookArchive.Zip.extract/3` the
      entries' directories and the removal of an entry whose CRC-32 does not match.

  `mkdir_p/1`, `rm_rf/1` and `cp/2` are also checked against Elixir's own `File` call on the same
  fixture. `ls/1` and `lstat/1` are covered through the walk in `Cinder.Library.SafeWalkTest`, and
  the lookup before each subprocess in `Cinder.BoundedCommandLookupTest`. Every other call in the
  modules `Cinder.CodeHealth.MountPathRawCallsTest` scans, such as the reads in
  `Cinder.Subtitles.SidecarTransaction.Backup` and `Cinder.Subtitles.Sync`, has only that fence.
  """
  # Suspends the VM file server, which every concurrent `File` call would queue behind. The
  # Disk entry points read the library roots, some of them from the database.
  use Cinder.DataCase, async: false

  import Cinder.BoundedWalkHelpers
  import Cinder.ConfigCase, only: [put_env: 2]

  alias Cinder.Download.PathMapping
  alias Cinder.Library.BookArchive
  alias Cinder.Library.BookArchive.Zip
  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.PathPolicy
  alias Cinder.Subtitles.SidecarTransaction.AtomicFile

  @moduletag :tmp_dir

  # A call meant to finish gets a deadline a loaded CI runner cannot miss (docs/agents/testing.md).
  @answer_ms 10_000

  # `Disk.moviehash_data/1` reads a 64 KiB head and tail, and refuses a file under twice that.
  @moviehash_size 2 * 65_536

  # A missing tree, an existing directory, a file, and a path below that file.
  @mkdir_paths ["new/nested/dir", "existing", "file", "file/below"]

  test "dir?/1 answers for a directory, a file and a missing path while the VM file server " <>
         "is blocked",
       %{tmp_dir: tmp} do
    file = Path.join(tmp, "feature.mkv")
    File.write!(file, "video")
    paths = [tmp, file, Path.join(tmp, "missing")]
    # Loads every module dir?/1 calls, so the blocked calls below load no code.
    assert Enum.map(paths, &Disk.dir?/1) == [true, false, false]

    assert yield_while_file_server_blocked(fn -> Enum.map(paths, &Disk.dir?/1) end) ==
             {:ok, [true, false, false]}
  end

  test "open_bound/2 binds a file outside the library roots while the VM file server is " <>
         "blocked",
       %{tmp_dir: tmp} do
    file = Path.join(tmp, "feature.mkv")
    File.write!(file, "video")
    stat = File.stat!(file)
    identity = {stat.major_device, stat.minor_device, stat.inode}

    open_and_close = fn ->
      with {:ok, bound} <- Disk.open_bound(file, [:read, :raw, :binary]) do
        {Disk.close_bound(bound), bound.identity}
      end
    end

    assert open_and_close.() == {:ok, identity}
    assert yield_while_file_server_blocked(open_and_close, @answer_ms) == {:ok, {:ok, identity}}
  end

  test "moviehash_data/1 hashes a file outside the library roots, and refuses a small one, " <>
         "while the VM file server is blocked",
       %{tmp_dir: tmp} do
    video = Path.join(tmp, "feature.mkv")
    head = :binary.copy("h", 65_536)
    tail = :binary.copy("t", 65_536)
    File.write!(video, [head, "middle", tail])
    small = Path.join(tmp, "small.mkv")
    File.write!(small, :binary.copy("s", @moviehash_size - 1))
    hash_both = fn -> {Disk.moviehash_data(video), Disk.moviehash_data(small)} end
    expected = {{:ok, {@moviehash_size + 6, head, tail}}, :too_small}

    assert hash_both.() == expected
    assert yield_while_file_server_blocked(hash_both, @answer_ms) == {:ok, expected}
  end

  test "read/1 reads a file outside the library roots, and reports a missing one, while the " <>
         "VM file server is blocked",
       %{tmp_dir: tmp} do
    file = Path.join(tmp, "feature.en.srt")
    File.write!(file, "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
    read_both = fn -> {Disk.read(file), Disk.read(Path.join(tmp, "missing.srt"))} end
    expected = {{:ok, "1\n00:00:01,000 --> 00:00:02,000\nHello\n"}, {:error, :enoent}}

    assert read_both.() == expected
    assert yield_while_file_server_blocked(read_both, @answer_ms) == {:ok, expected}
  end

  test "PathMapping.validate_local_prefix/2 accepts a readable directory and refuses a missing " <>
         "one and a file while the VM file server is blocked",
       %{tmp_dir: tmp} do
    missing = Path.join(tmp, "missing")
    file = Path.join(tmp, "feature.mkv")
    File.write!(file, "video")

    validate_each = fn ->
      Enum.map([tmp, missing, file], &PathMapping.validate_local_prefix("/downloads", &1))
    end

    expected = [
      :ok,
      {:error, {:path_mapping_local_prefix_unreadable, missing}},
      {:error, {:path_mapping_local_prefix_unreadable, file}}
    ]

    assert validate_each.() == expected
    assert yield_while_file_server_blocked(validate_each, @answer_ms) == {:ok, expected}
  end

  describe "outside the library roots, while the VM file server is blocked" do
    test "write/2 creates a file and replaces one", %{tmp_dir: tmp} do
      write_both = fn dir ->
        {Disk.write(Path.join(dir, "new.srt"), "new"),
         Disk.write(Path.join(dir, "old.srt"), "replaced")}
      end

      {warm, blocked, dir} =
        run_blocked(tmp, &File.write!(Path.join(&1, "old.srt"), "old"), write_both)

      assert warm == {:ok, :ok}
      assert blocked == {:ok, {:ok, :ok}}
      assert File.read!(Path.join(dir, "new.srt")) == "new"
      assert File.read!(Path.join(dir, "old.srt")) == "replaced"
    end

    test "chmod/2 changes a file's mode and reports a missing one", %{tmp_dir: tmp} do
      fixture = fn dir ->
        File.write!(Path.join(dir, "feature.en.srt"), "subtitle")
        File.chmod!(Path.join(dir, "feature.en.srt"), 0o600)
      end

      chmod_both = fn dir ->
        {Disk.chmod(Path.join(dir, "feature.en.srt"), 0o644),
         Disk.chmod(Path.join(dir, "missing.srt"), 0o644)}
      end

      {warm, blocked, dir} = run_blocked(tmp, fixture, chmod_both)

      assert warm == {:ok, {:error, :enoent}}
      assert blocked == {:ok, {:ok, {:error, :enoent}}}
      assert mode(Path.join(dir, "feature.en.srt")) == 0o644
    end

    test "mkdir_p/1 creates missing parents, accepts an existing directory and refuses a file",
         %{tmp_dir: tmp} do
      fixture = fn dir ->
        File.mkdir_p!(Path.join(dir, "existing"))
        File.write!(Path.join(dir, "file"), "x")
      end

      mkdir_each = fn dir ->
        Enum.map(@mkdir_paths, &Disk.mkdir_p(Path.join(dir, &1)))
      end

      expected = [:ok, :ok, {:error, :enotdir}, {:error, :enotdir}]
      {warm, blocked, dir} = run_blocked(tmp, fixture, mkdir_each)

      assert warm == expected
      assert blocked == {:ok, expected}
      assert File.dir?(Path.join(dir, "new/nested/dir"))

      assert oracle(tmp, fixture, fn dir ->
               Enum.map(@mkdir_paths, &File.mkdir_p(Path.join(dir, &1)))
             end) == expected
    end

    test "mkdir_exclusive/2 creates a directory with its mode and refuses an existing one",
         %{tmp_dir: tmp} do
      mkdir_both = fn dir ->
        {Disk.mkdir_exclusive(Path.join(dir, "workspace"), 0o750),
         Disk.mkdir_exclusive(Path.join(dir, "existing"), 0o750)}
      end

      {warm, blocked, dir} = run_blocked(tmp, &File.mkdir!(Path.join(&1, "existing")), mkdir_both)

      assert warm == {:ok, {:error, :eexist}}
      assert blocked == {:ok, {:ok, {:error, :eexist}}}
      assert mode(Path.join(dir, "workspace")) == 0o750
    end

    test "rm/1 removes a file and reports a missing one", %{tmp_dir: tmp} do
      rm_both = fn dir ->
        {Disk.rm(Path.join(dir, "old.srt")), Disk.rm(Path.join(dir, "missing"))}
      end

      {warm, blocked, dir} =
        run_blocked(tmp, &File.write!(Path.join(&1, "old.srt"), "old"), rm_both)

      assert warm == {:ok, {:error, :enoent}}
      assert blocked == {:ok, {:ok, {:error, :enoent}}}
      refute File.exists?(Path.join(dir, "old.srt"))
    end

    test "rmdir/1 removes an empty directory and refuses a full one", %{tmp_dir: tmp} do
      fixture = fn dir ->
        File.mkdir!(Path.join(dir, "empty"))
        File.mkdir!(Path.join(dir, "full"))
        File.write!(Path.join(dir, "full/file"), "x")
      end

      rmdir_both = fn dir ->
        {Disk.rmdir(Path.join(dir, "empty")), Disk.rmdir(Path.join(dir, "full"))}
      end

      {warm, blocked, dir} = run_blocked(tmp, fixture, rmdir_both)

      assert warm == {:ok, {:error, :eexist}}
      assert blocked == {:ok, {:ok, {:error, :eexist}}}
      refute File.exists?(Path.join(dir, "empty"))
    end

    test "rm_rf/1 removes a tree, ignores a missing path and removes a symlink without following it",
         %{tmp_dir: tmp} do
      fixture = fn dir ->
        File.mkdir_p!(Path.join(dir, "tree/sub"))
        File.write!(Path.join(dir, "tree/a"), "a")
        File.write!(Path.join(dir, "tree/sub/b"), "b")
        File.mkdir_p!(Path.join(dir, "elsewhere"))
        File.write!(Path.join(dir, "elsewhere/kept"), "kept")
        File.ln_s!(Path.join(dir, "elsewhere"), Path.join(dir, "link"))
      end

      remove_each = fn dir -> Enum.map(["tree", "missing", "link"], &rm_rf(dir, &1)) end
      expected = [{:ok, ["tree", "tree/a", "tree/sub", "tree/sub/b"]}, {:ok, []}, {:ok, ["link"]}]
      {warm, blocked, dir} = run_blocked(tmp, fixture, remove_each)

      assert warm == expected
      assert blocked == {:ok, expected}
      refute File.exists?(Path.join(dir, "tree"))
      assert {:error, :enoent} = File.lstat(Path.join(dir, "link"))
      assert File.read!(Path.join(dir, "elsewhere/kept")) == "kept"

      assert oracle(tmp, fixture, fn dir ->
               Enum.map(["tree", "missing", "link"], fn path ->
                 with {:ok, removed} <- File.rm_rf(Path.join(dir, path)),
                      do: {:ok, removed |> Enum.map(&Path.relative_to(&1, dir)) |> Enum.sort()}
               end)
             end) == expected
    end

    test "ln/2 hard-links a file and refuses an existing destination", %{tmp_dir: tmp} do
      fixture = fn dir ->
        File.write!(Path.join(dir, "source"), "video")
        File.write!(Path.join(dir, "taken"), "other")
      end

      ln_both = fn dir ->
        {Disk.ln(Path.join(dir, "source"), Path.join(dir, "link")),
         Disk.ln(Path.join(dir, "source"), Path.join(dir, "taken"))}
      end

      {warm, blocked, dir} = run_blocked(tmp, fixture, ln_both)

      assert warm == {:ok, {:error, :eexist}}
      assert blocked == {:ok, {:ok, {:error, :eexist}}}

      assert File.stat!(Path.join(dir, "link")).inode ==
               File.stat!(Path.join(dir, "source")).inode
    end

    test "cp/2 copies onto a missing destination and replaces an existing one, mode included",
         %{tmp_dir: tmp} do
      fixture = fn dir ->
        File.write!(Path.join(dir, "source"), "fresh")
        File.chmod!(Path.join(dir, "source"), 0o640)
        File.write!(Path.join(dir, "existing"), "stale content")
        File.chmod!(Path.join(dir, "existing"), 0o600)
      end

      copy_each = fn dir ->
        Enum.map(
          ["new", "existing", "source"],
          &Disk.cp(Path.join(dir, "source"), Path.join(dir, &1))
        )
      end

      {warm, blocked, dir} = run_blocked(tmp, fixture, copy_each)

      assert warm == [:ok, :ok, :ok]
      assert blocked == {:ok, [:ok, :ok, :ok]}

      for name <- ["new", "existing", "source"] do
        assert File.read!(Path.join(dir, name)) == "fresh"
        assert mode(Path.join(dir, name)) == 0o640
      end

      oracle_dir =
        oracle(tmp, fixture, fn dir ->
          Enum.each(
            ["new", "existing", "source"],
            &(:ok = File.cp(Path.join(dir, "source"), Path.join(dir, &1)))
          )

          dir
        end)

      for name <- ["new", "existing", "source"] do
        assert File.stat!(Path.join(oracle_dir, name)).mode ==
                 File.stat!(Path.join(dir, name)).mode
      end
    end

    test "rename/2 moves a file and reports a missing source", %{tmp_dir: tmp} do
      rename_both = fn dir ->
        {Disk.rename(Path.join(dir, "staged"), Path.join(dir, "final")),
         Disk.rename(Path.join(dir, "missing"), Path.join(dir, "other"))}
      end

      {warm, blocked, dir} =
        run_blocked(tmp, &File.write!(Path.join(&1, "staged"), "video"), rename_both)

      assert warm == {:ok, {:error, :enoent}}
      assert blocked == {:ok, {:ok, {:error, :enoent}}}
      assert File.read!(Path.join(dir, "final")) == "video"
    end

    test "rename_exclusive/2 moves a file and refuses an existing destination", %{tmp_dir: tmp} do
      fixture = fn dir ->
        File.write!(Path.join(dir, "staged"), "video")
        File.write!(Path.join(dir, "other"), "other")
        File.write!(Path.join(dir, "taken"), "taken")
      end

      rename_both = fn dir ->
        {Disk.rename_exclusive(Path.join(dir, "staged"), Path.join(dir, "final")),
         Disk.rename_exclusive(Path.join(dir, "other"), Path.join(dir, "taken"))}
      end

      {warm, blocked, dir} = run_blocked(tmp, fixture, rename_both)

      assert warm == {:ok, {:error, :eexist}}
      assert blocked == {:ok, {:ok, {:error, :eexist}}}
      assert File.read!(Path.join(dir, "final")) == "video"
      refute File.exists?(Path.join(dir, "staged"))
      assert File.read!(Path.join(dir, "other")) == "other"
    end

    test "exchange/2 swaps two files", %{tmp_dir: tmp} do
      exchanging_mv!(tmp)

      fixture = fn dir ->
        File.write!(Path.join(dir, "left"), "left")
        File.write!(Path.join(dir, "right"), "right")
      end

      exchange = fn dir -> Disk.exchange(Path.join(dir, "left"), Path.join(dir, "right")) end
      {warm, blocked, dir} = run_blocked(tmp, fixture, exchange)

      assert warm == :ok
      assert blocked == {:ok, :ok}
      assert File.read!(Path.join(dir, "left")) == "right"
      assert File.read!(Path.join(dir, "right")) == "left"
    end

    test "create_bound/2, write_bound/2, discard_bound/1 and close_bound/1 run on one bound",
         %{tmp_dir: tmp} do
      bound_steps = fn dir ->
        path = Path.join(dir, "staged.srt")

        with {:ok, bound} <- Disk.create_bound(path, "first") do
          written = Disk.write_bound(bound, "second")
          after_write = File.read(path, [:raw])
          discarded = Disk.discard_bound(bound)
          after_discard = File.read(path, [:raw])
          {written, after_write, discarded, after_discard, Disk.close_bound(bound)}
        end
      end

      expected = {:ok, {:ok, "second"}, :ok, {:ok, ""}, :ok}
      {warm, blocked, _dir} = run_blocked(tmp, fn _dir -> :ok end, bound_steps)

      assert warm == expected
      assert blocked == {:ok, expected}
    end
  end

  describe "under a library root, while the VM file server is blocked" do
    setup %{tmp_dir: tmp} do
      root = Path.join(tmp, "library")
      File.mkdir_p!(root)
      put_env(:movies_library_path, root)
      %{root: root}
    end

    test "read/1, write/2 and chmod/2 answer through the rooted helper", %{root: root} do
      fixture = fn dir ->
        File.write!(Path.join(dir, "feature.en.srt"), "subtitle")
        File.chmod!(Path.join(dir, "feature.en.srt"), 0o600)
      end

      rooted_calls = fn dir ->
        path = Path.join(dir, "feature.en.srt")
        {Disk.read(path), Disk.write(path, "rewritten"), Disk.chmod(path, 0o644)}
      end

      {warm, blocked, dir} = run_blocked(root, fixture, rooted_calls)

      assert warm == {{:ok, "subtitle"}, :ok, :ok}
      assert blocked == {:ok, {{:ok, "subtitle"}, :ok, :ok}}
      assert File.read!(Path.join(dir, "feature.en.srt")) == "rewritten"
      assert mode(Path.join(dir, "feature.en.srt")) == 0o644
    end

    # The staged file's chmod to 0o644 runs on its descriptor path before the publication.
    test "AtomicFile publishes a new sidecar and replaces one", %{root: root} do
      use_disk()

      fixture = fn dir ->
        File.write!(Path.join(dir, "Movie.fr.srt"), "old")
        File.chmod!(Path.join(dir, "Movie.fr.srt"), 0o600)
      end

      publish_both = fn dir ->
        {AtomicFile.swap(Path.join(dir, "Movie.en.srt"), :absent, "new"),
         AtomicFile.write(Path.join(dir, "Movie.fr.srt"), "replaced", "old")}
      end

      {warm, blocked, dir} = run_blocked(root, fixture, publish_both)

      assert warm == {:ok, :ok}
      assert blocked == {:ok, {:ok, :ok}}
      assert File.read!(Path.join(dir, "Movie.en.srt")) == "new"
      assert File.read!(Path.join(dir, "Movie.fr.srt")) == "replaced"
      assert mode(Path.join(dir, "Movie.en.srt")) == 0o644
      assert mode(Path.join(dir, "Movie.fr.srt")) == 0o644
    end
  end

  describe "book archives in an import root, while the VM file server is blocked" do
    setup %{tmp_dir: tmp} do
      downloads = Path.join(tmp, "downloads")
      File.mkdir_p!(downloads)
      put_env(:import_roots, [downloads])
      put_env(:explicit_import_roots, [downloads])
      use_disk()
      %{downloads: downloads}
    end

    test "BookArchive.extract_and_resolve/2 resets the scratch directory, and removes it when " <>
           "the resolver refuses",
         %{downloads: downloads} do
      fixture = fn dir ->
        File.mkdir_p!(Path.join(dir, ".cinder-extract/old"))
        File.write!(Path.join(dir, ".cinder-extract/old/stale.epub"), "stale")
        zip!(Path.join(dir, "book.zip"), [{~c"book.epub", "epub"}])
        zip!(Path.join(dir, "refused/book.zip"), [{~c"book.epub", "epub"}])
      end

      extract_both = fn dir ->
        {BookArchive.extract_and_resolve(Path.join(dir, "book.zip"), &{:ok, &1}),
         BookArchive.extract_and_resolve(Path.join(dir, "refused/book.zip"), fn _scratch ->
           {:error, :no_book_file}
         end)}
      end

      {warm, blocked, dir} = run_blocked(downloads, fixture, extract_both)
      scratch = Path.join(dir, ".cinder-extract")

      assert {{:ok, _warm_scratch}, {:error, :no_book_file}} = warm
      assert blocked == {:ok, {{:ok, scratch}, {:error, :no_book_file}}}
      assert File.ls!(scratch) == ["book.epub"]
      refute File.exists?(Path.join(dir, "refused/.cinder-extract"))
    end

    test "Zip.extract/2 makes an entry's directories, and removes an entry whose CRC-32 " <>
           "does not match",
         %{downloads: downloads} do
      fixture = fn dir ->
        File.mkdir_p!(Path.join(dir, "src/sub"))
        File.write!(Path.join(dir, "src/sub/book.epub"), "epub")
        {:ok, _} = :zip.create(~c"#{dir}/tree.zip", [~c"sub"], cwd: ~c"#{dir}/src")
        zip!(Path.join(dir, "corrupt.zip"), [{~c"book.epub", "epub bytes"}])
        corrupt_stored_data!(Path.join(dir, "corrupt.zip"))
      end

      extract_both = fn dir ->
        {Zip.extract(Path.join(dir, "tree.zip"), Path.join(dir, "tree")),
         Zip.extract(Path.join(dir, "corrupt.zip"), Path.join(dir, "corrupt"))}
      end

      {warm, blocked, dir} = run_blocked(downloads, fixture, extract_both)

      assert warm == {:ok, {:error, :archive_corrupt}}
      assert blocked == {:ok, {:ok, {:error, :archive_corrupt}}}
      assert File.read!(Path.join(dir, "tree/sub/book.epub")) == "epub"
      assert File.ls!(Path.join(dir, "corrupt")) == []
    end
  end

  # Puts an `mv` at the front of `PATH` that swaps the two paths `Disk.exchange/2` passes it after
  # its three options. The CI image's coreutils `mv` has no `--exchange`.
  defp exchanging_mv!(tmp) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "swap.py"), """
    import os, sys
    a, b = sys.argv[1:]
    os.rename(a, a + ".swap")
    os.rename(b, a)
    os.rename(a + ".swap", b)
    """)

    File.write!(Path.join(bin, "mv"), """
    #!/bin/sh
    exec python3 "$(dirname "$0")/swap.py" "$4" "$5"
    """)

    File.chmod!(Path.join(bin, "mv"), 0o755)
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)
    System.put_env("PATH", bin <> ":" <> path)
  end

  # AtomicFile and BookArchive reach the filesystem through the configured impl, a Mox mock in
  # the test env, and check paths through the configured policy.
  defp use_disk do
    put_env(:filesystem, Disk)
    put_env(:path_policy, PathPolicy)
  end

  # Stores each entry uncompressed, so a flipped data byte reaches the CRC-32 check.
  defp zip!(archive, entries) do
    File.mkdir_p!(Path.dirname(archive))
    {:ok, _} = :zip.create(String.to_charlist(archive), entries, compress: [])
  end

  # Flips the first data byte of the archive's first entry.
  defp corrupt_stored_data!(archive) do
    <<header::binary-size(26), name_len::little-16, extra_len::little-16, rest::binary>> =
      File.read!(archive)

    names_size = name_len + extra_len
    <<names::binary-size(^names_size), byte, tail::binary>> = rest

    File.write!(
      archive,
      <<header::binary, name_len::little-16, extra_len::little-16, names::binary,
        Bitwise.bxor(byte, 0xFF), tail::binary>>
    )
  end

  # Builds `fixture` in a warm-up directory and in a second one under `parent`. `call` runs on the
  # warm-up copy first, so the blocked run loads no code, then on the second copy with the VM file
  # server suspended. Returns both answers and the second copy's directory.
  defp run_blocked(parent, fixture, call) do
    [warm, blocked] = Enum.map(["warm", "blocked"], &fixture_dir(parent, &1, fixture))
    {call.(warm), yield_while_file_server_blocked(fn -> call.(blocked) end, @answer_ms), blocked}
  end

  # What Elixir's own `File` call answers on a third copy of the fixture, the contract the Disk
  # call keeps.
  defp oracle(parent, fixture, call), do: call.(fixture_dir(parent, "oracle", fixture))

  defp fixture_dir(parent, name, fixture) do
    dir = Path.join(parent, name)
    File.mkdir_p!(dir)
    fixture.(dir)
    dir
  end

  defp rm_rf(dir, path) do
    with {:ok, removed} <- Disk.rm_rf(Path.join(dir, path)),
         do: {:ok, removed |> Enum.map(&Path.relative_to(&1, dir)) |> Enum.sort()}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
