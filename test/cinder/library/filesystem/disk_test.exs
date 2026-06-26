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
end
