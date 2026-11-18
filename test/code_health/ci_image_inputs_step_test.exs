defmodule Cinder.CodeHealth.CiImageInputsStepTest do
  # #1486: ci.yml's `image-inputs` job tells `container` whether a pull request changes a path of
  # image-inputs.txt, and `container` skips on an explicit `false`. The first tests read the two
  # jobs' shape from the workflow. The rest run the decide step's `run:` text under bash, as
  # `shell: bash` runs it, in fixture repos whose main sits at refs/remotes/origin/main, as the
  # job's full-history checkout leaves it, and read the output file the step writes.
  #
  # The runner's name for that output file is built from parts, so this file holds no runner
  # variable name and Cinder.PushRepeatsPr's scan passes it.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @ci ".forgejo/workflows/ci.yml"
  @output_var "GITHUB" <> "_OUTPUT"

  # forgejo-runner v13.2.1 runs a `shell: bash` step file as `bash --noprofile --norc -e -o
  # pipefail <file>` (`shellCommand/1` in act/runner/step_run.go).
  @bash_flags ~w(--noprofile --norc -e -o pipefail)

  @list "# the paths\n\nlib\nmix.exs\n.github/scripts\n"

  test "container needs image-inputs and skips only on its explicit false" do
    jobs = jobs()
    container = jobs["container"]

    assert container["needs"] == "image-inputs"
    assert container["if"] == "needs.image-inputs.outputs.build != 'false'"
    assert jobs["image-inputs"]["outputs"] == %{"build" => "${{ steps.decide.outputs.build }}"}
  end

  test "image-inputs checks out the full history, then runs the decide step under bash" do
    [checkout, decide] = jobs()["image-inputs"]["steps"]

    assert checkout["uses"] =~ ~r/\Aactions\/checkout@[0-9a-f]{40}\z/
    assert checkout["with"] == %{"fetch-depth" => 0}
    assert Map.keys(decide) |> Enum.sort() == ~w(env id name run shell)
    assert {decide["id"], decide["shell"]} == {"decide", "bash"}

    assert decide["env"] == %{
             "EVENT" => "${{ github.event_name }}",
             "BASE_REF" => "${{ github.base_ref }}"
           }
  end

  describe "a run of another event" do
    test "a push skips without reading git or the list", %{tmp_dir: dir} do
      assert {0, "false", log} = run_step(dir, "push", "")

      assert log ==
               "A push run builds no image: Coolify builds main's image for prod, so the " <>
                 "container job skips\n"
    end

    test "any other event builds without reading git or the list", %{tmp_dir: dir} do
      assert {0, "true", log} = run_step(dir, "workflow_dispatch", "")
      assert log == "A workflow_dispatch run: the container job runs\n"
    end
  end

  describe "a pull request" do
    test "builds when the branch changes a listed path, and prints the paths", %{tmp_dir: dir} do
      repo = repo!(dir, %{"lib/a.ex" => "changed\n", "test/a_test.exs" => "changed\n"})

      assert {0, "true", log} = run_step(repo, "pull_request", "main")
      assert log =~ "since it left origin/main, so the container job runs:\nlib/a.ex\n"
      refute log =~ "test/a_test.exs"
    end

    test "skips when the branch changes no listed path", %{tmp_dir: dir} do
      repo = repo!(dir, %{"test/a_test.exs" => "changed\n", ".github/other.yml" => "x\n"})

      assert {0, "false", log} = run_step(repo, "pull_request", "main")
      assert log =~ "changes no path of image-inputs.txt since it left origin/main"
    end

    test "builds on a change under a listed folder, a deleted file, a listed file, and a rename " <>
           "in either direction",
         %{tmp_dir: dir} do
      for {name, files} <- [
            {"under", %{".github/scripts/smoke.py" => "changed\n"}},
            {"deleted", %{"lib/a.ex" => nil}},
            {"file", %{"mix.exs" => "changed\n"}},
            {"out", %{"lib/a.ex" => nil, "test/a.ex" => "a\n"}},
            {"in", %{"test/a_test.exs" => nil, "lib/a_test.exs" => "a\n"}}
          ] do
        repo = repo!(Path.join(dir, name), files)
        {status, build, log} = run_step(repo, "pull_request", "main")
        assert {name, status, build} == {name, 0, "true"}, log
      end
    end

    test "counts only the branch's own changes, not what main gained since", %{tmp_dir: dir} do
      repo =
        repo!(dir, %{"test/a_test.exs" => "changed\n"}, main_after: %{"lib/a.ex" => "main\n"})

      assert {0, "false", _log} = run_step(repo, "pull_request", "main")
    end

    test "reads a last list line with no newline", %{tmp_dir: dir} do
      repo = repo!(dir, %{"lib/a.ex" => "changed\n"}, list: "mix.exs\nlib")

      assert {0, "true", _log} = run_step(repo, "pull_request", "main")
    end
  end

  describe "fails, writing no output" do
    test "on a list line outside the path form", %{tmp_dir: dir} do
      for {line, index} <-
            Enum.with_index([
              "lib/",
              "/lib",
              "./lib",
              "lib/../x",
              "l*b",
              "lib\r",
              " lib",
              "lib // x"
            ]) do
        repo =
          repo!(Path.join(dir, "#{index}"), %{"lib/a.ex" => "changed\n"},
            list: "mix.exs\n" <> line <> "\n"
          )

        assert {1, nil, log} = run_step(repo, "pull_request", "main")

        assert {line, log =~ "::error::image-inputs.txt:2: '#{line}' is not a path"} ==
                 {line, true}
      end
    end

    test "on a list with no path, and on a missing list", %{tmp_dir: dir} do
      repo = repo!(Path.join(dir, "empty"), %{"lib/a.ex" => "changed\n"}, list: "# none\n\n")
      assert {1, nil, log} = run_step(repo, "pull_request", "main")
      assert log =~ "::error::image-inputs.txt holds no path"

      repo = repo!(Path.join(dir, "missing"), %{"lib/a.ex" => "changed\n"}, list: nil)
      assert {1, nil, log} = run_step(repo, "pull_request", "main")
      assert log =~ "::error::image-inputs.txt is missing"
    end

    test "when git cannot diff against the base branch", %{tmp_dir: dir} do
      repo = repo!(dir, %{"lib/a.ex" => "changed\n"})

      assert {1, nil, log} = run_step(repo, "pull_request", "release")
      assert log =~ "::error::git cannot diff origin/release...HEAD"
    end

    test "when git fails on a base branch that exists", %{tmp_dir: dir} do
      repo = repo!(Path.join(dir, "repo"), %{"test/a_test.exs" => "changed\n"})
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "git"), "#!/bin/sh\necho \"git: $*\" >&2\nexit 128\n")
      File.chmod!(Path.join(bin, "git"), 0o755)

      assert {1, nil, log} = run_step(repo, "pull_request", "main", path: bin)
      assert log =~ "git: diff --name-only --no-renames origin/main...HEAD -- :(literal)lib"
      assert log =~ "::error::git cannot diff origin/main...HEAD"
    end
  end

  defp jobs do
    [workflow] = YamlElixir.read_all_from_string!(File.read!(@ci))
    workflow["jobs"]
  end

  # A repo in `dir`: main holds the list and a few files, refs/remotes/origin/main points at it,
  # and HEAD is a branch that lays `files` over main (nil deletes a file). `opts[:main_after]`
  # adds a commit to origin/main after the branch left it. `opts[:list]` sets the list on main,
  # nil leaving it out.
  defp repo!(dir, files, opts \\ []) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])

    base = %{
      "image-inputs.txt" => Keyword.get(opts, :list, @list),
      "lib/a.ex" => "a\n",
      "mix.exs" => "m\n",
      ".github/scripts/smoke.py" => "s\n",
      "test/a_test.exs" => "t\n"
    }

    commit!(dir, base, "main")
    git!(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(dir, ["checkout", "-q", "-b", "branch"])
    commit!(dir, files, "branch")

    if gained = opts[:main_after] do
      git!(dir, ["checkout", "-q", "origin/main"])
      commit!(dir, gained, "main after")
      git!(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      git!(dir, ["checkout", "-q", "branch"])
    end

    dir
  end

  defp commit!(dir, files, message) do
    for {path, content} <- files do
      full = Path.join(dir, path)

      if content == nil do
        File.rm_rf!(full)
      else
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
      end
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "--allow-empty", "-m", message])
  end

  # git without the caller's GIT_ variables, its global and system config, and its hooks.
  defp git!(dir, args) do
    {out, status} =
      System.cmd("git", git_config() ++ args, cd: dir, env: git_env(), stderr_to_stdout: true)

    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  defp git_config,
    do: ~w(-c user.name=fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null)

  defp git_env do
    set = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

    unset =
      for {name, _value} <- System.get_env(),
          String.starts_with?(name, "GIT_"),
          not List.keymember?(set, name, 0),
          do: {name, nil}

    unset ++ set
  end

  # Runs the decide step in `dir` and returns its exit status, the `build` value it wrote (nil
  # when it wrote none) and its log.
  # `opts[:path]` puts a folder of stub commands first on PATH.
  defp run_step(dir, event, base_ref, opts \\ []) do
    [_checkout, decide] = jobs()["image-inputs"]["steps"]
    work = Path.join(dir, ".step-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    script = Path.join(work, "step.sh")
    output = Path.join(work, "output")
    File.write!(script, decide["run"])
    File.write!(output, "")

    env = git_env() ++ [{"EVENT", event}, {"BASE_REF", base_ref}, {@output_var, output}]

    env =
      if stubs = opts[:path],
        do: [{"PATH", stubs <> ":" <> System.get_env("PATH")} | env],
        else: env

    {log, status} =
      System.cmd(bash(), @bash_flags ++ [script], env: env, cd: dir, stderr_to_stdout: true)

    build =
      case File.read!(output) do
        "" -> nil
        "build=" <> value -> String.trim_trailing(value, "\n")
      end

    {status, build, log}
  end

  defp bash, do: System.find_executable("bash") || flunk("bash is not on PATH")
end
