defmodule Cinder.CodeHealth.CiContainerAttemptTest do
  # #1193: ci.yml's `container` job named its image and smoke container by the run id alone. A
  # re-run keeps the run id, so when the runner lost an attempt before its cleanup step, the
  # re-run's `docker run --name` collided with the container that attempt left on the runner
  # CT's Docker daemon. The job now names both per run and attempt, and a step before the build
  # removes what earlier attempts of the run left. The first tests read the job's names and
  # steps from the workflow. The rest run that step's own `run:` text under bash, as
  # `shell: bash` runs it, with a stub `docker` first on PATH that keeps its containers and
  # images as files, and that fails the one call DOCKER_STUB_FAIL names. The stub answers as
  # Docker 29.9.3 did on the dev host (#1223): `rm --force` and `image rm --force` exit 0 on a
  # missing name, `image rm` printing an error for it, the `name` filter is an unanchored regex
  # matched against the name with and without its leading slash, and two tags of one image share
  # its ID.
  use ExUnit.Case, async: true

  @ci ".forgejo/workflows/ci.yml"
  @removal "Remove earlier attempts' container and image"
  @run_id "3707"
  @image_id "0123456789ab"

  # forgejo-runner v13.2.1 runs a `shell: bash` step file as `bash --noprofile --norc -e -o
  # pipefail <file>` (`shellCommand/1` in act/runner/step_run.go).
  @bash_flags ~w(--noprofile --norc -e -o pipefail)

  @stub_body ~S"""
  # Answers the four docker calls the removal step makes, and fails on any other.
  state=$DOCKER_STUB_STATE
  printf '%s\n' "$*" >>"$state/calls"
  call=$1
  if [ "$1" = image ]; then call="$1 $2"; fi
  if [ "$call" = "${DOCKER_STUB_FAIL:-}" ]; then
    echo "Error response from daemon: stub failure on $call" >&2
    exit 1
  fi
  case "$1 $2 $3 $4" in
    "ps --all --quiet --filter")
      regex=${5#name=}
      for f in "$state"/containers/*; do
        [ -e "$f" ] || continue
        name=${f##*/}
        # grep reads every line, not -q: a grep that quits on the first match can leave the
        # second line unwritten, and with SIGPIPE ignored, as the BEAM's children inherit it,
        # bash then prints "printf: write error: Broken pipe" into the output under test.
        if printf '%s\n' "/$name" "$name" | grep -E -- "$regex" >/dev/null; then echo "id-$name"; fi
      done
      ;;
    "rm --force "*)
      rm -f -- "$state/containers/$3"
      ;;
    "images --quiet "*)
      if [ -e "$state/images/$3" ]; then echo "$DOCKER_STUB_IMAGE_ID"; fi
      ;;
    "image rm --force "*)
      if [ "$4" = "$DOCKER_STUB_IMAGE_ID" ]; then
        rm -f -- "$state"/images/*
      elif [ -e "$state/images/$4" ]; then
        rm -f -- "$state/images/$4"
      else
        echo "Error response from daemon: No such image: $4" >&2
      fi
      ;;
    *)
      echo "docker stub: unexpected call: $*" >&2
      exit 2
      ;;
  esac
  """

  test "the container job names its image and smoke container once, per run and attempt" do
    job = container_job()

    assert job["env"]["CINDER_IMAGE"] ==
             "cinder:ci-${{ github.run_id }}-${{ github.run_attempt }}"

    assert job["env"]["CINDER_SMOKE_CONTAINER"] ==
             "cinder-ci-${{ github.run_id }}-${{ github.run_attempt }}"

    resets =
      for step <- job["steps"],
          name <- Map.keys(step["env"] || %{}),
          name in ["CINDER_IMAGE", "CINDER_SMOKE_CONTAINER"],
          do: "#{label(step)} sets #{name}"

    assert resets == []
  end

  test "no container step spells out an image or container name instead of reading the env" do
    spelled =
      for step <- container_job()["steps"],
          text <- step_strings(step),
          text =~ ~r/cinder[-:]ci-/,
          do: "#{label(step)}: #{text}"

    assert spelled == []
  end

  test "the removal step runs under bash, before any image build, on github.run_attempt" do
    steps = container_job()["steps"]
    removal = Enum.find_index(steps, &(&1["name"] == @removal))
    build = Enum.find_index(steps, &String.contains?(&1["run"] || "", "docker build"))

    assert is_integer(removal) and is_integer(build) and removal < build,
           "the removal step is at #{inspect(removal)}, the first docker build at #{inspect(build)}"

    step = Enum.at(steps, removal)
    assert step["shell"] == "bash"
    assert step["env"] == %{"RUN_ATTEMPT" => "${{ github.run_attempt }}"}
  end

  test "Boot a fresh instance prints both names before its docker run" do
    lines = "Boot a fresh instance" |> step!() |> Map.fetch!("run") |> String.split("\n")
    echo = Enum.find_index(lines, &(&1 =~ ~r/^echo .*\$CINDER_SMOKE_CONTAINER.*\$CINDER_IMAGE/))
    docker_run = Enum.find_index(lines, &String.starts_with?(&1, "docker run "))

    assert is_integer(echo) and is_integer(docker_run) and echo < docker_run,
           "the names echo is at line #{inspect(echo)}, docker run at #{inspect(docker_run)}"
  end

  describe "the removal step" do
    @describetag :tmp_dir

    test "on attempt 1 prints one line and calls no docker", %{tmp_dir: tmp_dir} do
      stub = stub!(tmp_dir, containers: ["cinder-ci-3707-1"])

      assert run_removal(stub, "1") ==
               {"This is attempt 1: no earlier attempt to clean up\n", 0}

      assert calls(stub) == []
      assert containers(stub) == ["cinder-ci-3707-1"]
    end

    test "with nothing left behind reads each earlier attempt as absent", %{tmp_dir: tmp_dir} do
      stub = stub!(tmp_dir)

      assert run_removal(stub, "2") ==
               {"Attempt 1: container cinder-ci-3707-1 absent, image cinder:ci-3707-1 absent\n",
                0}

      assert removals(stub) == []
    end

    test "on attempt 3 removes by name what attempts 1 and 2 left, and nothing else",
         %{tmp_dir: tmp_dir} do
      stub =
        stub!(tmp_dir,
          containers: decoy_containers() ++ ["cinder-ci-3707-1", "cinder-ci-3707-3"],
          images: ["cinder:ci-3707-2", "cinder:ci-3707-10", "cinder:ci-3707-3"]
        )

      assert run_removal(stub, "3") ==
               {"Attempt 1: container cinder-ci-3707-1 removed, image cinder:ci-3707-1 absent\n" <>
                  "Attempt 2: container cinder-ci-3707-2 absent, image cinder:ci-3707-2 removed\n",
                0}

      assert removals(stub) == [
               "rm --force cinder-ci-3707-1",
               "image rm --force cinder:ci-3707-2"
             ]

      assert containers(stub) == Enum.sort(decoy_containers() ++ ["cinder-ci-3707-3"])
      assert images(stub) == ["cinder:ci-3707-10", "cinder:ci-3707-3"]
    end

    test "reads a name that only contains an earlier attempt's name as absent",
         %{tmp_dir: tmp_dir} do
      stub = stub!(tmp_dir, containers: decoy_containers(), images: ["cinder:ci-3707-10"])

      assert run_removal(stub, "2") ==
               {"Attempt 1: container cinder-ci-3707-1 absent, image cinder:ci-3707-1 absent\n",
                0}

      assert removals(stub) == []
      assert containers(stub) == Enum.sort(decoy_containers())
      assert images(stub) == ["cinder:ci-3707-10"]
    end

    # Attempt 1's container and image are both left, so the step reaches all four calls.
    test "stops at whichever docker call fails, before it reports the attempt",
         %{tmp_dir: tmp_dir} do
      for call <- ["ps", "rm", "images", "image rm"] do
        stub =
          stub!(Path.join(tmp_dir, String.replace(call, " ", "-")),
            containers: ["cinder-ci-3707-1"],
            images: ["cinder:ci-3707-1"]
          )

        {output, status} = run_removal(stub, "2", fail: call)

        assert status != 0, "a failed #{call} exited 0: #{output}"
        assert output == "Error response from daemon: stub failure on #{call}\n"
        assert stub |> calls() |> List.last() |> String.starts_with?(call <> " ")
      end
    end

    # #1193's brief correction: forgejo-runner copies the forge's run_attempt over its own "1"
    # default unchecked, so an empty value from the forge would give every attempt one name.
    test "fails, naming the cause, on a run_attempt that is not a positive integer",
         %{tmp_dir: tmp_dir} do
      for attempt <- ["", "a", "0", "01", "2x", "-1"] do
        stub = stub!(Path.join(tmp_dir, "attempt#{attempt}"))
        {output, status} = run_removal(stub, attempt)

        assert status == 1, "run_attempt #{inspect(attempt)} exited #{status}: #{output}"

        assert output ==
                 "::error::github.run_attempt is '#{attempt}', not a positive integer, so the " <>
                   "container and image names do not tell this run's attempts apart\n"

        assert calls(stub) == []
      end
    end

    test "fails before any docker call when a name lacks the attempt suffix",
         %{tmp_dir: tmp_dir} do
      for {container, image} <- [
            {"cinder-ci-3707", "cinder:ci-3707-2"},
            {"cinder-ci-3707-2", "cinder:ci-3707"}
          ] do
        stub = stub!(Path.join(tmp_dir, container <> image))
        {output, status} = run_removal(stub, "2", container: container, image: image)

        assert status == 1, "#{container} and #{image} exited #{status}: #{output}"
        assert output =~ "must both end in -2"
        assert calls(stub) == []
      end
    end
  end

  # Containers whose names contain attempt 1's name `cinder-ci-3707-1` without being it.
  defp decoy_containers, do: ["cinder-ci-3707-10", "cinder-ci-3707-1x", "pre-cinder-ci-3707-1"]

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

  defp label(step), do: step["name"] || step["uses"] || step["run"]

  # Every string a step hands its command: the run text, and each with: and env: value.
  defp step_strings(step) do
    values = Map.values(step["with"] || %{}) ++ Map.values(step["env"] || %{})
    for value <- [step["run"] | values], is_binary(value), do: value
  end

  # A temp dir holding the stub `docker` and its state: one file per container and per image.
  defp stub!(dir, opts \\ []) do
    stub = %{bin: Path.join(dir, "bin"), state: Path.join(dir, "state"), dir: dir}

    for sub <- ["containers", "images"], do: File.mkdir_p!(Path.join(stub.state, sub))
    File.mkdir_p!(stub.bin)
    File.write!(Path.join(stub.state, "calls"), "")

    for name <- Keyword.get(opts, :containers, []),
        do: File.write!(Path.join([stub.state, "containers", name]), "")

    for name <- Keyword.get(opts, :images, []),
        do: File.write!(Path.join([stub.state, "images", name]), "")

    docker = Path.join(stub.bin, "docker")
    File.write!(docker, "#!#{bash()}\n" <> @stub_body)
    File.chmod!(docker, 0o755)
    stub
  end

  defp run_removal(stub, attempt, opts \\ []) do
    script = Path.join(stub.dir, "removal.sh")
    File.write!(script, step!(@removal)["run"])

    env = [
      {"PATH", stub.bin <> ":" <> System.get_env("PATH", "")},
      {"DOCKER_STUB_STATE", stub.state},
      {"DOCKER_STUB_IMAGE_ID", @image_id},
      {"DOCKER_STUB_FAIL", opts[:fail]},
      {"RUN_ATTEMPT", attempt},
      {"CINDER_SMOKE_CONTAINER",
       Keyword.get(opts, :container, "cinder-ci-#{@run_id}-#{attempt}")},
      {"CINDER_IMAGE", Keyword.get(opts, :image, "cinder:ci-#{@run_id}-#{attempt}")}
    ]

    System.cmd(bash(), @bash_flags ++ [script], env: env, stderr_to_stdout: true)
  end

  defp bash, do: System.find_executable("bash") || flunk("bash is not on PATH")

  defp calls(stub),
    do: stub.state |> Path.join("calls") |> File.read!() |> String.split("\n", trim: true)

  defp removals(stub), do: Enum.filter(calls(stub), &(&1 =~ ~r/^(image )?rm /))

  defp containers(stub), do: stub.state |> Path.join("containers") |> File.ls!() |> Enum.sort()

  defp images(stub), do: stub.state |> Path.join("images") |> File.ls!() |> Enum.sort()
end
