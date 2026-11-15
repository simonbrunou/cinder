defmodule Cinder.CodeHealth.BrowserLifecycleRpcTest do
  # #1334: the browser lifecycle smoke's `rpc()` killed every `docker exec` after 15 s, and on a
  # loaded runner the bare `subprocess.TimeoutExpired` failed a case whose call still landed in
  # the container. `rpc()` now waits 60 s, makes one attempt, and turns a timeout into a
  # `CaseFailure` that names the expression, the bound and the elapsed seconds.
  #
  # Each test runs the script's `rpc()` under `python3` with a fake `docker` first on PATH, so no
  # container or Playwright install is needed: the driver stubs `playwright.sync_api` before it
  # loads the script.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand(".github/scripts/browser_lifecycle.py")

  # The fake `docker` appends one line per call to $FAKE_DOCKER_CALLS, then acts on
  # $FAKE_DOCKER_MODE. `exec sleep` keeps it one process, so the timeout's kill ends it.
  @fake_docker """
  #!/bin/sh
  echo call >> "$FAKE_DOCKER_CALLS"
  case "$FAKE_DOCKER_MODE" in
    ok) echo "RPCRESULT:ok" ;;
    no_result) echo "no sentinel here" ;;
    fail) echo "boom" >&2; exit 3 ;;
    slow) echo partial; echo err >&2; exec sleep 5 ;;
    silent) exec sleep 5 ;;
  esac
  """

  @driver ~S'''
  import importlib.util, inspect, sys, types

  stub = types.ModuleType("playwright.sync_api")
  stub.expect = stub.sync_playwright = None
  sys.modules["playwright"] = types.ModuleType("playwright")
  sys.modules["playwright.sync_api"] = stub

  spec = importlib.util.spec_from_file_location("browser_lifecycle", sys.argv[1])
  lifecycle = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(lifecycle)

  if sys.argv[2] == "defaults":
      default = inspect.signature(lifecycle.rpc).parameters["timeout"].default
      print(f"RPC_TIMEOUT={lifecycle.RPC_TIMEOUT} default={default}")
  else:
      try:
          print("RESULT:" + lifecycle.rpc('IO.puts("RPCRESULT:ok")', timeout=float(sys.argv[2])))
      except lifecycle.CaseFailure as e:
          print("CASEFAILURE:" + str(e))
  '''

  test "every rpc() call gets 60 s by default", %{tmp_dir: dir} do
    assert run_rpc(dir, "ok", "defaults") == {"RPC_TIMEOUT=60 default=60\n", 0}
  end

  test "a call that returns its sentinel answers its value after one attempt", %{tmp_dir: dir} do
    assert run_rpc(dir, "ok", "5") == {"RESULT:ok\n", 1}
  end

  test "a timeout raises CaseFailure with the bound, the elapsed seconds and the partial output",
       %{tmp_dir: dir} do
    {out, calls} = run_rpc(dir, "slow", "0.5")

    assert out =~
             ~r/^CASEFAILURE:rpc call timed out after \d+\.\ds \(bound 0\.5s\); only the docker client was killed, so the command may still be running in the container\n/

    assert out =~ ~s|  expr: IO.puts("RPCRESULT:ok")\n|
    assert out =~ "  stdout: partial\n"
    assert out =~ "  stderr: err\n"
    assert calls == 1
  end

  test "a timeout with nothing on either stream still raises CaseFailure", %{tmp_dir: dir} do
    {out, calls} = run_rpc(dir, "silent", "0.5")

    assert out =~ ~r/^CASEFAILURE:rpc call timed out after \d+\.\ds \(bound 0\.5s\)/
    assert out =~ "  stdout: \n  stderr: \n"
    assert calls == 1
  end

  test "a non-zero exit names the exit code and the elapsed seconds", %{tmp_dir: dir} do
    {out, calls} = run_rpc(dir, "fail", "5")

    assert out =~ ~r/^CASEFAILURE:rpc call failed \(exit 3\) after \d+\.\ds\n/
    assert out =~ "  stderr: boom\n"
    assert calls == 1
  end

  test "output without the sentinel names the elapsed seconds", %{tmp_dir: dir} do
    {out, calls} = run_rpc(dir, "no_result", "5")

    assert out =~ ~r/^CASEFAILURE:rpc call failed \(exit 0\) after \d+\.\ds\n/
    assert out =~ "  stdout: no sentinel here\n"
    assert calls == 1
  end

  defp run_rpc(dir, mode, timeout) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    docker = Path.join(bin, "docker")
    File.write!(docker, @fake_docker)
    File.chmod!(docker, 0o755)
    calls = Path.join(dir, "calls")
    File.write!(calls, "")

    {out, 0} =
      System.cmd("python3", ["-I", "-c", @driver, @script, timeout],
        env: [
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"FAKE_DOCKER_MODE", mode},
          {"FAKE_DOCKER_CALLS", calls},
          {"CINDER_SMOKE_EMAIL", "rpc-test@example.invalid"},
          {"CINDER_SMOKE_PASSWORD", "rpc-test"}
        ],
        stderr_to_stdout: true
      )

    {out, calls |> File.read!() |> String.split("\n", trim: true) |> length()}
  end
end
