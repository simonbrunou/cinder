defmodule Cinder.Subtitles.Sync.EngineWorkspaceBoundedTest do
  # Issue #591: same defect shape as #590, one file over. `seal/1` had no Elixir-side bound at
  # all -- `System.cmd/3` has no `:timeout` option -- and `start_holder/0`'s existing bound's
  # timeout branch (`close_holder/1`) only closed the Erlang side of the `Port`, never killing
  # the underlying OS child. Mirrors `Cinder.Library.Filesystem.DiskBoundedTest`'s own
  # conventions: a stub that writes its own pid, sleeps past the configured bound, and only then
  # writes a marker file proves both that the call returns within its bound AND that the real OS
  # process is dead, not merely abandoned.
  use ExUnit.Case, async: false

  import Cinder.ConfigCase, only: [put_env: 2]

  alias Cinder.Subtitles.Sync.EngineWorkspace

  # Wide enough for the helpers to start on a loaded CI runner (#636). The bound also covers the
  # `hold` that `run/5` starts before any seal, and at 150 ms that `hold` sometimes timed out
  # first (`:anonymous_helper_timeout`), so the seal stage under test was never reached. At 1 s a
  # Python start on the runner still missed it, in the `hold` spawn and before the `seal` stub's
  # pid write (#1043), so every spawn runs a `/bin/sh` stub instead (`fake_python3!/3`). The
  # stubs sleep 3 s before writing their marker; see `DiskBoundedTest` for the same reasoning.
  @bound_ms 1_000
  @marker_wait_ms 2_500

  setup %{tmp_dir: tmp} do
    path_env = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path_env) end)

    reference_path = Path.join(tmp, "reference.srt")
    input_path = Path.join(tmp, "input.srt")
    File.write!(reference_path, "reference")
    File.write!(input_path, "input")

    %{
      reference: %{path: reference_path},
      input: %{path: input_path}
    }
  end

  # --- seal/1, exercised via run/5's mandatory output seal in finish_execution/2 -------------
  #
  # `run/5` always seals `output` once the engine callback returns (`finish_execution/2`),
  # regardless of what `reference` is -- so a `%{path: _}` reference (skipping reference's own
  # anonymous-file/seal path entirely) is the simplest route to exercise `seal/1` on its own.

  @tag :tmp_dir
  test "seal/1 returns a bounded error when the helper hangs, and the OS process is killed", %{
    reference: reference,
    input: input,
    tmp_dir: tmp
  } do
    pidfile = Path.join(tmp, "seal.pid")
    marker = Path.join(tmp, "seal_survived")
    fake_python3!(tmp, working_hold(tmp), hanging(pidfile, marker))
    put_env(:engine_workspace_subprocess_timeout_ms, @bound_ms)

    t0 = System.monotonic_time(:millisecond)

    assert {:error, {:anonymous_seal_exit, :timeout, ""}} =
             EngineWorkspace.run(reference, input, ".srt", ".srt", &noop_callback/6)

    assert System.monotonic_time(:millisecond) - t0 < 3000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)

    Process.sleep(@marker_wait_ms)
    refute File.exists?(marker)
  end

  # Proves the deadline is an ABSOLUTE bound, not a per-message poll tick a chatty helper can
  # keep resetting — mirrors `Cinder.Library.Filesystem.DiskBoundedTest`'s own max-speed emitter
  # test.
  @tag :tmp_dir
  @tag timeout: 15_000
  test "seal/1 still times out when the helper emits data faster than any poll tick", %{
    reference: reference,
    input: input,
    tmp_dir: tmp
  } do
    pidfile = Path.join(tmp, "seal-spam.pid")
    fake_python3!(tmp, working_hold(tmp), spamming(pidfile))
    put_env(:engine_workspace_subprocess_timeout_ms, @bound_ms)

    t0 = System.monotonic_time(:millisecond)

    assert {:error, {:anonymous_seal_exit, :timeout, _output}} =
             EngineWorkspace.run(reference, input, ".srt", ".srt", &noop_callback/6)

    elapsed = System.monotonic_time(:millisecond) - t0

    # Close to the configured bound (not merely "eventually finite") — proves the deadline fired
    # on schedule rather than being starved indefinitely by the continuous stream of data.
    assert elapsed >= @bound_ms
    assert elapsed < @bound_ms + 2_000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)
  end

  # --- start_holder/0's timeout branch (close_holder/1), exercised directly via run/5 --------
  #
  # `run/5` always calls `start_holder/0` first, for `output`, before ever touching `reference`
  # -- so a hanging `hold` fires here regardless of what `reference`/`input`/the callback are.

  @tag :tmp_dir
  test "close_holder's timeout branch kills the OS process, not merely abandons it", %{
    reference: reference,
    input: input,
    tmp_dir: tmp
  } do
    pidfile = Path.join(tmp, "hold.pid")
    marker = Path.join(tmp, "hold_survived")
    fake_python3!(tmp, hanging(pidfile, marker), refuse())
    put_env(:engine_workspace_subprocess_timeout_ms, @bound_ms)

    t0 = System.monotonic_time(:millisecond)

    assert {:error, :anonymous_helper_timeout} =
             EngineWorkspace.run(reference, input, ".srt", ".srt", &noop_callback/6)

    assert System.monotonic_time(:millisecond) - t0 < 3000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)

    Process.sleep(@marker_wait_ms)
    refute File.exists?(marker)
  end

  # --- fake_python3!/3's argv guard -------------------------------------------------------
  #
  # Pins the guard that `fake_python3!/3`'s comment describes: a stub that served any `hold` would
  # serve a background `Disk` call that lands in the window instead of failing it.

  @tag :tmp_dir
  test "the python3 stub serves only the configured helper's hold and seal", %{tmp_dir: tmp} do
    fake_python3!(tmp, "echo served-hold", "echo served-seal")
    python = System.find_executable("python3")
    assert python == Path.join([tmp, "bin", "python3"])
    helper = Application.fetch_env!(:cinder, :anonymous_file_helper)

    assert System.cmd(python, [helper, "hold"], stderr_to_stdout: true) == {"served-hold\n", 0}

    assert System.cmd(python, [helper, "seal", "/proc/1/fd/3"], stderr_to_stdout: true) ==
             {"served-seal\n", 0}

    rooted_fs = Path.join(tmp, "rooted_fs.py")

    for argv <- [
          [rooted_fs, "hold", tmp, "subtitle.srt"],
          [rooted_fs, "hold"],
          [helper, "hold", "extra"],
          [helper, "seal"],
          ["-c", "print(1)"]
        ] do
      {output, status} = System.cmd(python, argv, stderr_to_stdout: true)
      assert {status, output} == {1, "fake python3: unexpected argv: #{Enum.join(argv, " ")}\n"}
    end
  end

  # --- helpers ---------------------------------------------------------------------------

  defp noop_callback(_reference_path, _input_path, _output_path, _output, _ref_ext, _inp_ext),
    do: :ok

  # A `/bin/sh` script first on `PATH` as `python3`, so no spawn waits on Python's start: on the
  # loaded runner that start missed the 1 s bound in the `hold` spawn and before the `seal` stub's
  # pid write (#1043), and a `/bin/sh` start costs about a twelfth of a Python one. Both of
  # `run/5`'s spawns resolve `python3` on `PATH` at call time and pass the configured helper path
  # first. The script runs `hold` only for `[helper, "hold"]` and `seal` only for
  # `[helper, "seal", path]`. Any other argv fails and never reaches the real `python3`: `Disk`'s
  # `rooted_fs.py` also has a `hold` operation, so a background `Disk` call that lands in the
  # window shows up instead of being served. Nothing reads the helper file, so none is written.
  defp fake_python3!(tmp, hold, seal) do
    helper = Path.join(tmp, "anonymous_file.py")
    bin_dir = Path.join(tmp, "bin")
    File.mkdir_p!(bin_dir)
    path = Path.join(bin_dir, "python3")

    File.write!(path, """
    #!/bin/sh
    if [ "$#" -eq 2 ] && [ "$1" = #{shell_quote(helper)} ] && [ "$2" = hold ]; then
    #{hold}
    elif [ "$#" -eq 3 ] && [ "$1" = #{shell_quote(helper)} ] && [ "$2" = seal ]; then
    #{seal}
    else
    #{refuse()}
    fi
    """)

    File.chmod!(path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> System.get_env("PATH"))
    put_env(:anonymous_file_helper, helper)
  end

  # A working `hold`, needed because `run/5` always opens an anonymous file for `output` before
  # `seal/1` is ever reached. Like the real helper, it emits the fd it holds, then blocks on stdin,
  # here with a builtin loop that forks no child. `run/5` writes the empty output through
  # `/proc/<pid>/fd/3`. A regular file stands in for the real helper's sealable memfd: `run/5`
  # opens `output` with `seal?` false and these tests pass a `%{path: _}` reference, so nothing
  # here seals the held fd for real.
  defp working_hold(tmp) do
    """
    exec 3<>#{shell_quote(Path.join(tmp, "held_output"))}
    echo '{"ok":{"fd":3}}'
    while read -r line; do :; done
    """
  end

  # Writes its own pid, sleeps past the bound, then writes `marker`, never emitting the real
  # helper's JSON line, so only a stub the bound failed to kill gets to write `marker`.
  defp hanging(pidfile, marker) do
    """
    echo $$ > #{shell_quote(pidfile)}
    sleep 3
    touch #{shell_quote(marker)}
    """
  end

  # Writes its own pid, then emits stdout with builtins as fast as the shell can, so a fixed poll
  # tick (rather than an absolute deadline) would have its `after` clause reset by every `:data`
  # message and never fire.
  defp spamming(pidfile) do
    """
    echo $$ > #{shell_quote(pidfile)}
    while :; do printf spam; done
    """
  end

  # The branch for any argv the real helper's callers never pass, and the `seal` of a test that
  # never reaches its seal: an `if` branch cannot be empty in `sh`.
  defp refuse do
    """
    echo "fake python3: unexpected argv: $*" >&2
    exit 1
    """
  end

  # ExUnit's `tmp_dir` embeds the test name in the path, and names here hold spaces, commas and
  # the quote in "close_holder's", so every path in the script is single-quoted.
  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp wait_for_pidfile(pidfile, attempts \\ 50)
  defp wait_for_pidfile(_pidfile, 0), do: flunk("stub process never wrote its pid file")

  # An empty pid file counts as missing: a stub creates the file before it writes its pid, and a
  # stub killed in between leaves it empty (#1043).
  defp wait_for_pidfile(pidfile, attempts) do
    case File.read(pidfile) do
      {:ok, content} when content != "" ->
        content |> String.trim() |> String.to_integer()

      missing when missing in [{:ok, ""}, {:error, :enoent}] ->
        Process.sleep(20)
        wait_for_pidfile(pidfile, attempts - 1)
    end
  end

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
