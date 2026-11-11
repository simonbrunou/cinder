defmodule Cinder.Subtitles.SidecarTransactionTest do
  # Drives the sidecar replacement transaction directly, on real temp directories through the
  # `Cinder.Library.Filesystem` seam: no engine, no media probe. Crashes are a killed process at a
  # `Cinder.Test.BarrierFilesystem` barrier, or a pending record written by hand.
  use Cinder.DataCase, async: false

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1, fail_in_order: 1]
  import ExUnit.CaptureLog

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Subtitles.{Manifest, Moviehash, SidecarTransaction}
  alias Cinder.Subtitles.Sync.Timing
  alias Cinder.Test.{DiskTask, MergerfsControl}

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

  @moduletag :tmp_dir

  @changed_video "x" <> String.duplicate("v", 131_071)
  @replacement "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n"
  # A workspace's entries: persisted names, so spelled out here.
  @staged ".cinder-subtitle-sync-write-staged"
  @tombstone ".cinder-subtitle-sync-write-tombstone"

  setup %{tmp_dir: tmp} do
    keys = [
      :filesystem,
      :path_policy,
      :movies_library_path,
      :tv_library_path,
      :rooted_filesystem_helper,
      :filesystem_barrier,
      :filesystem_failure,
      :filesystem_failures
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})
    movies = Path.join(tmp, "movies")
    File.mkdir_p!(movies)
    File.mkdir_p!(Path.join(tmp, "tv"))
    Application.put_env(:cinder, :filesystem, Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :movies_library_path, movies)
    Application.put_env(:cinder, :tv_library_path, Path.join(tmp, "tv"))

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    video = Path.join(movies, "Movie/Movie.mkv")
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 131_072))
    path = managed_srt!(video)
    %{video: video, path: path, original: File.read!(path), backup: backup(path)}
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
      task = Task.async(fn -> manual(video, 0) end)

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
      assert :ok = Manifest.clear_backup_tombstone(video, "en")
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
      assert Manifest.reset_cleanup_sync(Manifest.read(video), "en") != nil

      assert :ok = SidecarTransaction.reconcile(video, moviehash!(video))
      assert File.read!(path) == original
      assert File.read!(backup) == ""
      assert Manifest.reset_cleanup_sync(Manifest.read(video), "en") == nil
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
      assert Manifest.reset_cleanup_sync(Manifest.read(video), "en") == record
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

    test "leaves workspaces holding bytes nothing in the folder holds, another name or another entry",
         %{video: video, path: path, original: original, tmp_dir: tmp} do
      # The same size as the sidecar, other bytes.
      same_size = plant_workspace!(path, %{@staged => shifted(original)})
      other_size = plant_workspace!(path, %{@staged => "bytes nothing holds"})
      two_links = plant_workspace!(path, %{@staged => ""})
      File.ln!(Path.join(two_links, @staged), Path.join(tmp, "outside"))
      accounted_two_links = plant_workspace!(path, %{@staged => original})
      File.ln!(Path.join(accounted_two_links, @staged), Path.join(tmp, "outside-accounted"))
      extra_entry = plant_workspace!(path, %{@staged => "", "other" => ""})
      accounted_extra_entry = plant_workspace!(path, %{@staged => original, "other" => ""})
      not_an_id = Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-short")
      File.mkdir!(not_an_id)

      kept = [
        same_size,
        other_size,
        two_links,
        accounted_two_links,
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
      assert File.read!(Path.join(accounted_two_links, @staged)) == original
      assert File.stat!(Path.join(tmp, "outside")).links == 2
      assert File.stat!(Path.join(tmp, "outside-accounted")).links == 2
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

    test "a sweep leaves accounted bytes that gained a name before it held them", %{
      video: video,
      path: path,
      original: original,
      tmp_dir: tmp
    } do
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

      assert File.read!(Path.join(workspace, @staged)) == original
      assert File.stat!(Path.join(tmp, "second-name")).links == 2
      assert log =~ "subtitle workspace kept at #{workspace}: :not_a_tombstone"
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
  end

  test "only the transaction writes the manifest's record, journal and tombstone fields" do
    writers =
      ~r/Manifest\.(put_sync|clear_sync|begin_replacement_cleanup|clear_replacement_cleanup|begin_reset_cleanup|finish_reset_cleanup|put_backup_tombstone|clear_backup_tombstone)\(/

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

  # A manual correction by `offset_ms`, driven through the transaction the way
  # `Cinder.Subtitles.Sync.manual/4` drives it: recover, start from the original, publish.
  defp manual(video, offset_ms) do
    moviehash = moviehash!(video)

    with {:ok, sidecar} <- recovered(sidecar(video), moviehash),
         {:ok, current} <- File.read(sidecar.sidecar_path),
         {:ok, original} <- SidecarTransaction.original(sidecar, current) do
      {:ok, corrected} = Timing.retime(original, ".srt", offset_ms, 1.0)
      record = record(moviehash, original, corrected, %{offset_ms: offset_ms})
      SidecarTransaction.publish(sidecar, current, corrected, record)
    end
  end

  defp recovered(sidecar, moviehash) do
    case SidecarTransaction.recover(sidecar, moviehash) do
      {:ok, sidecar} -> {:ok, sidecar}
      {:review, reason, _sidecar} -> {:error, reason}
    end
  end

  defp recover(video), do: SidecarTransaction.recover(sidecar(video), moviehash!(video))
  defp reset(video), do: SidecarTransaction.restore_original(sidecar(video), moviehash!(video))
  defp reconcile(video), do: SidecarTransaction.reconcile(video, moviehash!(video))

  defp operation_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  # A workspace beside `path` holding `entries` (name => bytes), the way a correction or a reset
  # leaves one. Returns its path.
  defp plant_workspace!(path, entries, id \\ operation_id()) do
    workspace = Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-#{id}")
    File.mkdir!(workspace)
    File.chmod!(workspace, 0o700)
    for {name, content} <- entries, do: File.write!(Path.join(workspace, name), content)
    workspace
  end

  # Another video in the folder of `video` with a pending correction, and the empty workspace
  # its record names beside `path`. Returns that video and the workspace.
  defp other_video_pending_workspace!(video, path) do
    other = Path.join(Path.dirname(video), "Other.mkv")
    File.write!(other, String.duplicate("o", 131_072))
    other_original = other |> managed_srt!() |> File.read!()
    record = record(moviehash!(other), other_original, shifted(other_original))
    id = operation_id()
    assert :ok = Manifest.put_sync(other, "en", pending(record, other_original, id))
    {other, plant_workspace!(path, %{@staged => ""}, id)}
  end

  # Rewrites one track of the manifest of `video` in its JSON, the way a hand edit or a write
  # by another version leaves it.
  defp edit_manifest_track!(video, language, change) do
    manifest = Manifest.path(video)
    json = manifest |> File.read!() |> Jason.decode!()

    File.write!(
      manifest,
      Jason.encode!(update_in(json, ["tracks", language], &edit_track(change, &1)))
    )
  end

  defp edit_track(:invalid_sync, track), do: put_in(track, ["sync", "status"], "unknown")

  defp edit_track(:invalid_reset_journal, track),
    do: Map.put(track, "reset_cleanup_sync", %{"status" => "unknown"})

  defp edit_track(:invalid_replacement_journal, track),
    do: Map.put(track, "replacement_cleanup_sync", %{"status" => "unknown"})

  defp edit_track(:without_file, track), do: Map.delete(track, "file")

  defp warning_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]"))

  # The two entries `replace_shared_tombstone/2` leaves when killed between creating the fresh
  # tombstone and renaming it over the staged name (#1131): the staged name still holds a
  # download's file, with `content`, beside an empty fresh tombstone. `extra` adds or overrides
  # entries. Returns the workspace and the download's path.
  defp plant_interrupted_disposal!(path, tmp, content, extra \\ %{}) do
    workspace = plant_workspace!(path, Map.merge(%{@staged => content, @tombstone => ""}, extra))
    download = Path.join(tmp, "downloads/#{Path.basename(workspace)}.srt")
    File.mkdir_p!(Path.dirname(download))
    File.ln!(Path.join(workspace, @staged), download)
    {workspace, download}
  end

  # Kills a correction of the sidecar at `path`, hardlinked to `download`, right after it created
  # the fresh tombstone. Returns its workspace, whose staged name still holds the download's file.
  defp kill_at_fresh_tombstone!(video, path, download) do
    use_barrier(%{operation: :create_bound, contains: @tombstone})
    kill_at_barrier(fn -> manual(video, 1_000) end, :create_bound)

    assert [workspace] = workspaces(path)
    assert Enum.sort(File.ls!(workspace)) == [@staged, @tombstone]
    assert same_inode?(Path.join(workspace, @staged), download)
    assert File.stat!(download).links == 2
    assert_fresh_tombstone(Path.join(workspace, @tombstone))
    workspace
  end

  # The two entries a failed rename of the fresh tombstone leaves (#1156), the same a kill right
  # after its create leaves: the staged name still holds the download's file, with `original`,
  # beside the empty fresh tombstone. Returns the workspace.
  defp assert_failed_rename_entries(path, original, download) do
    assert [workspace] = workspaces(path)
    assert Enum.sort(File.ls!(workspace)) == [@staged, @tombstone]
    assert same_inode?(Path.join(workspace, @staged), download)
    assert File.read!(download) == original
    assert File.stat!(download).links == 2
    assert_fresh_tombstone(Path.join(workspace, @tombstone))
    workspace
  end

  defp same_inode?(left, right) do
    identity = &Map.take(File.stat!(&1), [:major_device, :minor_device, :inode])
    identity.(left) == identity.(right)
  end

  # Backdates a workspace and its entries past the hour a sweep waits.
  defp age!(workspace) do
    old = System.os_time(:second) - 7_200
    for name <- File.ls!(workspace), do: File.touch!(Path.join(workspace, name), old)
    File.touch!(workspace, old)
  end

  defp replace(video, content) do
    sidecar = %{video_path: video, sidecar_path: sidecar(video).sidecar_path, language: "en"}
    SidecarTransaction.replace(sidecar, content, "opensubtitles_id", moviehash!(video))
  end

  # A fetch of a French sidecar the setup never created.
  defp replace_fr(video, content) do
    sidecar = %{
      video_path: video,
      sidecar_path: Path.rootname(video) <> ".fr.srt",
      language: "fr"
    }

    SidecarTransaction.replace(sidecar, content, "embedded", moviehash!(video))
  end

  defp workspaces(path) do
    path
    |> Path.dirname()
    |> Path.join(".cinder-subtitle-sync-cas-*")
    |> Path.wildcard(match_dot: true)
  end

  # The sidecar's second name in a download folder, the way `Library.Sidecars` imports one.
  defp hardlink_download!(path, tmp) do
    download = Path.join(tmp, "downloads/#{Path.basename(path)}")
    File.mkdir_p!(Path.dirname(download))
    File.ln!(path, download)
    download
  end

  # Runs `fun` until its exchange onto `path` committed, renames "newer" over `path` there, and
  # returns `fun`'s result.
  defp replace_after_exchange(path, tmp, fun) do
    use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-staged"})
    task = Task.async(fun)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
    newer = Path.join(tmp, "newer.srt")
    File.write!(newer, "newer")
    File.rename!(newer, path)
    send(pid, {ref, :continue})
    DiskTask.await(task)
  end

  # The workspace tombstone recovery and the reversal reuse read: empty, and no name but its own.
  defp assert_fresh_tombstone(staged) do
    assert File.read!(staged) == ""
    assert File.stat!(staged).links == 1
  end

  # Fails, before its effect, the next discard of a bound opened at the sidecar's name: the inode
  # a write's exchange displaced. The immutable original's name contains the sidecar's too, and its
  # retirement discards it after that inode. The exclusion keeps the failure off the original even
  # if that order changes.
  defp fail_displaced_discard_once(path) do
    fail_once(%{
      operation: :discard_bound,
      source_contains: Path.basename(path),
      excludes: ".cinder-sync-original",
      reason: :eio
    })
  end

  # A finished reversal's workspace beside `path`, whose staged name is `staged`: the only one left,
  # holding at most an empty staged file with no other name.
  defp assert_settled_reversal(path, staged) do
    workspace = Path.dirname(staged)
    assert workspaces(path) -- [workspace] == []

    if File.exists?(workspace) do
      assert File.ls!(workspace) -- [@staged] == []
      if File.exists?(staged), do: assert_fresh_tombstone(staged)
    end
  end

  # A correction killed after its exchange: the corrected bytes and the pending record stay, and
  # `recover/2` records them. The download keeps its bytes through that and a reset.
  defp assert_killed_correction_recovers(video, path, original, download) do
    assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
    assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
    assert :ok = SidecarTransaction.reconcile(video, moviehash!(video))
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
    assert File.read!(download) == original

    assert :ok = reset(video)
    assert File.read!(path) == original
    assert File.read!(download) == original
  end

  defp fail_manifest_once do
    fail_once(%{
      operation: :write_exclusive,
      source_contains: ".cinder-subtitle-manifest-",
      reason: :eio
    })
  end

  # Runs `fun` until the manifest write that follows its publication, writes "edited" over
  # `path` there, then fails that manifest write. Returns the log.
  defp edit_during_failed_manifest(path, fun) do
    use_barrier(%{
      operation: :write_exclusive,
      phase: :before,
      contains: ".cinder-subtitle-manifest-"
    })

    fail_manifest_once()

    capture_log(fn ->
      task = Task.async(fun)

      assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, _manifest},
                     DiskTask.timeout_ms()

      File.write!(path, "edited")
      send(pid, {ref, :continue})
      assert {:error, {:manifest, {:error, :eio}}} = DiskTask.await(task)
    end)
  end

  # The sidecar as `Sync.discover/1` hands it over: its paths plus the manifest track's fields.
  defp sidecar(video, language \\ "en") do
    track = Manifest.read(video).tracks[language]

    %{
      video_path: video,
      sidecar_path: Path.join(Path.dirname(video), track.file),
      language: language,
      managed_sha256: track.managed_sha256,
      sync: Map.get(track, :sync),
      reset_cleanup_sync: Map.get(track, :reset_cleanup_sync),
      backup_tombstone: Map.get(track, :backup_tombstone)
    }
  end

  defp record(moviehash, source, applied, overrides \\ %{}) do
    Map.merge(
      %{
        version: 6,
        status: "aligned",
        method: "manual",
        moviehash: moviehash,
        source_sha256: digest(source),
        applied_sha256: digest(applied),
        offset_ms: 1_000,
        rate: 1.0,
        score: nil,
        reason: nil
      },
      overrides
    )
  end

  defp pending(record, expected, operation_id \\ String.duplicate("a", 22)) do
    record
    |> Map.put(:status, "applying")
    |> Map.put(:expected_sha256, digest(expected))
    |> Map.put(:operation_id, operation_id)
  end

  # The exchange a reset makes: puts `content` back where `current` is.
  defp write_back!(path, content, current) do
    assert :ok = SidecarTransaction.AtomicFile.write(path, content, current)
  end

  defp use_barrier(barrier) do
    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)

    Application.put_env(
      :cinder,
      :filesystem_barrier,
      Map.merge(%{owner: self(), once: true}, barrier)
    )
  end

  # Runs `fun` until the exchange onto `path` committed and the displaced inode was disposed of
  # (the `disposal:` option: `:discard`, the default, empties it for `write/3` and `write/4`,
  # `:unlink` removes its workspace name for `swap/3`), then fails the next close of each
  # descriptor in order: `:staged`, `:target`, or the workspace `:directory` (only after
  # `:staged`, whose path it contains). Armed any earlier, a failure would hit the identity probes
  # that verify the exchange instead. A `paused:` function runs while `fun` waits after the
  # exchange. Returns `fun`'s result and the log; `fail_in_order/1` fails the test if a failure
  # never fired.
  defp fail_close_after_exchange(path, descriptors, fun, opts \\ []) do
    use_barrier(disposal_barrier(Keyword.get(opts, :disposal, :discard), path))

    with_log(fn ->
      task = Task.async(fun)
      assert_receive {:filesystem_barrier, pid, ref, _disposal, _displaced}, DiskTask.timeout_ms()
      Keyword.get(opts, :paused, fn -> :ok end).()

      fail_in_order(
        for descriptor <- descriptors,
            do: %{
              operation: :close_bound,
              source_contains: close_source(descriptor, path),
              reason: :eio
            }
      )

      send(pid, {ref, :continue})
      DiskTask.await(task)
    end)
  end

  defp disposal_barrier(:discard, path), do: %{operation: :discard_bound, contains: path}

  defp disposal_barrier(:unlink, _path),
    do: %{operation: :rm, contains: ".cinder-subtitle-sync-write-staged"}

  defp close_source(:staged, _path), do: ".cinder-subtitle-sync-write-staged"
  defp close_source(:target, path), do: path
  defp close_source(:directory, _path), do: ".cinder-subtitle-sync-cas-"

  # The workspace directory's close alone: the staged file's path contains the directory's.
  defp directory_close_failure(overrides \\ %{}) do
    Map.merge(
      %{
        operation: :close_bound,
        source_contains: close_source(:directory, nil),
        excludes: close_source(:staged, nil),
        reason: :eio
      },
      overrides
    )
  end

  # A fetch recorded despite an unacknowledged publication: its bytes, its track, no workspace.
  defp assert_fetched_track(video, target, language, origin) do
    assert File.read!(target) == @replacement
    assert %{origin: ^origin, managed_sha256: managed} = Manifest.read(video).tracks[language]
    assert managed == digest(@replacement)
    assert workspaces(target) == []
  end

  # A correction whose exchange committed unacknowledged: the corrected bytes and the pending
  # record stay until `recover/2` records them.
  defp assert_unacknowledged_correction(video, path, original, backup) do
    assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    assert File.read!(backup) == original
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

    assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  # Runs `fun` with its write's exchange onto `path` committed and one step after it failed: the
  # staged descriptor's close, the exchange's own acknowledgement, or the displaced inode's
  # discard. Returns `fun`'s result and the log.
  defp unacknowledged_write(:close, path, fun),
    do: fail_close_after_exchange(path, [:staged], fun)

  defp unacknowledged_write(:exchange, _path, fun) do
    fail_once(%{
      operation: :exchange,
      source_contains: ".cinder-subtitle-sync-write-",
      phase: :post_effect,
      reason: :eio
    })

    with_log(fun)
  end

  defp unacknowledged_write(:discard, path, fun) do
    fail_once(%{
      operation: :discard_bound,
      source_contains: Path.basename(path),
      phase: :post_effect,
      reason: :eio
    })

    with_log(fun)
  end

  # The `{:publication_committed, detail}` each `unacknowledged_write/3` failure gives.
  defp unacknowledged_detail(:close), do: {:descriptor_close_failed, :eio}
  defp unacknowledged_detail(:exchange), do: {:effect_committed, "exchange", :eio}
  defp unacknowledged_detail(:discard), do: {:effect_committed, "discard_bound", :eio}

  # A reset that put the original back and retired it: no record and no reset journal.
  defp assert_reset_finished(video, path, original, backup) do
    assert File.read!(path) == original
    assert File.read!(backup) == ""
    assert Manifest.sync(Manifest.read(video), "en") == nil
    assert Manifest.reset_cleanup_sync(Manifest.read(video), "en") == nil
  end

  # The one warning a recovery logs when its write published a correction, or restored the
  # original, unacknowledged.
  defp assert_unacknowledged_warning(log, path, detail) do
    assert [line] =
             log
             |> String.split("\n")
             |> Enum.filter(&(&1 =~ "subtitle publication unacknowledged"))

    assert line =~ "[warning] subtitle publication unacknowledged for #{path}: #{inspect(detail)}"
  end

  # A first correction killed just before its exchange: its staged bytes wait in the workspace
  # and its pending record reads "applying".
  defp interrupt_before_exchange!(video, :manual) do
    use_barrier(%{operation: :exchange, phase: :before, contains: ".cinder-subtitle-sync-write-"})
    kill_at_barrier(fn -> manual(video, 1_000) end, :exchange)
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
  end

  # The same, recorded as automatic: recovery publishes its staged bytes instead of recomputing.
  defp interrupt_before_exchange!(video, :automatic) do
    interrupt_before_exchange!(video, :manual)
    record = Manifest.sync(Manifest.read(video), "en")
    assert :ok = Manifest.put_sync(video, "en", %{record | method: "audio", score: 30.0})
  end

  # A recovery that recorded the interrupted correction: its bytes and an "aligned" record that
  # keeps the correction's `method`.
  defp assert_recorded_correction(result, video, path, method) do
    assert {:ok, %{sync: %{status: "aligned", method: ^method}}} = result
    assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    assert %{status: "aligned", method: ^method} = Manifest.sync(Manifest.read(video), "en")
  end

  # Runs `fun` until it reaches the barrier at `operation`, then kills it there: a crash at that
  # exact step. Returns the path the barrier paused on.
  defp kill_at_barrier(fun, operation) do
    {:ok, task} = Task.start(fun)
    monitor = Process.monitor(task)

    assert_receive {:filesystem_barrier, ^task, _ref, ^operation, paused_path},
                   DiskTask.timeout_ms()

    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    paused_path
  end

  defp workspace_staged_files(path) do
    path
    |> Path.dirname()
    |> Path.join(".cinder-subtitle-sync-cas-*/.cinder-subtitle-sync-write-staged")
    |> Path.wildcard(match_dot: true)
  end

  defp drain_write_bound_messages do
    receive do
      {:write_bound, _} -> drain_write_bound_messages()
    after
      0 -> :ok
    end
  end

  defp assert_tombstone_rebound(video, backup) do
    assert {:ok, bound} = Disk.open_bound(backup, [:read, :raw, :binary])
    assert %{identity: identity} = Manifest.backup_tombstone(Manifest.read(video), "en")
    assert identity == Tuple.to_list(bound.identity)
    assert :ok = Disk.close_bound(bound)
  end

  defp managed_srt!(video, language \\ "en") do
    path = Path.rootname(video) <> ".#{language}.srt"
    content = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    File.write!(path, content)

    assert :ok =
             Manifest.put(
               video,
               moviehash!(video),
               language,
               "opensubtitles_hash",
               path,
               digest(content)
             )

    path
  end

  defp owned_backup!(video, sidecar, content, language \\ "en") do
    backup = backup(sidecar)
    assert {:ok, bound} = Disk.create_bound(backup, content)
    assert :ok = Manifest.put_backup_tombstone(video, language, bound.identity)
    assert :ok = Disk.close_bound(bound)
    backup
  end

  # The on-disk name of a sidecar's immutable original: a persisted format, so spelled out here.
  defp backup(path),
    do: Path.join(Path.dirname(path), ".#{Path.basename(path)}.cinder-sync-original")

  # Reproduces the production state behind issue #350: a corrected-then-reset track whose
  # manifest holds an owned backup tombstone with no record, while the logical backup path is a
  # zero-byte container on two mergerfs branches. The shim supplies the mergerfs surface (mount
  # detection, allpaths, and the control file through Cinder.Test.MergerfsControl) that the test
  # environment cannot; the proofs and effects are the real helper. `legacy_identity` records a
  # tombstone identity that mergerfs also reports as the union identity; `recorded_identity`
  # records one and leaves the union identity to the real helper. The logical path is the
  # branch-0 container itself, so the union identity the helper reports (the logical
  # descriptor's fstat) would equal the physical one, where real mergerfs would report a hash.
  # `inodecalc` defaults to "path-hash" so the helper reports no union identity unless a test
  # asks for one. `mount_root` sets the mount's root field, `/` by default; another value models
  # a bind of that pool subdirectory, through which no control file is reachable.
  defp duplicate_tombstones!(video, tmp, opts \\ []) do
    path = sidecar(video).sidecar_path
    original = File.read!(path)
    assert {:ok, :corrected, _} = manual(video, 1_000)
    assert :ok = reset(video)

    backup = backup(path)
    assert File.read!(backup) == ""
    assert %{identity: identity} = Manifest.backup_tombstone(Manifest.read(video), "en")
    assert Manifest.sync(Manifest.read(video), "en") == nil

    recorded_identity = opts[:legacy_identity] || opts[:recorded_identity]

    if recorded_identity do
      assert :ok = Manifest.put_backup_tombstone(video, "en", recorded_identity)
    end

    root = Application.fetch_env!(:cinder, :movies_library_path)
    control = Path.join(root, ".mergerfs")
    mount_root = Keyword.get(opts, :mount_root, "/")
    if mount_root == "/", do: File.write!(control, "")
    relative = Path.relative_to(backup, root)
    branch = Path.join(tmp, "branch-b")
    duplicate = Path.join(branch, relative)
    File.mkdir_p!(Path.dirname(duplicate))
    File.write!(duplicate, "")

    layout = %{
      logical: backup,
      containers: [backup, duplicate],
      branches: [root, branch],
      mount_root: mount_root,
      control: control
    }

    helper = mergerfs_duplicate_helper!(tmp, layout, opts)

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)

    %{path: path, backup: backup, duplicate: duplicate, original: original, identity: identity}
  end

  defp mergerfs_duplicate_helper!(tmp, layout, opts) do
    %{logical: logical, branches: branches} = layout
    legacy_identity = opts[:legacy_identity]
    inodecalc = Keyword.get(opts, :inodecalc, "path-hash")
    control_file = MergerfsControl.python(layout.control, branches, inodecalc: inodecalc)
    helper = Path.join(tmp, "mergerfs_duplicate_helper.py")
    real_helper = Path.expand("../../../priv/rooted_fs.py", __DIR__)

    File.write!(helper, """
    import os
    import sys

    LOGICAL = #{inspect(logical)}
    CONTAINERS = #{inspect(layout.containers)}
    BRANCHES = #{inspect(branches)}
    MOUNT_ROOT = #{inspect(layout.mount_root)}
    LEGACY_IDENTITY = #{if legacy_identity, do: Jason.encode!(legacy_identity), else: "None"}
    ALIAS_IDENTITY = #{if opts[:alias_identity], do: "True", else: "False"}
    REAL_HELPER = #{inspect(real_helper)}

    real_getxattr = os.getxattr

    def targeted():
        return any(os.path.basename(LOGICAL) in arg for arg in sys.argv[2:])

    def getxattr(path, name, **kwargs):
        if name == "user.mergerfs.allpaths":
            existing = [c for c in CONTAINERS if os.path.lexists(c)]
            if existing:
                return b"\\0".join(os.fsencode(c) for c in existing)
        # The surviving container IS the logical path here, so the mount maps
        # onto itself: this keeps the real mergerfs reactivation path (backing
        # location lookup + mapping verification) exercised after reconciling.
        if name == "user.mergerfs.fullpath" and targeted():
            return os.fsencode(LOGICAL)
        if name == "user.mergerfs.basepath" and targeted():
            return os.fsencode(BRANCHES[0])
        return real_getxattr(path, name, **kwargs)

    os.getxattr = getxattr

    # exec into a namespace we own so the helper's own functions resolve
    # mergerfs_mount through this dict; runpy would hand back a detached copy.
    namespace = {"__name__": "rooted_fs_shim", "__file__": REAL_HELPER}
    with open(REAL_HELPER, encoding="utf-8") as source:
        exec(compile(source.read(), REAL_HELPER, "exec"), namespace)

    #{control_file}

    if LEGACY_IDENTITY is not None:
        namespace["legacy_union_identity"] = lambda mountpoint, fd: LEGACY_IDENTITY

    if ALIAS_IDENTITY:
        real_tombstone_identity = namespace["tombstone_identity"]
        aliased_identity = [None]

        def tombstone_identity(branch, relative):
            identity = real_tombstone_identity(branch, relative)
            if aliased_identity[0] is None:
                aliased_identity[0] = identity
            return aliased_identity[0]

        namespace["tombstone_identity"] = tombstone_identity

    real_mount = namespace["mergerfs_mount"]

    # Scope the mergerfs illusion to the backup path, and keep it mergerfs after
    # the duplicate is gone so the post-reconciliation reactivation still runs
    # through hold_open_mergerfs rather than the ordinary rooted open.
    real_mount_fields = namespace["mergerfs_mount_fields"]
    namespace["mergerfs_mount_fields"] = (
        lambda path: (BRANCHES[0], MOUNT_ROOT) if targeted() else real_mount_fields(path)
    )
    namespace["mergerfs_mount"] = lambda path: targeted() or real_mount(path)

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

  defp legacy_identity_helper!(tmp, path_fragment, identity) do
    helper = Path.join(tmp, "legacy_identity_helper.py")
    real_helper = Path.expand("../../../priv/rooted_fs.py", __DIR__)

    File.write!(helper, """
    import json
    import os
    import sys

    if (
        sys.argv[1] != "hold"
        or #{inspect(path_fragment)} not in sys.argv[3]
        or sys.argv[4] == "create"
    ):
        os.execv(sys.executable, [sys.executable, #{inspect(real_helper)}] + sys.argv[1:])

    path = os.path.join(sys.argv[2], sys.argv[3])
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    print(json.dumps({"ok": {"fd": fd, "union_identity": #{Jason.encode!(identity)}}}), flush=True)
    sys.stdin.buffer.read()
    os.close(fd)
    """)

    helper
  end

  defp shifted(content),
    do: String.replace(content, "00:00:01,000 --> 00:00:02,000", "00:00:02,000 --> 00:00:03,000")

  defp digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp moviehash!(video) do
    assert {:ok, hash} = Moviehash.of_file(video)
    hash
  end
end
