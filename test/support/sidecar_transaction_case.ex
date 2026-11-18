defmodule Cinder.Test.SidecarTransactionCase do
  @moduledoc """
  The setup and helpers of the `Cinder.Subtitles.SidecarTransaction*Test` modules, which drive
  `Cinder.Subtitles.SidecarTransaction` on real temp directories through the real `Disk`
  filesystem. They were one module until #1474 split it by `describe` block, so that test
  partitions can run its parts at once.

  `use Cinder.Test.SidecarTransactionCase` tags the module `:tmp_dir`, defines the attributes
  below, imports these helpers, and adds the setup: a movie library and a TV library under the
  test's `tmp_dir`, the real `Disk` filesystem and path policy, and a managed English sidecar
  beside `Movie/Movie.mkv`, recorded in its manifest. It passes the test `video`, `path`,
  `original` (the sidecar's bytes) and `backup` (the immutable original's path).
  """

  import Cinder.Test.BarrierFilesystem, only: [fail_once: 1, fail_in_order: 1]
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.CaptureLog

  alias Cinder.Library.Filesystem.Disk
  alias Cinder.Subtitles.{Manifest, Moviehash, SidecarTransaction}
  alias Cinder.Subtitles.Sync.Timing
  alias Cinder.Test.{DiskTask, MergerfsControl}

  @changed_video "x" <> String.duplicate("v", 131_071)
  @replacement "1\n00:00:10,000 --> 00:00:11,000\nReplacement\n\n"
  # A workspace's entries: persisted names, so spelled out here.
  @staged ".cinder-subtitle-sync-write-staged"
  @tombstone ".cinder-subtitle-sync-write-tombstone"
  # The detail of a correction whose two names went unverified after its exchange (#1284).
  @names_unverified {:exchanged_names_unverified, :displaced_kept}
  # The detail of a correction whose rollback failed after the staged name's check (#1322), and
  # the result the rollback's failure keeps when the bytes do not settle it.
  @rollback_kept {:displaced_rollback_failed, :eio, :displaced_kept}
  @rollback_failed {:exchange_rollback_failed, {:error, :concurrent_change}, :eio}

  defmacro __using__(_opts) do
    quote do
      import Cinder.Test.SidecarTransactionCase

      @moduletag :tmp_dir
      @changed_video unquote(Macro.escape(@changed_video))
      @replacement unquote(Macro.escape(@replacement))
      @staged unquote(Macro.escape(@staged))
      @tombstone unquote(Macro.escape(@tombstone))
      @names_unverified unquote(Macro.escape(@names_unverified))
      @rollback_kept unquote(Macro.escape(@rollback_kept))
      @rollback_failed unquote(Macro.escape(@rollback_failed))

      setup %{tmp_dir: tmp}, do: library!(tmp)
    end
  end

  @doc false
  def library!(tmp) do
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

  # A manual correction by `offset_ms`, driven through the transaction the way
  # `Cinder.Subtitles.Sync.manual/4` drives it: recover, start from the original, publish.
  def manual(video, offset_ms, moviehash \\ nil) do
    moviehash = moviehash || moviehash!(video)

    with {:ok, sidecar} <- recovered(sidecar(video), moviehash),
         {:ok, current} <- File.read(sidecar.sidecar_path),
         {:ok, original} <- SidecarTransaction.original(sidecar, current) do
      {:ok, corrected} = Timing.retime(original, ".srt", offset_ms, 1.0)
      record = record(moviehash, original, corrected, %{offset_ms: offset_ms})
      SidecarTransaction.publish(sidecar, current, corrected, record)
    end
  end

  def recovered(sidecar, moviehash) do
    case SidecarTransaction.recover(sidecar, moviehash) do
      {:ok, sidecar} -> {:ok, sidecar}
      {:review, reason, _sidecar} -> {:error, reason}
    end
  end

  def recover(video), do: SidecarTransaction.recover(sidecar(video), moviehash!(video))

  def reset(video), do: SidecarTransaction.restore_original(sidecar(video), moviehash!(video))

  def reconcile(video), do: SidecarTransaction.reconcile(video, moviehash!(video))

  def operation_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  # A workspace beside `path` holding `entries` (name => bytes), the way a correction or a reset
  # leaves one. Returns its path.
  def plant_workspace!(path, entries, id \\ operation_id()) do
    workspace = Path.join(Path.dirname(path), ".cinder-subtitle-sync-cas-#{id}")
    File.mkdir!(workspace)
    File.chmod!(workspace, 0o700)
    for {name, content} <- entries, do: File.write!(Path.join(workspace, name), content)
    workspace
  end

  # Another video in the folder of `video` with a pending correction, and the empty workspace
  # its record names beside `path`. Returns that video and the workspace.
  def other_video_pending_workspace!(video, path) do
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
  def edit_manifest_track!(video, language, change) do
    manifest = Manifest.path(video)
    json = manifest |> File.read!() |> Jason.decode!()

    File.write!(
      manifest,
      Jason.encode!(update_in(json, ["tracks", language], &edit_track(change, &1)))
    )
  end

  # Makes the manifest of `video` one a sweep cannot read in full.
  def break_manifest!(video, :unreadable) do
    fail_once(%{
      operation: :read,
      source_contains: Path.basename(Manifest.path(video)),
      reason: :eacces
    })
  end

  def break_manifest!(video, :malformed), do: File.write!(Manifest.path(video), "{not json")

  def break_manifest!(video, track_change), do: edit_manifest_track!(video, "en", track_change)

  def edit_track(:invalid_sync, track), do: put_in(track, ["sync", "status"], "unknown")

  def edit_track(:invalid_reset_journal, track),
    do: Map.put(track, "reset_cleanup_sync", %{"status" => "unknown"})

  def edit_track(:invalid_replacement_journal, track),
    do: Map.put(track, "replacement_cleanup_sync", %{"status" => "unknown"})

  def edit_track(:without_file, track), do: Map.delete(track, "file")

  def warning_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]"))

  # The two entries `replace_shared_tombstone/2` leaves when killed between creating the fresh
  # tombstone and renaming it over the staged name (#1131): the staged name still holds a
  # download's file, with `content`, beside an empty fresh tombstone. `extra` adds or overrides
  # entries. Returns the workspace and the download's path.
  def plant_interrupted_disposal!(path, tmp, content, extra \\ %{}) do
    workspace = plant_workspace!(path, Map.merge(%{@staged => content, @tombstone => ""}, extra))
    download = Path.join(tmp, "downloads/#{Path.basename(workspace)}.srt")
    File.mkdir_p!(Path.dirname(download))
    File.ln!(Path.join(workspace, @staged), download)
    {workspace, download}
  end

  # Kills a correction of the sidecar at `path`, hardlinked to `download`, right after it created
  # the fresh tombstone. Returns its workspace, whose staged name still holds the download's file.
  def kill_at_fresh_tombstone!(video, path, download) do
    use_barrier(%{operation: :create_bound, contains: @tombstone})
    kill_at_barrier(fn -> manual(video, 1_000) end, :create_bound)

    assert [workspace] = workspaces(path)
    assert Enum.sort(File.ls!(workspace)) == [@staged, @tombstone]
    assert same_inode?(Path.join(workspace, @staged), download)
    assert File.stat!(download).links == 2
    assert_fresh_tombstone(Path.join(workspace, @tombstone))
    workspace
  end

  def kill_before_fresh_tombstone!(video, path, tmp) do
    download = hardlink_download!(path, tmp)
    use_barrier(%{operation: :create_bound, phase: :before, contains: @tombstone})
    kill_at_barrier(fn -> manual(video, 1_000) end, :create_bound)

    assert [workspace] = workspaces(path)
    assert File.ls!(workspace) == [@staged]
    assert same_inode?(Path.join(workspace, @staged), download)
    assert File.stat!(download).links == 2
    {workspace, download}
  end

  # The states of the #1290 table: kills a correction, then arms one failure of the disposal step
  # the recovery's cleanup runs in its workspace. Returns that workspace and the download sharing
  # its staged inode, or nil when none does.
  def interrupt_disposal!(:fresh_tombstone, video, path, tmp) do
    download = hardlink_download!(path, tmp)
    workspace = kill_at_fresh_tombstone!(video, path, download)
    fresh = Path.join(workspace, @tombstone)
    fail_once(%{operation: :rename, source_contains: fresh, reason: :eio})
    {workspace, download}
  end

  def interrupt_disposal!(:no_fresh_tombstone, video, path, tmp) do
    {workspace, download} = kill_before_fresh_tombstone!(video, path, tmp)
    fresh = Path.join(workspace, @tombstone)
    fail_once(%{operation: :rename, source_contains: fresh, reason: :eio})
    {workspace, download}
  end

  # `rename/2` takes no `phase: :post_effect`, so the callback performs the rename the failure
  # then reports as committed.
  def interrupt_disposal!(:committed_rename, video, path, tmp) do
    {workspace, download} = kill_before_fresh_tombstone!(video, path, tmp)
    fresh = Path.join(workspace, @tombstone)
    staged = Path.join(workspace, @staged)

    fail_in_order([
      %{
        operation: :rename,
        source_contains: fresh,
        reason: {:effect_committed, "rename", :eio},
        callback: fn -> :ok = Disk.rename(fresh, staged) end
      }
    ])

    {workspace, download}
  end

  # The rename fails, then so does the close of the staged file the cleanup held.
  def interrupt_disposal!(:unclosed_staged, video, path, tmp) do
    download = hardlink_download!(path, tmp)
    workspace = kill_at_fresh_tombstone!(video, path, download)

    fail_in_order([
      %{operation: :rename, source_contains: Path.join(workspace, @tombstone), reason: :eio},
      %{operation: :close_bound, source_contains: Path.join(workspace, @staged), reason: :ebadf}
    ])

    {workspace, download}
  end

  def interrupt_disposal!(:committed_discard, video, path, _tmp) do
    use_barrier(%{operation: :discard_bound, phase: :before, contains: Path.basename(path)})
    kill_at_barrier(fn -> manual(video, 1_000) end, :discard_bound)
    assert [staged] = workspace_staged_files(path)
    assert File.stat!(staged).links == 1

    fail_once(%{
      operation: :discard_bound,
      source_contains: staged,
      reason: :eio,
      phase: :post_effect
    })

    {Path.dirname(staged), nil}
  end

  def assert_download_kept(nil, _original), do: :ok

  def assert_download_kept(download, original) do
    assert File.read!(download) == original
    assert File.stat!(download).links == 1
  end

  # Runs `cleanup_pending/4` over a workspace whose staged file holds the target's bytes, the
  # expected side, with the discard of that file failing, then optionally its close. Asserts the
  # kept line and the staged bytes, and returns the result and the workspace.
  def cleanup_kept_beside_expected(path, fail_close?) do
    current = File.read!(path)
    id = operation_id()
    workspace = plant_workspace!(path, %{@staged => current}, id)
    staged = Path.join(workspace, @staged)
    discard = %{operation: :discard_bound, source_contains: staged, reason: :eio}
    unclosed = %{operation: :close_bound, source_contains: staged, reason: :ebadf}
    fail_in_order(if fail_close?, do: [discard, unclosed], else: [discard])

    {result, log} =
      with_log(fn ->
        SidecarTransaction.AtomicFile.cleanup_pending(path, id, digest(current), digest("x"))
      end)

    assert log =~ "subtitle workspace kept at #{workspace}: {:discard_failed, :eio}"
    assert File.read!(staged) == current
    {result, workspace}
  end

  def run_recovery(:recover, video), do: recover(video)

  def run_recovery(:reset, video), do: reset(video)

  def assert_recovery_result(:recover, result, video, path, _original) do
    assert {:ok, %{sync: %{status: "aligned"}}} = result
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
    assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
  end

  def assert_recovery_result(:reset, result, video, path, original) do
    assert :ok = result
    assert Manifest.sync(Manifest.read(video), "en") == nil
    assert File.read!(path) == original
  end

  # The cleanup's kept line, then one removal line for the same workspace, both warnings.
  def assert_removal_logged(log, workspace, reason) do
    lines = warning_lines(log)
    kept_line = "[warning] subtitle workspace kept at #{workspace}: #{inspect(reason)}"
    kept = Enum.find_index(lines, &String.ends_with?(&1, kept_line))
    assert is_integer(kept)

    removals =
      for {line, index} <- Enum.with_index(log |> String.split("\n")),
          line =~ "subtitle workspace removed",
          do: {line, index}

    assert [{removal, _index}] = removals
    assert String.ends_with?(removal, "[warning] subtitle workspace removed at #{workspace}")
    assert Enum.find_index(lines, &(&1 == removal)) > kept
  end

  # The two entries a failed rename of the fresh tombstone leaves (#1156), the same a kill right
  # after its create leaves: the staged name still holds the download's file, with `original`,
  # beside the empty fresh tombstone. Returns the workspace.
  def assert_failed_rename_entries(path, original, download) do
    assert [workspace] = workspaces(path)
    assert Enum.sort(File.ls!(workspace)) == [@staged, @tombstone]
    assert same_inode?(Path.join(workspace, @staged), download)
    assert File.read!(download) == original
    assert File.stat!(download).links == 2
    assert_fresh_tombstone(Path.join(workspace, @tombstone))
    workspace
  end

  def same_inode?(left, right) do
    identity = &Map.take(File.stat!(&1), [:major_device, :minor_device, :inode])
    identity.(left) == identity.(right)
  end

  # Backdates a workspace and its entries past the hour a sweep waits.
  def age!(workspace) do
    old = System.os_time(:second) - 7_200
    for name <- File.ls!(workspace), do: File.touch!(Path.join(workspace, name), old)
    File.touch!(workspace, old)
  end

  def replace(video, content), do: replace_as(video, content, "opensubtitles_id")

  def replace_as(video, content, origin) do
    sidecar = %{video_path: video, sidecar_path: sidecar(video).sidecar_path, language: "en"}
    SidecarTransaction.replace(sidecar, content, origin, moviehash!(video))
  end

  # A fetch of a French sidecar the setup never created.
  def replace_fr(video, content) do
    sidecar = %{
      video_path: video,
      sidecar_path: Path.rootname(video) <> ".fr.srt",
      language: "fr"
    }

    SidecarTransaction.replace(sidecar, content, "embedded", moviehash!(video))
  end

  def workspaces(path) do
    path
    |> Path.dirname()
    |> Path.join(".cinder-subtitle-sync-cas-*")
    |> Path.wildcard(match_dot: true)
  end

  # The sidecar's second name in a download folder, the way `Library.Sidecars` imports one.
  def hardlink_download!(path, tmp) do
    download = Path.join(tmp, "downloads/#{Path.basename(path)}")
    File.mkdir_p!(Path.dirname(download))
    File.ln!(path, download)
    download
  end

  # Runs `fun` until its exchange onto `path` committed, renames "newer" over `path` there, and
  # returns `fun`'s result. `resume.(pid, ref)` lets the paused task go on.
  def replace_after_exchange(path, tmp, fun, resume \\ &send(&1, {&2, :continue})) do
    use_barrier(%{operation: :exchange, contains: ".cinder-subtitle-sync-write-staged"})
    task = Task.async(fun)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
    newer = Path.join(tmp, "newer.srt")
    File.write!(newer, "newer")
    File.rename!(newer, path)
    resume.(pid, ref)
    DiskTask.await(task)
  end

  # Runs `fun` until its exchange committed, runs `paused` while it waits there, and returns
  # `fun`'s result.
  def after_exchange(fun, paused) do
    use_barrier(%{operation: :exchange, contains: @staged})
    task = Task.async(fun)
    assert_receive {:filesystem_barrier, pid, ref, :exchange, _staged}, DiskTask.timeout_ms()
    paused.()
    send(pid, {ref, :continue})
    DiskTask.await(task)
  end

  # Runs `fun` until its exchange onto `path` committed, then fails the next open of `path` with
  # `:eio`: the check that `path` still names the published inode. Each of `more` fails in order
  # after it. Armed any earlier, the failure would hit the opens before the exchange.
  def fail_target_open_after_exchange(path, fun, more \\ []) do
    after_exchange(fun, fn ->
      fail_in_order([%{operation: :open_bound, source_contains: path, reason: :eio} | more])
    end)
  end

  # Runs `fun` until its exchange onto `path` committed, then fails the next open of `path` and
  # then the next open of the staged name with `:eio`: the two checks that the exchange swapped
  # the two inodes. Each of `more` fails in order after them.
  def fail_names_open_after_exchange(path, fun, more \\ []),
    do: after_exchange(fun, fn -> fail_in_order(names_open_failures(path) ++ more) end)

  # Runs `fun` until its exchange committed, then fails the next open of the staged name with
  # `:eio`: the exchange's check that it names the displaced inode, which sends the write to its
  # rollback. Each of `more` fails in order after it.
  def fail_staged_open_after_exchange(fun, more),
    do: after_exchange(fun, fn -> fail_in_order([staged_open_failure() | more]) end)

  def staged_open_failure, do: %{operation: :open_bound, source_contains: @staged, reason: :eio}

  def names_open_failures(path) do
    [
      %{operation: :open_bound, source_contains: path, reason: :eio},
      %{operation: :open_bound, source_contains: @staged, reason: :eio}
    ]
  end

  # Resumes a disposal paused at its exchange until it created the fresh tombstone, then fails
  # the next open of the staged name: the check before the fresh tombstone's rename. The
  # exchange's own checks open the staged name too, so the failure is armed only here.
  def fail_staged_check(pid, ref) do
    use_barrier(%{operation: :create_bound, contains: @tombstone})
    send(pid, {ref, :continue})

    assert_receive {:filesystem_barrier, ^pid, ref, :create_bound, _fresh},
                   DiskTask.timeout_ms()

    fail_once(%{operation: :open_bound, source_contains: @staged, reason: :eacces})
    send(pid, {ref, :continue})
  end

  # #1187: a disposal on the external-preservation branch failed before its fresh tombstone's
  # rename, so the staged name alone holds the download's inode, and no record names the
  # workspace. A reconcile keeps it for the hour, then retires it, since the immutable original
  # holds its bytes. The download keeps them with one link, and the sidecar keeps "newer".
  def assert_staged_download_swept(video, path, original, backup, download) do
    assert [workspace] = workspaces(path)
    assert File.ls!(workspace) == [@staged]
    assert same_inode?(Path.join(workspace, @staged), download)
    assert File.stat!(download).links == 2
    assert Manifest.sync(Manifest.read(video), "en") == nil
    assert File.read!(path) == "newer"

    assert :ok = reconcile(video)
    assert File.ls!(workspace) == [@staged]
    assert File.stat!(download).links == 2

    age!(workspace)
    assert :ok = reconcile(video)
    refute File.exists?(workspace)
    assert workspaces(path) == []
    assert File.read!(download) == original
    assert File.stat!(download).links == 1
    assert File.read!(backup) == original
    assert File.read!(path) == "newer"
  end

  # The workspace tombstone recovery and the reversal reuse read: empty, and no name but its own.
  def assert_fresh_tombstone(staged) do
    assert File.read!(staged) == ""
    assert File.stat!(staged).links == 1
  end

  # Fails, before its effect, the next discard of a bound opened at the sidecar's name: the inode
  # a write's exchange displaced. The immutable original's name contains the sidecar's too, and its
  # retirement discards it after that inode. The exclusion keeps the failure off the original even
  # if that order changes.
  def fail_displaced_discard_once(path) do
    fail_once(%{
      operation: :discard_bound,
      source_contains: Path.basename(path),
      excludes: ".cinder-sync-original",
      reason: :eio
    })
  end

  # A finished reversal's workspace beside `path`, whose staged name is `staged`: the only one left,
  # holding at most an empty staged file with no other name.
  def assert_settled_reversal(path, staged) do
    workspace = Path.dirname(staged)
    assert workspaces(path) -- [workspace] == []

    if File.exists?(workspace) do
      assert File.ls!(workspace) -- [@staged] == []
      if File.exists?(staged), do: assert_fresh_tombstone(staged)
    end
  end

  # A correction killed after its exchange: the corrected bytes and the pending record stay, and
  # `recover/2` records them. The download keeps its bytes through that and a reset.
  def assert_killed_correction_recovers(video, path, original, download) do
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

  def fail_manifest_once do
    fail_once(%{
      operation: :write_exclusive,
      source_contains: ".cinder-subtitle-manifest-",
      reason: :eio
    })
  end

  # Runs `fun` until the manifest write that follows its publication, writes "edited" over
  # `path` there, then fails that manifest write. Returns the log.
  def edit_during_failed_manifest(path, fun) do
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
  def sidecar(video, language \\ "en") do
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

  def record(moviehash, source, applied, overrides \\ %{}) do
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

  def pending(record, expected, operation_id \\ String.duplicate("a", 22)) do
    record
    |> Map.put(:status, "applying")
    |> Map.put(:expected_sha256, digest(expected))
    |> Map.put(:operation_id, operation_id)
  end

  # The exchange a reset makes: puts `content` back where `current` is.
  def write_back!(path, content, current) do
    assert :ok = SidecarTransaction.AtomicFile.write(path, content, current)
  end

  def use_barrier(barrier) do
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
  def fail_close_after_exchange(path, descriptors, fun, opts \\ []) do
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

  def disposal_barrier(:discard, path), do: %{operation: :discard_bound, contains: path}

  def disposal_barrier(:unlink, _path),
    do: %{operation: :rm, contains: ".cinder-subtitle-sync-write-staged"}

  def close_source(:staged, _path), do: ".cinder-subtitle-sync-write-staged"

  def close_source(:target, path), do: path

  def close_source(:directory, _path), do: ".cinder-subtitle-sync-cas-"

  # The workspace directory's close alone: the staged file's path contains the directory's.
  def directory_close_failure(overrides \\ %{}) do
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
  def assert_fetched_track(video, target, language, origin) do
    assert File.read!(target) == @replacement
    assert %{origin: ^origin, managed_sha256: managed} = Manifest.read(video).tracks[language]
    assert managed == digest(@replacement)
    assert workspaces(target) == []
  end

  # A correction whose exchange committed unacknowledged: the corrected bytes and the pending
  # record stay until `recover/2` records them.
  def assert_unacknowledged_correction(video, path, original, backup) do
    assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    assert File.read!(backup) == original
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")

    assert {:ok, %{sync: %{status: "aligned"}}} = recover(video)
    assert %{status: "aligned"} = Manifest.sync(Manifest.read(video), "en")
  end

  # Runs `fun` with its write's exchange onto `path` committed and one step after it failed: the
  # staged descriptor's close, the exchange's own acknowledgement, or the displaced inode's
  # discard. Returns `fun`'s result and the log.
  def unacknowledged_write(:close, path, fun),
    do: fail_close_after_exchange(path, [:staged], fun)

  def unacknowledged_write(:exchange, _path, fun) do
    fail_once(%{
      operation: :exchange,
      source_contains: ".cinder-subtitle-sync-write-",
      phase: :post_effect,
      reason: :eio
    })

    with_log(fun)
  end

  def unacknowledged_write(:discard, path, fun) do
    fail_once(%{
      operation: :discard_bound,
      source_contains: Path.basename(path),
      phase: :post_effect,
      reason: :eio
    })

    with_log(fun)
  end

  # The `{:publication_committed, detail}` each `unacknowledged_write/3` failure gives.
  def unacknowledged_detail(:close), do: {:descriptor_close_failed, :eio}

  def unacknowledged_detail(:exchange), do: {:effect_committed, "exchange", :eio}

  def unacknowledged_detail(:discard), do: {:effect_committed, "discard_bound", :eio}

  # A reset that put the original back and retired it: no record and no reset journal.
  def assert_reset_finished(video, path, original, backup) do
    assert File.read!(path) == original
    assert File.read!(backup) == ""
    assert Manifest.sync(Manifest.read(video), "en") == nil
    assert reset_journal(video) == nil
  end

  # The one warning a recovery logs when its write published a correction, or restored the
  # original, unacknowledged.
  def assert_unacknowledged_warning(log, path, detail) do
    assert [line] =
             log
             |> String.split("\n")
             |> Enum.filter(&(&1 =~ "subtitle publication unacknowledged"))

    assert line =~ "[warning] subtitle publication unacknowledged for #{path}: #{inspect(detail)}"
  end

  # A first correction killed just before its exchange: its staged bytes wait in the workspace
  # and its pending record reads "applying".
  def interrupt_before_exchange!(video, :manual) do
    use_barrier(%{operation: :exchange, phase: :before, contains: ".cinder-subtitle-sync-write-"})
    kill_at_barrier(fn -> manual(video, 1_000) end, :exchange)
    assert %{status: "applying"} = Manifest.sync(Manifest.read(video), "en")
  end

  # The same, recorded as automatic: recovery publishes its staged bytes instead of recomputing.
  def interrupt_before_exchange!(video, :automatic) do
    interrupt_before_exchange!(video, :manual)
    record = Manifest.sync(Manifest.read(video), "en")
    assert :ok = Manifest.put_sync(video, "en", %{record | method: "audio", score: 30.0})
  end

  # A recovery that recorded the interrupted correction: its bytes and an "aligned" record that
  # keeps the correction's `method`.
  def assert_recorded_correction(result, video, path, method) do
    assert {:ok, %{sync: %{status: "aligned", method: ^method}}} = result
    assert File.read!(path) =~ "00:00:02,000 --> 00:00:03,000"
    assert %{status: "aligned", method: ^method} = Manifest.sync(Manifest.read(video), "en")
  end

  # Runs `fun` until it reaches the barrier at `operation`, then kills it there: a crash at that
  # exact step. Returns the path the barrier paused on.
  def kill_at_barrier(fun, operation) do
    {:ok, task} = Task.start(fun)
    monitor = Process.monitor(task)

    assert_receive {:filesystem_barrier, ^task, _ref, ^operation, paused_path},
                   DiskTask.timeout_ms()

    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    paused_path
  end

  def workspace_staged_files(path) do
    path
    |> Path.dirname()
    |> Path.join(".cinder-subtitle-sync-cas-*/.cinder-subtitle-sync-write-staged")
    |> Path.wildcard(match_dot: true)
  end

  def drain_write_bound_messages do
    receive do
      {:write_bound, _} -> drain_write_bound_messages()
    after
      0 -> :ok
    end
  end

  def assert_tombstone_rebound(video, backup) do
    assert {:ok, bound} = Disk.open_bound(backup, [:read, :raw, :binary])
    assert %{identity: identity} = Manifest.backup_tombstone(Manifest.read(video), "en")
    assert identity == Tuple.to_list(bound.identity)
    assert :ok = Disk.close_bound(bound)
  end

  def managed_srt!(video, language \\ "en") do
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

  def owned_backup!(video, sidecar, content, language \\ "en") do
    backup = backup(sidecar)
    assert {:ok, bound} = Disk.create_bound(backup, content)
    assert :ok = Manifest.put_backup_tombstone(video, language, bound.identity)
    assert :ok = Disk.close_bound(bound)
    backup
  end

  # The on-disk name of a sidecar's immutable original: a persisted format, so spelled out here.
  def backup(path),
    do: Path.join(Path.dirname(path), ".#{Path.basename(path)}.cinder-sync-original")

  # The reset journal the manifest holds for the "en" track, nil when there is none.
  def reset_journal(video), do: Manifest.sync_item(Manifest.read(video), "en").reset_cleanup_sync

  # Simulates a manifest whose "en" track holds no recorded backup tombstone, by deleting that
  # field from the stored JSON. Nothing in `lib/` clears a recorded tombstone.
  def drop_recorded_tombstone!(video) do
    manifest = Manifest.path(video)
    stored = manifest |> File.read!() |> Jason.decode!()

    File.write!(
      manifest,
      Jason.encode!(update_in(stored, ["tracks", "en"], &Map.delete(&1, "backup_tombstone")))
    )

    assert Manifest.backup_tombstone(Manifest.read(video), "en") == nil
  end

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
  def duplicate_tombstones!(video, tmp, opts \\ []) do
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

  def mergerfs_duplicate_helper!(tmp, layout, opts) do
    %{logical: logical, branches: branches} = layout
    legacy_identity = opts[:legacy_identity]
    inodecalc = Keyword.get(opts, :inodecalc, "path-hash")
    control_file = MergerfsControl.python(layout.control, branches, inodecalc: inodecalc)
    helper = Path.join(tmp, "mergerfs_duplicate_helper.py")
    real_helper = Path.expand("../../priv/rooted_fs.py", __DIR__)

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

  def legacy_identity_helper!(tmp, path_fragment, identity) do
    helper = Path.join(tmp, "legacy_identity_helper.py")
    real_helper = Path.expand("../../priv/rooted_fs.py", __DIR__)

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

  def shifted(content),
    do: String.replace(content, "00:00:01,000 --> 00:00:02,000", "00:00:02,000 --> 00:00:03,000")

  def digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  # The hash a caller passes in, computed here from the bytes: `Moviehash.of_file/1` reads through
  # the filesystem seam, which starts a rooted helper process per call (#1474). The transaction
  # still hashes through the seam itself.
  def moviehash!(video) do
    bytes = File.read!(video)
    size = byte_size(bytes)
    Moviehash.compute(size, binary_part(bytes, 0, 65_536), binary_part(bytes, size, -65_536))
  end
end
