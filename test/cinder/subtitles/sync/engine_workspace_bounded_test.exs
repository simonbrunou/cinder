defmodule Cinder.Subtitles.Sync.EngineWorkspaceBoundedTest do
  # Issue #591: same defect shape as #590, one file over. `seal/1` had no Elixir-side bound at
  # all -- `System.cmd/3` has no `:timeout` option -- and `start_holder/0`'s existing bound's
  # timeout branch (`close_holder/1`) only closed the Erlang side of the `Port`, never killing
  # the underlying OS child. Mirrors `Cinder.Library.Filesystem.DiskBoundedTest`'s own
  # conventions: a stub that writes its own pid, sleeps past the configured bound, and only then
  # writes a marker file proves both that the call returns within its bound AND that the real OS
  # process is dead, not merely abandoned.
  use ExUnit.Case, async: false

  alias Cinder.Subtitles.Sync.EngineWorkspace

  @env_keys [:anonymous_file_helper, :engine_workspace_subprocess_timeout_ms]

  setup %{tmp_dir: tmp} do
    saved = Map.new(@env_keys, &{&1, Application.get_env(:cinder, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

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
    use_helper!(tmp, hold_source(), hanging_seal_source(pidfile, marker))
    Application.put_env(:cinder, :engine_workspace_subprocess_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)

    assert {:error, {:anonymous_seal_exit, :timeout, ""}} =
             EngineWorkspace.run(reference, input, ".srt", ".srt", &noop_callback/6)

    assert System.monotonic_time(:millisecond) - t0 < 3000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)

    Process.sleep(1200)
    refute File.exists?(marker)
  end

  # Proves the deadline is an ABSOLUTE bound, not a per-message poll tick a chatty helper can
  # keep resetting — mirrors `Cinder.Library.Filesystem.DiskBoundedTest`'s own max-speed emitter
  # test.
  @tag :tmp_dir
  @tag timeout: 5_000
  test "seal/1 still times out when the helper emits data faster than any poll tick", %{
    reference: reference,
    input: input,
    tmp_dir: tmp
  } do
    pidfile = Path.join(tmp, "seal-spam.pid")
    use_helper!(tmp, hold_source(), spam_seal_source(pidfile))
    Application.put_env(:cinder, :engine_workspace_subprocess_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)

    assert {:error, {:anonymous_seal_exit, :timeout, _output}} =
             EngineWorkspace.run(reference, input, ".srt", ".srt", &noop_callback/6)

    elapsed = System.monotonic_time(:millisecond) - t0

    # Close to the configured bound (not merely "eventually finite") — proves the deadline fired
    # on schedule rather than being starved indefinitely by the continuous stream of data.
    assert elapsed >= 150
    assert elapsed < 1000

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
    use_helper!(tmp, hanging_hold_source(pidfile, marker), "")
    Application.put_env(:cinder, :engine_workspace_subprocess_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)

    assert {:error, :anonymous_helper_timeout} =
             EngineWorkspace.run(reference, input, ".srt", ".srt", &noop_callback/6)

    assert System.monotonic_time(:millisecond) - t0 < 3000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)

    Process.sleep(1200)
    refute File.exists?(marker)
  end

  # --- helpers ---------------------------------------------------------------------------

  defp noop_callback(_reference_path, _input_path, _output_path, _output, _ref_ext, _inp_ext),
    do: :ok

  # A faithful, minimal reimplementation of `priv/anonymous_file.py`'s own `hold()`: creates a
  # real sealable memfd, emits its fd, then blocks on stdin exactly like the real helper --
  # needed because `run/5` always opens an anonymous file for `output` before `seal/1` is ever
  # reached, so a stub `seal`-hang test still needs a genuinely working `hold`.
  defp hold_source do
    """
    def hold():
        fd = os.memfd_create(
            "cinder-subtitle-engine-test",
            flags=os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING,
        )
        try:
            emit({"ok": {"fd": fd}})
            sys.stdin.buffer.read()
        finally:
            os.close(fd)
    """
  end

  defp hanging_seal_source(pidfile, marker) do
    """
    def seal(path):
        with open(#{inspect(pidfile)}, "w") as f:
            f.write(str(os.getpid()))
        time.sleep(1)
        with open(#{inspect(marker)}, "w") as f:
            f.write("")
    """
  end

  defp spam_seal_source(pidfile) do
    """
    def seal(path):
        with open(#{inspect(pidfile)}, "w") as f:
            f.write(str(os.getpid()))
        while True:
            sys.stdout.write("spam")
            sys.stdout.flush()
    """
  end

  defp hanging_hold_source(pidfile, marker) do
    """
    def hold():
        with open(#{inspect(pidfile)}, "w") as f:
            f.write(str(os.getpid()))
        time.sleep(1)
        with open(#{inspect(marker)}, "w") as f:
            f.write("")
    """
  end

  # Writes a stub `anonymous_file_helper` dispatching on argv exactly like the real
  # `priv/anonymous_file.py`, with `hold_source`/`seal_source` as the bodies of `hold()`/
  # `seal(path)`. Matches `Cinder.Library.Filesystem.DiskRootedTest`'s convention of substituting
  # a purpose-built stub script rather than monkey-patching the real helper file -- the real
  # helper's own trailing `main()` call is NOT guarded by `if __name__ == "__main__":`, so it
  # cannot be `exec`'d into a namespace and monkey-patched before running the way
  # `disk_rooted_test.exs`'s `mergerfs_shim.py` does for `priv/rooted_fs.py`.
  defp use_helper!(tmp, hold_source, seal_source) do
    helper = Path.join(tmp, "anonymous_file_stub.py")

    File.write!(helper, """
    import errno
    import os
    import sys
    import time

    def emit(payload):
        import json
        sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\\n")
        sys.stdout.flush()

    #{hold_source}

    #{seal_source}

    if sys.argv[1:] == ["hold"]:
        hold()
    elif len(sys.argv) == 3 and sys.argv[1] == "seal":
        seal(sys.argv[2])
    else:
        raise OSError(errno.EINVAL, "invalid anonymous-file operation")
    """)

    Application.put_env(:cinder, :anonymous_file_helper, helper)
  end

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
