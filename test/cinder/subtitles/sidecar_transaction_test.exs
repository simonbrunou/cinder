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
  alias Cinder.Test.MergerfsControl

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

      assert_receive {:filesystem_barrier, pid, ref, :moviehash_data, ^video}, 15_000
      File.write!(video, @changed_video)
      send(pid, {ref, :continue})

      assert {:error, :video_changed} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000

      assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
      assert File.read!(backup) == original

      send(pid, {ref, :continue})
      assert {:ok, :corrected, _} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000
      File.write!(path, external)
      send(pid, {ref, :continue})

      assert {:error, :concurrent_change} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000
      File.rename!(replacement, path)
      send(pid, {ref, :continue})

      assert {:error, :concurrent_change} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000

      fail_once(%{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio
      })

      send(pid, {ref, :continue})
      assert {:error, {:manifest, :eio}} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000

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
      assert {:error, {:manifest_and_rollback_failed, :eio, :enospc}} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000

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
               Task.await(task, 15_000)

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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000

      fail_once(%{
        operation: :write_exclusive,
        source_contains: ".cinder-subtitle-manifest-",
        reason: :eio
      })

      send(pid, {ref, :continue})
      assert {:error, {:manifest, :eio}} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000

      fail_in_order([
        %{
          operation: :write_exclusive,
          source_contains: ".cinder-subtitle-manifest-",
          reason: :eio
        },
        %{operation: :exchange, source_contains: ".cinder-subtitle-sync-write-", reason: :eacces}
      ])

      send(pid, {ref, :continue})
      assert {:error, {:manifest_and_rollback_failed, :eio, :eacces}} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000
      File.write!(video, @changed_video)
      send(pid, {ref, :continue})

      assert {:error, :video_changed} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000
      File.write!(video, @changed_video)

      fail_once(%{
        operation: :exchange,
        source_contains: ".cinder-subtitle-sync-write-",
        reason: :eacces
      })

      send(pid, {ref, :continue})

      assert {:error, {:correction_and_rollback_failed, :video_changed, :eacces}} =
               Task.await(task, 15_000)

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
      assert_receive {:filesystem_barrier, pid, ref, :create_bound, staged}, 15_000
      File.ln_s!(outside, staged)
      send(pid, {ref, :continue})

      assert {:error, _reason} = Task.await(task, 15_000)
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

    test "a committed exchange leaves an empty workspace tombstone", %{video: video, path: path} do
      assert {:ok, :corrected, _} = manual(video, 1_000)

      assert [staged] = workspace_staged_files(path)
      assert File.read!(staged) == ""
      assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
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
      assert File.read!(Path.join(workspace, ".cinder-subtitle-sync-write-staged")) == ""
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

      assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
      assert File.dir?(Path.dirname(staged))
      assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
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
      assert File.read!(backup) == ""
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
      assert_receive {:filesystem_barrier, pid, ref, :mkdir_exclusive, _workspace}, 15_000
      File.write!(path, "edited")
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :concurrent_change}}} = Task.await(task, 15_000)
      assert File.read!(path) == "edited"
      assert %{origin: "opensubtitles_hash"} = Manifest.read(video).tracks["en"]
      assert workspaces(path) == []
    end

    test "a fetch leaves bytes edited just before its exchange alone", %{video: video, path: path} do
      use_barrier(%{operation: :exchange, phase: :before, contains: ".cinder-subtitle-sync-"})

      task = Task.async(fn -> replace(video, @replacement) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000
      File.write!(path, "edited")
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :captured_target_changed}}} = Task.await(task, 15_000)
      assert File.read!(path) == "edited"
      assert %{origin: "opensubtitles_hash"} = Manifest.read(video).tracks["en"]
      assert workspaces(path) == []
    end

    test "a fetch never replaces a sidecar that appeared after its snapshot", %{video: video} do
      target = Path.rootname(video) <> ".fr.srt"
      use_barrier(%{operation: :rename_exclusive, phase: :before, contains: "cas-"})

      task = Task.async(fn -> replace_fr(video, @replacement) end)
      assert_receive {:filesystem_barrier, pid, ref, :rename_exclusive, _staged}, 15_000
      File.write!(target, "external")
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :concurrent_change}}} = Task.await(task, 15_000)
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
      use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-staged"})

      task = Task.async(fn -> replace(video, @replacement) end)
      assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, 15_000
      newer = Path.join(tmp, "newer.srt")
      File.write!(newer, "newer")
      File.rename!(newer, path)
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :concurrent_change}}} = Task.await(task, 15_000)
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
      assert_receive {:filesystem_barrier, pid, ref, :rename_exclusive, _staged}, 15_000
      File.write!(target, @replacement)
      send(pid, {ref, :continue})

      assert {:error, {:write, {:error, :concurrent_change}}} = Task.await(task, 15_000)
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
          :unlink
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
      assert_receive {:filesystem_barrier, pid, ref, :write_exclusive, _manifest}, 15_000
      File.write!(path, "edited")
      send(pid, {ref, :continue})
      assert {:error, {:manifest, {:error, :eio}}} = Task.await(task, 15_000)
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
  # (`:discard` empties it for `write/3` and `write/4`, `:unlink` removes its workspace name for
  # `swap/3`), then fails the next close of each descriptor in order: `:staged`, `:target`, or the
  # workspace `:directory` (only after `:staged`, whose path it contains). Armed any earlier, a
  # failure would hit the identity probes that verify the exchange instead. Returns `fun`'s result
  # and the log; `fail_in_order/1` fails the test if a failure never fired.
  defp fail_close_after_exchange(path, descriptors, fun, disposal \\ :discard) do
    use_barrier(disposal_barrier(disposal, path))

    with_log(fn ->
      task = Task.async(fun)
      assert_receive {:filesystem_barrier, pid, ref, _disposal, _displaced}, 15_000

      fail_in_order(
        for descriptor <- descriptors,
            do: %{
              operation: :close_bound,
              source_contains: close_source(descriptor, path),
              reason: :eio
            }
      )

      send(pid, {ref, :continue})
      Task.await(task, 15_000)
    end)
  end

  defp disposal_barrier(:discard, path), do: %{operation: :discard_bound, contains: path}

  defp disposal_barrier(:unlink, _path),
    do: %{operation: :rm, contains: ".cinder-subtitle-sync-write-staged"}

  defp close_source(:staged, _path), do: ".cinder-subtitle-sync-write-staged"
  defp close_source(:target, path), do: path
  defp close_source(:directory, _path), do: ".cinder-subtitle-sync-cas-"

  # A correction whose exchange committed unacknowledged: the corrected bytes and the pending
  # record stay until `recover/2` records them.
  defp assert_unacknowledged_correction(video, path, original, backup) do
    assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    assert File.read!(backup) == original
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

    assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  # Runs `fun` until it reaches the barrier at `operation`, then kills it there: a crash at that
  # exact step. Returns the path the barrier paused on.
  defp kill_at_barrier(fun, operation) do
    {:ok, task} = Task.start(fun)
    monitor = Process.monitor(task)
    assert_receive {:filesystem_barrier, ^task, _ref, ^operation, paused_path}, 15_000
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
