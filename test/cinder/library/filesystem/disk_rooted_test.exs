defmodule Cinder.Library.Filesystem.DiskRootedTest do
  use Cinder.DataCase, async: false

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
  test "rooted chmod rejects an ancestor replaced by an outside symlink", %{root: root, tmp: tmp} do
    {path, moved, outside} = prepare_swap(root, tmp, "subtitle.srt", "inside", "outside")
    outside_path = Path.join(outside, Path.basename(path))
    File.chmod!(path, 0o600)
    File.chmod!(outside_path, 0o600)
    barrier!(:chmod, path)

    task = Task.async(fn -> BarrierFilesystem.chmod(path, 0o644) end)
    assert_receive {:filesystem_barrier, pid, ref, :chmod, ^path}
    swap_parent!(path, moved, outside)
    send(pid, {ref, :continue})

    assert {:error, reason} = Task.await(task)
    assert reason in [:eloop, :enotdir]
    assert mode(outside_path) == 0o600
    assert mode(Path.join(moved, Path.basename(path))) == 0o600
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
  test "a rooted hold reporting a committed effect stays committed", %{root: root, tmp: tmp} do
    helper = Path.join(tmp, "post_effect_hold.py")

    File.write!(
      helper,
      ~S|import json
print(json.dumps({"error": {"operation": "hold", "phase": "post_effect", "reason": "EEXIST"}}))
|
    )

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)

    assert {:error, {:effect_committed, "hold", %{"reason" => "EEXIST"}}} =
             Disk.create_bound(Path.join(root, "backup.srt"), "managed")
  end

  @tag :tmp_dir
  test "a rename completed before parent sync failed is still successful", %{root: root, tmp: tmp} do
    helper = Path.join(tmp, "post_effect_rename.py")

    File.write!(
      helper,
      """
      import json
      import os
      import sys

      _, operation, source_root, source, dest_root, dest = sys.argv
      os.rename(os.path.join(source_root, source), os.path.join(dest_root, dest))
      print(json.dumps({"error": {"operation": operation, "phase": "post_effect", "reason": "EIO"}}))
      """
    )

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)
    source = Path.join(root, "source.srt")
    dest = Path.join(root, "dest.srt")
    File.write!(source, "subtitle")

    assert :ok = Disk.rename(source, dest)
    refute File.exists?(source)
    assert File.read!(dest) == "subtitle"
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

  @tag :tmp_dir
  test "duplicate zero-byte tombstones proven owned are reconciled to the owned container", %{
    root: root,
    tmp: tmp
  } do
    %{path: path, owned: owned, duplicate: duplicate, identity: identity} =
      duplicate_tombstones!(root, tmp)

    assert :ok = Disk.reconcile_duplicate_containers(path, identity)
    assert File.exists?(owned)
    refute File.exists?(duplicate)
    assert Path.wildcard(Path.join(Path.dirname(duplicate), ".*cinder-duplicate-*")) == []
  end

  @tag :tmp_dir
  test "a nonzero duplicate container is refused and left untouched", %{root: root, tmp: tmp} do
    %{path: path, owned: owned, duplicate: duplicate, identity: identity} =
      duplicate_tombstones!(root, tmp)

    File.write!(duplicate, "unrelated payload")

    assert {:error, :enotempty} = Disk.reconcile_duplicate_containers(path, identity)
    assert File.read!(duplicate) == "unrelated payload"
    assert File.exists?(owned)
  end

  @tag :tmp_dir
  test "duplicates that do not include the owned identity are refused", %{root: root, tmp: tmp} do
    %{path: path, owned: owned, duplicate: duplicate} = duplicate_tombstones!(root, tmp)

    assert {:error, :estale} = Disk.reconcile_duplicate_containers(path, {38, 0, 123_456})
    assert File.exists?(owned)
    assert File.exists?(duplicate)
  end

  @tag :tmp_dir
  test "a single-branch logical path is refused as nothing to reconcile", %{root: root, tmp: tmp} do
    %{path: path, owned: owned, duplicate: duplicate, identity: identity} =
      duplicate_tombstones!(root, tmp)

    File.rm!(duplicate)

    assert {:error, :einval} = Disk.reconcile_duplicate_containers(path, identity)
    assert File.exists?(owned)
  end

  @tag :tmp_dir
  test "duplicate allpaths entries are refused before any removal", %{root: root, tmp: tmp} do
    %{path: path, owned: owned, duplicate: duplicate, identity: identity} =
      duplicate_tombstones!(root, tmp, repeat_duplicate: true)

    assert {:error, :einval} = Disk.reconcile_duplicate_containers(path, identity)
    assert File.exists?(owned)
    assert File.exists?(duplicate)
  end

  # A mutation completed after quarantine but before the final proof must be
  # detected and restored. External writers that append after the proof require
  # cooperative locking and are outside this helper's guarantee.
  @tag :tmp_dir
  test "a duplicate filled after quarantine is restored with its bytes intact", %{
    root: root,
    tmp: tmp
  } do
    %{path: path, owned: owned, duplicate: duplicate, identity: identity} =
      duplicate_tombstones!(root, tmp, fill_after_quarantine: "RESCUED")

    assert {:error, :enotempty} = Disk.reconcile_duplicate_containers(path, identity)

    assert File.read!(duplicate) == "RESCUED"
    assert File.exists?(owned)
    assert Path.wildcard(Path.join(Path.dirname(duplicate), ".*cinder-duplicate-*")) == []
  end

  # user.mergerfs.allpaths is only authoritative on a real mergerfs mount;
  # anywhere else it is ordinary caller-writable metadata. Without the mount
  # proof, a forged xattr naming a file outside the library would delete it.
  @tag :tmp_dir
  test "a forged allpaths xattr off a mergerfs mount cannot delete anything", %{
    root: root,
    tmp: tmp
  } do
    %{path: path, owned: owned, duplicate: duplicate, identity: identity} =
      duplicate_tombstones!(root, tmp, mergerfs: false)

    outsider = Path.join(tmp, "outside-the-library")
    File.write!(outsider, "")

    assert {:error, :einval} = Disk.reconcile_duplicate_containers(path, identity)
    assert File.exists?(outsider)
    assert File.exists?(owned)
    assert File.exists?(duplicate)
  end

  @tag :tmp_dir
  test "a mergerfs logical open cannot cross into a nested mount" do
    helper = Path.expand("../../../../priv/rooted_fs.py", __DIR__)

    script = """
    import errno
    import os
    import sys

    namespace = {"__name__": "rooted_fs_test", "__file__": sys.argv[1]}
    with open(sys.argv[1], encoding="utf-8") as source:
        exec(compile(source.read(), sys.argv[1], "exec"), namespace)

    same_mount = namespace["open_mergerfs_path"]("/proc", "version")
    os.close(same_mount)

    for opener in (
        lambda: namespace["open_mergerfs_path"]("/", "proc/version"),
        lambda: namespace["open_at_root"](
            "/", "proc/version", namespace["O_PATH"], resolve=namespace["RESOLVE_NO_XDEV"]
        ),
    ):
        try:
            crossed = opener()
        except OSError as exc:
            if exc.errno != errno.EXDEV:
                raise
        else:
            os.close(crossed)
            raise RuntimeError("protected open crossed a nested mount")
    """

    assert {"", 0} = System.cmd("python3", ["-c", script, helper], stderr_to_stdout: true)
  end

  # A container reachable under a second name is not wholly ours to remove:
  # unlinking this link would leave the bytes live under the other one.
  @tag :tmp_dir
  test "a hardlinked duplicate container is refused", %{root: root, tmp: tmp} do
    %{path: path, owned: owned, duplicate: duplicate, identity: identity} =
      duplicate_tombstones!(root, tmp)

    link = Path.join(tmp, "second-name")
    File.ln!(duplicate, link)

    assert {:error, :emlink} = Disk.reconcile_duplicate_containers(path, identity)
    assert File.exists?(duplicate)
    assert File.exists?(link)
    assert File.exists?(owned)
  end

  # A real mergerfs mount is not available in the test environment, so the shim
  # forces mergerfs_mount() to true and answers user.mergerfs.allpaths for the
  # logical backup path with the two branch containers. Everything else -- the
  # zero-byte and identity proofs, the RENAME_NOREPLACE quarantine, the recheck
  # and the unlink -- is the real helper running against real files.
  defp duplicate_tombstones!(root, tmp, opts \\ []) do
    relative = "Movie/.subtitle.srt.cinder-sync-original"
    path = Path.join(root, relative)
    branch_a = Path.join(tmp, "branch-a")
    branch_b = Path.join(tmp, "branch-b")
    owned = Path.join(branch_a, relative)
    duplicate = Path.join(branch_b, relative)

    Enum.each(
      [Path.dirname(path), Path.dirname(owned), Path.dirname(duplicate)],
      &File.mkdir_p!/1
    )

    Enum.each([path, owned, duplicate], &File.write!(&1, ""))

    if Keyword.get(opts, :mergerfs, true), do: File.write!(Path.join(root, ".mergerfs"), "")

    stat = File.stat!(owned)
    identity = {stat.major_device, stat.minor_device, stat.inode}

    containers =
      if opts[:repeat_duplicate], do: [owned, duplicate, duplicate], else: [owned, duplicate]

    helper = mergerfs_shim!(tmp, containers, [branch_a, branch_b], root, opts)

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)

    %{path: path, owned: owned, duplicate: duplicate, identity: identity}
  end

  defp mergerfs_shim!(tmp, containers, branches, mountpoint, opts) do
    fill_after_quarantine = opts[:fill_after_quarantine]
    mergerfs = Keyword.get(opts, :mergerfs, true)
    helper = Path.join(tmp, "mergerfs_shim.py")
    real_helper = Path.expand("../../../../priv/rooted_fs.py", __DIR__)

    File.write!(helper, """
    import os
    import sys

    CONTAINERS = #{inspect(containers)}
    BRANCHES = #{inspect(branches)}
    REAL_HELPER = #{inspect(real_helper)}
    FILL_AFTER_QUARANTINE = #{if fill_after_quarantine, do: inspect(fill_after_quarantine), else: "None"}

    real_getxattr = os.getxattr

    def getxattr(path, name, **kwargs):
        if name == "user.mergerfs.allpaths":
            existing = [c for c in CONTAINERS if os.path.lexists(c)]
            if existing:
                return b"\\0".join(os.fsencode(c) for c in existing)
        if name in ("user.mergerfs.branches", "user.mergerfs.srcmounts"):
            if not isinstance(path, int) or os.path.basename(
                os.readlink(f"/proc/self/fd/{path}")
            ) != ".mergerfs":
                raise OSError(61, "ENODATA")
            return os.fsencode(":".join(BRANCHES))
        return real_getxattr(path, name, **kwargs)

    os.getxattr = getxattr

    # exec into a namespace we own so the helper's own functions resolve
    # mergerfs_mount through this dict; runpy would hand back a detached copy.
    namespace = {"__name__": "rooted_fs_shim", "__file__": REAL_HELPER}
    with open(REAL_HELPER, encoding="utf-8") as source:
        exec(compile(source.read(), REAL_HELPER, "exec"), namespace)

    MOUNTPOINT = #{inspect(mountpoint)} if #{if mergerfs, do: "True", else: "False"} else None
    namespace["mergerfs_mountpoint"] = lambda path: MOUNTPOINT
    namespace["mergerfs_mount"] = lambda path: MOUNTPOINT is not None

    # Simulate a writer that fills the container after the quarantine rename
    # but before the helper's final held-descriptor proof.
    if FILL_AFTER_QUARANTINE is not None:
        real_rename_noreplace = namespace["rename_noreplace"]
        renames = []

        def rename_noreplace(parent, source, destination):
            real_rename_noreplace(parent, source, destination)
            renames.append(destination)
            if len(renames) == 1:
                fd = os.open(destination, os.O_WRONLY, dir_fd=parent)
                try:
                    os.write(fd, os.fsencode(FILL_AFTER_QUARANTINE))
                finally:
                    os.close(fd)

        namespace["rename_noreplace"] = rename_noreplace

    sys.argv = [REAL_HELPER] + sys.argv[1:]
    operation = sys.argv[1] if len(sys.argv) > 1 else "unknown"

    try:
        namespace["main"]()
    except OSError as exc:
        committed = isinstance(exc, namespace["EffectCommittedError"])
        namespace["fail"](operation, "post_effect" if committed else "pre_effect", exc)
        sys.exit(1)
    """)

    helper
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

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
