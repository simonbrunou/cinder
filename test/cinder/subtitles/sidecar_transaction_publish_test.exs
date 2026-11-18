defmodule Cinder.Subtitles.SidecarTransactionPublishTest do
  # Drives the sidecar replacement transaction directly, on real temp directories through the
  # `Cinder.Library.Filesystem` seam: no engine, no media probe. Crashes are a killed process at a
  # `Cinder.Test.BarrierFilesystem` barrier, or a pending record written by hand. This module
  # covers `publish/4`, also on a mergerfs library; `Cinder.Test.SidecarTransactionCase` holds the
  # setup and helpers it shares with its sibling modules (#1474).
  use Cinder.DataCase, async: false
  use Cinder.Test.SidecarTransactionCase

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1, fail_in_order: 1]
  import ExUnit.CaptureLog

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Subtitles.{Manifest, Moviehash, SidecarTransaction}
  alias Cinder.Subtitles.Sync.Timing
  alias Cinder.Test.DiskTask

  # Delegates every operation to the real `Disk` filesystem, except it reports each
  # `write_bound/2` call back to the owning test process — so a test can pin "the reclaim path
  # restages through the syncing primitive" without being able to observe an fsync directly.
  defmodule SpyWriteBoundFilesystem do
    @moduledoc false
    @behaviour Cinder.Library.Filesystem

    alias Cinder.Library.Filesystem.Disk

    @impl true
    defdelegate dir?(path), to: Disk
    @impl true
    defdelegate ls(path), to: Disk
    @impl true
    defdelegate find_files(path), to: Disk
    @impl true
    defdelegate find_files(path, opts), to: Disk
    @impl true
    defdelegate mkdir_p(path), to: Disk
    @impl true
    defdelegate mkdir_exclusive(path, mode), to: Disk
    @impl true
    defdelegate ln(source, dest), to: Disk
    @impl true
    defdelegate cp(source, dest), to: Disk
    @impl true
    defdelegate cp_exclusive(source, dest, on_create), to: Disk
    @impl true
    defdelegate lstat(path), to: Disk
    @impl true
    defdelegate rename(source, dest), to: Disk
    @impl true
    defdelegate rename_exclusive(source, dest), to: Disk
    @impl true
    defdelegate rm(path), to: Disk
    @impl true
    defdelegate rmdir(path), to: Disk
    @impl true
    defdelegate rm_rf(path), to: Disk
    @impl true
    defdelegate read(path), to: Disk
    @impl true
    defdelegate read_prefix(path, bytes), to: Disk
    @impl true
    defdelegate write(path, content), to: Disk
    @impl true
    defdelegate chmod(path, mode), to: Disk
    @impl true
    defdelegate write_exclusive(path, content), to: Disk
    @impl true
    defdelegate open_bound(path, modes), to: Disk
    @impl true
    defdelegate create_bound(path, content), to: Disk
    @impl true
    defdelegate close_bound(bound), to: Disk
    @impl true
    defdelegate discard_bound(bound), to: Disk
    @impl true
    defdelegate exchange(source, dest), to: Disk
    @impl true
    defdelegate moviehash_data(path), to: Disk
    @impl true
    defdelegate backing_identity(path), to: Disk

    @impl true
    def write_bound(bound, content) do
      send(self(), {:write_bound, bound.path})
      Disk.write_bound(bound, content)
    end
  end

  describe "publish/4" do
    test "a correction keeps the immutable original and records the new timing", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      corrected = shifted(original)
      record = record(moviehash!(video), original, corrected)

      assert {:ok, :corrected, %{sync: ^record}} =
               SidecarTransaction.publish(sidecar(video), original, corrected, record)

      assert File.read!(path) == corrected
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == record
    end

    test "every correction starts from the one immutable original, which a reset restores", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert File.read!(backup) == original
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"

      assert {:ok, :corrected, _} = manual(video, 2_000)
      assert File.read!(backup) == original
      assert File.read!(path) =~ "00:00:03,000"

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert File.read!(backup) == ""
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "unchanged bytes record the alignment without rewriting or keeping an original", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      before = File.stat!(path).mtime
      record = record(moviehash!(video), original, original, %{offset_ms: 0})

      assert {:ok, :aligned, _} =
               SidecarTransaction.publish(sidecar(video), original, original, record)

      assert File.read!(path) == original
      assert File.stat!(path).mtime == before
      refute File.exists?(backup)
      assert Manifest.sync(Manifest.read(video), "en") == record
    end

    test "a review record is written without touching the bytes", %{
      video: video,
      original: original,
      backup: backup
    } do
      record = record(moviehash!(video), original, original, %{status: "review", reason: "low"})

      assert {:ok, :review, %{sync: ^record}} =
               SidecarTransaction.publish(sidecar(video), original, original, record)

      refute File.exists?(backup)
    end

    test "a record is refused when the video changed after the caller hashed it", %{
      video: video,
      path: path,
      original: original
    } do
      use_barrier(%{operation: :moviehash_data, contains: Path.basename(video)})

      # The caller hashes through the seam, so the barrier pauses it right after its own hash.
      task =
        Task.async(fn ->
          {:ok, moviehash} = Moviehash.of_file(video)
          manual(video, 0, moviehash)
        end)

      assert_receive {:filesystem_barrier, pid, ref, :moviehash_data, ^video},
                     DiskTask.timeout_ms()

      File.write!(video, @changed_video)
      send(pid, {ref, :continue})

      assert {:error, :video_changed} = DiskTask.await(task)
      assert File.read!(path) == original
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "the pending record is written before the bytes are exchanged", %{
      video: video,
      backup: backup,
      original: original
    } do
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()

      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
      assert File.read!(backup) == original

      send(pid, {ref, :continue})
      assert {:ok, :corrected, _} = DiskTask.await(task)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
    end

    test "bytes edited just before the exchange are left alone", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      external = String.replace(original, "One", "External edit")
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      File.write!(path, external)
      send(pid, {ref, :continue})

      assert {:error, :concurrent_change} = DiskTask.await(task)
      assert File.read!(path) == external
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a sidecar atomically replaced just before the exchange is restored", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      external = String.replace(original, "One", "Atomic replacement")
      replacement = path <> ".replacement"
      File.write!(replacement, external)

      use_barrier(%{
        operation: :exchange,
        phase: :before,
        contains: ".cinder-subtitle-sync-write-"
      })

      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      File.rename!(replacement, path)
      send(pid, {ref, :continue})

      assert {:error, :concurrent_change} = DiskTask.await(task)
      assert File.read!(path) == external
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a staged descriptor that fails to close after the exchange keeps the pending record", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      {result, _log} = fail_close_after_exchange(path, [:staged], fn -> manual(video, 1_000) end)

      assert {:error, {:publication_committed, {:descriptor_close_failed, :eio}}} = result
      assert_unacknowledged_correction(video, path, original, backup)
    end

    test "staged and directory descriptors that both fail to close keep the pending record", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      {result, _log} =
        fail_close_after_exchange(path, [:staged, :directory], fn -> manual(video, 1_000) end)

      assert {:error, {:publication_committed, {:descriptor_close_failed, :eio}}} = result
      assert_unacknowledged_correction(video, path, original, backup)
    end

    test "a target descriptor that fails to close after the exchange keeps the pending record", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      {result, _log} = fail_close_after_exchange(path, [:target], fn -> manual(video, 1_000) end)

      assert {:error, {:publication_committed, {:descriptor_close_failed, :eio}}} = result
      assert_unacknowledged_correction(video, path, original, backup)
    end

    test "a descriptor that fails to close after a failed exchange restores the previous record",
         %{
           video: video,
           path: path
         } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      previous = File.read!(path)
      previous_record = Manifest.sync(Manifest.read(video), "en")

      fail_in_order([
        %{operation: :exchange, source_contains: ".cinder-subtitle-sync-write-", reason: :eio},
        %{
          operation: :close_bound,
          source_contains: ".cinder-subtitle-sync-write-staged",
          reason: :eio
        }
      ])

      assert {:error, {:descriptor_close_failed, :eio}} = manual(video, 2_000)
      assert File.read!(path) == previous
      assert Manifest.sync(Manifest.read(video), "en") == previous_record
    end

    # #1190: the check after the exchange cannot open the sidecar, which holds the corrected
    # bytes, so the publication is committed and the pending record stays for the recovery.
    test "a sidecar with no other name that fails to open right after the exchange is recovered",
         %{video: video, path: path, original: original, backup: backup} do
      assert {:error, {:publication_committed, :published_target_unverified}} =
               fail_target_open_after_exchange(path, fn -> manual(video, 1_000) end)

      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert File.read!(backup) == original
      assert workspaces(path) == []
      assert {:ok, :corrected, _} = manual(video, 2_000)
    end

    # #1190: whatever holds the sidecar's name after the exchange, bytes equal to the correction
    # are what the pending record names.
    test "a sidecar replaced right after the exchange by the corrected bytes keeps the pending record",
         %{video: video, path: path, original: original, backup: backup, tmp_dir: tmp} do
      {:ok, corrected} = Timing.retime(original, ".srt", 1_000, 1.0)

      result =
        after_exchange(fn -> manual(video, 1_000) end, fn ->
          replacement = Path.join(tmp, "replacement.srt")
          File.write!(replacement, corrected)
          File.rename!(replacement, path)
        end)

      assert {:error, {:publication_committed, :published_target_unverified}} = result
      assert_unacknowledged_correction(video, path, original, backup)
      assert workspaces(path) == []
    end

    # #1190: bytes the write cannot read back count as unpublished, as `swap/3` counts them.
    test "a sidecar that fails to open and to read right after the exchange restores the previous record",
         %{video: video, path: path, original: original, backup: backup} do
      read_failure = %{operation: :read, source_contains: path, reason: :eio}

      assert {:error, :concurrent_change} =
               fail_target_open_after_exchange(path, fn -> manual(video, 1_000) end, [
                 read_failure
               ])

      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    # #1284: neither name the exchange swapped opens right after it, but the sidecar reads as the
    # corrected bytes, so the publication is committed. The write empties nothing it could not
    # verify, and the recovery's workspace cleanup disposes of the displaced inode.
    test "a sidecar with no other name whose two names fail to open right after the exchange is recovered",
         %{video: video, path: path, original: original, backup: backup} do
      assert {:error, {:publication_committed, @names_unverified}} =
               fail_names_open_after_exchange(path, fn -> manual(video, 1_000) end)

      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == original

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert File.read!(backup) == original
      assert workspaces(path) == []
      assert {:ok, :corrected, _} = manual(video, 2_000)
    end

    # #1284: a warning the exchange itself committed is kept beside the unverified names.
    test "a post-effect exchange failure, then two names that fail to open, keeps the pending record",
         %{video: video, path: path, original: original, backup: backup} do
      fail_once(%{
        operation: :exchange,
        source_contains: @staged,
        phase: :post_effect,
        reason: :eio
      })

      use_barrier(%{operation: :exchange, phase: :before, contains: @staged})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      fail_in_order(names_open_failures(path))
      send(pid, {ref, :continue})

      assert {:error,
              {:publication_committed, {{:effect_committed, "exchange", :eio}, @names_unverified}}} =
               DiskTask.await(task)

      assert_unacknowledged_correction(video, path, original, backup)
      assert workspaces(path) == []
    end

    # #1284: bytes the write cannot read back count as unpublished, so nothing settles the
    # result and the staged name keeps the displaced bytes.
    test "two names that fail to open and a sidecar that fails to read right after the exchange restore the previous record",
         %{video: video, path: path} do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      previous = File.read!(path)
      previous_record = Manifest.sync(Manifest.read(video), "en")
      read_failure = %{operation: :read, source_contains: path, reason: :eio}

      assert {:error, :concurrent_change} =
               fail_names_open_after_exchange(path, fn -> manual(video, 2_000) end, [read_failure])

      assert File.read!(path) =~ "00:00:03,000 --> 00:00:04,000"
      assert Manifest.sync(Manifest.read(video), "en") == previous_record
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == previous
    end

    # #1284: other bytes at the sidecar's name are not the correction's, so the result stays a
    # concurrent change and nothing is disposed of.
    test "a sidecar replaced right after the exchange by other bytes, with a staged name that fails to open, restores the previous record",
         %{video: video, path: path, tmp_dir: tmp} do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      previous = File.read!(path)
      previous_record = Manifest.sync(Manifest.read(video), "en")

      result =
        after_exchange(fn -> manual(video, 2_000) end, fn ->
          replacement = Path.join(tmp, "replacement.srt")
          File.write!(replacement, "newer")
          File.rename!(replacement, path)
          fail_once(%{operation: :open_bound, source_contains: @staged, reason: :eio})
        end)

      assert {:error, :concurrent_change} = result
      assert File.read!(path) == "newer"
      assert Manifest.sync(Manifest.read(video), "en") == previous_record
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == previous
    end

    # #1322: the exchange's check and then the rollback's identity read fail to open the staged
    # name, but the sidecar reads as the corrected bytes, so the publication is committed. The
    # write disposes of nothing, and the recovery's workspace cleanup disposes of the displaced
    # inode.
    test "a sidecar with no other name whose staged name fails to open twice right after the exchange is recovered",
         %{video: video, path: path, original: original, backup: backup} do
      assert {:error, {:publication_committed, @rollback_kept}} =
               fail_staged_open_after_exchange(fn -> manual(video, 1_000) end, [
                 staged_open_failure()
               ])

      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == original

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert workspaces(path) == []
      assert File.read!(backup) == original
      assert {:ok, :corrected, _} = manual(video, 2_000)
    end

    # #1322: the rollback fails at its first step, its check of the sidecar before its own
    # exchange, so the sidecar still holds the corrected bytes.
    test "a staged name that fails to open, then a rollback whose check of the sidecar fails, keeps the pending record",
         %{video: video, path: path, original: original, backup: backup} do
      target_failure = %{operation: :open_bound, source_contains: path, reason: :eio}

      assert {:error,
              {:publication_committed,
               {:displaced_rollback_failed, :concurrent_change, :displaced_kept}}} =
               fail_staged_open_after_exchange(fn -> manual(video, 1_000) end, [target_failure])

      assert_unacknowledged_correction(video, path, original, backup)
      assert workspaces(path) == []
    end

    # #1322: the rollback read the displaced inode at the staged name, but its own exchange failed
    # with no effect, so the sidecar still holds the corrected bytes.
    test "a staged name that fails to open, then a rollback whose exchange fails, keeps the pending record",
         %{video: video, path: path, original: original, backup: backup} do
      exchange_failure = %{operation: :exchange, source_contains: @staged, reason: :eio}

      assert {:error, {:publication_committed, @rollback_kept}} =
               fail_staged_open_after_exchange(fn -> manual(video, 1_000) end, [exchange_failure])

      assert_unacknowledged_correction(video, path, original, backup)
      assert workspaces(path) == []
    end

    # #1322: a warning the correction's exchange committed goes in front of the failed rollback.
    test "a post-effect exchange failure, then a staged name that fails to open twice, keeps the pending record",
         %{video: video, path: path, original: original, backup: backup} do
      fail_once(%{
        operation: :exchange,
        source_contains: @staged,
        phase: :post_effect,
        reason: :eio
      })

      use_barrier(%{operation: :exchange, phase: :before, contains: @staged})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      fail_in_order([staged_open_failure(), staged_open_failure()])
      send(pid, {ref, :continue})

      assert {:error,
              {:publication_committed, {{:effect_committed, "exchange", :eio}, @rollback_kept}}} =
               DiskTask.await(task)

      assert_unacknowledged_correction(video, path, original, backup)
      assert workspaces(path) == []
    end

    # #1322: the rollback read another writer's file at the staged name, so its failed exchange
    # keeps the result a failed rollback, whatever the sidecar holds.
    test "a sidecar atomically replaced just before the exchange, then a failed rollback exchange, restores the previous record",
         %{video: video, path: path, original: original, backup: backup} do
      external = String.replace(original, "One", "Atomic replacement")
      replacement = path <> ".replacement"
      File.write!(replacement, external)

      use_barrier(%{operation: :exchange, phase: :before, contains: @staged})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      File.rename!(replacement, path)
      use_barrier(%{operation: :exchange, contains: @staged})
      send(pid, {ref, :continue})
      assert_receive {:filesystem_barrier, ^pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      fail_once(%{operation: :exchange, source_contains: @staged, reason: :eio})
      send(pid, {ref, :continue})

      assert {:error, @rollback_failed} = DiskTask.await(task)
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == nil
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == external
    end

    # #1322: the rollback opened the staged name and read another writer's file there, and only
    # the close after that read failed, so the result stays a failed rollback.
    test "a sidecar atomically replaced just before the exchange, then a staged name that fails to close after the rollback reads it, restores the previous record",
         %{video: video, path: path, original: original, backup: backup} do
      external = String.replace(original, "One", "Atomic replacement")
      replacement = path <> ".replacement"
      File.write!(replacement, external)
      close_failure = %{operation: :close_bound, source_contains: @staged, reason: :eio}

      use_barrier(%{operation: :exchange, phase: :before, contains: @staged})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      File.rename!(replacement, path)
      use_barrier(%{operation: :exchange, contains: @staged})
      send(pid, {ref, :continue})
      assert_receive {:filesystem_barrier, ^pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      # The exchange's check of the staged name closes first, then the rollback's identity read.
      fail_in_order([close_failure, close_failure])
      send(pid, {ref, :continue})

      assert {:error,
              {:exchange_rollback_failed, {:error, :concurrent_change},
               {:descriptor_close_failed, :eio}}} = DiskTask.await(task)

      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == nil
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == external
    end

    # #1322: bytes the write cannot read back count as unpublished, so the failed rollback stays
    # the result and the staged name keeps the displaced bytes.
    test "a staged name that fails to open twice and a sidecar that fails to read right after the exchange restore the previous record",
         %{video: video, path: path, original: original} do
      read_failure = %{operation: :read, source_contains: path, reason: :eio}

      assert {:error, @rollback_failed} =
               fail_staged_open_after_exchange(fn -> manual(video, 1_000) end, [
                 staged_open_failure(),
                 read_failure
               ])

      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert Manifest.sync(Manifest.read(video), "en") == nil
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == original
    end

    # #1322: the rollback's own exchange ran before its check of the sidecar failed, so the
    # sidecar holds the first correction's bytes, which the previous record names.
    test "a rollback whose exchange ran before its check of the sidecar failed restores the previous record",
         %{video: video, path: path} do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      previous = File.read!(path)
      previous_record = Manifest.sync(Manifest.read(video), "en")

      use_barrier(%{operation: :exchange, contains: @staged})
      task = Task.async(fn -> manual(video, 2_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      fail_once(staged_open_failure())
      use_barrier(%{operation: :exchange, contains: @staged})
      send(pid, {ref, :continue})
      assert_receive {:filesystem_barrier, ^pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      fail_once(%{operation: :open_bound, source_contains: path, reason: :eio})
      send(pid, {ref, :continue})

      assert {:error,
              {:exchange_rollback_failed, {:error, :concurrent_change}, :concurrent_change}} =
               DiskTask.await(task)

      assert File.read!(path) == previous
      assert Manifest.sync(Manifest.read(video), "en") == previous_record
      assert {:ok, _} = recover(video)
    end

    # #1190: a sidecar that holds other bytes before the exchange is left alone with nothing
    # exchanged, and nothing reads it to settle a result, even when it holds the corrected bytes.
    test "a sidecar edited to the corrected bytes before the exchange restores the previous record",
         %{video: video, path: path, original: original} do
      {:ok, corrected} = Timing.retime(original, ".srt", 1_000, 1.0)
      use_barrier(%{operation: :create_bound, contains: @staged})
      task = Task.async(fn -> manual(video, 1_000) end)

      assert_receive {:filesystem_barrier, pid, ref, :create_bound, _staged},
                     DiskTask.timeout_ms()

      File.write!(path, corrected)

      # Stays armed: a read of the sidecar from here on would clear it.
      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :read,
        source_contains: path,
        reason: :read_forbidden,
        once: true
      })

      send(pid, {ref, :continue})

      assert {:error, :concurrent_change} = DiskTask.await(task)
      assert %{reason: :read_forbidden} = Application.get_env(:cinder, :filesystem_failure)
      Application.delete_env(:cinder, :filesystem_failure)
      assert File.read!(path) == corrected
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a post-effect exchange failure leaves the pending record for recovery", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      fail_once(%{
        operation: :exchange,
        source_contains: ".cinder-subtitle-sync-write-",
        phase: :post_effect,
        reason: :eio
      })

      assert {:error, {:publication_committed, _reason}} = manual(video, 1_000)
      assert_unacknowledged_correction(video, path, original, backup)
    end

    test "a post-effect staged discard failure leaves the pending record for recovery", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      fail_once(%{
        operation: :discard_bound,
        source_contains: Path.basename(path),
        phase: :post_effect,
        reason: :eio
      })

      assert {:error, {:publication_committed, _reason}} = manual(video, 1_000)
      assert_unacknowledged_correction(video, path, original, backup)
    end

    test "a failed final record rolls back the bytes and the original it created", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()

      fail_once(%{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio
      })

      send(pid, {ref, :continue})
      assert {:error, {:manifest, :eio}} = DiskTask.await(task)
      assert File.read!(path) == original
      assert File.read!(backup) == ""
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a failed restore of the previous record keeps the original it created", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()

      fail_in_order([
        %{
          operation: :write_exclusive,
          source_contains: ".cinder-subtitle-manifest-",
          reason: :eio
        },
        %{
          operation: :write_exclusive,
          source_contains: ".cinder-subtitle-manifest-",
          reason: :enospc
        }
      ])

      send(pid, {ref, :continue})
      assert {:error, {:manifest_and_rollback_failed, :eio, :enospc}} = DiskTask.await(task)
      assert File.read!(path) == original
      assert File.read!(backup) == original
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
    end

    test "a rollback never overwrites a newer concurrent sidecar", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      external = String.replace(original, "One", "Concurrent edit")
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()

      fail_in_order([
        %{
          operation: :write_exclusive,
          source_contains: ".cinder-subtitle-manifest-",
          reason: :eio,
          callback: fn -> File.write!(path, external) end
        }
      ])

      send(pid, {ref, :continue})

      assert {:error, {:manifest_and_rollback_failed, :eio, :concurrent_change}} =
               DiskTask.await(task)

      assert File.read!(path) == external
      assert File.read!(backup) == original
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
    end

    test "a failed final record of a second correction restores the first", %{
      video: video,
      path: path
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      previous = File.read!(path)
      previous_record = Manifest.sync(Manifest.read(video), "en")
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 2_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()

      fail_once(%{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio
      })

      send(pid, {ref, :continue})
      assert {:error, {:manifest, :eio}} = DiskTask.await(task)
      assert File.read!(path) == previous
      assert Manifest.sync(Manifest.read(video), "en") == previous_record
    end

    test "a failed rollback keeps the immutable original", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()

      fail_in_order([
        %{
          operation: :write_exclusive,
          source_contains: ".cinder-subtitle-manifest-",
          reason: :eio
        },
        %{operation: :exchange, source_contains: ".cinder-subtitle-sync-write-", reason: :eacces}
      ])

      send(pid, {ref, :continue})
      assert {:error, {:manifest_and_rollback_failed, :eio, :eacces}} = DiskTask.await(task)
      refute File.read!(path) == original
      assert File.read!(backup) == original
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
    end

    test "a failed video check after the exchange rolls the correction back", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      File.write!(video, @changed_video)
      send(pid, {ref, :continue})

      assert {:error, :video_changed} = DiskTask.await(task)
      assert File.read!(path) == original
      assert File.read!(backup) == ""
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a failed rollback after the video changed reports both failures", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-"})
      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
      File.write!(video, @changed_video)

      fail_once(%{
        operation: :exchange,
        source_contains: ".cinder-subtitle-sync-write-",
        reason: :eacces
      })

      send(pid, {ref, :continue})

      assert {:error, {:correction_and_rollback_failed, :video_changed, :eacces}} =
               DiskTask.await(task)

      refute File.read!(path) == original
      assert File.read!(backup) == original
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
    end

    test "staged bytes never follow a pre-created symlink", %{video: video, tmp_dir: tmp} do
      outside = Path.join(tmp, "outside.srt")
      File.write!(outside, "outside")

      use_barrier(%{
        operation: :create_bound,
        phase: :before,
        contains: ".cinder-subtitle-sync-write-"
      })

      task = Task.async(fn -> manual(video, 1_000) end)
      assert_receive {:filesystem_barrier, pid, ref, :create_bound, staged}, DiskTask.timeout_ms()
      File.ln_s!(outside, staged)
      send(pid, {ref, :continue})

      assert {:error, _reason} = DiskTask.await(task)
      assert File.read!(outside) == "outside"
    end

    test "an ambiguous workspace mkdir never grants cleanup ownership", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
      helper = Path.join(tmp, "unknown-mkdir.py")
      real_helper = Path.join(File.cwd!(), "priv/rooted_fs.py")

      File.write!(
        helper,
        """
        import os
        import sys

        if sys.argv[1] not in ("mkdir", "mkdir_near"):
            os.execv(sys.executable, [sys.executable, #{inspect(real_helper)}] + sys.argv[1:])

        directory = os.path.join(sys.argv[2], sys.argv[3])
        os.mkdir(directory, 0o700)
        with open(os.path.join(directory, ".cinder-subtitle-sync-write-staged"), "wb") as output:
            output.write(b"attacker-owned")
        sys.stdout.write("malformed helper response\\n")
        """
      )

      Application.put_env(:cinder, :rooted_filesystem_helper, helper)

      assert {:error, {:effect_committed, "mkdir_near", _reason}} = manual(video, 1_000)

      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == "attacker-owned"
      assert File.read!(path) == original
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a completed correction leaves no workspace beside the sidecar", %{
      video: video,
      path: path
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)

      assert workspaces(path) == []
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    end

    # #1290: only a recovery whose cleanup kept the workspace logs its removal.
    test "a correction logs no removal line for the workspace it retires", %{
      video: video,
      path: path
    } do
      {result, log} = with_log(fn -> manual(video, 1_000) end)

      assert {:ok, :corrected, _} = result
      assert workspaces(path) == []
      refute log =~ "subtitle workspace removed"
    end

    test "a workspace that fails to retire is logged and the correction still records", %{
      video: video,
      path: path
    } do
      fail_once(%{operation: :rm, source_contains: @staged, reason: :eio})

      {result, log} = with_log(fn -> manual(video, 1_000) end)

      assert {:ok, :corrected, _} = result
      assert [workspace] = workspaces(path)
      assert log =~ "subtitle workspace kept at #{workspace}: :eio"
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
    end

    # Its five operations start about 165 rooted Python helpers through Disk. On a loaded CI
    # runner that passed ExUnit's 60 s default, with no single Disk call near its bound (#1276).
    @tag timeout: 300_000
    test "identical correct and reset cycles never collide with a retired workspace", %{
      video: video,
      path: path,
      original: original
    } do
      for _cycle <- 1..2 do
        assert {:ok, :corrected, _} = manual(video, 1_000)
        assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
        assert :ok = reset(video)
        assert File.read!(path) == original
      end

      assert Manifest.sync(Manifest.read(video), "en") == nil
      assert {:ok, :corrected, _} = manual(video, 2_000)
      assert File.read!(path) =~ "00:00:03,000"
    end

    test "a reclaimed workspace tombstone restages through the syncing write_bound", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert :ok = reset(video)
      assert File.read!(path) == original

      Application.put_env(:cinder, :filesystem, SpyWriteBoundFilesystem)
      assert {:ok, :corrected, _} = manual(video, 1_000)

      # Drain any write_bound activity from the correction itself (e.g. reactivating a backup
      # tombstone the first reset left) so the messages left afterward can only be the reset's
      # own restage.
      drain_write_bound_messages()

      assert :ok = reset(video)
      assert File.read!(path) == original
      assert_received {:write_bound, _}
    end

    test "a multiply-linked staged tombstone is refused instead of written through", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert :ok = reset(video)
      assert File.read!(path) == original

      # Every workspace tombstone left so far gets a second link, standing in for a
      # same-filesystem file outside the library that an attacker planted at the deterministic
      # path before Cinder's own exclusive mkdir ran.
      outside_links =
        path
        |> workspace_staged_files()
        |> Enum.with_index()
        |> Enum.map(fn {staged, index} ->
          outside = Path.join(Path.dirname(path), "outside-link-#{index}")
          File.ln!(staged, outside)
          outside
        end)

      refute outside_links == []

      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert {:error, :pending_workspace_mismatch} = reset(video)
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      for outside <- outside_links, do: assert(File.read!(outside) == "")
    end
  end

  # Issues #344 and #350: a mergerfs library whose logical backup path spans backing branches.
  describe "publish/4 on a mergerfs library" do
    test "reactivates a verified legacy backup tombstone and rebinds its identity", %{
      video: video,
      original: original,
      backup: backup,
      tmp_dir: tmp
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert :ok = reset(video)

      legacy_identity = [38, 0, 123_456]
      assert :ok = Manifest.put_backup_tombstone(video, "en", legacy_identity)
      helper = legacy_identity_helper!(tmp, Path.basename(backup), legacy_identity)
      Application.put_env(:cinder, :rooted_filesystem_helper, helper)

      assert {:ok, :corrected, _} = manual(video, 2_000)
      assert File.read!(backup) == original
      assert_tombstone_rebound(video, backup)
    end

    test "reconciles duplicate zero-byte tombstones and completes the correction", %{
      video: video,
      tmp_dir: tmp
    } do
      %{path: path, backup: backup, duplicate: duplicate, original: original} =
        duplicate_tombstones!(video, tmp)

      assert {:ok, :corrected, _} = manual(video, 2_000)
      assert File.read!(backup) == original
      refute File.exists?(duplicate)
      refute File.read!(path) == original
      assert_tombstone_rebound(video, backup)
    end

    test "reconciles duplicate tombstones recorded with a legacy identity", %{
      video: video,
      tmp_dir: tmp
    } do
      legacy_identity = [38, 0, 123_456]

      %{path: path, backup: backup, duplicate: duplicate, original: original} =
        duplicate_tombstones!(video, tmp, legacy_identity: legacy_identity)

      assert %{identity: ^legacy_identity} =
               Manifest.backup_tombstone(Manifest.read(video), "en")

      assert {:ok, :corrected, _} = manual(video, 2_000)
      assert File.read!(backup) == original
      refute File.exists?(duplicate)
      refute File.read!(path) == original
      assert_tombstone_rebound(video, backup)
    end

    test "refuses backing paths that alias one physical file", %{video: video, tmp_dir: tmp} do
      %{backup: backup, duplicate: duplicate} =
        duplicate_tombstones!(video, tmp,
          legacy_identity: [38, 0, 123_456],
          alias_identity: true
        )

      assert {:error, :estale} = manual(video, 2_000)
      assert File.exists?(backup)
      assert File.exists?(duplicate)
    end

    # Issue #972: with the control file readable, the helper derives a union identity from a
    # hybrid-hash mount. A tombstone matching neither it nor a container proves nothing.
    test "a tombstone recorded under neither identity stays fail-closed", %{
      video: video,
      tmp_dir: tmp
    } do
      %{path: path, backup: backup, duplicate: duplicate} =
        duplicate_tombstones!(video, tmp,
          recorded_identity: [38, 0, 123_456],
          inodecalc: "hybrid-hash"
        )

      current = File.read!(path)

      assert {:error, :estale} = manual(video, 2_000)
      assert File.exists?(duplicate)
      assert File.read!(backup) == ""
      assert File.read!(path) == current
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "a nonzero duplicate container stays fail-closed", %{video: video, tmp_dir: tmp} do
      %{path: path, backup: backup, duplicate: duplicate} = duplicate_tombstones!(video, tmp)
      File.write!(duplicate, "unrelated payload")
      current = File.read!(path)

      assert {:error, :enotempty} = manual(video, 2_000)
      assert File.read!(duplicate) == "unrelated payload"
      assert File.read!(backup) == ""
      assert File.read!(path) == current
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    # Issue #884: the correction returns the helper's refusal of a pool-subdirectory bind as is.
    test "a bind of a mergerfs pool subdirectory fails the correction with the layout", %{
      video: video,
      tmp_dir: tmp
    } do
      %{path: path, backup: backup, duplicate: duplicate} =
        duplicate_tombstones!(video, tmp, mount_root: "/media")

      current = File.read!(path)

      assert {:error, {:mergerfs_subdirectory_bind, "/media"}} = manual(video, 2_000)
      assert File.read!(duplicate) == ""
      assert File.read!(backup) == ""
      assert File.read!(path) == current
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end

    test "duplicate containers without a recorded tombstone stay fail-closed", %{
      video: video,
      tmp_dir: tmp
    } do
      %{path: path, backup: backup, duplicate: duplicate} = duplicate_tombstones!(video, tmp)
      drop_recorded_tombstone!(video)
      current = File.read!(path)

      # Without a recorded tombstone nothing proves the duplicates are ours, so the original
      # post-effect EEXIST surfaces unchanged instead of a new atom.
      assert {:error, {:effect_committed, "hold", %{"reason" => "EEXIST"}}} = manual(video, 2_000)
      assert File.exists?(duplicate)
      assert File.read!(backup) == ""
      assert File.read!(path) == current
      assert Manifest.sync(Manifest.read(video), "en") == nil
    end
  end
end
