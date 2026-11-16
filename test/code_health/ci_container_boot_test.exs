defmodule Cinder.CodeHealth.CiContainerBootTest do
  # #1350: ci.yml's `container` job boots the release image, then waits for /healthz. On run 1203
  # a loaded runner outlasted the wait's 30 tries: the endpoint started during the sleep after the
  # last try, 0.6 s before the step gave up. The step now makes 120 tries, 1 s apart, each `curl`
  # bounded at 2 s, and names that bound in an `::error::` line when no try answers. The setup
  # that needs the booted container (the `mark_setup_complete` eval, the Playwright venv and
  # installs) moved to the next step, so the boot step's `run:` text runs here under bash, as
  # `shell: bash` runs it, with stub `docker`, `hostname`, `curl` and `sleep` first on PATH. Each
  # stub records its arguments, one call per line. The stub `curl` fails until call
  # CURL_STUB_OK_ON (never when unset), and `docker` and `sleep` exit with DOCKER_STUB_STATUS and
  # SLEEP_STUB_STATUS.
  use ExUnit.Case, async: true

  @ci ".forgejo/workflows/ci.yml"
  @boot "Boot a fresh instance"
  @setup "Mark setup complete and install Playwright"
  @mv_exchange "mv --exchange in the release image (#1201)"
  @container "cinder-ci-3707-1"
  @image "cinder:ci-3707-1"
  @token "ci-only-not-a-real-bootstrap-token"
  @curl_args "--fail --silent --max-time 2 http://127.0.0.1:4000/healthz"
  @booting "Booting container #{@container} from image #{@image}"
  @error "::error::/healthz did not answer in 120 tries, 1 s apart; the \"Container logs and " <>
           "cleanup\" step prints the container's log"

  # forgejo-runner v13.2.1 runs a `shell: bash` step file as `bash --noprofile --norc -e -o
  # pipefail <file>` (`shellCommand/1` in act/runner/step_run.go).
  @bash_flags ~w(--noprofile --norc -e -o pipefail)

  @stubs %{
    "docker" => ~S"""
    printf '%s\n' "$*" >>"$STUB_STATE/docker"
    if [ "$DOCKER_STUB_STATUS" != 0 ]; then echo "docker: stub failure" >&2; fi
    exit "$DOCKER_STUB_STATUS"
    """,
    "hostname" => ~S"""
    echo job-host
    """,
    "curl" => ~S"""
    printf '%s\n' "$*" >>"$STUB_STATE/curl"
    calls=$(wc -l <"$STUB_STATE/curl")
    if [ -n "${CURL_STUB_OK_ON:-}" ] && [ "$calls" -ge "$CURL_STUB_OK_ON" ]; then
      printf ok
      exit 0
    fi
    exit 7
    """,
    "sleep" => ~S"""
    printf '%s\n' "$*" >>"$STUB_STATE/sleep"
    exit "$SLEEP_STUB_STATUS"
    """
  }

  test "the boot step runs under bash and holds only the boot and the wait" do
    step = step!(@boot)

    assert step["shell"] == "bash"
    assert step["env"] == %{"CINDER_SMOKE_BOOTSTRAP_TOKEN" => @token}
    assert Map.keys(step) -- ["name", "shell", "env", "run"] == []

    for text <- ["docker exec", "playwright", "pip"],
        do: refute(step["run"] =~ text, "the boot step holds #{inspect(text)}")
  end

  test "the next step holds the eval and the Playwright setup, in today's order, before the " <>
         "mv --exchange step" do
    steps = container_job()["steps"]
    names = Enum.map(steps, & &1["name"])
    index = fn name -> Enum.find_index(names, &(&1 == name)) end
    boot = index.(@boot)
    setup = index.(@setup)
    mv_exchange = index.(@mv_exchange)

    assert is_integer(boot) and setup == boot + 1 and is_integer(mv_exchange) and
             setup < mv_exchange,
           "the boot is at #{inspect(boot)}, the setup at #{inspect(setup)}, " <>
             "the mv --exchange step at #{inspect(mv_exchange)}"

    holders =
      for step <- steps,
          String.contains?(step["run"] || "", "mark_setup_complete"),
          do: step["name"]

    assert holders == [@setup]

    step = Enum.at(steps, setup)
    assert Map.keys(step) -- ["name", "run"] == []

    commands = [
      ~s(docker exec "$CINDER_SMOKE_CONTAINER" /app/bin/cinder eval),
      ~s(python3 -m venv "$RUNNER_TEMP/cinder-browser-smoke"),
      ~s("$RUNNER_TEMP/cinder-browser-smoke/bin/pip" install),
      ~s(for attempt in 1 2 3; do),
      ~s("$RUNNER_TEMP/cinder-browser-smoke/bin/playwright" install-deps chromium && break),
      ~s("$RUNNER_TEMP/cinder-browser-smoke/bin/playwright" install chromium)
    ]

    lines = step["run"] |> String.split("\n") |> Enum.map(&String.trim/1)
    at = for command <- commands, do: Enum.find_index(lines, &String.starts_with?(&1, command))

    assert Enum.all?(at, &is_integer/1) and at == Enum.sort(at),
           "the setup step's commands sit at lines #{inspect(at)}"
  end

  describe "the boot step" do
    @describetag :tmp_dir

    test "boots the image in the job's network namespace", %{tmp_dir: tmp_dir} do
      {_output, 0, calls} = run_boot(tmp_dir, ok_on: 1)

      assert calls.docker == [
               "run --detach --name #{@container} --network container:job-host " <>
                 "-e SECRET_KEY_BASE=ci-only-not-a-real-secret-key-base-0123456789" <>
                 "abcdefghijklmnopqrstuvwxyz -e DATABASE_PATH=/data/cinder.db " <>
                 "-e PHX_HOST=127.0.0.1 -e CINDER_BOOTSTRAP_TOKEN=#{@token} #{@image}"
             ]
    end

    test "passes on the first try without a sleep", %{tmp_dir: tmp_dir} do
      {output, status, calls} = run_boot(tmp_dir, ok_on: 1)

      assert {status, length(calls.curl), calls.sleep} == {0, 1, []}
      assert output == answered(1)
    end

    # Run 1203's case: the 30 tries the step made then ended before the endpoint answered.
    test "passes when /healthz first answers on try 31", %{tmp_dir: tmp_dir} do
      {output, status, calls} = run_boot(tmp_dir, ok_on: 31)

      assert {status, length(calls.curl)} == {0, 31}
      assert calls.sleep == List.duplicate("1", 30)
      assert output == answered(31)
    end

    test "passes when /healthz first answers on the 120th try", %{tmp_dir: tmp_dir} do
      {output, status, calls} = run_boot(tmp_dir, ok_on: 120)

      assert {status, length(calls.curl)} == {0, 120}
      assert calls.sleep == List.duplicate("1", 119)
      assert output == answered(120)
    end

    test "fails after 120 tries, 1 s apart, naming the bound, when /healthz never answers",
         %{tmp_dir: tmp_dir} do
      {output, status, calls} = run_boot(tmp_dir)

      assert status == 1
      assert length(calls.curl) == 120
      assert calls.sleep == List.duplicate("1", 119)
      assert output == "#{@booting}\n#{@error}\n"
    end

    test "bounds every curl call at 2 s", %{tmp_dir: tmp_dir} do
      {_output, 1, calls} = run_boot(tmp_dir)

      assert Enum.uniq(calls.curl) == [@curl_args]
    end

    test "makes no curl call when docker run fails", %{tmp_dir: tmp_dir} do
      {output, status, calls} = run_boot(tmp_dir, docker_status: 125)

      assert status == 125
      assert output =~ "docker: stub failure"
      assert {length(calls.docker), calls.curl, calls.sleep} == {1, [], []}
    end

    test "stops at a failed sleep instead of trying again", %{tmp_dir: tmp_dir} do
      {output, status, calls} = run_boot(tmp_dir, sleep_status: 1)

      assert status == 1
      assert {length(calls.curl), calls.sleep} == {1, ["1"]}
      refute output =~ "::error::"
    end
  end

  # The whole log of a step whose curl answered on try `n`: the names line, the stub's body, then
  # the line that names the try. It holds no ::error:: line.
  defp answered(n), do: "#{@booting}\nok\n/healthz answered on try #{n} of 120\n"

  defp container_job do
    [workflow] = YamlElixir.read_all_from_string!(File.read!(@ci))
    workflow["jobs"]["container"]
  end

  defp step!(name) do
    case Enum.filter(container_job()["steps"], &(&1["name"] == name)) do
      [step] -> step
      steps -> flunk("#{@ci} has #{length(steps)} container steps named #{inspect(name)}")
    end
  end

  # Runs the boot step's text against the stubs and returns its log, its exit status, and each
  # stub's calls by name.
  defp run_boot(dir, opts \\ []) do
    bin = Path.join(dir, "bin")
    state = Path.join(dir, "state")
    File.mkdir_p!(bin)
    File.mkdir_p!(state)

    for {name, body} <- @stubs do
      path = Path.join(bin, name)
      File.write!(path, "#!#{bash()}\n" <> body)
      File.chmod!(path, 0o755)
      File.write!(Path.join(state, name), "")
    end

    script = Path.join(dir, "boot.sh")
    File.write!(script, step!(@boot)["run"])

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH", "")},
      {"STUB_STATE", state},
      {"CURL_STUB_OK_ON", opts[:ok_on] && Integer.to_string(opts[:ok_on])},
      {"DOCKER_STUB_STATUS", Integer.to_string(Keyword.get(opts, :docker_status, 0))},
      {"SLEEP_STUB_STATUS", Integer.to_string(Keyword.get(opts, :sleep_status, 0))},
      {"CINDER_SMOKE_CONTAINER", @container},
      {"CINDER_IMAGE", @image},
      {"CINDER_SMOKE_BOOTSTRAP_TOKEN", @token}
    ]

    {output, status} =
      System.cmd(bash(), @bash_flags ++ [script], env: env, stderr_to_stdout: true)

    read = fn name ->
      state |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
    end

    calls = %{docker: read.("docker"), curl: read.("curl"), sleep: read.("sleep")}

    {output, status, calls}
  end

  defp bash, do: System.find_executable("bash") || flunk("bash is not on PATH")
end
