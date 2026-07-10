defmodule Cinder.Library.Filesystem.DiskTest do
  # The one place real disk is allowed: ExUnit's :tmp_dir, auto-created and
  # cleaned per test. Everything else mocks the Filesystem behaviour.
  use ExUnit.Case, async: true

  alias Cinder.Library.Filesystem.Disk

  @tag :tmp_dir
  test "dir?/find_files/mkdir_p/ln operate on real files", %{tmp_dir: tmp} do
    refute Disk.dir?(Path.join(tmp, "nope.mkv"))
    assert Disk.dir?(tmp)

    release = Path.join(tmp, "release")
    File.mkdir_p!(Path.join(release, "Sample"))
    File.write!(Path.join(release, "feature.mkv"), String.duplicate("x", 100))
    File.write!(Path.join(release, "Sample/sample.mkv"), "x")

    assert {:ok, files} = Disk.find_files(release)
    paths = Enum.map(files, fn {p, _size} -> p end)
    assert Path.join(release, "feature.mkv") in paths
    assert Path.join(release, "Sample/sample.mkv") in paths
    assert {_, 100} = Enum.find(files, fn {p, _} -> p == Path.join(release, "feature.mkv") end)

    lib = Path.join(tmp, "lib/Movie (2020)")
    assert :ok = Disk.mkdir_p(lib)
    assert Disk.dir?(lib)

    src = Path.join(release, "feature.mkv")
    dest = Path.join(lib, "Movie (2020).mkv")
    assert :ok = Disk.ln(src, dest)
    assert File.read!(dest) == String.duplicate("x", 100)
    # Hardlink shares the inode; a second link to the same dest is :eexist.
    assert {:error, :eexist} = Disk.ln(src, dest)
  end

  test "find_files/1 propagates an unreadable root as {:error, _}, not an empty listing" do
    # Regression: {:ok, []} on EACCES/ENOENT read downstream as "release has no video
    # file" — a permanent park + blocklist for what is a transient filesystem failure.
    assert {:error, :enoent} =
             Disk.find_files("/nonexistent/cinder-#{System.unique_integer([:positive])}")
  end

  @tag :tmp_dir
  test "find_files/1 propagates an unreadable NESTED directory too", %{tmp_dir: tmp} do
    # The common torrent layout is a readable root whose single video-bearing subfolder is
    # unreadable (the documented PUID mismatch); {:ok, []} there is the same park+blocklist
    # misclassification one level down.
    sub = Path.join(tmp, "Show.S01.1080p")
    File.mkdir_p!(sub)
    File.chmod!(sub, 0o000)
    on_exit(fn -> File.chmod(sub, 0o755) end)

    # Root can list a 000 directory; the assertion only holds when the OS actually denies.
    if match?({:error, :eacces}, File.ls(sub)) do
      assert {:error, :eacces} = Disk.find_files(tmp)
    end
  end

  @tag :tmp_dir
  test "find_files/1 includes dotfiles so the stale-temp sweep can find leftovers", %{
    tmp_dir: tmp
  } do
    File.write!(Path.join(tmp, "feature.mkv"), "x")
    # A `.cinder-tmp-*` partial left by a crash mid-copy — sweep_temps must be able to see it.
    File.write!(Path.join(tmp, ".cinder-tmp-1"), "partial")

    assert {:ok, files} = Disk.find_files(tmp)
    paths = Enum.map(files, fn {p, _size} -> p end)
    assert Path.join(tmp, "feature.mkv") in paths
    assert Path.join(tmp, ".cinder-tmp-1") in paths
  end

  @tag :tmp_dir
  test "find_files/1 finds files under a dir whose name has glob metacharacters", %{tmp_dir: tmp} do
    # cinder names libraries `Title (Year) {tmdb-N}`; `{}` is Path.wildcard brace-expansion, so
    # globbing the literal base path silently matches nothing. find_files must not glob the base.
    lib = Path.join(tmp, "Cowboy Bebop (1998) {tmdb-30991}/Season 01")
    File.mkdir_p!(lib)
    video = Path.join(lib, "Cowboy Bebop (1998) {tmdb-30991} - S01E07.mkv")
    sub = Path.join(lib, "Cowboy Bebop (1998) {tmdb-30991} - S01E07.en.srt")
    File.write!(video, "x")
    File.write!(sub, "subtitle")

    assert {:ok, files} = Disk.find_files(lib)
    paths = Enum.map(files, fn {p, _size} -> p end)
    assert video in paths
    assert sub in paths
  end

  @tag :tmp_dir
  test "cp/2 byte-copies content into an independent inode (not a hardlink)", %{tmp_dir: tmp} do
    src = Path.join(tmp, "src.mkv")
    dst = Path.join(tmp, "dst.mkv")
    File.write!(src, "payload")

    assert :ok = Disk.cp(src, dst)
    assert File.read!(dst) == "payload"

    # Unlike ln/2 (a hardlink), a copy is a distinct inode: removing the source leaves the copy intact.
    File.rm!(src)
    assert File.read!(dst) == "payload"
  end

  test "rename/2 atomically replaces an existing dest" do
    dir = Path.join(System.tmp_dir!(), "cinder-rename-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    src = Path.join(dir, "src")
    dst = Path.join(dir, "dst")
    File.write!(src, "new")
    File.write!(dst, "old")
    assert :ok = Disk.rename(src, dst)
    assert File.read!(dst) == "new"
    refute File.exists?(src)
  end

  test "moviehash_data/1 returns {size, head, tail} for a >=128KiB file and :too_small below it" do
    dir = Path.join(System.tmp_dir!(), "cinder-moviehash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Non-uniform fixture (head all 0x00, tail all 0xFF) so the content asserts pin BOTH read
    # offsets: a tail read at the wrong offset would return 0x00 bytes and fail. An all-zero file
    # would make head == tail and leave the tail offset unproven.
    big = Path.join(dir, "big.mkv")
    File.write!(big, :binary.copy(<<0>>, 200_000 - 65_536) <> :binary.copy(<<0xFF>>, 65_536))
    assert {:ok, {200_000, head, tail}} = Disk.moviehash_data(big)
    assert head == :binary.copy(<<0>>, 65_536)
    assert tail == :binary.copy(<<0xFF>>, 65_536)

    small = Path.join(dir, "small.mkv")
    File.write!(small, :binary.copy(<<0>>, 1000))
    assert :too_small = Disk.moviehash_data(small)

    assert {:error, _} = Disk.moviehash_data(Path.join(dir, "nope.mkv"))
  end

  test "write/2 writes bytes to disk" do
    dir = Path.join(System.tmp_dir!(), "cinder-fs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "out.srt")

    assert :ok = Disk.write(path, "1\n00:00:01,000 --> 00:00:02,000\nhi\n")
    assert File.read!(path) == "1\n00:00:01,000 --> 00:00:02,000\nhi\n"
  end
end
