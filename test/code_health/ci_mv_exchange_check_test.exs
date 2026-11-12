defmodule Cinder.CodeHealth.CiMvExchangeCheckTest do
  # #1201: ci.yml's `container` job runs .github/scripts/mv_exchange_check.exs in the booted
  # release through `bin/cinder rpc`, since no other CI run reaches a real `mv --exchange`. The
  # first tests read the step's place and settings from the workflow. The rest run its `run:`
  # text under bash, as `shell: bash` runs it, with a stub `docker` first on PATH that records
  # its arguments, prints DOCKER_STUB_OUTPUT on stdout, then DOCKER_STUB_STDERR on stderr, and
  # exits with DOCKER_STUB_STATUS.
  use ExUnit.Case, async: true

  @ci ".forgejo/workflows/ci.yml"
  @check ".github/scripts/mv_exchange_check.exs"
  @step "mv --exchange in the release image (#1201)"
  @container "cinder-ci-3707-1"
  @success "Disk.exchange/2 ran mv --exchange in the release image and swapped two files"

  # forgejo-runner v13.2.1 runs a `shell: bash` step file as `bash --noprofile --norc -e -o
  # pipefail <file>` (`shellCommand/1` in act/runner/step_run.go).
  @bash_flags ~w(--noprofile --norc -e -o pipefail)

  @stub_body ~S"""
  printf '%s\0' "$@" >"$DOCKER_STUB_ARGS"
  printf '%s' "$DOCKER_STUB_OUTPUT"
  printf '%s' "${DOCKER_STUB_STDERR:-}" >&2
  exit "$DOCKER_STUB_STATUS"
  """

  test "the check runs under bash after the boot and before the cleanup, on every run" do
    steps = container_job()["steps"]
    names = Enum.map(steps, & &1["name"])
    index = fn name -> Enum.find_index(names, &(&1 == name)) end
    check = index.(@step)
    boot = index.("Boot a fresh instance")
    cleanup = index.("Container logs and cleanup")

    assert is_integer(check) and is_integer(boot) and is_integer(cleanup) and
             boot < check and check < cleanup,
           "the check is at #{inspect(check)}, the boot at #{inspect(boot)}, " <>
             "the cleanup at #{inspect(cleanup)}"

    assert Enum.count(names, &(&1 == @step)) == 1
    step = Enum.at(steps, check)
    assert step["shell"] == "bash"
    assert Map.keys(step) -- ["name", "shell", "run"] == []
  end

  describe "the step" do
    @describetag :tmp_dir

    test "hands the check file's text to bin/cinder rpc in the smoke container and passes on " <>
           "its ok line",
         %{tmp_dir: tmp_dir} do
      output = "mv --exchange swapped /tmp/x/left and /tmp/x/right\nMV_EXCHANGE_CHECK:ok\n"
      {log, status, args} = run_step(tmp_dir, output, 0)

      assert {log, status} == {output <> @success <> "\n", 0}

      assert args == [
               "exec",
               @container,
               "/app/bin/cinder",
               "rpc",
               String.trim_trailing(File.read!(@check), "\n")
             ]
    end

    test "fails on a non-zero rpc exit even with the ok line, and prints the output",
         %{tmp_dir: tmp_dir} do
      output = "MV_EXCHANGE_CHECK:ok\n** (RuntimeError) boom\n"
      {log, status, _args} = run_step(tmp_dir, output, 1)

      assert status == 1
      assert log =~ "** (RuntimeError) boom"
      assert log =~ "::error::bin/cinder rpc exited 1"
      refute log =~ @success
    end

    test "fails on the check's failed line, and prints it", %{tmp_dir: tmp_dir} do
      output = ~s(MV_EXCHANGE_CHECK:failed {{:error, {:exchange_failed, 1, "mv: x"}}}\n)
      {log, status, _args} = run_step(tmp_dir, output, 0)

      assert status == 1
      assert log =~ output
      assert log =~ "::error::the mv --exchange check printed no MV_EXCHANGE_CHECK:ok line"
      refute log =~ @success
    end

    test "prints the rpc's stderr after its stdout, in the order the rpc wrote them",
         %{tmp_dir: tmp_dir} do
      output = "MV_EXCHANGE_CHECK:failed {:ok, {:ok, \"left\"}, {:ok, \"right\"}}\n"
      stderr = "** (RuntimeError) boom\n"
      {log, status, _args} = run_step(tmp_dir, output, 0, stderr: stderr)

      assert status == 1
      assert String.starts_with?(log, output <> stderr)
    end

    test "fails when the ok marker is only part of a line", %{tmp_dir: tmp_dir} do
      for output <- [
            "echo MV_EXCHANGE_CHECK:ok\n",
            "MV_EXCHANGE_CHECK:ok.\n",
            "MV_EXCHANGE_CHECK:okay\n",
            "  MV_EXCHANGE_CHECK:ok\n",
            ""
          ] do
        {log, status, _args} = run_step(tmp_dir, output, 0)
        assert status == 1, "passed on #{inspect(output)}: #{log}"
        refute log =~ @success
      end
    end

    test "fails without calling docker when the check file is missing", %{tmp_dir: tmp_dir} do
      {log, status, args} = run_step(tmp_dir, "MV_EXCHANGE_CHECK:ok\n", 0, cd: tmp_dir)

      assert status == 1
      assert log =~ "mv_exchange_check.exs: No such file or directory"
      assert args == nil
    end
  end

  defp container_job do
    [workflow] = YamlElixir.read_all_from_string!(File.read!(@ci))
    workflow["jobs"]["container"]
  end

  defp step! do
    case Enum.filter(container_job()["steps"], &(&1["name"] == @step)) do
      [step] -> step
      steps -> flunk("#{@ci} has #{length(steps)} container steps named #{inspect(@step)}")
    end
  end

  # Runs the step from `opts[:cd]` (the repo root by default) and returns its log, its exit
  # status and the arguments the stub docker got, or nil when it was never called.
  defp run_step(dir, output, docker_status, opts \\ []) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    docker = Path.join(bin, "docker")
    File.write!(docker, "#!#{bash()}\n" <> @stub_body)
    File.chmod!(docker, 0o755)
    args_file = Path.join(dir, "docker-args")
    File.rm_rf!(args_file)
    script = Path.join(dir, "step.sh")
    File.write!(script, step!()["run"])

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH", "")},
      {"DOCKER_STUB_ARGS", args_file},
      {"DOCKER_STUB_OUTPUT", output},
      {"DOCKER_STUB_STDERR", opts[:stderr]},
      {"DOCKER_STUB_STATUS", Integer.to_string(docker_status)},
      {"CINDER_SMOKE_CONTAINER", @container}
    ]

    {log, status} =
      System.cmd(bash(), @bash_flags ++ [script],
        env: env,
        cd: Keyword.get(opts, :cd, File.cwd!()),
        stderr_to_stdout: true
      )

    args =
      case File.read(args_file) do
        {:ok, text} -> String.split(text, "\0", trim: true)
        {:error, :enoent} -> nil
      end

    {log, status, args}
  end

  defp bash, do: System.find_executable("bash") || flunk("bash is not on PATH")
end
