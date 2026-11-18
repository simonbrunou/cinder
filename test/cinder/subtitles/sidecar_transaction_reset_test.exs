defmodule Cinder.Subtitles.SidecarTransactionResetTest do
  # Drives the sidecar replacement transaction directly, on real temp directories through the
  # `Cinder.Library.Filesystem` seam: no engine, no media probe. Crashes are a killed process at a
  # `Cinder.Test.BarrierFilesystem` barrier, or a pending record written by hand. This module
  # covers `restore_original/2`, `reconcile/2`, `remove/3`, the `AtomicFile` writes, and which
  # module writes the manifest's transaction fields; `Cinder.Test.SidecarTransactionCase` holds
  # the setup and helpers it shares with its sibling modules (#1474).
  use Cinder.DataCase, async: false
  use Cinder.Test.SidecarTransactionCase

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1]
  import ExUnit.CaptureLog

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Subtitles.{Manifest, SidecarTransaction}
  alias Cinder.Test.DiskTask

  describe "restore_original/2" do
    test "a reset killed after its exchange is finished by the next reset", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      staged = kill_at_barrier(fn -> reset(video) end, :exchange)
      workspace = Path.dirname(staged)
      assert File.read!(path) == original
      assert File.dir?(workspace)

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert File.dir?(workspace)
      assert_fresh_tombstone(staged)
      assert File.read!(backup) == ""
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    # #1149: the killed reset left the corrected bytes at its staged name. The next reset empties
    # them, so the same correction and its reset reuse that workspace.
    test "the same correction and reset go on after a reset killed after its exchange", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      staged = kill_at_barrier(fn -> reset(video) end, :exchange)
      assert File.read!(staged) == corrected

      assert :ok = reset(video)
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert File.read!(path) == corrected
      assert :ok = reset(video)
      assert File.read!(path) == original
      assert [^staged] = workspace_staged_files(path)
      assert_fresh_tombstone(staged)
    end

    test "a recovery empties the bytes a reset killed after its exchange left", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      staged = kill_at_barrier(fn -> reset(video) end, :exchange)
      assert File.read!(staged) == corrected

      assert {:ok, _sidecar} = recover(video)
      assert File.read!(path) == original
      assert_fresh_tombstone(staged)
    end

    # Beside a sidecar that holds neither side of the reset, the staged bytes are not proven the
    # inode its exchange displaced.
    test "a reset refused over an edited sidecar leaves the killed reset's bytes", %{
      video: video,
      path: path
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      staged = kill_at_barrier(fn -> reset(video) end, :exchange)
      File.write!(path, "edited")

      assert {:error, _reason} = reset(video)
      assert File.read!(path) == "edited"
      assert File.read!(staged) == corrected
    end

    test "a reset whose disposal fails still finishes, and a later reset disposes again", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      staged = kill_at_barrier(fn -> reset(video) end, :exchange)
      fail_once(%{operation: :discard_bound, source_contains: @staged, reason: :eio})

      {result, log} = with_log(fn -> reset(video) end)
      assert :ok = result

      assert log =~
               "subtitle workspace kept at #{Path.dirname(staged)}: {:discard_failed, :eio}"

      assert File.read!(path) == original
      assert File.read!(staged) == corrected
      assert Manifest.sync(Manifest.read(video), "en") == nil

      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert :ok = reset(video)
      assert File.read!(path) == original
      assert_fresh_tombstone(staged)
    end

    # #1169: a reset whose discard of the inode its exchange displaced failed finished, but left
    # the corrected bytes at its staged name. The same correction derives the same reversal id, so
    # its reset meets that workspace and empties them.
    test "the same correction and reset go on after a reset whose discard failed", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      fail_displaced_discard_once(path)

      {result, log} = with_log(fn -> reset(video) end)
      assert :ok = result
      assert log =~ "discard_failed"
      assert File.read!(path) == original
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == corrected

      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert File.read!(path) == corrected
      assert :ok = reset(video)
      assert_reset_finished(video, path, original, backup)
      assert_settled_reversal(path, staged)
    end

    test "a reset killed before its exchange publishes its staged original on the next reset", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)

      use_barrier(%{
        operation: :exchange,
        phase: :before,
        contains: ".cinder-subtitle-sync-write-"
      })

      staged = kill_at_barrier(fn -> reset(video) end, :exchange)
      assert File.read!(staged) == original
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert_fresh_tombstone(staged)
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a reset killed after retiring the original is finished by reconcile", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      use_barrier(%{operation: :discard_bound, contains: backup})
      ^backup = kill_at_barrier(fn -> reset(video) end, :discard_bound)
      assert File.read!(path) == original
      assert File.read!(backup) == ""
      assert Manifest.sync(Manifest.read(video), "en") != nil
      assert reset_journal(video) != nil

      assert :ok = SidecarTransaction.reconcile(video, moviehash!(video))
      assert File.read!(path) == original
      assert File.read!(backup) == ""
      assert reset_journal(video) == nil
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a reset journal for another video is not replayed", %{video: video} do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      assert :ok = Manifest.begin_reset_cleanup(video, "en", record)
      File.write!(video, @changed_video)

      assert {:error, :reset_video_changed} =
               SidecarTransaction.reconcile(video, moviehash!(video))

      assert {:error, :reset_video_changed} = reset(video)
    end

    test "never claims a matching reserved file after an unchanged record", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      record = record(moviehash!(video), original, original, %{method: "audio", offset_ms: 0})

      assert {:ok, :aligned, _} =
               SidecarTransaction.publish(sidecar(video), original, original, record)

      File.write!(backup, original)

      assert {:error, :unexpected_backup} = reset(video)
      assert {:error, :unexpected_backup} = manual(video, 1_000)
      assert File.read!(path) == original
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == record
    end

    test "retires a proven duplicate original of an unchanged record", %{
      video: video,
      path: path,
      original: original
    } do
      backup = owned_backup!(video, path, original)
      record = record(moviehash!(video), original, original, %{method: "audio", offset_ms: 0})
      assert :ok = Manifest.put_sync(video, "en", record)

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert File.read!(backup) == ""
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a missing original fails and keeps the corrected bytes and record", %{
      video: video,
      path: path,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      corrected = File.read!(path)
      File.rm!(backup)

      assert {:error, :missing_backup} = reset(video)
      assert File.read!(path) == corrected
      assert Manifest.sync(Manifest.read(video), "en") == record
    end

    test "a mismatched original fails closed", %{video: video, path: path, backup: backup} do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      corrected = File.read!(path)
      File.write!(backup, "1\n00:00:01,000 --> 00:00:02,000\nWrong\n\n")

      assert {:error, :backup_mismatch} = reset(video)
      assert {:error, :backup_mismatch} = manual(video, 2_000)
      assert File.read!(path) == corrected
      assert Manifest.sync(Manifest.read(video), "en") == record
    end

    test "a newer external edit is refused", %{video: video, path: path, original: original} do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      external = String.replace(original, "One", "External edit")
      File.write!(path, external)

      assert {:error, :externally_modified} = reset(video)
      assert File.read!(path) == external
      assert SidecarTransaction.stranded_backup?(path)
      assert Manifest.sync(Manifest.read(video), "en") == record
    end

    # Issue #1127: the restore's exchange put the original back; a step after it went
    # unacknowledged.
    for failure <- [:close, :exchange, :discard] do
      test "a reset whose restore went unacknowledged (#{failure}) finishes on the first call", %{
        video: video,
        path: path,
        original: original,
        backup: backup
      } do
        assert {:ok, :corrected, _} = manual(video, 1_000)

        {result, log} = unacknowledged_write(unquote(failure), path, fn -> reset(video) end)

        assert :ok = result
        assert_reset_finished(video, path, original, backup)
        assert_unacknowledged_warning(log, path, unacknowledged_detail(unquote(failure)))
      end
    end

    test "a journaled reset whose restore went unacknowledged finishes on the first call", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      assert :ok = Manifest.begin_reset_cleanup(video, "en", record)

      {result, log} = unacknowledged_write(:close, path, fn -> reset(video) end)

      assert :ok = result
      assert_reset_finished(video, path, original, backup)
      assert_unacknowledged_warning(log, path, unacknowledged_detail(:close))
    end

    test "reconcile finishes a reset journal whose restore went unacknowledged", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      assert :ok = Manifest.begin_reset_cleanup(video, "en", record)

      {result, log} = unacknowledged_write(:close, path, fn -> reconcile(video) end)

      assert :ok = result
      assert_reset_finished(video, path, original, backup)
      assert_unacknowledged_warning(log, path, unacknowledged_detail(:close))
    end

    test "a reset whose restore exchange failed keeps the corrected bytes and journal", %{
      video: video,
      path: path,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      corrected = File.read!(path)

      fail_once(%{
        operation: :exchange,
        source_contains: ".cinder-subtitle-sync-write-",
        reason: :eio
      })

      {result, log} = with_log(fn -> reset(video) end)

      assert {:error, :eio} = result
      assert File.read!(path) == corrected
      assert File.exists?(backup)
      assert Manifest.sync(Manifest.read(video), "en") == record
      assert reset_journal(video) == record
      refute log =~ "subtitle publication unacknowledged"
    end
  end

  # Issue #795: `reconcile/2` sweeps the workspace tombstones earlier corrections and resets left
  # in the video's folder, once they are an hour old and no record there names them.
  describe "reconcile/2 retiring workspaces" do
    test "retires an old empty tombstone no record names", %{video: video, path: path} do
      workspace = plant_workspace!(path, %{@staged => ""})
      age!(workspace)

      assert :ok = reconcile(video)
      refute File.exists?(workspace)
    end

    test "retires an old workspace with no entry", %{video: video, path: path} do
      workspace = plant_workspace!(path, %{})
      age!(workspace)

      assert :ok = reconcile(video)
      refute File.exists?(workspace)
    end

    test "leaves a workspace whose directory or staged file changed within the hour", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      young = plant_workspace!(path, %{@staged => ""})
      young_empty = plant_workspace!(path, %{})
      young_staged = plant_workspace!(path, %{@staged => ""})
      age!(young_staged)
      File.touch!(Path.join(young_staged, @staged))
      young_directory = plant_workspace!(path, %{@staged => ""})
      age!(young_directory)
      File.touch!(young_directory)
      {young_interrupted, _} = plant_interrupted_disposal!(path, tmp, original)
      {young_shared, _} = plant_interrupted_disposal!(path, tmp, original)
      age!(young_shared)
      File.touch!(Path.join(young_shared, @staged))
      {young_fresh, _} = plant_interrupted_disposal!(path, tmp, original)
      age!(young_fresh)
      File.touch!(Path.join(young_fresh, @tombstone))

      assert :ok = reconcile(video)

      for workspace <- [young, young_empty, young_staged, young_directory],
          do: assert(File.dir?(workspace))

      for workspace <- [young_interrupted, young_shared, young_fresh],
          do: assert(Enum.sort(File.ls!(workspace)) == [@staged, @tombstone])
    end

    test "leaves a workspace a pending record names", %{video: video, path: path} do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      first = File.read!(path)
      assert {:ok, :corrected, %{sync: record}} = manual(video, 2_000)
      id = operation_id()
      named = plant_workspace!(path, %{@staged => ""}, id)
      # The workspace a rollback of the second correction, `AtomicFile.write/3` back to the first
      # one's bytes, would reuse.
      rollback_id =
        SidecarTransaction.AtomicFile.reversal_id(path, record.applied_sha256, digest(first))

      rollback = plant_workspace!(path, %{@staged => ""}, rollback_id)
      unnamed = plant_workspace!(path, %{@staged => ""})
      assert :ok = Manifest.put_sync(video, "en", pending(record, first, id))
      Enum.each([named, rollback, unnamed], &age!/1)

      assert :ok = reconcile(video)
      assert File.read!(Path.join(named, @staged)) == ""
      assert File.read!(Path.join(rollback, @staged)) == ""
      refute File.exists?(unnamed)
    end

    test "leaves a workspace another video's pending record names in the same folder", %{
      video: video,
      path: path
    } do
      other = Path.join(Path.dirname(video), "Other.mkv")
      File.write!(other, String.duplicate("o", 131_072))
      other_path = managed_srt!(other)
      other_original = File.read!(other_path)
      record = record(moviehash!(other), other_original, shifted(other_original))
      id = operation_id()
      assert :ok = Manifest.put_sync(other, "en", pending(record, other_original, id))
      named = plant_workspace!(path, %{@staged => ""}, id)
      unnamed = plant_workspace!(path, %{@staged => ""})
      age!(named)
      age!(unnamed)

      assert :ok = reconcile(video)
      assert File.read!(Path.join(named, @staged)) == ""
      refute File.exists?(unnamed)
    end

    # #1149: bytes Cinder keeps elsewhere in the folder, whichever video's manifest names them.
    test "retires workspaces holding a track's sidecar bytes or its immutable original", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      other = Path.join(Path.dirname(video), "Other.mkv")
      File.write!(other, String.duplicate("o", 131_072))
      other_path = managed_srt!(other)
      File.write!(other_path, "the other video's sidecar")
      current = plant_workspace!(path, %{@staged => corrected})
      kept_original = plant_workspace!(path, %{@staged => original})
      other_current = plant_workspace!(path, %{@staged => "the other video's sidecar"})
      Enum.each([current, kept_original, other_current], &age!/1)

      assert :ok = reconcile(video)
      assert workspaces(path) == []
      assert File.read!(path) == corrected
      assert File.read!(backup) == original
      assert File.read!(other_path) == "the other video's sidecar"
    end

    # #1187: dropping the workspace's name for a file with other names loses no bytes, and a
    # candidate still holds them once those names go.
    test "retires accounted bytes whose staged file has other names, which keep them", %{
      video: video,
      path: path,
      original: original,
      backup: backup,
      tmp_dir: tmp
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      kept_original = plant_workspace!(path, %{@staged => original})
      File.ln!(Path.join(kept_original, @staged), Path.join(tmp, "outside-original"))
      current = plant_workspace!(path, %{@staged => corrected})
      File.ln!(Path.join(current, @staged), Path.join(tmp, "outside-current"))
      three_names = plant_workspace!(path, %{@staged => original})
      File.ln!(Path.join(three_names, @staged), Path.join(tmp, "outside-first"))
      File.ln!(Path.join(three_names, @staged), Path.join(tmp, "outside-second"))
      Enum.each([kept_original, current, three_names], &age!/1)

      {result, log} = with_log(fn -> reconcile(video) end)
      assert :ok = result
      refute log =~ "subtitle workspace kept"
      assert workspaces(path) == []

      for {name, bytes, links} <- [
            {"outside-original", original, 1},
            {"outside-current", corrected, 1},
            {"outside-first", original, 2},
            {"outside-second", original, 2}
          ] do
        assert File.read!(Path.join(tmp, name)) == bytes
        assert File.stat!(Path.join(tmp, name)).links == links
      end

      assert File.read!(path) == corrected
      assert File.read!(backup) == original
    end

    test "leaves workspaces holding bytes nothing in the folder holds, another name or another entry",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      # The same size as the sidecar, other bytes.
      same_size = plant_workspace!(path, %{@staged => shifted(original)})
      other_size = plant_workspace!(path, %{@staged => "bytes nothing holds"})
      two_links = plant_workspace!(path, %{@staged => ""})
      File.ln!(Path.join(two_links, @staged), Path.join(tmp, "outside"))
      # #1187: another name drops no rule but the link count. The same size as the sidecar, so
      # the sweep reads and compares the bytes.
      same_size_two_links = plant_workspace!(path, %{@staged => shifted(original)})
      File.ln!(Path.join(same_size_two_links, @staged), Path.join(tmp, "outside-same-size"))
      extra_entry = plant_workspace!(path, %{@staged => "", "other" => ""})
      accounted_extra_entry = plant_workspace!(path, %{@staged => original, "other" => ""})
      not_an_id = Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-short")
      File.mkdir!(not_an_id)

      kept = [
        same_size,
        other_size,
        two_links,
        same_size_two_links,
        extra_entry,
        accounted_extra_entry,
        not_an_id
      ]

      Enum.each(kept, &age!/1)

      assert :ok = reconcile(video)
      for workspace <- kept, do: assert(File.dir?(workspace))
      assert File.read!(Path.join(same_size, @staged)) == shifted(original)
      assert File.read!(Path.join(other_size, @staged)) == "bytes nothing holds"
      assert File.read!(Path.join(extra_entry, @staged)) == ""
      assert File.read!(Path.join(accounted_extra_entry, @staged)) == original
      assert File.read!(Path.join(same_size_two_links, @staged)) == shifted(original)
      assert File.stat!(Path.join(tmp, "outside")).links == 2
      assert File.stat!(Path.join(tmp, "outside-same-size")).links == 2
    end

    test "leaves accounted bytes a pending record names or that changed within the hour", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      corrected = File.read!(path)
      id = operation_id()
      named = plant_workspace!(path, %{@staged => corrected}, id)
      assert :ok = Manifest.put_sync(video, "en", pending(record, original, id))
      age!(named)
      young = plant_workspace!(path, %{@staged => corrected})
      young_staged = plant_workspace!(path, %{@staged => original})
      age!(young_staged)
      File.touch!(Path.join(young_staged, @staged))
      young_directory = plant_workspace!(path, %{@staged => original})
      age!(young_directory)
      File.touch!(young_directory)

      assert :ok = reconcile(video)
      assert File.read!(Path.join(named, @staged)) == corrected
      assert File.read!(Path.join(young, @staged)) == corrected
      assert File.read!(Path.join(young_staged, @staged)) == original
      assert File.read!(Path.join(young_directory, @staged)) == original
    end

    # #1187: a staged file with another name goes only once it has not changed for the hour too.
    test "leaves accounted bytes with another name that changed within the hour", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      young = plant_workspace!(path, %{@staged => original})
      young_staged = plant_workspace!(path, %{@staged => original})
      young_directory = plant_workspace!(path, %{@staged => original})

      for workspace <- [young, young_staged, young_directory],
          do: File.ln!(Path.join(workspace, @staged), Path.join(tmp, Path.basename(workspace)))

      age!(young_staged)
      File.touch!(Path.join(young_staged, @staged))
      age!(young_directory)
      File.touch!(young_directory)

      assert :ok = reconcile(video)

      for workspace <- [young, young_staged, young_directory] do
        assert File.ls!(workspace) == [@staged]
        assert File.stat!(Path.join(tmp, Path.basename(workspace))).links == 2
      end
    end

    test "a sweep reads no candidate before it holds a workspace with bytes", %{
      video: video,
      path: path
    } do
      tombstone = plant_workspace!(path, %{@staged => ""})
      age!(tombstone)

      # Armed by hand, without `fail_once/1`'s exit check: the first part needs it never to fire.
      lstat_failure = %{
        operation: :lstat,
        source_contains: Path.basename(path),
        reason: :lstat_forbidden,
        once: true
      }

      Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
      Application.put_env(:cinder, :filesystem_failure, lstat_failure)

      assert :ok = reconcile(video)
      refute File.exists?(tombstone)
      assert Application.get_env(:cinder, :filesystem_failure) == lstat_failure

      # A workspace holding bytes reads the candidates' metadata, which fires the failure.
      bytes = plant_workspace!(path, %{@staged => File.read!(path)})
      age!(bytes)
      assert :ok = reconcile(video)
      assert Application.get_env(:cinder, :filesystem_failure) == nil
    end

    test "a sweep never opens a staged file whose size no candidate has", %{
      video: video,
      path: path
    } do
      workspace = plant_workspace!(path, %{@staged => "no candidate has this size"})
      age!(workspace)

      # Stays armed: any open of that staged file fails.
      Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :open_bound,
        source_contains: Path.join(Path.basename(workspace), @staged),
        reason: :open_forbidden
      })

      {result, log} = with_log(fn -> reconcile(video) end)
      assert :ok = result
      refute log =~ "subtitle workspace kept"
      assert %{operation: :open_bound} = Application.get_env(:cinder, :filesystem_failure)
      assert File.read!(Path.join(workspace, @staged)) == "no candidate has this size"
    end

    test "a sweep leaves accounted bytes whose staged name changed after it held them", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      workspace = plant_workspace!(path, %{@staged => original})
      age!(workspace)
      use_barrier(%{operation: :open_bound, phase: :before, contains: @staged, once: false})

      log =
        capture_log(fn ->
          task = Task.async(fn -> reconcile(video) end)
          # The first open holds the staged file, the second checks its name before the removal.
          assert_receive {:filesystem_barrier, pid, ref, :open_bound, _staged},
                         DiskTask.timeout_ms()

          send(pid, {ref, :continue})

          assert_receive {:filesystem_barrier, ^pid, ref, :open_bound, staged},
                         DiskTask.timeout_ms()

          newer = Path.join(tmp, "newer")
          File.write!(newer, "newer")
          File.rename!(newer, staged)
          Application.delete_env(:cinder, :filesystem_barrier)
          send(pid, {ref, :continue})
          assert :ok = DiskTask.await(task)
        end)

      assert File.read!(Path.join(workspace, @staged)) == "newer"
      assert log =~ "subtitle workspace kept at #{workspace}: :concurrent_change"
    end

    # #1187: the removal re-checks the held file's age through its descriptor, so a file with
    # another name that changed after the classification stays.
    test "a sweep leaves accounted bytes with another name that changed before it held them", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      workspace = plant_workspace!(path, %{@staged => original})
      outside = Path.join(tmp, "outside")
      File.ln!(Path.join(workspace, @staged), outside)
      age!(workspace)
      use_barrier(%{operation: :open_bound, phase: :before, contains: @staged})

      log =
        capture_log(fn ->
          task = Task.async(fn -> reconcile(video) end)

          assert_receive {:filesystem_barrier, pid, ref, :open_bound, staged},
                         DiskTask.timeout_ms()

          File.touch!(staged)
          send(pid, {ref, :continue})
          assert :ok = DiskTask.await(task)
        end)

      assert File.ls!(workspace) == [@staged]
      assert File.read!(outside) == original
      assert File.stat!(outside).links == 2
      assert log =~ "subtitle workspace kept at #{workspace}: :recent"
    end

    # #1187: the removal re-checks no link count, so a name gained after the classification keeps
    # the bytes.
    test "a sweep retires accounted bytes that gained a name before it held them, and that name keeps them",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      workspace = plant_workspace!(path, %{@staged => original})
      age!(workspace)
      use_barrier(%{operation: :open_bound, phase: :before, contains: @staged})

      log =
        capture_log(fn ->
          task = Task.async(fn -> reconcile(video) end)

          assert_receive {:filesystem_barrier, pid, ref, :open_bound, staged},
                         DiskTask.timeout_ms()

          File.ln!(staged, Path.join(tmp, "second-name"))
          send(pid, {ref, :continue})
          assert :ok = DiskTask.await(task)
        end)

      refute File.exists?(workspace)
      assert File.read!(Path.join(tmp, "second-name")) == original
      assert File.stat!(Path.join(tmp, "second-name")).links == 1
      refute log =~ "subtitle workspace kept"
    end

    # #1149: a manifest in the folder that cannot be read in full may name any of its workspaces.
    test "removes nothing in a folder with a manifest it cannot read, and says so once", %{
      video: video,
      path: path
    } do
      {other, named} = other_video_pending_workspace!(video, path)
      unnamed = plant_workspace!(path, %{@staged => ""})
      accounted = plant_workspace!(path, %{@staged => File.read!(path)})
      Enum.each([named, unnamed, accounted], &age!/1)

      fail_once(%{
        operation: :read,
        source_contains: Path.basename(Manifest.path(other)),
        reason: :eacces
      })

      {result, log} = with_log(fn -> reconcile(video) end)
      assert :ok = result
      for workspace <- [named, unnamed, accounted], do: assert(File.dir?(workspace))

      assert [line] = warning_lines(log)
      assert line =~ "subtitle workspaces not swept in #{Path.dirname(path)}: "
      assert line =~ inspect({Manifest.path(other), :eacces})
    end

    # #1187: the fail-closed rule holds for a staged file with another name too.
    for {name, breakage} <- [
          {"it cannot read", :unreadable},
          {"it cannot decode", :malformed},
          {"holding an invalid sync record", :invalid_sync},
          {"holding an invalid reset journal", :invalid_reset_journal},
          {"holding an invalid replacement journal", :invalid_replacement_journal},
          {"holding a record and no file", :without_file}
        ] do
      test "leaves accounted bytes with another name in a folder with a manifest #{name}", %{
        video: video,
        path: path,
        tmp_dir: tmp
      } do
        {other, named} = other_video_pending_workspace!(video, path)
        accounted = plant_workspace!(path, %{@staged => File.read!(path)})
        File.ln!(Path.join(accounted, @staged), Path.join(tmp, "outside"))
        Enum.each([named, accounted], &age!/1)
        break_manifest!(other, unquote(breakage))

        {result, log} = with_log(fn -> reconcile(video) end)
        assert :ok = result
        assert File.ls!(accounted) == [@staged]
        assert File.stat!(Path.join(tmp, "outside")).links == 2
        assert [line] = warning_lines(log)
        assert line =~ "subtitle workspaces not swept in #{Path.dirname(path)}: "
      end
    end

    test "removes nothing in a folder with malformed manifests, and says so once", %{
      video: video,
      path: path
    } do
      {other, named} = other_video_pending_workspace!(video, path)
      third = Path.join(Path.dirname(video), "Third.mkv")
      File.write!(Manifest.path(other), "{not json")
      File.write!(Manifest.path(third), "[]")
      unnamed = plant_workspace!(path, %{@staged => ""})
      Enum.each([named, unnamed], &age!/1)

      {result, log} = with_log(fn -> reconcile(video) end)
      assert :ok = result
      for workspace <- [named, unnamed], do: assert(File.dir?(workspace))

      assert [line] = warning_lines(log)
      assert line =~ "subtitle workspaces not swept in #{Path.dirname(path)}: "
      assert line =~ ":malformed"
    end

    for {name, track_change} <- [
          {"an invalid sync record", :invalid_sync},
          {"an invalid reset journal", :invalid_reset_journal},
          {"an invalid replacement journal", :invalid_replacement_journal},
          {"a record and no file", :without_file}
        ] do
      test "removes nothing in a folder whose manifest holds #{name}", %{
        video: video,
        path: path
      } do
        {other, named} = other_video_pending_workspace!(video, path)
        edit_manifest_track!(other, "en", unquote(track_change))
        unnamed = plant_workspace!(path, %{@staged => ""})
        Enum.each([named, unnamed], &age!/1)

        {result, log} = with_log(fn -> reconcile(video) end)
        assert :ok = result
        for workspace <- [named, unnamed], do: assert(File.dir?(workspace))
        assert [line] = warning_lines(log)
        assert line =~ "subtitle workspaces not swept in #{Path.dirname(path)}: "
        assert line =~ inspect(Manifest.path(other))
      end
    end

    # #1131: the two entries a correction of a hardlinked sidecar leaves when killed between
    # creating the fresh tombstone and renaming it over the staged name.
    test "retires an interrupted disposal and keeps the download's inode as it was", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      {workspace, download} = plant_interrupted_disposal!(path, tmp, original)
      age!(workspace)
      before = File.stat!(download)

      # Stays armed: a `discard_bound` on the staged name would empty the download's inode.
      Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :discard_bound,
        source_contains: @staged,
        reason: :discard_forbidden
      })

      assert :ok = reconcile(video)
      refute File.exists?(workspace)
      assert %{operation: :discard_bound} = Application.get_env(:cinder, :filesystem_failure)
      assert File.read!(download) == original
      assert %{links: 1} = after_sweep = File.stat!(download)

      assert Map.take(after_sweep, [:inode, :major_device, :size, :mtime]) ==
               Map.take(before, [:inode, :major_device, :size, :mtime])
    end

    test "a sweep never renames the fresh tombstone over a staged name that changed", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      {workspace, download} = plant_interrupted_disposal!(path, tmp, original)
      age!(workspace)
      use_barrier(%{operation: :open_bound, phase: :before, contains: @staged, once: false})

      log =
        capture_log(fn ->
          task = Task.async(fn -> reconcile(video) end)
          # The first open holds the staged file, the second checks its name before the rename.
          assert_receive {:filesystem_barrier, pid, ref, :open_bound, _staged},
                         DiskTask.timeout_ms()

          send(pid, {ref, :continue})

          assert_receive {:filesystem_barrier, ^pid, ref, :open_bound, staged},
                         DiskTask.timeout_ms()

          newer = Path.join(tmp, "newer")
          File.write!(newer, "newer")
          File.rename!(newer, staged)
          Application.delete_env(:cinder, :filesystem_barrier)
          send(pid, {ref, :continue})
          assert :ok = DiskTask.await(task)
        end)

      assert File.read!(Path.join(workspace, @staged)) == "newer"
      assert_fresh_tombstone(Path.join(workspace, @tombstone))
      assert File.read!(download) == original
      assert log =~ "subtitle workspace kept at #{workspace}: :concurrent_change"
    end

    test "leaves an interrupted disposal whose entries do not match", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      {tombstone_bytes, _} =
        plant_interrupted_disposal!(path, tmp, original, %{@tombstone => "bytes"})

      {tombstone_two_links, _} = plant_interrupted_disposal!(path, tmp, original)

      File.ln!(
        Path.join(tombstone_two_links, @tombstone),
        Path.join(tmp, "tombstone-elsewhere")
      )

      {third_entry, _} = plant_interrupted_disposal!(path, tmp, original, %{"other" => ""})
      single_link = plant_workspace!(path, %{@staged => original, @tombstone => ""})
      kept = [tombstone_bytes, tombstone_two_links, third_entry, single_link]
      Enum.each(kept, &age!/1)

      assert :ok = reconcile(video)

      for workspace <- kept do
        assert File.read!(Path.join(workspace, @staged)) == original
        assert File.exists?(Path.join(workspace, @tombstone))
      end

      for {workspace, links} <- [
            {tombstone_bytes, 2},
            {tombstone_two_links, 2},
            {third_entry, 2},
            {single_link, 1}
          ],
          do: assert(File.stat!(Path.join(workspace, @staged)).links == links)

      assert File.read!(Path.join(tombstone_bytes, @tombstone)) == "bytes"
      assert File.stat!(Path.join(tmp, "tombstone-elsewhere")).links == 2
      assert File.exists?(Path.join(third_entry, "other"))
    end

    # What each kill leaves: every entry with whether it is empty and its link count.
    for {step, barrier, left} <- [
          {"holding the fresh tombstone",
           %{operation: :open_bound, phase: :before, contains: @tombstone},
           %{@staged => {false, 2}, @tombstone => {true, 1}}},
          {"renaming the fresh tombstone", %{operation: :rename, contains: @staged},
           %{@staged => {true, 1}}},
          {"removing the staged name", %{operation: :rm, contains: @staged}, %{}}
        ] do
      test "a sweep of an interrupted disposal killed after #{step} is finished later", %{
        video: video,
        path: path,
        original: original,
        tmp_dir: tmp
      } do
        {workspace, download} = plant_interrupted_disposal!(path, tmp, original)
        age!(workspace)
        use_barrier(unquote(Macro.escape(barrier)))
        kill_at_barrier(fn -> reconcile(video) end, unquote(barrier.operation))
        Application.put_env(:cinder, :filesystem, Disk)

        entries =
          Map.new(File.ls!(workspace), fn name ->
            entry = Path.join(workspace, name)
            {name, {File.read!(entry) == "", File.stat!(entry).links}}
          end)

        assert entries == unquote(Macro.escape(left))
        assert File.read!(download) == original

        age!(workspace)
        assert :ok = reconcile(video)
        refute File.exists?(workspace)
        assert File.read!(download) == original
        assert File.stat!(download).links == 1
      end
    end

    test "leaves the tombstone a reset of the current record would reuse", %{
      video: video,
      path: path
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert :ok = reset(video)
      assert [reversal] = workspaces(path)
      assert {:ok, :corrected, _} = manual(video, 1_000)
      age!(reversal)

      assert :ok = reconcile(video)
      assert [^reversal] = workspaces(path)

      assert :ok = reset(video)
      age!(reversal)
      assert :ok = reconcile(video)
      assert workspaces(path) == []
    end

    test "a reset creates a fresh workspace once a sweep retired its tombstone", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert :ok = reset(video)
      assert [reversal] = workspaces(path)
      age!(reversal)
      assert :ok = reconcile(video)
      assert workspaces(path) == []

      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert :ok = reset(video)
      assert File.read!(path) == original
      assert [^reversal] = workspaces(path)
      assert_fresh_tombstone(Path.join(reversal, @staged))
    end

    test "a sweep leaves a staged name that changed after it held the tombstone", %{
      video: video,
      path: path,
      tmp_dir: tmp
    } do
      workspace = plant_workspace!(path, %{@staged => ""})
      age!(workspace)
      use_barrier(%{operation: :open_bound, phase: :before, contains: @staged, once: false})

      log =
        capture_log(fn ->
          task = Task.async(fn -> reconcile(video) end)
          # The first open holds the tombstone, the second checks its name before the removal.
          assert_receive {:filesystem_barrier, pid, ref, :open_bound, _staged},
                         DiskTask.timeout_ms()

          send(pid, {ref, :continue})

          assert_receive {:filesystem_barrier, ^pid, ref, :open_bound, staged},
                         DiskTask.timeout_ms()

          newer = Path.join(tmp, "newer")
          File.write!(newer, "newer")
          File.rename!(newer, staged)
          Application.delete_env(:cinder, :filesystem_barrier)
          send(pid, {ref, :continue})
          assert :ok = DiskTask.await(task)
        end)

      assert File.read!(Path.join(workspace, @staged)) == "newer"
      assert log =~ "subtitle workspace kept at #{workspace}: :concurrent_change"
    end

    test "a reset and a correction go on after a sweep killed in their reversal's workspace", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert :ok = reset(video)
      assert [reversal] = workspaces(path)
      age!(reversal)
      use_barrier(%{operation: :rm, contains: @staged})
      kill_at_barrier(fn -> reconcile(video) end, :rm)
      assert File.ls!(reversal) == []
      Application.put_env(:cinder, :filesystem, Disk)

      # The same correction names that reversal again, so the sweep keeps its empty directory.
      assert {:ok, :corrected, _} = manual(video, 1_000)
      age!(reversal)
      assert :ok = reconcile(video)
      assert File.ls!(reversal) == []

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert [^reversal] = workspaces(path)
      assert_fresh_tombstone(Path.join(reversal, @staged))
      assert {:ok, :corrected, _} = manual(video, 2_000)
      assert File.read!(path) =~ "00:00:03,000"
    end

    test "a reset replaces a workspace with no entry at its own name", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)

      id =
        SidecarTransaction.AtomicFile.reversal_id(
          path,
          record.applied_sha256,
          record.source_sha256
        )

      workspace = plant_workspace!(path, %{}, id)

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert [^workspace] = workspaces(path)
      assert_fresh_tombstone(Path.join(workspace, @staged))
    end

    test "a sweep killed before removing the directory is finished by a later one", %{
      video: video,
      path: path
    } do
      workspace = plant_workspace!(path, %{@staged => ""})
      age!(workspace)
      use_barrier(%{operation: :rm, contains: @staged})
      kill_at_barrier(fn -> reconcile(video) end, :rm)
      assert File.ls!(workspace) == []

      Application.put_env(:cinder, :filesystem, Disk)
      assert :ok = reconcile(video)
      assert File.dir?(workspace)

      age!(workspace)
      assert :ok = reconcile(video)
      refute File.exists?(workspace)
    end

    test "a tombstone that fails to retire is logged and reconcile still succeeds", %{
      video: video,
      path: path
    } do
      workspace = plant_workspace!(path, %{@staged => ""})
      age!(workspace)
      fail_once(%{operation: :rm, source_contains: @staged, reason: :eio})

      {result, log} = with_log(fn -> reconcile(video) end)

      assert :ok = result
      assert File.dir?(workspace)
      assert log =~ "subtitle workspace kept at #{workspace}: :eio"
    end

    test "stops after its limit and leaves the rest for the next sweep", %{path: path} do
      planted = for _ <- 1..3, do: plant_workspace!(path, %{@staged => ""})
      Enum.each(planted, &age!/1)
      directory = Path.dirname(path)

      records = fn _names -> {:ok, [], []} end
      assert 2 = SidecarTransaction.Workspace.sweep(directory, records, limit: 2)
      assert [_left] = workspaces(path)
      assert 1 = SidecarTransaction.Workspace.sweep(directory, records, limit: 2)
      assert workspaces(path) == []
    end

    # #1187: the limit and the failure log hold for accounted bytes with another name too.
    test "stops after its limit, and logs and keeps a removal that fails, for accounted bytes with another name",
         %{path: path, tmp_dir: tmp} do
      bytes = File.read!(path)

      planted =
        for index <- 1..3 do
          workspace = plant_workspace!(path, %{@staged => bytes})
          File.ln!(Path.join(workspace, @staged), Path.join(tmp, "outside-#{index}"))
          age!(workspace)
          workspace
        end

      directory = Path.dirname(path)
      records = fn _names -> {:ok, [], [path]} end
      assert 2 = SidecarTransaction.Workspace.sweep(directory, records, limit: 2)
      assert [left] = workspaces(path)
      assert left in planted
      fail_once(%{operation: :rm, source_contains: @staged, reason: :eio})

      {removed, log} =
        with_log(fn -> SidecarTransaction.Workspace.sweep(directory, records, limit: 2) end)

      assert removed == 0
      assert File.ls!(left) == [@staged]
      assert log =~ "subtitle workspace kept at #{left}: :eio"
      assert 1 = SidecarTransaction.Workspace.sweep(directory, records, limit: 2)
      assert workspaces(path) == []

      for index <- 1..3 do
        assert File.read!(Path.join(tmp, "outside-#{index}")) == bytes
        assert File.stat!(Path.join(tmp, "outside-#{index}")).links == 1
      end
    end
  end

  describe "AtomicFile.write/3" do
    test "a descriptor that fails to close after the exchange reports the bytes published", %{
      path: path,
      original: original
    } do
      corrected = shifted(original)

      {result, _log} =
        fail_close_after_exchange(path, [:staged], fn ->
          SidecarTransaction.AtomicFile.write(path, corrected, original)
        end)

      assert {:error, {:publication_committed, {:descriptor_close_failed, :eio}}} = result
      assert File.read!(path) == corrected
    end

    test "a target that fails to open right after the exchange reports the bytes published", %{
      path: path,
      original: original
    } do
      corrected = shifted(original)

      assert {:error, {:publication_committed, :published_target_unverified}} =
               fail_target_open_after_exchange(path, fn ->
                 SidecarTransaction.AtomicFile.write(path, corrected, original)
               end)

      assert File.read!(path) == corrected
    end

    # #1284: `write/3`'s callers keep a journal or record naming the reversal workspace while they
    # report the error, and their next pass settles by the bytes.
    test "a target and staged name that fail to open right after the exchange report a concurrent change",
         %{path: path, original: original} do
      corrected = shifted(original)

      assert {:error, :concurrent_change} =
               fail_names_open_after_exchange(path, fn ->
                 SidecarTransaction.AtomicFile.write(path, corrected, original)
               end)

      assert File.read!(path) == corrected
    end

    # #1322: `write/3` keeps the failed rollback as its result, as it does after #1284.
    test "a staged name that fails to open twice right after the exchange reports a failed rollback",
         %{path: path, original: original} do
      corrected = shifted(original)

      assert {:error, @rollback_failed} =
               fail_staged_open_after_exchange(
                 fn -> SidecarTransaction.AtomicFile.write(path, corrected, original) end,
                 [staged_open_failure()]
               )

      assert File.read!(path) == corrected
    end
  end

  describe "AtomicFile.write/4" do
    # #1322: `recover/4`'s staged resume settles a failed rollback by the target's bytes too.
    test "a resumed write whose staged name fails to open twice right after the exchange reports the bytes published",
         %{path: path, original: original} do
      corrected = shifted(original)
      id = operation_id()
      plant_workspace!(path, %{@staged => corrected}, id)

      assert {:error, {:publication_committed, @rollback_kept}} =
               fail_staged_open_after_exchange(
                 fn ->
                   SidecarTransaction.AtomicFile.recover(
                     path,
                     id,
                     digest(original),
                     digest(corrected)
                   )
                 end,
                 [staged_open_failure()]
               )

      assert File.read!(path) == corrected
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == original
    end

    # #1284: `recover/4`'s staged resume reaches `write/4` through the workspace it reuses.
    test "a resumed write whose two names fail to open right after the exchange reports the bytes published",
         %{path: path, original: original} do
      corrected = shifted(original)
      id = operation_id()
      plant_workspace!(path, %{@staged => corrected}, id)

      assert {:error, {:publication_committed, @names_unverified}} =
               fail_names_open_after_exchange(path, fn ->
                 SidecarTransaction.AtomicFile.recover(
                   path,
                   id,
                   digest(original),
                   digest(corrected)
                 )
               end)

      assert File.read!(path) == corrected
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == original
    end

    # #1284: a workspace with no staged name, such as a crash between its mkdir and its create
    # leaves, is replaced with a fresh one before the write goes on.
    test "a write into an entryless workspace whose two names fail to open right after the exchange reports the bytes published",
         %{path: path, original: original} do
      corrected = shifted(original)
      id = operation_id()
      plant_workspace!(path, %{}, id)

      assert {:error, {:publication_committed, @names_unverified}} =
               fail_names_open_after_exchange(path, fn ->
                 SidecarTransaction.AtomicFile.write(path, corrected, original, id)
               end)

      assert File.read!(path) == corrected
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == original
    end
  end

  describe "remove/3" do
    test "removes the sidecar and its track", %{video: video, path: path} do
      content = "1\n00:00:01,000 --> 00:00:02,000\nEmbedded\n\n"
      assert :ok = replace_as(video, content, "embedded")
      assert :ok = Manifest.put(video, moviehash!(video), "de", "translated")

      assert :ok = SidecarTransaction.remove(sidecar(video), content, "embedded")
      refute File.exists?(path)
      assert %{tracks: %{"de" => %{origin: "translated"}} = tracks} = Manifest.read(video)
      refute Map.has_key?(tracks, "en")
    end

    test "removes nothing for a track of another origin or none", %{
      video: video,
      path: path,
      original: original
    } do
      entry = Manifest.read(video).tracks["en"]

      assert {:error, {:origin, "opensubtitles_hash"}} =
               SidecarTransaction.remove(sidecar(video), original, "embedded")

      assert {:error, :unknown_track} =
               SidecarTransaction.remove(%{sidecar(video) | language: "fr"}, original, "embedded")

      assert File.read!(path) == original
      assert Manifest.read(video).tracks["en"] == entry
    end

    test "removes nothing when the sidecar changed", %{video: video, path: path} do
      content = "1\n00:00:01,000 --> 00:00:02,000\nEmbedded\n\n"
      assert :ok = replace_as(video, content, "embedded")
      entry = Manifest.read(video).tracks["en"]
      File.write!(path, "1\n00:00:01,000 --> 00:00:02,000\nEdited\n\n")

      assert {:error, :concurrent_change} =
               SidecarTransaction.remove(sidecar(video), content, "embedded")

      assert File.read!(path) == "1\n00:00:01,000 --> 00:00:02,000\nEdited\n\n"
      assert Manifest.read(video).tracks["en"] == entry
    end

    # An embedded sidecar that replaced a corrected one carries the backup tombstone forward. Its
    # track stays once the sidecar is gone, so the next sidecar in the language carries the
    # tombstone again and its own correction reactivates the container.
    test "keeps a backup tombstone a later correction reactivates", %{
      video: video,
      path: path,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      content = "1\n00:00:01,000 --> 00:00:02,000\nEmbedded\n\n"
      assert :ok = replace_as(video, content, "embedded")
      assert File.read!(backup) == ""
      assert %{backup_tombstone: tombstone} = entry = Manifest.read(video).tracks["en"]

      assert :ok = SidecarTransaction.remove(sidecar(video), content, "embedded")
      refute File.exists?(path)
      assert Manifest.read(video).tracks["en"] == entry

      replacement = "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n"
      assert :ok = replace(video, replacement)
      assert %{backup_tombstone: ^tombstone} = Manifest.read(video).tracks["en"]
      assert {:ok, :corrected, _} = manual(video, 500)
      assert File.read!(backup) == replacement
    end
  end

  test "only the transaction writes the manifest's record, journal and tombstone fields" do
    writers =
      ~r/Manifest\.(put_sync|clear_sync|begin_replacement_cleanup|clear_replacement_cleanup|begin_reset_cleanup|finish_reset_cleanup|put_backup_tombstone)\(/

    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(&1, "lib/cinder/subtitles/sidecar_transaction"))
      |> Enum.filter(&(File.read!(&1) =~ writers))

    assert offenders == []

    # `Manifest.put/7` opens the replacement cleanup journal; `put/5` and `put/6` do not.
    journal_puts =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(&1, "lib/cinder/subtitles/sidecar_transaction"))
      |> Enum.flat_map(&manifest_put_arities/1)

    refute 7 in journal_puts
  end

  defp manifest_put_arities(file) do
    {_ast, arities} =
      file
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, aliases}, :put]}, _, args} = node, acc
        when is_list(args) ->
          if List.last(aliases) == :Manifest, do: {node, [length(args) | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    arities
  end
end
