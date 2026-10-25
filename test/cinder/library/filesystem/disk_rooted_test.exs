defmodule Cinder.Library.Filesystem.DiskRootedTest do
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Library.PathPolicy
  alias Cinder.Subtitles.{Manifest, SidecarTransaction}
  alias Cinder.Subtitles.SidecarTransaction.AtomicFile
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

  @tag :tmp_dir
  test "exchange returns an error when mv cannot execute", %{tmp_dir: tmp} do
    source = Path.join(tmp, "exchange-source")
    destination = Path.join(tmp, "exchange-destination")
    File.write!(source, "source")
    File.write!(destination, "destination")
    path = System.get_env("PATH")
    System.put_env("PATH", "")
    on_exit(fn -> System.put_env("PATH", path) end)

    assert {:error, {:exchange_exec_failed, _reason}} = Disk.exchange(source, destination)

    assert File.read!(source) == "source"
    assert File.read!(destination) == "destination"
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

  # Issue #758: the fetch side publishes a sidecar that may not exist yet without replacing one
  # that appeared meanwhile.
  describe "rename_exclusive/2" do
    @describetag :tmp_dir

    test "moves a file onto a name nothing holds", %{root: root} do
      {source, dest} = exclusive_rename_paths!(root)

      assert :ok = Disk.rename_exclusive(source, dest)
      refute File.exists?(source)
      assert File.read!(dest) == "fetched"
    end

    test "never replaces a destination that exists", %{root: root} do
      {source, dest} = exclusive_rename_paths!(root)
      File.write!(dest, "external")

      assert {:error, :eexist} = Disk.rename_exclusive(source, dest)
      assert File.read!(source) == "fetched"
      assert File.read!(dest) == "external"
    end

    test "never replaces a destination outside the roots either", %{tmp: tmp} do
      {source, dest} = exclusive_rename_paths!(Path.join(tmp, "outside"))

      assert :ok = Disk.rename_exclusive(source, dest)
      assert File.read!(dest) == "fetched"

      File.write!(source, "second")
      assert {:error, :eexist} = Disk.rename_exclusive(source, dest)
      assert File.read!(source) == "second"
      assert File.read!(dest) == "fetched"
    end

    test "rejects a destination ancestor replaced by an outside symlink", %{root: root, tmp: tmp} do
      {source, dest} = exclusive_rename_paths!(root)
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(outside)
      barrier!(:rename_exclusive, source)

      task = Task.async(fn -> BarrierFilesystem.rename_exclusive(source, dest) end)
      assert_receive {:filesystem_barrier, pid, ref, :rename_exclusive, ^source}
      swap_parent!(dest, Path.join(root, "Movie.original"), outside)
      send(pid, {ref, :continue})

      assert {:error, reason} = Task.await(task)
      assert reason in [:eloop, :enotdir]
      assert File.ls!(outside) == []
      assert File.read!(Path.join(root, "Movie.original/.workspace/staged")) == "fetched"
    end

    test "on mergerfs renames on the backing branch once the name is unique", %{
      root: root,
      tmp: tmp
    } do
      {source, dest} = exclusive_rename_paths!(root)
      mergerfs_rename_shim!(root, tmp, dest)

      assert :ok = Disk.rename_exclusive(source, dest)
      refute File.exists?(source)
      assert File.read!(dest) == "fetched"
    end

    # Issue #796: the shim's union cannot see the other branch, so the absence check passes and
    # only the wait after the rename finds two containers, as when the name appears in between.
    test "on mergerfs a file renamed onto a name another branch gains goes back to the source",
         %{root: root, tmp: tmp} do
      {source, dest} = exclusive_rename_paths!(root)
      %{duplicate: duplicate} = mergerfs_rename_shim!(root, tmp, dest)
      write_other_branch!(duplicate)

      assert {:error, :eexist} = Disk.rename_exclusive(source, dest)
      assert File.read!(source) == "fetched"
      refute File.exists?(dest)
      assert File.read!(duplicate) == "other branch"
    end

    # What each failed move back leaves: the file that replaced ours stays at `dest`, and ours is
    # back at the source only when the last sync failed. After the forward rename and its sync,
    # a replaced file is never moved, a file swapped in is moved back and synced, and the failed
    # sync is the last step tried.
    for {case_name, interfere, at_source, at_dest, effects} <- [
          {"a renamed file replaced before the move back", :after_rename, nil, "replacement",
           ~w(rename sync)},
          {"a file swapped in during the move back", :before_move_back, nil, "replacement",
           ~w(rename sync rename rename sync)},
          {"a move back that cannot be synced", :unsynced_move_back, "fetched", nil,
           ~w(rename sync rename sync)}
        ] do
      test "on mergerfs #{case_name} stays committed", %{root: root, tmp: tmp} do
        {source, dest} = exclusive_rename_paths!(root)

        %{duplicate: duplicate, effects: effects} =
          mergerfs_rename_shim!(root, tmp, dest, interfere: unquote(interfere))

        write_other_branch!(duplicate)

        assert {:error, {:effect_committed, "rename_exclusive", %{"reason" => "EEXIST"}}} =
                 Disk.rename_exclusive(source, dest)

        assert contents(source) == unquote(at_source)
        assert contents(dest) == unquote(at_dest)
        assert File.read!(duplicate) == "other branch"
        assert String.split(File.read!(effects), "\n", trim: true) == unquote(effects)
      end
    end

    test "on mergerfs a source on another backing branch is refused", %{root: root, tmp: tmp} do
      {source, dest} = exclusive_rename_paths!(root)
      mergerfs_rename_shim!(root, tmp, dest, foreign: ".workspace")

      assert {:error, :exdev} = Disk.rename_exclusive(source, dest)
      assert File.read!(source) == "fetched"
      refute File.exists?(dest)
    end
  end

  # Issue #798: a fetch creates an absent sidecar through a workspace anchored on the sidecar's
  # directory. That directory may be the library root itself, and on mergerfs the library root
  # may be the mount or a directory below it.
  describe "on mergerfs, a fetch of an absent sidecar" do
    @describetag :tmp_dir

    setup do
      Application.put_env(:cinder, :filesystem, Disk)
      Application.put_env(:cinder, :path_policy, PathPolicy)
    end

    for {layout, branch} <- [{"is the mount", :root}, {"is below the mount", :parent}] do
      for {place, folder} <- [{"in a title folder", "Movie"}, {"at the library root", "."}] do
        test "creates it #{place} when the library root #{layout}", %{root: root, tmp: tmp} do
          folder = Path.expand(unquote(folder), root)
          dest = Path.join(folder, "Movie.en.srt")
          File.mkdir_p!(folder)
          File.write!(Path.join(folder, "Movie.mkv"), "video")
          mergerfs_rename_shim!(root, tmp, dest, branch: shim_branch(root, unquote(branch)))

          assert :ok = AtomicFile.swap(dest, :absent, "fetched")
          assert File.read!(dest) == "fetched"
          assert Enum.sort(File.ls!(folder)) == ["Movie.en.srt", "Movie.mkv"]
        end
      end

      test "refuses a title folder whose backing path has another name when the library root #{layout}",
           %{root: root, tmp: tmp} do
        folder = Path.join(root, "Movie")
        dest = Path.join(folder, "Movie.en.srt")
        File.mkdir_p!(folder)
        File.write!(Path.join(folder, "Movie.mkv"), "video")

        mergerfs_rename_shim!(root, tmp, dest,
          branch: shim_branch(root, unquote(branch)),
          misplaced: "Movie"
        )

        assert {:error, :exdev} = AtomicFile.swap(dest, :absent, "fetched")
        assert File.ls!(folder) == ["Movie.mkv"]
      end
    end

    # Issue #796: another branch gains the sidecar's name before the fetch's rename.
    test "loses the name to another branch without leaving its own copy", %{root: root, tmp: tmp} do
      %{folder: folder, dest: dest, duplicate: duplicate} = absent_sidecar!(root, tmp)
      write_other_branch!(duplicate)

      assert {:error, :concurrent_change} = AtomicFile.swap(dest, :absent, "fetched")
      assert File.ls!(folder) == ["Movie.mkv"]
      assert File.read!(duplicate) == "other branch"
    end

    test "records no track when it loses the name to another branch", %{root: root, tmp: tmp} do
      %{video: video, dest: dest, duplicate: duplicate} = absent_sidecar!(root, tmp)
      write_other_branch!(duplicate)
      sidecar = %{video_path: video, sidecar_path: dest, language: "en"}

      assert {:error, {:write, {:error, :concurrent_change}}} =
               SidecarTransaction.replace(sidecar, "fetched", "embedded", nil)

      assert Manifest.read(video).tracks == %{}
      refute File.exists?(dest)
      assert File.read!(duplicate) == "other branch"
    end

    test "records its track when no other branch holds the name", %{root: root, tmp: tmp} do
      %{video: video, dest: dest} = absent_sidecar!(root, tmp)
      sidecar = %{video_path: video, sidecar_path: dest, language: "en"}

      assert :ok = SidecarTransaction.replace(sidecar, "fetched", "embedded", nil)
      assert %{"en" => %{origin: "embedded"}} = Manifest.read(video).tracks
      assert File.read!(dest) == "fetched"
    end

    # A retraction that finds other bytes puts them back, and that restore is a create too: when
    # another branch gains the name first, they stay in the workspace, as when the name is taken
    # before the restore.
    test "a retraction whose restore loses the name to another branch keeps the file in its workspace",
         %{root: root, tmp: tmp} do
      %{folder: folder, dest: dest, duplicate: duplicate} = absent_sidecar!(root, tmp)
      File.write!(dest, "edited")
      write_other_branch!(duplicate)

      log =
        capture_log(fn ->
          assert {:error, {:retract_restore_failed, :concurrent_change, :eexist}} =
                   AtomicFile.swap(dest, "fetched", :absent)
        end)

      assert log =~ "subtitle workspace kept"
      refute File.exists?(dest)
      assert File.read!(duplicate) == "other branch"

      assert [workspace] =
               Path.wildcard(Path.join(folder, ".cinder-subtitle-sync-cas-*"), match_dot: true)

      assert File.read!(Path.join(workspace, ".cinder-subtitle-sync-write-staged")) == "edited"
    end
  end

  defp absent_sidecar!(root, tmp) do
    folder = Path.join(root, "Movie")
    video = Path.join(folder, "Movie.mkv")
    dest = Path.join(folder, "Movie.en.srt")
    File.mkdir_p!(folder)
    File.write!(video, "video")
    %{duplicate: duplicate} = mergerfs_rename_shim!(root, tmp, dest)
    %{folder: folder, video: video, dest: dest, duplicate: duplicate}
  end

  # The shim's union never shows this container, so it reads as one another branch gained after
  # the absence check.
  defp write_other_branch!(duplicate) do
    File.mkdir_p!(Path.dirname(duplicate))
    File.write!(duplicate, "other branch")
  end

  defp contents(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, :enoent} -> nil
    end
  end

  defp shim_branch(root, :root), do: root
  defp shim_branch(root, :parent), do: Path.dirname(root)

  defp exclusive_rename_paths!(root) do
    source = Path.join(root, "Movie/.workspace/staged")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "fetched")
    {source, Path.join(root, "Movie/subtitle.srt")}
  end

  # A real mergerfs mount is not available in the test environment, so the shim maps every
  # logical path onto itself on a branch that is also the mount: the library root by default,
  # or `branch`, a directory above it. It answers user.mergerfs.allpaths for `dest` with
  # whichever of its two branch containers exist. A path containing `foreign` instead maps
  # onto a second branch, and a path whose last component is `misplaced` reports a backing
  # path under another name. `interfere` breaks a `rename_exclusive` that has to move its file
  # back: another file replaces `dest` right after the rename onto it (`:after_rename`) or
  # right before the move back (`:before_move_back`), or the move back's directory sync fails
  # (`:unsynced_move_back`); each rename and directory sync the helper then tries is logged to
  # `effects`. The renames and proofs are the real helper's.
  defp mergerfs_rename_shim!(root, tmp, dest, opts \\ []) do
    branch = Keyword.get(opts, :branch, root)
    branch_b = Path.join(tmp, "branch-b")
    duplicate = Path.join(branch_b, Path.relative_to(dest, branch))
    helper = Path.join(tmp, "mergerfs_rename_shim.py")
    effects = Path.join(tmp, "helper-effects.log")
    real_helper = Path.expand("../../../../priv/rooted_fs.py", __DIR__)

    File.write!(helper, """
    import os
    import posixpath
    import sys

    BRANCH = #{inspect(branch)}
    BRANCH_B = #{inspect(branch_b)}
    DEST = #{inspect(dest)}
    CONTAINERS = [DEST, #{inspect(duplicate)}]
    FOREIGN = #{python_literal(opts[:foreign])}
    MISPLACED = #{python_literal(opts[:misplaced])}
    INTERFERE = #{python_literal(opts[:interfere] && Atom.to_string(opts[:interfere]))}
    EFFECTS = #{inspect(effects)}
    REAL_HELPER = #{inspect(real_helper)}

    real_getxattr = os.getxattr

    def real_path(path):
        return os.readlink(f"/proc/self/fd/{path}") if isinstance(path, int) else path

    def getxattr(path, name, **kwargs):
        real = real_path(path)
        foreign = FOREIGN is not None and FOREIGN in real
        if name == "user.mergerfs.allpaths":
            if real == DEST:
                return b"\\0".join(os.fsencode(c) for c in CONTAINERS if os.path.lexists(c))
            return os.fsencode(real)
        if name == "user.mergerfs.fullpath":
            if foreign:
                return os.fsencode(posixpath.join(BRANCH_B, posixpath.relpath(real, BRANCH)))
            if posixpath.basename(real) == MISPLACED:
                return os.fsencode(real + ".elsewhere")
            return os.fsencode(real)
        if name == "user.mergerfs.basepath":
            return os.fsencode(BRANCH_B if foreign else BRANCH)
        return real_getxattr(path, name, **kwargs)

    os.getxattr = getxattr

    namespace = {"__name__": "rooted_fs_shim", "__file__": REAL_HELPER}
    with open(REAL_HELPER, encoding="utf-8") as source:
        exec(compile(source.read(), REAL_HELPER, "exec"), namespace)

    namespace["mergerfs_mountpoint"] = lambda path: BRANCH
    namespace["mergerfs_mount"] = lambda path: True

    def on_call(name, number, effect):
        real = namespace[name]
        calls = []

        def wrapper(*args):
            calls.append(args)
            if len(calls) == number:
                effect()
            return real(*args)

        namespace[name] = wrapper

    def replace_dest():
        replacement = DEST + ".replacement"
        with open(replacement, "w", encoding="utf-8") as file:
            file.write("replacement")
        os.replace(replacement, DEST)

    def fail_sync():
        raise OSError(5, "EIO")

    def log_effect(name, effect):
        real = namespace[name]

        def wrapper(*args):
            with open(EFFECTS, "a", encoding="utf-8") as log:
                log.write(effect + "\\n")
            return real(*args)

        namespace[name] = wrapper

    if INTERFERE == "after_rename":
        on_call("wait_for_unique_path", 1, replace_dest)
    elif INTERFERE == "before_move_back":
        on_call("rename_with_flags", 2, replace_dest)
    elif INTERFERE == "unsynced_move_back":
        on_call("sync_parents", 2, fail_sync)

    if INTERFERE is not None:
        log_effect("rename_with_flags", "rename")
        log_effect("sync_parents", "sync")

    sys.argv = [REAL_HELPER] + sys.argv[1:]
    operation = sys.argv[1] if len(sys.argv) > 1 else "unknown"

    try:
        namespace["main"]()
    except OSError as exc:
        committed = isinstance(exc, namespace["EffectCommittedError"])
        namespace["fail"](operation, "post_effect" if committed else "pre_effect", exc)
        sys.exit(1)
    """)

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)
    %{duplicate: duplicate, effects: effects}
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
    FILL_AFTER_QUARANTINE = #{python_literal(fill_after_quarantine)}

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

  defp python_literal(value) when value in [nil, false], do: "None"
  defp python_literal(value), do: inspect(value)

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
