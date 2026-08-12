defmodule Cinder.Library.Filesystem.DiskRootedTest do
  use ExUnit.Case, async: false

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.PathPolicy
  alias Cinder.Subtitles.Sync.AtomicFile
  alias Cinder.Test.BarrierFilesystem

  setup %{tmp_dir: tmp} do
    keys = [
      :filesystem,
      :path_policy,
      :filesystem_barrier,
      :rooted_filesystem_helper,
      :movies_library_path,
      :tv_library_path
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    root = Path.join(tmp, "library")
    File.mkdir_p!(root)
    Application.put_env(:cinder, :movies_library_path, root)
    Application.put_env(:cinder, :tv_library_path, Path.join(tmp, "tv"))

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    %{root: root, tmp: tmp}
  end

  @tag :tmp_dir
  test "rooted open rejects an ancestor replaced by an outside symlink", %{root: root, tmp: tmp} do
    {path, moved, outside} = prepare_swap(root, tmp, "subtitle.srt", "inside", "outside")
    barrier!(:open_bound, path)

    task = Task.async(fn -> BarrierFilesystem.open_bound(path, [:read, :raw, :binary]) end)
    assert_receive {:filesystem_barrier, pid, ref, :open_bound, ^path}
    swap_parent!(path, moved, outside)
    send(pid, {ref, :continue})

    assert {:error, :eloop} = Task.await(task)
    assert File.read!(Path.join(outside, Path.basename(path))) == "outside"
  end

  @tag :tmp_dir
  test "rooted exclusive create rejects an ancestor replaced by an outside symlink", %{
    root: root,
    tmp: tmp
  } do
    parent = Path.join(root, "Movie")
    moved = Path.join(root, "Movie.original")
    outside = Path.join(tmp, "outside")
    path = Path.join(parent, "subtitle.srt")
    File.mkdir_p!(parent)
    File.mkdir_p!(outside)
    barrier!(:create_bound, path)

    task = Task.async(fn -> BarrierFilesystem.create_bound(path, "managed") end)
    assert_receive {:filesystem_barrier, pid, ref, :create_bound, ^path}
    swap_parent!(path, moved, outside)
    send(pid, {ref, :continue})

    assert {:error, :eloop} = Task.await(task)
    refute File.exists?(Path.join(outside, Path.basename(path)))
  end

  @tag :tmp_dir
  test "rooted exchange rejects an ancestor replaced by an outside symlink", %{
    root: root,
    tmp: tmp
  } do
    parent = Path.join(root, "Movie")
    moved = Path.join(root, "Movie.original")
    outside = Path.join(tmp, "outside")
    target = Path.join(parent, "subtitle.srt")
    staged = Path.join(parent, "staged.srt")
    File.mkdir_p!(parent)
    File.mkdir_p!(outside)
    File.write!(target, "inside old")
    File.write!(staged, "inside new")
    File.write!(Path.join(outside, "subtitle.srt"), "outside old")
    File.write!(Path.join(outside, "staged.srt"), "outside new")
    barrier!(:exchange, staged)

    task = Task.async(fn -> BarrierFilesystem.exchange(staged, target) end)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, ^staged}
    swap_parent!(target, moved, outside)
    send(pid, {ref, :continue})

    assert {:error, reason} = Task.await(task)
    assert reason in [:eloop, :enotdir]
    assert File.read!(Path.join(outside, "subtitle.srt")) == "outside old"
    assert File.read!(Path.join(outside, "staged.srt")) == "outside new"
    assert File.read!(Path.join(moved, "subtitle.srt")) == "inside old"
    assert File.read!(Path.join(moved, "staged.srt")) == "inside new"
  end

  defp prepare_swap(root, tmp, basename, inside, outside_content) do
    parent = Path.join(root, "Movie")
    moved = Path.join(root, "Movie.original")
    outside = Path.join(tmp, "outside")
    path = Path.join(parent, basename)
    File.mkdir_p!(parent)
    File.mkdir_p!(outside)
    File.write!(path, inside)
    File.write!(Path.join(outside, basename), outside_content)
    {path, moved, outside}
  end

  @tag :tmp_dir
  test "atomic publication creates nothing for an out-of-root target", %{tmp_dir: tmp} do
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(outside)
    target = Path.join(outside, "subtitle.srt")
    File.write!(target, "old")
    operation_id = String.duplicate("a", 22)
    workspace = Path.join(outside, ".cinder-subtitle-sync-cas-#{operation_id}")

    Application.put_env(:cinder, :filesystem, BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, PathPolicy)
    barrier!(:mkdir_exclusive, workspace)

    task = Task.async(fn -> AtomicFile.write(target, "new", "old", operation_id) end)

    refute_receive {:filesystem_barrier, _pid, _ref, :mkdir_exclusive, ^workspace}, 100
    assert {:error, :unsafe_destination} = Task.await(task)

    assert File.read!(target) == "old"
    refute File.exists?(workspace)
  end

  @tag :tmp_dir
  test "an aborted mutating helper is conservatively classified as effect committed", %{
    root: root,
    tmp: tmp
  } do
    helper = Path.join(tmp, "abort_helper.py")
    File.write!(helper, "import os\nos._exit(70)\n")
    Application.put_env(:cinder, :rooted_filesystem_helper, helper)
    path = Path.join(root, "workspace")

    assert {:error, {:effect_committed, "mkdir", {:helper_outcome_unknown, ""}}} =
             Disk.mkdir_exclusive(path, 0o700)

    refute File.exists?(path)
  end

  @tag :tmp_dir
  test "an eexist workspace race never cleans another actor's files", %{root: root} do
    target = Path.join(root, "Movie/subtitle.srt")
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, "old")
    operation_id = String.duplicate("b", 22)
    workspace = Path.join(Path.dirname(target), ".cinder-subtitle-sync-cas-#{operation_id}")
    staged = Path.join(workspace, ".cinder-subtitle-sync-write-staged")
    Application.put_env(:cinder, :filesystem, BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, PathPolicy)
    barrier!(:mkdir_exclusive, workspace)

    task = Task.async(fn -> AtomicFile.write(target, "new", "old", operation_id) end)
    assert_receive {:filesystem_barrier, pid, ref, :mkdir_exclusive, ^workspace}
    File.mkdir!(workspace)
    File.write!(staged, "external")
    send(pid, {ref, :continue})

    assert {:error, :pending_workspace_mismatch} = Task.await(task)
    assert File.read!(target) == "old"
    assert File.read!(staged) == "external"
  end

  @tag :tmp_dir
  test "root opening rejects a configured-root ancestor replaced by a symlink", %{tmp: tmp} do
    approved_parent = Path.join(tmp, "approved")
    root = Path.join(approved_parent, "library")
    Application.put_env(:cinder, :movies_library_path, root)
    path = Path.join(root, "Movie/subtitle.srt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "inside")
    outside_parent = Path.join(tmp, "outside-parent")
    outside_path = Path.join(outside_parent, "library/Movie/subtitle.srt")
    File.mkdir_p!(Path.dirname(outside_path))
    File.write!(outside_path, "outside")
    barrier!(:open_bound, path)

    task = Task.async(fn -> BarrierFilesystem.open_bound(path, [:read, :raw, :binary]) end)
    assert_receive {:filesystem_barrier, pid, ref, :open_bound, ^path}
    moved_parent = approved_parent <> "-moved"
    File.rename!(approved_parent, moved_parent)
    File.ln_s!(outside_parent, approved_parent)
    send(pid, {ref, :continue})

    assert {:error, reason} = Task.await(task)
    assert reason in [:eloop, :enotdir]
    assert File.read!(outside_path) == "outside"
  end

  defp barrier!(operation, contains) do
    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: operation,
      phase: :before,
      contains: contains,
      once: true
    })
  end

  defp swap_parent!(path, moved, outside) do
    parent = Path.dirname(path)
    File.rename!(parent, moved)
    File.ln_s!(outside, parent)
  end
end
