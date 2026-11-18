defmodule Cinder.Subtitles.SidecarTransactionReplaceTest do
  # Drives the sidecar replacement transaction directly, on real temp directories through the
  # `Cinder.Library.Filesystem` seam: no engine, no media probe. Crashes are a killed process at a
  # `Cinder.Test.BarrierFilesystem` barrier, or a pending record written by hand. This module
  # covers `replace/4`, and corrections over a sidecar hardlinked into a download with the
  # disposal steps their recovery runs; `Cinder.Test.SidecarTransactionCase` holds the setup and
  # helpers it shares with its sibling modules (#1474).
  use Cinder.DataCase, async: false
  use Cinder.Test.SidecarTransactionCase

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1, fail_in_order: 1]
  import ExUnit.CaptureLog

  alias Cinder.Subtitles.{Manifest, SidecarTransaction}
  alias Cinder.Test.DiskTask

  # Issue #860: a release sidecar is a hardlink into a download that may still be seeding. A
  # correction exchanges a new inode in, and the inode it displaces keeps its bytes there.
  describe "publish/4 over a sidecar hardlinked into a download" do
    test "a correction and a reset leave the download's bytes alone", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)

      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
      assert workspaces(path) == []

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert File.read!(download) == original
      assert [staged] = workspace_staged_files(path)
      assert_fresh_tombstone(staged)
    end

    test "a sidecar replaced right after the correction's exchange keeps the download's bytes", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)

      assert {:error, :concurrent_change} =
               replace_after_exchange(path, tmp, fn -> manual(video, 1_000) end)

      assert File.read!(path) == "newer"
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
      assert [staged] = workspace_staged_files(path)
      assert_fresh_tombstone(staged)
    end

    test "a sidecar with no other name still goes through discard_bound when replaced after the exchange",
         %{
           video: video,
           path: path,
           tmp_dir: tmp
         } do
      fail_once(%{operation: :discard_bound, source_contains: Path.basename(path), reason: :eio})

      assert {:error, {:external_preservation_discard_failed, :eio}} =
               replace_after_exchange(path, tmp, fn -> manual(video, 1_000) end)

      assert File.read!(path) == "newer"
    end

    # #1284: the write empties nothing it could not verify, so the download keeps its second
    # name until the recovery's workspace cleanup drops it.
    test "a correction whose two names fail to open right after the exchange keeps the download's bytes",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)

      assert {:error, {:publication_committed, @names_unverified}} =
               fail_names_open_after_exchange(path, fn -> manual(video, 1_000) end)

      assert File.read!(download) == original
      assert File.stat!(download).links == 2

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert workspaces(path) == []
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end

    # #1322: the write empties nothing after its failed rollback, so the download keeps its second
    # name until the recovery's workspace cleanup drops it.
    test "a correction whose staged name fails to open twice right after the exchange keeps the download's bytes",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)

      assert {:error, {:publication_committed, @rollback_kept}} =
               fail_staged_open_after_exchange(fn -> manual(video, 1_000) end, [
                 staged_open_failure()
               ])

      assert File.read!(download) == original
      assert File.stat!(download).links == 2

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert workspaces(path) == []
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end

    # #1131: the kill leaves the download's inode at the staged name beside the empty fresh
    # tombstone. The recovery's final record retires that workspace.
    test "a correction killed after creating the fresh tombstone is finished by recover", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)
      workspace = kill_at_fresh_tombstone!(video, path, download)

      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      refute File.exists?(workspace)
      assert workspaces(path) == []
      assert File.read!(download) == original
      assert File.stat!(download).links == 1

      assert :ok = reconcile(video)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert :ok = reset(video)
      assert File.read!(path) == original
      assert File.read!(download) == original
    end

    test "a sweep retires a killed correction's workspace its recovery kept, and a reset goes on",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)
      workspace = kill_at_fresh_tombstone!(video, path, download)
      # The recovery tries the rename twice: its cleanup finishes the disposal (#1149), then the
      # final record's retirement does.
      rename_failure = %{operation: :rename, source_contains: @tombstone, reason: :eio}
      fail_in_order([rename_failure, rename_failure])

      {result, log} = with_log(fn -> recover(video) end)
      assert {:ok, %{sync: %{status: "aligned"}}} = result
      assert log =~ "subtitle workspace kept at #{workspace}: :eio"
      refute log =~ "subtitle workspace removed"
      assert Enum.sort(File.ls!(workspace)) == [@staged, @tombstone]

      age!(workspace)
      assert :ok = reconcile(video)
      refute File.exists?(workspace)
      assert File.stat!(download).links == 1

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end

    # #1149: the recovery finishes the rename whatever the staged inode's link count. Its bytes
    # are the ones before the correction, which the immutable original keeps.
    test "a killed correction whose download was deleted is finished by recover", %{
      video: video,
      path: path,
      original: original,
      backup: backup,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)
      workspace = kill_at_fresh_tombstone!(video, path, download)
      File.rm!(download)
      assert File.stat!(Path.join(workspace, @staged)).links == 1

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      refute File.exists?(workspace)
      assert workspaces(path) == []
      assert File.read!(backup) == original
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    end

    # #1149: the staged name alone still holds the download's inode. The recovery renames a fresh
    # tombstone over it, as the uninterrupted write does, and never writes that inode.
    test "a correction killed before creating the fresh tombstone is finished by recover", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)
      use_barrier(%{operation: :create_bound, phase: :before, contains: @tombstone})
      kill_at_barrier(fn -> manual(video, 1_000) end, :create_bound)
      assert [workspace] = workspaces(path)
      assert File.ls!(workspace) == [@staged]
      assert same_inode?(Path.join(workspace, @staged), download)
      before = File.stat!(download)

      # Stays armed: a `discard_bound` on the staged name would empty the download's inode.
      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :discard_bound,
        source_contains: @staged,
        reason: :discard_forbidden
      })

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert %{operation: :discard_bound} = Application.get_env(:cinder, :filesystem_failure)
      refute File.exists?(workspace)
      assert workspaces(path) == []
      assert File.read!(download) == original
      assert %{links: 1} = after_recovery = File.stat!(download)

      assert Map.take(after_recovery, [:inode, :major_device, :size, :mtime]) ==
               Map.take(before, [:inode, :major_device, :size, :mtime])
    end

    test "a recovery killed after renaming the fresh tombstone over the download's name is finished by the next one",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)
      use_barrier(%{operation: :create_bound, phase: :before, contains: @tombstone})
      kill_at_barrier(fn -> manual(video, 1_000) end, :create_bound)
      use_barrier(%{operation: :rename, contains: @staged})
      kill_at_barrier(fn -> recover(video) end, :rename)
      assert [workspace] = workspaces(path)
      assert File.ls!(workspace) == [@staged]
      assert_fresh_tombstone(Path.join(workspace, @staged))
      assert File.stat!(download).links == 1
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert workspaces(path) == []
      assert File.read!(download) == original
    end

    # #1187, on the correction branch: no fresh tombstone exists, so the staged name alone holds
    # the download's inode, and the pending record stays for the recovery that finishes the
    # disposal.
    test "a correction whose fresh tombstone could not be created is finished by recover", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)
      fail_once(%{operation: :create_bound, source_contains: @tombstone, reason: :enospc})

      assert {:error, {:publication_committed, {:tombstone_replace_failed, :enospc}}} =
               manual(video, 1_000)

      assert [workspace] = workspaces(path)
      assert File.ls!(workspace) == [@staged]
      assert File.stat!(download).links == 2

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      refute File.exists?(workspace)
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end

    # #1187: the immutable original holds the staged bytes, but the pending record names the
    # workspace, so the sweep leaves it to the recovery.
    test "reconcile leaves a correction's workspace whose fresh tombstone could not be created to its recovery",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)
      fail_once(%{operation: :create_bound, source_contains: @tombstone, reason: :enospc})

      assert {:error, {:publication_committed, {:tombstone_replace_failed, :enospc}}} =
               manual(video, 1_000)

      assert [workspace] = workspaces(path)
      age!(workspace)

      assert :ok = reconcile(video)
      assert File.ls!(workspace) == [@staged]
      assert same_inode?(Path.join(workspace, @staged), download)
      assert File.stat!(download).links == 2
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      refute File.exists?(workspace)
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end

    test "reconcile leaves a killed correction's workspace to its pending record's recovery", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)
      workspace = kill_at_fresh_tombstone!(video, path, download)
      age!(workspace)

      assert :ok = reconcile(video)
      assert Enum.sort(File.ls!(workspace)) == [@staged, @tombstone]
      assert same_inode?(Path.join(workspace, @staged), download)
      assert File.stat!(download).links == 2

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      refute File.exists?(workspace)
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end

    test "a correction killed after renaming the fresh tombstone is finished by recover", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)
      use_barrier(%{operation: :rename, contains: ".cinder-subtitle-sync-write-staged"})
      kill_at_barrier(fn -> manual(video, 1_000) end, :rename)

      assert [staged] = workspace_staged_files(path)
      assert_fresh_tombstone(staged)
      assert_killed_correction_recovers(video, path, original, download)
      refute File.exists?(Path.dirname(staged))
    end

    # #1156: a failed rename keeps the fresh tombstone, so the workspace holds the two entries a
    # kill after the create leaves (#1131), and the recovery's final record retires them.
    test "a failed tombstone rename leaves the pending record for recovery, which retires the workspace",
         %{video: video, path: path, original: original, backup: backup, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)
      fail_once(%{operation: :rename, source_contains: @tombstone, reason: :eio})

      assert {:error, {:publication_committed, {:tombstone_replace_failed, :eio}}} =
               manual(video, 1_000)

      assert_failed_rename_entries(path, original, download)

      assert_unacknowledged_correction(video, path, original, backup)
      assert workspaces(path) == []
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end

    # #1156: the correction's abort clears its record, so no record names the workspace and only a
    # sweep retires it.
    test "a failed tombstone rename after the sidecar was replaced leaves a workspace a sweep retires",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)
      fail_once(%{operation: :rename, source_contains: @tombstone, reason: :eio})

      assert {:error, {:external_preservation_replace_failed, :eio}} =
               replace_after_exchange(path, tmp, fn -> manual(video, 1_000) end)

      workspace = assert_failed_rename_entries(path, original, download)
      assert File.read!(path) == "newer"
      assert Manifest.sync(Manifest.read(video), "en") == nil

      assert :ok = reconcile(video)
      assert Enum.sort(File.ls!(workspace)) == [@staged, @tombstone]
      assert File.stat!(download).links == 2

      age!(workspace)
      assert :ok = reconcile(video)
      refute File.exists?(workspace)
      assert workspaces(path) == []
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
      assert File.read!(path) == "newer"
    end

    # #1187: no fresh tombstone exists, so the staged name alone holds the download's inode, and
    # the abort clears the record.
    test "a fresh tombstone not created after the sidecar was replaced leaves a workspace a sweep retires",
         %{video: video, path: path, original: original, backup: backup, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)
      fail_once(%{operation: :create_bound, source_contains: @tombstone, reason: :enospc})

      assert {:error, {:external_preservation_replace_failed, :enospc}} =
               replace_after_exchange(path, tmp, fn -> manual(video, 1_000) end)

      assert_staged_download_swept(video, path, original, backup, download)
    end

    # #1187: the check before the rename cannot open the staged name, so the disposal removes its
    # fresh tombstone and the staged name alone holds the download's inode. A failed open, not a
    # mode 000 file: CI runs the suite as root, which opens that file anyway.
    test "a staged name the check cannot open after the sidecar was replaced leaves a workspace a sweep retires",
         %{video: video, path: path, original: original, backup: backup, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)

      assert {:error, {:external_preservation_replace_failed, :concurrent_change}} =
               replace_after_exchange(
                 path,
                 tmp,
                 fn -> manual(video, 1_000) end,
                 &fail_staged_check/2
               )

      assert_staged_download_swept(video, path, original, backup, download)
    end

    # The check before the rename finds another file at the staged name: the disposal never
    # verified that file, so it removes its fresh tombstone and leaves the staged name alone.
    test "a staged name replaced before the tombstone rename keeps only that name", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)
      use_barrier(%{operation: :create_bound, contains: @tombstone})
      task = Task.async(fn -> manual(video, 1_000) end)

      assert_receive {:filesystem_barrier, pid, ref, :create_bound, fresh_path},
                     DiskTask.timeout_ms()

      workspace = Path.dirname(fresh_path)
      other = Path.join(tmp, "other.srt")
      File.write!(other, "other")
      File.rename!(other, Path.join(workspace, @staged))
      send(pid, {ref, :continue})

      assert {:error, {:publication_committed, {:tombstone_replace_failed, :concurrent_change}}} =
               DiskTask.await(task)

      assert File.ls!(workspace) == [@staged]
      assert File.read!(Path.join(workspace, @staged)) == "other"
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end

    # #1190: the check that the sidecar still names the published inode cannot open it, and the
    # sidecar holds the corrected bytes. The displaced inode is disposed of as after a verified
    # exchange, and the pending record stays for the recovery.
    test "a sidecar that fails to open right after the correction's exchange keeps the pending record",
         %{video: video, path: path, original: original, backup: backup, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)

      assert {:error, {:publication_committed, :published_target_unverified}} =
               fail_target_open_after_exchange(path, fn -> manual(video, 1_000) end)

      assert File.read!(download) == original
      assert File.stat!(download).links == 1
      assert_unacknowledged_correction(video, path, original, backup)
      assert workspaces(path) == []
      assert File.stat!(download).links == 1
    end

    # #1190, with the disposal failing as in #1156: the workspace keeps the download's inode
    # beside the fresh tombstone, and the recovery's final record retires both.
    test "a sidecar that fails to open after the exchange, then a failed tombstone rename, leaves the pending record",
         %{video: video, path: path, original: original, backup: backup, tmp_dir: tmp} do
      download = hardlink_download!(path, tmp)
      rename_failure = %{operation: :rename, source_contains: @tombstone, reason: :eio}

      assert {:error,
              {:publication_committed,
               {:published_target_unverified, {:tombstone_replace_failed, :eio}}}} =
               fail_target_open_after_exchange(path, fn -> manual(video, 1_000) end, [
                 rename_failure
               ])

      assert_failed_rename_entries(path, original, download)

      assert_unacknowledged_correction(video, path, original, backup)
      assert workspaces(path) == []
      assert File.read!(download) == original
      assert File.stat!(download).links == 1
    end
  end

  # #1290: a recovery's cleanup logs the workspace it could not finish disposing of as kept. When
  # the final record's retirement then removes it, the recovery logs that removal too.
  describe "recover/2 and restore_original/2 after a failed disposal step" do
    for {state, reason} <- [
          {:fresh_tombstone, :eio},
          {:no_fresh_tombstone, {:tombstone_replace_failed, :eio}},
          {:committed_rename, {:tombstone_replace_failed, {:effect_committed, "rename", :eio}}},
          {:committed_discard, {:discard_failed, {:effect_committed, "discard_bound", :eio}}},
          {:unclosed_staged, :eio}
        ],
        entry <- [:recover, :reset] do
      test "#{entry} logs the removal of a workspace its cleanup kept (#{state})", %{
        video: video,
        path: path,
        original: original,
        tmp_dir: tmp
      } do
        {workspace, download} = interrupt_disposal!(unquote(state), video, path, tmp)

        {result, log} = with_log(fn -> run_recovery(unquote(entry), video) end)

        assert_recovery_result(unquote(entry), result, video, path, original)
        assert_removal_logged(log, workspace, unquote(Macro.escape(reason)))
        refute File.exists?(workspace)
        assert_download_kept(download, original)
      end
    end

    # Beside a target that still holds the expected bytes, a cleanup that kept its workspace
    # passes only when the staged file then closes.
    test "a cleanup beside the expected bytes reports the workspace it kept", %{path: path} do
      {result, workspace} = cleanup_kept_beside_expected(path, false)
      assert result == {:kept, workspace}
    end

    test "a cleanup beside the expected bytes fails when the staged file then fails to close", %{
      path: path
    } do
      {result, _workspace} = cleanup_kept_beside_expected(path, true)
      assert result == {:error, {:descriptor_close_failed, :ebadf}}
    end

    # The removal line follows only the correction's own workspace: a reversal's workspace that
    # the same recovery keeps gets no retirement, so no removal line either.
    test "a reversal workspace a recovery keeps gets no removal line", %{
      video: video,
      path: path
    } do
      use_barrier(%{operation: :discard_bound, phase: :before, contains: Path.basename(path)})
      kill_at_barrier(fn -> manual(video, 1_000) end, :discard_bound)
      assert [staged] = workspace_staged_files(path)
      own = Path.dirname(staged)
      pending = Manifest.sync(Manifest.read(video), "en")

      reversal_id =
        SidecarTransaction.AtomicFile.reversal_id(
          path,
          pending.applied_sha256,
          pending.expected_sha256
        )

      reversal = plant_workspace!(path, %{@staged => File.read!(path)}, reversal_id)
      reversal_staged = Path.join(reversal, @staged)
      fail_once(%{operation: :discard_bound, source_contains: reversal_staged, reason: :eio})

      {result, log} = with_log(fn -> recover(video) end)

      assert {:ok, %{sync: %{status: "aligned"}}} = result
      assert log =~ "subtitle workspace kept at #{reversal}: {:discard_failed, :eio}"
      refute log =~ "subtitle workspace removed"
      refute File.exists?(own)
      assert File.read!(reversal_staged) == File.read!(path)
    end
  end

  # Issue #340: the fetch side journals the previous record before retiring its original.
  describe "replace/4" do
    test "a fetched replacement retires the stale original and closes its journal", %{
      video: video,
      path: path,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      replacement = "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n"

      assert :ok = replace(video, replacement)
      assert File.read!(path) == replacement
      assert File.read!(backup) == ""

      assert %{origin: "opensubtitles_id", managed_sha256: managed} =
               track = Manifest.read(video).tracks["en"]

      assert managed == digest(replacement)
      refute Map.has_key?(track, :sync)
      refute Map.has_key?(track, :replacement_cleanup_sync)
    end

    test "an original that fails to retire stays journaled for reconcile", %{
      video: video,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)

      fail_once(%{
        operation: :discard_bound,
        source_contains: Path.basename(backup),
        reason: :eio
      })

      log =
        capture_log(fn ->
          assert :ok = replace(video, "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n")
        end)

      assert log =~ "subtitle replacement cleanup remains journaled"
      assert File.exists?(backup)
      assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == record

      assert :ok = SidecarTransaction.reconcile(video, moviehash!(video))
      assert File.read!(backup) == ""
      assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
    end

    test "a replacement killed while retiring the original is finished by reconcile", %{
      video: video,
      path: path,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      replacement = "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n"
      use_barrier(%{operation: :discard_bound, phase: :before, contains: backup})
      ^backup = kill_at_barrier(fn -> replace(video, replacement) end, :discard_bound)

      assert File.read!(path) == replacement
      assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == record

      assert :ok = SidecarTransaction.reconcile(video, moviehash!(video))
      assert File.read!(backup) == ""
      assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
    end

    test "a failed manifest write puts the previous bytes back", %{
      video: video,
      path: path,
      original: original
    } do
      fail_once(%{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio
      })

      assert {:error, {:manifest, {:error, :eio}}} =
               replace(video, "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n")

      assert File.read!(path) == original
      assert %{origin: "opensubtitles_hash"} = Manifest.read(video).tracks["en"]
    end

    test "a sidecar that did not exist yet is created", %{video: video} do
      target = Path.rootname(video) <> ".fr.srt"
      content = "1\n00:00:05,000 --> 00:00:06,000\nUn\n\n"

      assert :ok = replace_fr(video, content)
      assert File.read!(target) == content
      assert %{origin: "embedded"} = Manifest.read(video).tracks["fr"]
      assert workspaces(target) == []
    end

    # Issue #758: the fetch side publishes through the same compare-and-swap as corrections.
    test "a replacement leaves no workspace beside the sidecar", %{video: video, path: path} do
      assert :ok = replace(video, @replacement)
      assert File.read!(path) == @replacement
      assert workspaces(path) == []
    end

    test "bytes the sidecar already holds are recorded without a write", %{
      video: video,
      path: path,
      original: original
    } do
      assert :ok = replace(video, original)
      assert File.read!(path) == original
      assert %{origin: "opensubtitles_id"} = Manifest.read(video).tracks["en"]
      assert workspaces(path) == []
    end

    test "a fetch never overwrites bytes edited after its snapshot", %{video: video, path: path} do
      use_barrier(%{
        operation: :mkdir_exclusive,
        phase: :before,
        contains: ".cinder-subtitle-sync-cas-"
      })

      task = Task.async(fn -> replace(video, @replacement) end)

      assert_receive {:filesystem_barrier, pid, ref, :mkdir_exclusive, _workspace},
                     DiskTask.timeout_ms()

      File.write!(path, "edited")
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :concurrent_change}}} = DiskTask.await(task)
      assert File.read!(path) == "edited"
      assert %{origin: "opensubtitles_hash"} = Manifest.read(video).tracks["en"]
      assert workspaces(path) == []
    end

    test "a fetch leaves bytes edited just before its exchange alone", %{video: video, path: path} do
      use_barrier(%{operation: :exchange, phase: :before, contains: ".cinder-subtitle-sync-"})

      task = Task.async(fn -> replace(video, @replacement) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      File.write!(path, "edited")
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :captured_target_changed}}} = DiskTask.await(task)
      assert File.read!(path) == "edited"
      assert %{origin: "opensubtitles_hash"} = Manifest.read(video).tracks["en"]
      assert workspaces(path) == []
    end

    test "a fetch never replaces a sidecar that appeared after its snapshot", %{video: video} do
      target = Path.rootname(video) <> ".fr.srt"
      use_barrier(%{operation: :rename_exclusive, phase: :before, contains: "cas-"})

      task = Task.async(fn -> replace_fr(video, @replacement) end)

      assert_receive {:filesystem_barrier, pid, ref, :rename_exclusive, _staged},
                     DiskTask.timeout_ms()

      File.write!(target, "external")
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :concurrent_change}}} = DiskTask.await(task)
      assert File.read!(target) == "external"
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
      assert workspaces(target) == []
    end

    test "a sidecar replaced right after the fetch's exchange keeps the newer file", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)

      assert {:error, {:write, {:error, :concurrent_change}}} =
               replace_after_exchange(path, tmp, fn -> replace(video, @replacement) end)

      assert File.read!(path) == "newer"
      assert File.read!(download) == original
      assert workspaces(path) == []
    end

    # #1322: `swap/3` keeps the failed rollback as its result.
    test "a staged name that fails to open twice right after the fetch's exchange reports a failed rollback",
         %{video: video, path: path} do
      {result, _log} =
        with_log(fn ->
          fail_staged_open_after_exchange(fn -> replace(video, @replacement) end, [
            staged_open_failure()
          ])
        end)

      assert {:error, {:write, {:error, @rollback_failed}}} = result
      assert File.read!(path) == @replacement
    end

    test "identical bytes another writer created first are not recorded as the fetch's", %{
      video: video
    } do
      target = Path.rootname(video) <> ".fr.srt"
      use_barrier(%{operation: :rename_exclusive, phase: :before, contains: "cas-"})

      task = Task.async(fn -> replace_fr(video, @replacement) end)

      assert_receive {:filesystem_barrier, pid, ref, :rename_exclusive, _staged},
                     DiskTask.timeout_ms()

      File.write!(target, @replacement)
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :concurrent_change}}} = DiskTask.await(task)
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
    end

    # A release sidecar is a hardlink into the download, which may still be seeding.
    test "a fetched replacement never empties the file it displaced", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)

      assert :ok = replace(video, @replacement)
      assert File.read!(path) == @replacement
      assert File.read!(download) == original
    end

    test "a descriptor that fails to close after the fetch's exchange still records the track", %{
      video: video,
      path: path
    } do
      {result, log} =
        fail_close_after_exchange(
          path,
          [:staged],
          fn -> replace(video, @replacement) end,
          disposal: :unlink
        )

      assert :ok = result
      assert log =~ "subtitle publication unacknowledged"
      assert File.read!(path) == @replacement
      assert %{managed_sha256: managed} = Manifest.read(video).tracks["en"]
      assert managed == digest(@replacement)
      assert workspaces(path) == []
    end

    test "a post-effect exchange failure still records the fetched track", %{
      video: video,
      path: path
    } do
      fail_once(%{
        operation: :exchange,
        source_contains: ".cinder-subtitle-sync-write-staged",
        reason: :eio,
        phase: :post_effect
      })

      capture_log(fn -> assert :ok = replace(video, @replacement) end)
      assert File.read!(path) == @replacement
      assert %{managed_sha256: managed} = Manifest.read(video).tracks["en"]
      assert managed == digest(@replacement)
    end

    test "a post-effect create failure still records the fetched track", %{video: video} do
      target = Path.rootname(video) <> ".fr.srt"

      fail_once(%{
        operation: :rename_exclusive,
        source_contains: ".cinder-subtitle-sync-write-staged",
        reason: :eio,
        phase: :post_effect
      })

      capture_log(fn -> assert :ok = replace_fr(video, @replacement) end)
      assert File.read!(target) == @replacement
      assert %{origin: "embedded"} = Manifest.read(video).tracks["fr"]
    end

    test "a descriptor that fails to close after the create still records the fetched track", %{
      video: video
    } do
      target = Path.rootname(video) <> ".fr.srt"

      fail_once(%{
        operation: :close_bound,
        source_contains: ".cinder-subtitle-sync-write-staged",
        reason: :eio
      })

      log = capture_log(fn -> assert :ok = replace_fr(video, @replacement) end)
      assert log =~ "subtitle publication unacknowledged"
      assert File.read!(target) == @replacement
      assert %{origin: "embedded"} = Manifest.read(video).tracks["fr"]
      assert workspaces(target) == []
    end

    test "a target that cannot be opened after the create still records the fetched track", %{
      video: video
    } do
      target = Path.rootname(video) <> ".fr.srt"
      fail_once(%{operation: :open_bound, source_contains: ".fr.srt", reason: :eio})

      log = capture_log(fn -> assert :ok = replace_fr(video, @replacement) end)
      assert log =~ "subtitle publication unacknowledged"
      assert File.read!(target) == @replacement
      assert %{origin: "embedded"} = Manifest.read(video).tracks["fr"]
      assert workspaces(target) == []
    end

    test "an unverified create whose workspace fails to close still records the fetched track", %{
      video: video
    } do
      target = Path.rootname(video) <> ".fr.srt"

      fail_in_order([
        %{operation: :open_bound, source_contains: ".fr.srt", reason: :eio},
        directory_close_failure()
      ])

      log = capture_log(fn -> assert :ok = replace_fr(video, @replacement) end)
      assert log =~ "subtitle publication unacknowledged"
      assert log =~ "{:operation_and_descriptor_close_failed, :concurrent_change, :eio}"
      assert_fetched_track(video, target, "fr", "embedded")
    end

    test "staged and workspace descriptors that fail to close after the create record the track",
         %{video: video} do
      target = Path.rootname(video) <> ".fr.srt"

      fail_in_order([
        %{operation: :open_bound, source_contains: ".fr.srt", reason: :eio},
        %{
          operation: :close_bound,
          source_contains: ".cinder-subtitle-sync-write-staged",
          reason: :eio
        },
        directory_close_failure()
      ])

      log = capture_log(fn -> assert :ok = replace_fr(video, @replacement) end)

      assert log =~
               "{:operation_and_descriptor_close_failed, {:descriptor_close_failed, :eio}, :eio}"

      assert_fetched_track(video, target, "fr", "embedded")
    end

    test "an unverified exchange whose workspace fails to close still records the fetched track",
         %{video: video, path: path} do
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-staged"})

      log =
        capture_log(fn ->
          task = Task.async(fn -> replace(video, @replacement) end)

          assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged},
                         DiskTask.timeout_ms()

          # Armed after the exchange: `swap/3` opens the target before it, too.
          fail_in_order([
            %{operation: :open_bound, source_contains: path, reason: :eio},
            directory_close_failure()
          ])

          send(pid, {ref, :continue})
          assert :ok = DiskTask.await(task)
        end)

      assert log =~ "{:operation_and_descriptor_close_failed, :concurrent_change, :eio}"
      assert_fetched_track(video, path, "en", "opensubtitles_id")
    end

    test "an unverified create whose workspace fails to close is not recorded once edited", %{
      video: video
    } do
      target = Path.rootname(video) <> ".fr.srt"

      fail_in_order([
        %{operation: :open_bound, source_contains: ".fr.srt", reason: :eio},
        directory_close_failure(%{callback: fn -> File.write!(target, "edited") end})
      ])

      capture_log(fn ->
        assert {:error,
                {:write,
                 {:error, {:operation_and_descriptor_close_failed, :concurrent_change, :eio}}}} =
                 replace_fr(video, @replacement)
      end)

      assert File.read!(target) == "edited"
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
    end

    test "an unverified create whose workspace fails to close is not recorded once unreadable", %{
      video: video,
      tmp_dir: tmp
    } do
      target = Path.rootname(video) <> ".fr.srt"
      outside = Path.join(tmp, "outside.srt")
      File.write!(outside, @replacement)

      # The fetched bytes stay reachable, through a symlink `safe_read/1` refuses to follow.
      swap_for_symlink = fn ->
        File.rm!(target)
        File.ln_s!(outside, target)
      end

      fail_in_order([
        %{operation: :open_bound, source_contains: ".fr.srt", reason: :eio},
        directory_close_failure(%{callback: swap_for_symlink})
      ])

      capture_log(fn ->
        assert {:error,
                {:write,
                 {:error, {:operation_and_descriptor_close_failed, :concurrent_change, :eio}}}} =
                 replace_fr(video, @replacement)
      end)

      assert File.read_link!(target) == outside
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
    end

    test "identical bytes created first stay unrecorded when the workspace fails to close", %{
      video: video
    } do
      target = Path.rootname(video) <> ".fr.srt"
      use_barrier(%{operation: :rename_exclusive, phase: :before, contains: "cas-"})
      fail_in_order([directory_close_failure()])

      task = Task.async(fn -> replace_fr(video, @replacement) end)

      assert_receive {:filesystem_barrier, pid, ref, :rename_exclusive, _staged},
                     DiskTask.timeout_ms()

      File.write!(target, @replacement)
      send(pid, {ref, :continue})

      assert {:error,
              {:write,
               {:error, {:operation_and_descriptor_close_failed, :concurrent_change, :eio}}}} =
               DiskTask.await(task)

      refute Map.has_key?(Manifest.read(video).tracks, "fr")
    end

    test "a rollback that cannot read back what it retracted puts it back", %{video: video} do
      target = Path.rootname(video) <> ".fr.srt"

      fail_in_order([
        %{
          operation: :write_exclusive,
          source_contains: ".cinder-subtitle-manifest-",
          reason: :eio
        },
        %{
          operation: :open_bound,
          source_contains: ".cinder-subtitle-sync-write-staged",
          reason: :eio
        }
      ])

      log =
        capture_log(fn ->
          assert {:error, {:manifest, {:error, :eio}}} = replace_fr(video, @replacement)
        end)

      assert log =~ "subtitle rollback failed"
      assert log =~ "retract_unverified"
      assert File.read!(target) == @replacement
      assert workspaces(target) == []
    end

    test "a failed manifest write removes the sidecar it created", %{video: video} do
      target = Path.rootname(video) <> ".fr.srt"
      fail_manifest_once()

      assert {:error, {:manifest, {:error, :eio}}} = replace_fr(video, @replacement)
      refute File.exists?(target)
      refute Map.has_key?(Manifest.read(video).tracks, "fr")
      assert workspaces(target) == []
    end

    # #1202: an unreadable manifest names no previous record to journal, so nothing is published.
    test "a replacement whose manifest read fails publishes nothing", %{
      video: video,
      path: path,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      sidecar = %{video_path: video, sidecar_path: path, language: "en"}
      moviehash = moviehash!(video)
      manifest = File.read!(Manifest.path(video))
      current = File.read!(path)
      original = File.read!(backup)
      fail_once(%{operation: :read, source_contains: ".cinder-subtitles.json", reason: :eio})

      log =
        capture_log(fn ->
          assert {:error, {:manifest, {:error, {:unreadable_manifest, :eio}}}} =
                   SidecarTransaction.replace(
                     sidecar,
                     @replacement,
                     "opensubtitles_id",
                     moviehash
                   )
        end)

      assert log =~ "subtitle manifest cannot be read for #{video}: :eio"
      assert File.read!(path) == current
      assert File.read!(Manifest.path(video)) == manifest
      assert File.read!(backup) == original
      assert workspaces(path) == []
    end

    test "a failed manifest write never empties the file the replacement displaced", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      download = hardlink_download!(path, tmp)
      fail_manifest_once()

      assert {:error, {:manifest, {:error, :eio}}} = replace(video, @replacement)
      assert File.read!(path) == original
      assert File.read!(download) == original
    end

    test "a rollback never overwrites a replacement edited after it was published", %{
      video: video,
      path: path
    } do
      log = edit_during_failed_manifest(path, fn -> replace(video, @replacement) end)

      assert log =~ "subtitle rollback failed"
      assert File.read!(path) == "edited"
    end

    test "a rollback never removes a created sidecar edited after it was published", %{
      video: video
    } do
      target = Path.rootname(video) <> ".fr.srt"

      log = edit_during_failed_manifest(target, fn -> replace_fr(video, @replacement) end)
      assert log =~ "subtitle rollback failed"
      assert File.read!(target) == "edited"
    end
  end
end
