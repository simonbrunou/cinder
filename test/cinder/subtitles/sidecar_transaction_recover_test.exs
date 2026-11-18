defmodule Cinder.Subtitles.SidecarTransactionRecoverTest do
  # Drives the sidecar replacement transaction directly, on real temp directories through the
  # `Cinder.Library.Filesystem` seam: no engine, no media probe. Crashes are a killed process at a
  # `Cinder.Test.BarrierFilesystem` barrier, or a pending record written by hand. This module
  # covers `recover/2`, `hold_for_review/2` and `original/2`; `Cinder.Test.SidecarTransactionCase`
  # holds the setup and helpers it shares with its sibling modules (#1474).
  use Cinder.DataCase, async: false
  use Cinder.Test.SidecarTransactionCase

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1]
  import ExUnit.CaptureLog

  alias Cinder.Subtitles.{Manifest, SidecarTransaction}

  describe "recover/2 with a pending record" do
    test "finalizes a pending record whose bytes were already exchanged", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      corrected = File.read!(path)
      assert :ok = Manifest.put_sync(video, "en", pending(record, original))

      assert {:ok, %{sync: ^record}} = recover(video)
      assert File.read!(path) == corrected
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == record
    end

    test "recomputes a manual correction whose staged bytes are gone from the original", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      assert :ok = Manifest.put_sync(video, "en", pending(record, original))
      File.write!(path, original)

      assert {:ok, %{sync: ^record}} = recover(video)
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert File.read!(backup) == original
    end

    test "holds an automatic correction whose staged bytes are gone for review", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      automatic = %{record | method: "audio", score: 30.0}
      assert :ok = Manifest.put_sync(video, "en", pending(automatic, original))
      File.write!(path, original)

      assert {:review, :apply_recovery_failed, _sidecar} = recover(video)
      assert File.read!(path) == original
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
    end

    test "finishes a second correction killed before its exchange", %{video: video, path: path} do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      previous = File.read!(path)

      use_barrier(%{
        operation: :exchange,
        phase: :before,
        contains: ".cinder-subtitle-sync-write-"
      })

      kill_at_barrier(fn -> manual(video, 2_000) end, :exchange)
      assert File.read!(path) == previous
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert File.read!(path) =~ "00:00:03,000"
    end

    test "retires the staged file a kill before the exchange left behind", %{
      video: video,
      path: path
    } do
      use_barrier(%{
        operation: :exchange,
        phase: :before,
        contains: ".cinder-subtitle-sync-write-"
      })

      staged = kill_at_barrier(fn -> manual(video, 1_000) end, :exchange)
      workspace = Path.dirname(staged)
      assert File.dir?(workspace)

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      refute File.exists?(workspace)
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    end

    test "finalizes a publication killed after its exchange emptied the workspace", %{
      video: video,
      path: path
    } do
      use_barrier(%{operation: :discard_bound, contains: Path.basename(path)})
      ^path = kill_at_barrier(fn -> manual(video, 1_000) end, :discard_bound)

      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == ""
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

      # The pending record names the workspace, so a sweep leaves it for `recover/2`.
      age!(Path.dirname(staged))
      assert :ok = SidecarTransaction.reconcile(video, moviehash!(video))
      assert File.dir?(Path.dirname(staged))

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      refute File.exists?(Path.dirname(staged))
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
    end

    # #1149: the staged name still holds the inode the exchange displaced, with the bytes from
    # before the correction. The recovery empties it, as the uninterrupted write does.
    test "a correction killed before emptying the inode its exchange displaced is finished by recover",
         %{video: video, path: path, original: original, backup: backup} do
      use_barrier(%{operation: :discard_bound, phase: :before, contains: Path.basename(path)})
      ^path = kill_at_barrier(fn -> manual(video, 1_000) end, :discard_bound)

      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == original
      assert File.stat!(staged).links == 1

      {result, log} = with_log(fn -> recover(video) end)
      assert {:ok, %{sync: %{status: "aligned"}}} = result
      refute log =~ "subtitle workspace kept"
      refute log =~ "subtitle workspace removed"
      assert workspaces(path) == []
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
      assert File.read!(backup) == original
    end

    # The disposal runs before the final record, so a recovery killed between them leaves the
    # pending record for the next one.
    test "a recovery killed after emptying the displaced inode is finished by the next one", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      use_barrier(%{operation: :discard_bound, phase: :before, contains: Path.basename(path)})
      kill_at_barrier(fn -> manual(video, 1_000) end, :discard_bound)
      assert [staged] = workspace_staged_files(path)
      use_barrier(%{operation: :discard_bound, contains: @staged})
      kill_at_barrier(fn -> recover(video) end, :discard_bound)
      assert_fresh_tombstone(staged)
      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert workspaces(path) == []
      assert File.read!(backup) == original
    end

    test "a correction whose discard failed before its effect is finished by recover", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      fail_once(%{operation: :discard_bound, source_contains: Path.basename(path), reason: :eio})

      assert {:error, {:publication_committed, {:discard_failed, :eio}}} = manual(video, 1_000)
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == original

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert workspaces(path) == []
      assert File.read!(backup) == original
    end

    # A disposal step that fails leaves the workspace to the warning `retire/2` logs, and the
    # correction still records: its sidecar holds the corrected bytes.
    test "a recovery whose disposal fails still records the correction", %{
      video: video,
      path: path,
      original: original
    } do
      use_barrier(%{operation: :discard_bound, phase: :before, contains: Path.basename(path)})
      kill_at_barrier(fn -> manual(video, 1_000) end, :discard_bound)
      assert [staged] = workspace_staged_files(path)
      workspace = Path.dirname(staged)
      fail_once(%{operation: :discard_bound, source_contains: @staged, reason: :eio})

      {result, log} = with_log(fn -> recover(video) end)
      assert {:ok, %{sync: %{status: "aligned"}}} = result
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert log =~ "subtitle workspace kept at #{workspace}: {:discard_failed, :eio}"
      assert log =~ "subtitle workspace kept at #{workspace}: :not_a_tombstone"
      assert File.read!(staged) == original
    end

    # Staged bytes that are neither side of the correction are not the inode its exchange
    # displaced: the recovery records the correction and leaves them.
    test "a recovery leaves staged bytes that are neither side of the correction", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      operation_id = String.duplicate("o", 22)
      workspace = plant_workspace!(path, %{@staged => "neither side"}, operation_id)
      assert :ok = Manifest.put_sync(video, "en", pending(record, original, operation_id))

      assert {:ok, %{sync: ^record}} = recover(video)
      assert File.read!(Path.join(workspace, @staged)) == "neither side"
    end

    # A manual correction is recomputed from the original (`replay`), an automatic one is
    # published from its staged bytes (`resume_staged`).
    for {kind, interruption, method} <- [
          {"a manual", :manual, "manual"},
          {"an automatic", :automatic, "audio"}
        ] do
      test "records #{kind} correction whose recovery published it unacknowledged", %{
        video: video,
        path: path
      } do
        interrupt_before_exchange!(video, unquote(interruption))

        {result, _log} = fail_close_after_exchange(path, [:staged], fn -> recover(video) end)

        assert_recorded_correction(result, video, path, unquote(method))
      end

      test "records #{kind} correction whose recovery exchange went unacknowledged", %{
        video: video,
        path: path
      } do
        interrupt_before_exchange!(video, unquote(interruption))

        fail_once(%{
          operation: :exchange,
          source_contains: ".cinder-subtitle-sync-write-",
          phase: :post_effect,
          reason: :eio
        })

        assert_recorded_correction(recover(video), video, path, unquote(method))
      end

      test "records #{kind} correction whose recovery discard went unacknowledged", %{
        video: video,
        path: path
      } do
        interrupt_before_exchange!(video, unquote(interruption))

        fail_once(%{
          operation: :discard_bound,
          source_contains: Path.basename(path),
          phase: :post_effect,
          reason: :eio
        })

        assert_recorded_correction(recover(video), video, path, unquote(method))
      end

      test "holds #{kind} correction whose recovery exchange failed for review", %{
        video: video,
        path: path,
        original: original
      } do
        interrupt_before_exchange!(video, unquote(interruption))

        fail_once(%{
          operation: :exchange,
          source_contains: ".cinder-subtitle-sync-write-",
          reason: :eio
        })

        assert {:review, :apply_recovery_failed, _sidecar} = recover(video)
        assert File.read!(path) == original
        assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
      end

      test "holds #{kind} correction whose video changed during an unacknowledged recovery", %{
        video: video,
        path: path
      } do
        interrupt_before_exchange!(video, unquote(interruption))

        {result, _log} =
          fail_close_after_exchange(path, [:staged], fn -> recover(video) end,
            paused: fn -> File.write!(video, @changed_video) end
          )

        assert {:review, :apply_recovery_failed, _sidecar} = result
        assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
        assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
      end

      test "holds #{kind} correction whose original changed during an unacknowledged recovery",
           %{video: video, path: path, backup: backup} do
        interrupt_before_exchange!(video, unquote(interruption))

        {result, _log} =
          fail_close_after_exchange(path, [:staged], fn -> recover(video) end,
            paused: fn -> File.write!(backup, "tampered") end
          )

        assert {:review, :apply_recovery_failed, _sidecar} = result
        assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
        assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
      end

      test "logs the unacknowledged discard of #{kind} correction its recovery records", %{
        video: video,
        path: path
      } do
        interrupt_before_exchange!(video, unquote(interruption))

        fail_once(%{
          operation: :discard_bound,
          source_contains: Path.basename(path),
          phase: :post_effect,
          reason: :eio
        })

        {result, log} = with_log(fn -> recover(video) end)

        assert_recorded_correction(result, video, path, unquote(method))
        assert_unacknowledged_warning(log, path, {:effect_committed, "discard_bound", :eio})
      end

      # The warning comes from the write's result, before the checks that hold the item.
      test "logs the unacknowledged publication of #{kind} correction held for review", %{
        video: video,
        path: path
      } do
        interrupt_before_exchange!(video, unquote(interruption))

        {result, log} =
          fail_close_after_exchange(path, [:staged], fn -> recover(video) end,
            paused: fn -> File.write!(video, @changed_video) end
          )

        assert {:review, :apply_recovery_failed, _sidecar} = result
        assert log =~ "descriptor close failed after committed subtitle publication: :eio"
        assert_unacknowledged_warning(log, path, {:descriptor_close_failed, :eio})
      end

      test "logs no unacknowledged publication for #{kind} correction its recovery confirms", %{
        video: video,
        path: path
      } do
        interrupt_before_exchange!(video, unquote(interruption))

        {result, log} = with_log(fn -> recover(video) end)

        assert_recorded_correction(result, video, path, unquote(method))
        refute log =~ "subtitle publication unacknowledged"
      end
    end

    test "validates a staged pathname without deleting it", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      corrected = File.read!(path)
      operation_id = String.duplicate("i", 22)
      workspace = Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-#{operation_id}")
      staged = Path.join(workspace, ".cinder-subtitle-sync-write-staged")
      File.mkdir!(workspace)
      File.chmod!(workspace, 0o700)
      File.write!(staged, corrected)
      assert :ok = Manifest.put_sync(video, "en", pending(record, original, operation_id))

      assert {:ok, %{sync: ^record}} = recover(video)
      assert File.read!(staged) == corrected
      assert File.dir?(workspace)
    end
  end

  describe "recover/2 after the video or the bytes changed" do
    test "a replaced video restores the immutable original and retires it", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      File.write!(video, @changed_video)

      assert {:ok, %{sync: nil}} = recover(video)
      assert File.read!(path) == original
      assert File.read!(backup) == ""
      assert Manifest.sync(Manifest.read(video), "en") == nil
      assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
    end

    test "a replaced video with a mismatched original is held for review", %{
      video: video,
      path: path,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      corrected = File.read!(path)
      File.write!(backup, "1\n00:00:01,000 --> 00:00:02,000\nWrong\n\n")
      File.write!(video, @changed_video)

      assert {:review, :replacement_cleanup_failed, %{sync: ^record}} = recover(video)
      assert File.read!(path) == corrected
      assert File.exists?(backup)
      assert Manifest.sync(Manifest.read(video), "en") == record
    end

    test "a failed restore of a replaced video's original keeps everything", %{
      video: video,
      path: path,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      File.write!(video, @changed_video)

      fail_once(%{
        operation: :exchange,
        source_contains: ".cinder-subtitle-sync-write-",
        reason: :eio
      })

      assert {:review, :replacement_cleanup_failed, _sidecar} = recover(video)
      assert File.read!(path) == corrected
      assert File.exists?(backup)
      assert Manifest.sync(Manifest.read(video), "en") != nil
    end

    # Issue #1127: the restore's exchange put the original back; a step after it went
    # unacknowledged.
    for failure <- [:close, :exchange, :discard] do
      test "a replaced video whose restore went unacknowledged (#{failure}) retires the original",
           %{video: video, path: path, original: original, backup: backup} do
        assert {:ok, :corrected, _} = manual(video, 1_000)
        File.write!(video, @changed_video)

        {result, log} = unacknowledged_write(unquote(failure), path, fn -> recover(video) end)

        assert {:ok, %{sync: nil}} = result
        assert File.read!(path) == original
        assert File.read!(backup) == ""
        assert Manifest.sync(Manifest.read(video), "en") == nil
        assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
        assert_unacknowledged_warning(log, path, unacknowledged_detail(unquote(failure)))
      end
    end

    # #1169: the cleanup after a changed video restores the original through the reversal a reset
    # makes. Its failed discard left the corrected bytes at the reversal's staged name, and the
    # same correction on the new video derives the same reversal id.
    test "the same correction and reset go on after a cleanup whose discard failed", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      File.write!(video, @changed_video)
      fail_displaced_discard_once(path)

      {result, log} = with_log(fn -> recover(video) end)
      assert {:ok, %{sync: nil}} = result
      assert log =~ "discard_failed"
      assert File.read!(path) == original
      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == corrected

      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert File.read!(path) == corrected
      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
      assert :ok = reset(video)
      assert_reset_finished(video, path, original, backup)
      assert_settled_reversal(path, staged)
    end

    test "a failed journal write keeps the original for a retry", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      File.write!(video, @changed_video)

      fail_once(%{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio
      })

      assert {:review, :replacement_cleanup_failed, _sidecar} = recover(video)
      assert File.read!(path) == original
      assert File.exists?(backup)
      assert Manifest.sync(Manifest.read(video), "en") != nil
    end

    test "an original that will not retire stays journaled until reconcile retires it", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      File.write!(video, @changed_video)

      fail_once(%{
        operation: :discard_bound,
        source_contains: ".cinder-sync-original",
        reason: :eacces
      })

      assert {:review, :replacement_cleanup_failed, %{sync: nil}} = recover(video)
      assert File.read!(path) == original
      assert File.read!(backup) == original
      assert Manifest.sync(Manifest.read(video), "en") == nil
      assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == record

      assert :ok = SidecarTransaction.reconcile(video, moviehash!(video))
      assert File.read!(backup) == ""
      assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
    end

    test "a replaced video with no original closes its journal without blocking", %{
      video: video,
      original: original,
      backup: backup
    } do
      record = record(moviehash!(video), original, original, %{offset_ms: 0})

      assert {:ok, :aligned, _} =
               SidecarTransaction.publish(sidecar(video), original, original, record)

      File.write!(video, @changed_video)

      assert {:ok, %{sync: nil}} = recover(video)
      assert Manifest.replacement_cleanup_sync(Manifest.read(video), "en") == nil
      refute File.exists?(backup)
    end

    test "bytes a reset restored before clearing the record are settled", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      corrected = File.read!(path)
      File.chmod!(path, 0o600)
      # The reset's exchange back to the original committed; the process died before the
      # reset journal was written.
      write_back!(path, original, corrected)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o644

      assert {:ok, %{sync: nil}} = recover(video)
      assert File.read!(path) == original
      assert File.read!(backup) == ""
    end

    test "an external edit after a correction is held for review", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      external = String.replace(original, "One", "Externally edited")
      File.write!(path, external)

      assert {:review, :externally_modified, %{sync: ^record}} = recover(video)
      assert File.read!(path) == external
      assert File.read!(backup) == original
    end

    test "an edit before any record is held for review", %{
      video: video,
      path: path,
      original: original,
      backup: backup
    } do
      external = String.replace(original, "One", "External edit")
      File.write!(path, external)

      assert {:review, :externally_modified, _sidecar} = recover(video)
      assert File.read!(path) == external
      refute File.exists?(backup)
    end
  end

  describe "recover/2 without a record" do
    test "never retires an original it cannot prove", %{video: video, path: path} do
      backup = owned_backup!(video, path, "unrelated file")

      assert {:review, :replacement_cleanup_failed, _sidecar} = recover(video)
      assert File.read!(backup) == "unrelated file"
      assert SidecarTransaction.stranded_backup?(path)
    end

    test "refuses matching bytes under a different backup inode", %{
      video: video,
      path: path,
      original: original
    } do
      backup = owned_backup!(video, path, original)
      replacement = backup <> ".replacement"
      File.write!(replacement, original)
      File.rename!(replacement, backup)

      assert {:review, :replacement_cleanup_failed, _sidecar} = recover(video)
      assert File.read!(backup) == original
    end

    test "retires a proven original legacy cleanup left behind", %{
      video: video,
      path: path,
      original: original
    } do
      backup = owned_backup!(video, path, original)
      assert SidecarTransaction.stranded_backup?(path)

      assert {:ok, %{sync: nil}} = recover(video)
      assert File.read!(backup) == ""
      refute SidecarTransaction.stranded_backup?(path)
    end

    test "leaves an unsafe backup path stranded", %{video: video, path: path, backup: backup} do
      File.ln_s!(path, backup)

      assert SidecarTransaction.stranded_backup?(path)
      assert {:review, :replacement_cleanup_failed, _sidecar} = recover(video)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(backup)
    end
  end

  describe "hold_for_review/2" do
    test "marks the final record for review and leaves the bytes alone", %{
      video: video,
      path: path,
      backup: backup,
      original: original
    } do
      assert {:ok, :corrected, %{sync: record}} = manual(video, 1_000)
      corrected = File.read!(path)

      assert {:ok, %{sync: held}} =
               SidecarTransaction.hold_for_review(sidecar(video), :externally_modified)

      assert held == %{record | status: "review", reason: "externally_modified"}
      assert Manifest.sync(Manifest.read(video), "en") == held
      assert File.read!(path) == corrected
      assert File.read!(backup) == original
    end
  end

  describe "original/2" do
    test "is the current bytes until a correction keeps an original", %{
      video: video,
      original: original
    } do
      assert {:ok, ^original} = SidecarTransaction.original(sidecar(video), original)
    end

    test "is the immutable original once a correction kept one", %{
      video: video,
      path: path,
      original: original
    } do
      assert {:ok, :corrected, _} = manual(video, 1_000)
      assert {:ok, ^original} = SidecarTransaction.original(sidecar(video), File.read!(path))
    end
  end
end
