defmodule Cinder.Library.Filesystem.DiskBoundedTest do
  # Issue #590: `run_rooted/2`, `sync_directory/1`, and `run_command/2` (the `mv --exchange`
  # fallback) had no Elixir-side bound at all — `System.cmd/3` has no `:timeout` option — and
  # `close_rooted_port/1`'s own timeout branch only closed the Erlang side of the `Port`, never
  # killing the underlying OS child. Mirrors `Cinder.Library.MediaInfo.FfprobeTest`'s own
  # hang-test conventions (#447/#510): a stub that writes its own pid, sleeps past the
  # configured bound, and only then writes a marker file proves both that the call returns
  # within its bound AND that the real OS process is dead, not merely abandoned.
  use Cinder.DataCase, async: false

  alias Cinder.Library.Filesystem.Disk

  @env_keys [
    :rooted_filesystem_helper,
    :disk_subprocess_timeout_ms,
    :movies_library_path,
    :tv_library_path
  ]

  setup do
    saved = Map.new(@env_keys, &{&1, Application.get_env(:cinder, &1)})
    path_env = System.get_env("PATH")

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)

      System.put_env("PATH", path_env)
    end)

    :ok
  end

  # --- run_rooted/2, exercised via mkdir_exclusive/2 (a rooted effect operation) -------------

  @tag :tmp_dir
  test "run_rooted returns a bounded error when the helper hangs, and the OS process is killed",
       %{tmp_dir: tmp} do
    root = library_root!(tmp)
    pidfile = Path.join(tmp, "mkdir.pid")
    marker = Path.join(tmp, "mkdir_survived")
    hanging_helper!(tmp, pidfile, marker)
    Application.put_env(:cinder, :disk_subprocess_timeout_ms, 150)

    path = Path.join(root, "workspace")

    t0 = System.monotonic_time(:millisecond)

    assert {:error, {:effect_committed, "mkdir", {:helper_outcome_unknown, ""}}} =
             Disk.mkdir_exclusive(path, 0o700)

    assert System.monotonic_time(:millisecond) - t0 < 3000
    refute File.exists?(path)

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)

    Process.sleep(1200)
    refute File.exists?(marker)
  end

  # Proves the deadline is an ABSOLUTE bound, not a per-message poll tick a chatty helper can
  # keep resetting — a fixed `after` timer restarts on every matched `:data` message, so a
  # helper emitting output faster than the tick interval would starve the `after` clause forever
  # and never time out at all. Mirrors `Cinder.Library.MediaInfo.FfprobeTest`'s own max-speed
  # emitter test for `extract_subtitle/2`.
  @tag :tmp_dir
  @tag timeout: 5_000
  test "run_rooted still times out when the helper emits data faster than any poll tick", %{
    tmp_dir: tmp
  } do
    root = library_root!(tmp)
    pidfile = Path.join(tmp, "spam.pid")
    spam_helper!(tmp, pidfile)
    Application.put_env(:cinder, :disk_subprocess_timeout_ms, 150)

    path = Path.join(root, "workspace")

    t0 = System.monotonic_time(:millisecond)
    assert {:error, {:effect_committed, "mkdir", _reason}} = Disk.mkdir_exclusive(path, 0o700)
    elapsed = System.monotonic_time(:millisecond) - t0

    # Close to the configured bound (not merely "eventually finite") — proves the deadline fired
    # on schedule rather than being starved indefinitely by the continuous stream of data.
    assert elapsed >= 150
    assert elapsed < 1000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)
  end

  # --- sync_directory/1, exercised via rm/1 on an unrooted path -------------------------------

  @tag :tmp_dir
  test "sync_directory returns a bounded error when sync hangs, and the OS process is killed", %{
    tmp_dir: tmp
  } do
    pidfile = Path.join(tmp, "sync.pid")
    marker = Path.join(tmp, "sync_survived")
    fake_bin!(tmp, "sync", pidfile, marker)
    Application.put_env(:cinder, :disk_subprocess_timeout_ms, 150)

    target = Path.join(tmp, "unrooted-file")
    File.write!(target, "x")

    t0 = System.monotonic_time(:millisecond)
    assert {:error, {:directory_sync_failed, :timeout, _output}} = Disk.rm(target)
    assert System.monotonic_time(:millisecond) - t0 < 3000

    refute File.exists?(target)

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)

    Process.sleep(1200)
    refute File.exists?(marker)
  end

  # --- run_command/2 (the `mv --exchange` fallback), exercised via exchange/2 on unrooted paths

  @tag :tmp_dir
  test "run_command (mv --exchange fallback) returns a bounded error when mv hangs, and the OS process is killed",
       %{tmp_dir: tmp} do
    pidfile = Path.join(tmp, "mv.pid")
    marker = Path.join(tmp, "mv_survived")
    fake_bin!(tmp, "mv", pidfile, marker)
    Application.put_env(:cinder, :disk_subprocess_timeout_ms, 150)

    source = Path.join(tmp, "exchange-source")
    dest = Path.join(tmp, "exchange-destination")
    File.write!(source, "source")
    File.write!(dest, "destination")

    t0 = System.monotonic_time(:millisecond)
    assert {:error, {:exchange_failed, :timeout, _output}} = Disk.exchange(source, dest)
    assert System.monotonic_time(:millisecond) - t0 < 3000

    assert File.read!(source) == "source"
    assert File.read!(dest) == "destination"

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)

    Process.sleep(1200)
    refute File.exists?(marker)
  end

  # --- close_rooted_port/1's existing timeout branch, exercised via read/1 on a rooted path ---

  # #510-class defect, closed here for this file's own `Port`: `open_rooted_bound/4`'s timeout
  # branch used to call `close_rooted_port/1`, which only ran `Port.close/1` — that stops
  # further Erlang-side messages but does nothing to a `python3` child stuck in a blocking
  # syscall before it ever reaches its own `sys.stdin.buffer.read()` shutdown wait. Proven the
  # same way #510 proved it for three other modules: a helper that outlives the configured bound
  # and then writes a marker must never get to, because the real OS process was killed.
  @tag :tmp_dir
  test "close_rooted_port's timeout branch kills the OS process, not merely abandons it", %{
    tmp_dir: tmp
  } do
    root = library_root!(tmp)
    pidfile = Path.join(tmp, "hold.pid")
    marker = Path.join(tmp, "hold_survived")
    hanging_helper!(tmp, pidfile, marker)
    Application.put_env(:cinder, :disk_subprocess_timeout_ms, 150)

    path = Path.join(root, "subtitle.srt")
    File.write!(path, "subtitle")

    t0 = System.monotonic_time(:millisecond)
    assert Disk.read(path) == {:error, :rooted_helper_timeout}
    assert System.monotonic_time(:millisecond) - t0 < 3000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)

    Process.sleep(1200)
    refute File.exists?(marker)
  end

  # --- helpers ---------------------------------------------------------------------------

  defp library_root!(tmp) do
    root = Path.join(tmp, "library")
    File.mkdir_p!(root)
    Application.put_env(:cinder, :movies_library_path, root)
    Application.put_env(:cinder, :tv_library_path, Path.join(tmp, "tv"))
    root
  end

  # A rooted helper stub that writes its own pid, sleeps past the configured bound, then writes
  # `marker` and exits — it never emits the real helper's JSON result line, so
  # `open_rooted_bound/4` and `run_rooted/2` both hang on it exactly like a wedged mount's
  # blocking syscall would (`rooted_helper` is a Python script path passed as `python3`'s own
  # first argument, matching `Cinder.Library.Filesystem.DiskRootedTest`'s "abort_helper.py"
  # convention, which likewise ignores its operation argv entirely).
  defp hanging_helper!(tmp, pidfile, marker) do
    helper = Path.join(tmp, "hanging_helper.py")

    File.write!(helper, """
    import os
    import time

    with open(#{inspect(pidfile)}, "w") as f:
        f.write(str(os.getpid()))

    time.sleep(1)

    with open(#{inspect(marker)}, "w") as f:
        f.write("")
    """)

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)
  end

  # Emits stdout continuously, as fast as CPython can write, so a fixed poll-tick supervisor
  # (rather than an absolute deadline) would have its `after` clause perpetually reset by
  # incoming `:data` messages and never fire at all.
  defp spam_helper!(tmp, pidfile) do
    helper = Path.join(tmp, "spam_helper.py")

    File.write!(helper, """
    import os
    import sys

    with open(#{inspect(pidfile)}, "w") as f:
        f.write(str(os.getpid()))

    while True:
        sys.stdout.write("spam")
        sys.stdout.flush()
    """)

    Application.put_env(:cinder, :rooted_filesystem_helper, helper)
  end

  # Prepends a fake `name` executable to `PATH` so `System.find_executable/1` resolves it before
  # the real one — `sync_directory/1` and `run_command/2` have no config override for which
  # binary they invoke (unlike `rooted_filesystem_helper`), so PATH manipulation is the only way
  # to substitute a stub. Mirrors `Cinder.Subtitles.SyncTest`'s own "disk exchange returns an
  # error when mv cannot execute" test, which already manipulates `PATH` the same way.
  defp fake_bin!(tmp, name, pidfile, marker) do
    bin_dir = Path.join(tmp, "bin")
    File.mkdir_p!(bin_dir)
    path = Path.join(bin_dir, name)

    File.write!(path, """
    #!/bin/sh
    echo $$ > #{shell_quote(pidfile)}
    sleep 1
    touch #{shell_quote(marker)}
    exit 0
    """)

    File.chmod!(path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> System.get_env("PATH"))
  end

  # ExUnit's `tmp_dir` embeds the test NAME in the path, which routinely contains parentheses
  # (e.g. "(mv --exchange fallback)") — unquoted, those are shell syntax, not data. Single-quote
  # defensively for every path interpolated into a generated shell script.
  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  # Bounded poll for the stub's own pid file — it is written before the stub sleeps, so this
  # only waits for the process to have actually started.
  defp wait_for_pidfile(pidfile, attempts \\ 50)
  defp wait_for_pidfile(_pidfile, 0), do: flunk("stub process never wrote its pid file")

  defp wait_for_pidfile(pidfile, attempts) do
    case File.read(pidfile) do
      {:ok, content} ->
        content |> String.trim() |> String.to_integer()

      {:error, :enoent} ->
        Process.sleep(20)
        wait_for_pidfile(pidfile, attempts - 1)
    end
  end

  # `kill -0` sends no signal, just checks the pid is reachable; a real SIGKILL is not
  # instantaneous from the caller's point of view, so this polls a short bounded window rather
  # than asserting on the very first check.
  defp process_gone?(pid, attempts \\ 50)
  defp process_gone?(_pid, 0), do: false

  defp process_gone?(pid, attempts) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} ->
        Process.sleep(20)
        process_gone?(pid, attempts - 1)

      {_out, _nonzero} ->
        true
    end
  end
end
