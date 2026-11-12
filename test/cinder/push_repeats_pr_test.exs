defmodule Cinder.PushRepeatsPrTest.Fixtures do
  # The fixture repos for `Cinder.PushRepeatsPr` (#1254). The base repo holds the shapes the check
  # must pass, as cinder's ci.yml and release.yml have them: every allowed difference at its key,
  # and a runner variable name in Markdown. Each case edits it into one difference and asserts
  # exit 1 and the line that names that difference, so removing a rule turns its case red.
  #
  # The runner variable names and the toolkit's module name are built from parts here, as in the
  # check, so neither file holds one and the check reads both.
  import ExUnit.Assertions

  alias Cinder.PushRepeatsPr

  @gh "GITHUB" <> "_"

  @ci ~s"""
  name: CI

  on:
    push:
      branches: [main]
    pull_request:

  concurrency:
    group: ci-${{ github.ref }}
    cancel-in-progress: true

  jobs:
    test:
      runs-on: ubuntu-24.04
      env:
        MIX_ENV: test
      steps:
        - uses: actions/checkout@v7
        - uses: erlef/setup-beam@v1
          id: beam
          with:
            otp-version: "29.1.2"
            elixir-version: "1.20.5"
        - uses: actions/cache@v6
          with:
            path: deps
            key: ${{ runner.os }}-${{ steps.beam.outputs.otp-version }}-${{ steps.beam.outputs.elixir-version }}-mix-${{ hashFiles('**/mix.lock') }}
            restore-keys: ${{ runner.os }}-${{ steps.beam.outputs.otp-version }}-${{ steps.beam.outputs.elixir-version }}-mix-
        - uses: actions/cache@v6
          id: deps-build
          with:
            path: _build/test/lib/*
            key: ${{ runner.os }}-deps-build-test-${{ hashFiles('**/mix.lock') }}
        - if: steps.deps-build.outputs.cache-hit != 'true'
          run: |
            for attempt in 1 2 3; do
              sudo apt-get update && break
              if [ "$attempt" = 3 ]; then exit 1; fi
              echo "apt-get update failed (attempt $attempt of 3); retrying in 30 s"
              sleep 30
            done
            sudo apt-get install -y --no-install-recommends cmake
        - shell: bash
          run: mix test 2>&1 | tee mix-test-output.log
        - name: Upload mix test output
          if: always()
          uses: https://data.forgejo.org/forgejo/upload-artifact@v5

    container:
      runs-on: ubuntu-latest
      env:
        CINDER_IMAGE: cinder:ci-${{ github.run_id }}-${{ github.run_attempt }}
      steps:
        - uses: actions/checkout@v7
        - name: Remove earlier attempts' container and image
          env:
            RUN_ATTEMPT: ${{ github.run_attempt }}
          run: echo "$RUN_ATTEMPT"
        # The download unsets #{@gh}TOKEN, and writes under #{@gh}WORKSPACE.
        - name: Download the Trivy vulnerability DB
          run: |
            if env -u #{@gh}TOKEN timeout 3m trivy image --download-db-only \\

              --cache-dir "$#{@gh}WORKSPACE/.cache/trivy"; then
              exit 0
            fi
            exit 1
        - uses: aquasecurity/trivy-action@v0.36.0
          with:
            image-ref: ${{ env.CINDER_IMAGE }}
        - name: Remove the CI image
          if: always()
          run: docker image rm -f "$CINDER_IMAGE" || true
  """

  @release ~s"""
  name: Release

  on:
    push:
      tags:
        - "v*.*.*"

  jobs:
    build-push:
      runs-on: ubuntu-latest
      steps:
        - uses: docker/login-action@v4
          with:
            registry: ghcr.io
            username: ${{ github.actor }}
            password: ${{ secrets.#{@gh}TOKEN }}
        - uses: docker/build-push-action@v7
          with:
            tags: ${{ steps.meta.outputs.tags }}
  """

  def gh, do: @gh
  def ci, do: @ci
  def release, do: @release

  def base do
    %{
      ".forgejo/workflows/ci.yml" => @ci,
      ".github/workflows/release.yml" => @release,
      "AGENTS.md" => "Read $#{@gh}REF in prose.\n",
      "scripts/build.sh" => "mix compile\n"
    }
  end

  # ci.yml with `steps` appended to the container job's steps, the last ones in the file. The
  # first appended step is jobs.container.steps[5], on line appended().
  def ci_with(steps), do: @ci <> steps

  def appended, do: length(String.split(@ci, "\n"))

  # `text` with `old` replaced once by `new`, failing when `old` is not in it, so a fixture edit
  # that matches nothing cannot pass as a case.
  def edit(text, old, new) do
    assert String.contains?(text, old), "the fixture holds no #{inspect(old)}"
    String.replace(text, old, new, global: false)
  end

  def ci_edit(old, new), do: edit(@ci, old, new)

  # A git repo in a fresh temporary directory, holding the base files with `files` laid over
  # them (a nil value deletes the file, `{:link, target}` makes a symbolic link), and its
  # commit's SHA.
  def repo!(files) do
    dir =
      Path.join(System.tmp_dir!(), "cinder-push-repeats-pr-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    git!(dir, ["init", "-q", "-b", "main"])

    for {path, content} <- Map.merge(base(), files), content != nil do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))

      case content do
        {:link, target} -> File.ln_s!(target, full)
        text -> File.write!(full, text)
      end
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "fixture"])
    {dir, String.trim(git!(dir, ["rev-parse", "HEAD"]))}
  end

  # git without the caller's GIT_ variables, its global and system config, and its hooks.
  def git!(dir, args) do
    set = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

    unset =
      for {name, _value} <- System.get_env(),
          String.starts_with?(name, "GIT_"),
          not List.keymember?(set, name, 0),
          do: {name, nil}

    env = unset ++ set

    config =
      ~w(-c user.name=fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null)

    {out, status} = System.cmd("git", config ++ args, cd: dir, env: env, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  def check(files) do
    {dir, sha} = repo!(files)
    PushRepeatsPr.check(sha, cd: dir)
  end

  def assert_reports(files, fragments) do
    {code, lines} = check(files)
    output = Enum.join(lines, "\n")

    for fragment <- List.wrap(fragments) do
      assert code == 1 and Enum.any?(lines, &String.contains?(&1, fragment)),
             "expected exit 1 and a line holding #{inspect(fragment)}, got exit #{code}:\n#{output}"
    end
  end

  def assert_passes(files, opts \\ []) do
    {dir, sha} = repo!(files)
    {code, lines} = PushRepeatsPr.check(sha, cd: Path.join(dir, Keyword.get(opts, :from, ".")))

    assert {code, length(lines)} == {0, 1},
           "expected exit 0 and one line:\n" <> Enum.join(lines, "\n")

    assert hd(lines) =~
             ~r/^check-push-repeats-pr: #{String.slice(sha, 0, 8)}: the push run repeats/
  end
end

defmodule Cinder.PushRepeatsPrTest do
  use ExUnit.Case, async: true

  import Cinder.PushRepeatsPrTest.Fixtures
  import ExUnit.CaptureIO

  alias Cinder.PushRepeatsPr

  @ci ".forgejo/workflows/ci.yml"
  @release ".github/workflows/release.yml"
  @gh "GITHUB" <> "_"

  describe "passes" do
    test "the base repo, which holds every allowed difference at its key" do
      {dir, sha} = repo!(%{})

      assert PushRepeatsPr.check(sha, cd: dir) ==
               {0,
                [
                  "check-push-repeats-pr: #{String.slice(sha, 0, 8)}: the push run repeats the " <>
                    "PR run (1 workflow file(s), 2 YAML file(s) read)"
                ]}
    end

    test "triggers as a list, as a string-branch filter, unfiltered, and beside schedule and workflow_dispatch" do
      for on <- [
            "on: [push, pull_request]\n",
            "on:\n  push:\n    branches: main\n  pull_request: {}\n",
            "on:\n  push:\n  pull_request:\n  schedule:\n    - cron: '0 3 * * *'\n  workflow_dispatch:\n"
          ] do
        assert_passes(%{
          @ci => ci_edit("on:\n  push:\n    branches: [main]\n  pull_request:\n", on)
        })
      end
    end

    test "run from a subfolder of the repo" do
      assert_passes(%{}, from: "scripts")
    end

    test "a workflow in a subfolder of .forgejo/workflows, an action.yml and another .github workflow, none holding a difference" do
      assert_passes(%{
        ".forgejo/workflows/nightly/lint.yml" =>
          "on:\n  push:\n  pull_request:\njobs:\n  lint:\n    runs-on: x\n    steps:\n      - run: mix credo\n",
        "tools/build/action.yaml" =>
          "name: build\nruns:\n  using: composite\n  steps:\n    - run: mix compile\n      shell: bash\n",
        ".github/workflows/docs.yml" => "on:\n  push:\n    tags: [docs-*]\njobs: {}\n"
      })
    end

    # cinder's own tree links CLAUDE.md to AGENTS.md and .claude/skills to .agents/skills. A link
    # to a folder the tree holds, the root and a folder named like Markdown included, leads to
    # files the scan reads.
    test "a symbolic link at a path the check does not read as YAML, to a file or a folder the tree holds" do
      assert_passes(%{
        "scripts/latest.sh" => {:link, "../scripts/build.sh"},
        "config/dev.yml" => {:link, "../scripts/build.sh"},
        "CLAUDE.md" => {:link, "AGENTS.md"},
        ".claude/skills" => {:link, "../.agents/skills"},
        ".agents/skills/x/SKILL.md" => "---\nname: x\n---\n",
        "tools.md" => {:link, "scripts"},
        "scripts/root" => {:link, ".."},
        "scripts/docs" => {:link, "../docs.md"},
        "docs.md/run.sh" => "mix compile\n"
      })
    end

    test "Markdown that names a runner variable, at any depth" do
      assert_passes(%{"docs/agents/ci.md" => "Read $#{@gh}EVENT_NAME.\n"})
    end

    test "the check's module, its script and this test, which hold none of the names the scan reads" do
      assert_passes(
        Map.new(
          [
            "test/support/push_repeats_pr.ex",
            "test/support/push_repeats_pr/context.ex",
            "scripts/check-push-repeats-pr.exs",
            "test/cinder/push_repeats_pr_test.exs"
          ],
          &{&1, File.read!(&1)}
        )
      )
    end
  end

  describe "a difference in the triggers" do
    test "no push trigger" do
      assert_reports(
        %{@ci => ci_edit("  push:\n    branches: [main]\n", "")},
        "#{@ci}: no push trigger"
      )
    end

    test "no pull_request trigger, in each form of on:" do
      for on <- ["on:\n  push:\n    branches: [main]\n", "on: push\n", "on: [push]\n"] do
        assert_reports(
          %{@ci => ci_edit("on:\n  push:\n    branches: [main]\n  pull_request:\n", on)},
          "#{@ci}: no pull_request trigger"
        )
      end
    end

    test "a pull_request filter, branches: [main] included" do
      for filter <- ["\n    branches: [main]\n", "\n    types: [opened]\n"] do
        assert_reports(
          %{@ci => ci_edit("  pull_request:\n", "  pull_request:" <> filter)},
          "#{@ci}: pull_request has a filter"
        )
      end
    end

    test "a push filter beyond branches: [main]" do
      for filter <- ["branches: [main, dev]", "branches: [dev]", "paths: [lib]", "tags: [v*]"] do
        assert_reports(
          %{@ci => ci_edit("    branches: [main]\n", "    " <> filter <> "\n")},
          "#{@ci}: push has a filter beyond branches: [main]"
        )
      end

      assert_reports(
        %{@ci => ci_edit("    branches: [main]\n", "    branches: [main]\n    paths: [lib]\n")},
        "#{@ci}: push has a filter beyond branches: [main]"
      )
    end

    test "a trigger other than push, pull_request, schedule and workflow_dispatch" do
      assert_reports(
        %{@ci => ci_edit("  pull_request:\n", "  pull_request:\n  pull_request_target:\n")},
        "#{@ci}: trigger pull_request_target"
      )
    end

    test "a workflow with no on:" do
      assert_reports(
        %{@ci => ci_edit("on:\n  push:\n    branches: [main]\n  pull_request:\n", "")},
        "#{@ci}: no on: triggers"
      )
    end

    test "no workflow under .forgejo/workflows" do
      assert_reports(%{@ci => nil}, ".forgejo/workflows/: no workflow file")
    end

    test "a job that calls a reusable workflow" do
      assert_reports(
        %{@ci => ci() <> "  reuse:\n    uses: ./.forgejo/workflows/other.yml\n"},
        "jobs.reuse: calls a reusable workflow: ./.forgejo/workflows/other.yml"
      )
    end

    test "a workflow in a subfolder of .forgejo/workflows, or named .yaml, that runs on push only" do
      for file <- [".forgejo/workflows/nightly/push.yml", ".forgejo/workflows/push.yaml"] do
        assert_reports(%{file => "on:\n  push:\njobs: {}\n"}, "#{file}: no pull_request trigger")
      end
    end

    test "a .github/workflows file with a trigger other than a push of tags" do
      for on <- [
            "on:\n  push:\n    branches: [main]\n",
            "on: [push]\n",
            "on:\n  push:\n    tags: [v*]\n    branches: [main]\n",
            "on:\n  push:\n    tags: [v*]\n  pull_request:\n"
          ] do
        assert_reports(
          %{@release => edit(release(), "on:\n  push:\n    tags:\n      - \"v*.*.*\"\n", on)},
          "#{@release}: a trigger other than a push of tags"
        )
      end

      assert_reports(
        %{".github/workflows/check.yml" => "on: pull_request\njobs: {}\n"},
        ".github/workflows/check.yml: a trigger other than a push of tags"
      )
    end
  end

  describe "an if:" do
    test "outside the two allowed" do
      assert_reports(
        %{@ci => ci_with("      - if: github.event_name == 'push'\n        run: mix docs\n")},
        "#{@ci}:#{appended()}: jobs.container.steps[5].if: an if: github.event_name == 'push'"
      )
    end

    test "with its key in quotes or a space before its colon" do
      for key <- [~s("if":), "if :"] do
        assert_reports(
          %{
            @ci =>
              ci_with("      - #{key} github.ref == 'refs/heads/main'\n        run: mix docs\n")
          },
          "jobs.container.steps[5].if: an if: github.ref == 'refs/heads/main'"
        )
      end
    end

    test "if: always() on a job, or under a step's with:" do
      assert_reports(
        %{@ci => ci_edit("  container:\n", "  container:\n    if: always()\n")},
        "jobs.container.if: an if: always()"
      )

      assert_reports(
        %{
          @ci => ci_with("      - uses: some/action@v1\n        with:\n          if: always()\n")
        },
        "jobs.container.steps[5].with.if: an if: always()"
      )
    end

    test "a pre-if: or post-if: in an action, and pre-if: always() on a workflow step" do
      action =
        "runs:\n  using: node20\n  main: index.js\n" <>
          "  pre-if: github.event_name == 'push'\n  post-if: github.ref == 'refs/heads/main'\n"

      assert_reports(%{"tools/action.yml" => action}, [
        "tools/action.yml:4: runs.pre-if: an if: github.event_name == 'push'",
        "tools/action.yml:5: runs.post-if: an if: github.ref == 'refs/heads/main'"
      ])

      assert_reports(
        %{@ci => ci_with("      - run: mix docs\n        pre-if: always()\n")},
        "#{@ci}:#{appended() + 1}: jobs.container.steps[5].pre-if: an if: always()"
      )
    end

    test "if: always() on a step of a YAML file under .forgejo that is not a workflow" do
      for file <- [".forgejo/actions/build/action.yml", ".forgejo/settings.yml"] do
        assert_reports(
          %{file => "jobs:\n  build:\n    steps:\n      - if: always()\n        run: x\n"},
          "#{file}:4: jobs.build.steps[0].if: an if: always()"
        )
      end
    end

    test "the cache-hit if: on a step that is not the cmake step of a job with the deps-build cache" do
      cmake_if = "jobs.test.steps[4].if: an if: steps.deps-build.outputs.cache-hit != 'true'"

      # A key besides if and run.
      assert_reports(
        %{
          @ci =>
            ci_edit(
              "      - if: steps.deps-build",
              "      - name: cmake\n        if: steps.deps-build"
            )
        },
        cmake_if
      )

      # A run that does more.
      assert_reports(
        %{
          @ci =>
            ci_edit(
              "--no-install-recommends cmake\n",
              "--no-install-recommends cmake\n          mix deps.compile\n"
            )
        },
        cmake_if
      )

      # deps-build is no actions/cache step.
      assert_reports(
        %{
          @ci =>
            ci_edit(
              "      - uses: actions/cache@v6\n        id: deps-build",
              "      - uses: some/cache@v6\n        id: deps-build"
            )
        },
        cmake_if
      )

      # No step of the job has the id deps-build.
      assert_reports(%{@ci => ci_edit("        id: deps-build\n", "")}, cmake_if)
    end
  end

  describe "an expression outside the allow-list" do
    test "in a value" do
      assert_reports(
        %{@ci => ci_with("      - run: echo ${{ github.event_name }}\n")},
        "#{@ci}:#{appended()}: jobs.container.steps[5].run: an expression: ${{ github.event_name }}"
      )
    end

    test "in a key, one a step's env allows in a value included" do
      for expression <- ["${{ github.event_name }}", "${{ github.run_id }}"] do
        assert_reports(
          %{@ci => ci_with("      - env:\n          #{expression}: x\n        run: env\n")},
          "jobs.container.steps[5].env.#{expression} (key): an expression: #{expression}"
        )
      end
    end

    test "spelled with a YAML escape, split over lines, or as a !!binary value" do
      for value <- [
            ~s("echo \\x24{{ github.event_name }}"),
            ">-\n          echo ${{ github.\n          event_name }}",
            "!!binary JHt7IGdpdGh1Yi5ldmVudF9uYW1lIH19"
          ] do
        assert_reports(
          %{@ci => ci_with("      - run: #{value}\n")},
          "jobs.container.steps[5].run: an expression: ${{ github."
        )
      end
    end

    test "in a YAML file under .forgejo that is not a workflow, or in an action.yml or action.yaml" do
      for file <- [".forgejo/issue_template/bug.yml", "tools/action.yml", "tools/action.yaml"] do
        assert_reports(
          %{file => "concurrency:\n  group: ci-${{ github.ref }}\n"},
          "#{file}:2: concurrency.group: an expression: ${{ github.ref }}"
        )
      end
    end

    test "in an action.yml under .forgejo/workflows, where the allowances of a workflow do not hold" do
      file = ".forgejo/workflows/build/action.yml"
      comment = Enum.find_index(String.split(ci(), "\n"), &(&1 =~ "# The download unsets")) + 1

      assert_reports(%{file => ci()}, [
        "#{file}:9: concurrency.group: an expression: ${{ github.ref }}",
        "jobs.container.steps[2].run: names a runner variable or reads the event",
        "#{file}:#{comment}: names a runner variable or reads the event: # The download unsets"
      ])
    end

    test "a step that uses actions/github-script" do
      assert_reports(
        %{@ci => ci_with("      - uses: actions/github-script@v7\n")},
        "jobs.container.steps[5].uses: runs code that gets the event: actions/github-script@v7"
      )
    end
  end

  describe "a runner variable name or an event read" do
    test "in a script, a module or a workflow, for each name the scan reads" do
      for {file, text} <- [
            {"scripts/ref.sh", ~s[echo "$#{@gh}REF"\n]},
            {"lib/forgejo.ex", ~s[System.get_env("#{"FORGEJO" <> "_"}EVENT_NAME")\n]},
            {"lib/forge.ex", ~s[System.get_env("#{"FORGE" <> "_"}REF")\n]},
            {"assets/js/ci.js", ~s[require("#{Enum.join(["@actions", "github"], "/")}");\n]},
            {"assets/js/event.js", ~s[context.#{"event" <> "Name"};\n]},
            {"README.MD", "Read $#{@gh}REF.\n"}
          ] do
        assert_reports(%{file => text}, "#{file}:1: names a runner variable or reads the event: ")
      end
    end

    # The scan skips Markdown, and a step that runs the link runs the Markdown it points to.
    test "in Markdown that a symbolic link outside Markdown points to" do
      assert_reports(
        %{
          "scripts/probe.sh" => {:link, "../docs/probe.md"},
          "docs/probe.md" => "echo $#{@gh}EVENT_NAME\n"
        },
        "scripts/probe.sh: a symbolic link to Markdown, which the scan skips"
      )
    end

    # A file outside the tree, such as the run's own environment, is no file the scan can read.
    # The kernel follows a link met inside a target before any `..` after it, so a target that
    # passes through another link can lead out of the tree whatever its text says. A link named
    # like Markdown runs what it reaches all the same.
    test "in a file out of the tree, or behind another link, that a link points to" do
      for {files, link} <- [
            {%{"scripts/env.txt" => {:link, "/proc/self/environ"}}, "scripts/env.txt"},
            {%{"tools.md" => {:link, "/tmp"}}, "tools.md"},
            {%{"tools.md" => {:link, "../.."}}, "tools.md"},
            {%{"scripts/root" => {:link, ".."}, "tools.md" => {:link, "scripts/root"}},
             "tools.md"},
            {%{"scripts/up.sh" => {:link, "../../outside.sh"}}, "scripts/up.sh"},
            {%{"scripts/dot.sh" => {:link, "./.././../outside.sh"}}, "scripts/dot.sh"},
            {%{"scripts/slash.sh" => {:link, "..//../outside.sh"}}, "scripts/slash.sh"},
            {%{"scripts/root" => {:link, ".."}, "scripts/x.sh" => {:link, "root/../outside.sh"}},
             "scripts/x.sh"},
            {%{
               "deep/a/b/up" => {:link, "../../.."},
               "scripts/env.txt" => {:link, "../deep/a/b/up/../../../proc/self/environ"}
             }, "scripts/env.txt"},
            {%{"scripts/a.sh" => {:link, "b.sh"}, "scripts/b.sh" => {:link, "build.sh"}},
             "scripts/a.sh"}
          ] do
        assert_reports(
          files,
          "#{link}: a symbolic link out of the tree or through another link, which the scan " <>
            "cannot follow"
        )
      end
    end

    # The checkout holds paths the tree does not: .git/, and deps/ or _build/ that a run fills.
    # A link to one reaches a file the scan never reads, and a link a run puts there can send
    # any `..` after it elsewhere.
    test "in a path where the tree holds no file or folder, that a link points to" do
      for {files, link} <- [
            {%{"scripts/x.sh" => {:link, "../.git/HEAD"}}, "scripts/x.sh"},
            {%{"scripts/v.sh" => {:link, "../deps/foo/link/../../../scripts/build.sh"}},
             "scripts/v.sh"},
            {%{"scripts/y.sh" => {:link, "../deps/foo/run.sh"}}, "scripts/y.sh"},
            {%{"scripts/z.sh" => {:link, "../_build/gen.sh"}}, "scripts/z.sh"},
            {%{"scripts/w.sh" => {:link, "missing.sh"}}, "scripts/w.sh"},
            {%{"notes.md" => {:link, ".git/HEAD"}}, "notes.md"}
          ] do
        assert_reports(
          files,
          "#{link}: a symbolic link through or to a path where the tree holds no file or " <>
            "folder, which the scan cannot read"
        )
      end
    end

    test "in a binary file" do
      assert_reports(
        %{"priv/blob.bin" => <<0, 1>> <> @gh <> "REF"},
        "priv/blob.bin: a binary file that names a runner variable or reads the event"
      )
    end

    test "in a workflow value as YAML decodes it, which the line scan cannot see" do
      assert_reports(
        %{@ci => ci_with(~s(      - run: "echo $\\x47ITHUB_REF"\n))},
        "#{@ci}:#{appended()}: jobs.container.steps[5].run: names a runner variable or reads the event"
      )
    end
  end

  describe "a YAML form the check does not follow" do
    test "a tag, a lone ! included" do
      assert_reports(
        %{@ci => ci_with("      - run: !!str mix docs\n")},
        "#{@ci}:#{appended()}: a tag (tag:yaml.org,2002:str)"
      )

      assert_reports(
        %{@ci => ci_with("      - run: ! mix docs\n")},
        "#{@ci}:#{appended()}: a tag (!)"
      )

      assert_reports(
        %{@ci => ci_with("      - ! {run: mix docs}\n")},
        "#{@ci}:#{appended()}: a tag (!)"
      )
    end

    test "an anchor and an alias" do
      file = ci_with("      - run: &docs mix docs\n      - run: *docs\n")

      assert_reports(%{@ci => file}, [
        "#{@ci}:#{appended()}: an anchor (&docs)",
        "#{@ci}:#{appended() + 1}: an alias (*docs)"
      ])
    end

    test "a merge key" do
      assert_reports(
        %{@ci => ci_with("      - <<: {run: mix docs}\n")},
        "#{@ci}:#{appended()}: a merge key (<<), which this check does not follow"
      )
    end

    test "a directive: %YAML, %TAG or a reserved one" do
      for directive <- ["%YAML 1.2", "%TAG !e! tag:example.com,2000:", "%FOO bar"] do
        assert_reports(%{@ci => directive <> "\n---\n" <> ci()}, "#{@ci}:1: a directive")
      end
    end

    test "a symbolic link at a path the check reads as YAML, which git stores as its target's name" do
      real = "runs:\n  using: composite\n  steps:\n    - run: echo ${{ github.event_name }}\n"

      # The check reports the link alone, and reads none of its target's name as YAML.
      for link <- ["ci/act/action.yml", ".forgejo/workflows/push.yml", ".github/workflows/x.yml"] do
        {code, lines} =
          check(%{link => {:link, "../../tools/real.yaml"}, "tools/real.yaml" => real})

        assert {code, Enum.drop(lines, -1)} ==
                 {1, ["#{link}: a symbolic link, which this check does not follow"]}
      end
    end

    test "a file yamerl cannot read, an unknown tag included" do
      for text <- [ci() <> "  broken: [\n", ci_with("      - run: !custom mix docs\n")] do
        assert_reports(%{@ci => text}, "#{@ci}: not readable as YAML")
      end
    end

    test "more than one YAML document" do
      assert_reports(%{@ci => ci() <> "---\nname: other\n"}, "#{@ci}: 2 YAML documents")
    end

    test "a file that is not UTF-8" do
      assert_reports(%{@ci => ci() <> "# " <> <<0xFF>> <> "\n"}, "#{@ci}: not UTF-8 text")
    end

    test "an alias in a .github/workflows file, which can hide its trigger" do
      assert_reports(
        %{@release => edit(release(), "    tags:\n", "    tags: &tags\n") <> "x: *tags\n"},
        "#{@release}:20: an alias (*tags)"
      )
    end
  end

  test "a file name the tree holds twice" do
    {dir, _sha} = repo!(%{})
    listing = String.trim_trailing(git!(dir, ["ls-tree", "HEAD"]))
    agents = listing |> String.split("\n") |> Enum.find(&String.ends_with?(&1, "\tAGENTS.md"))

    {tree, 0} =
      System.cmd(
        "sh",
        ["-c", ~s(printf '%s\\n%s\\n' "$1" "$2" | git mktree), "sh", listing, agents],
        cd: dir
      )

    commit = git!(dir, ["commit-tree", String.trim(tree), "-m", "twice"]) |> String.trim()
    {code, lines} = PushRepeatsPr.check(commit, cd: dir)
    assert {code, "AGENTS.md: a file name the tree holds 2 times"} == {1, hd(lines)}
  end

  # `uses: ./tools/act` would run code that only the submodule's own commit holds.
  test "a submodule, whose files the check cannot read" do
    {dir, sha} = repo!(%{})
    git!(dir, ["update-index", "--add", "--cacheinfo", "160000,#{sha},tools/act"])
    git!(dir, ["commit", "-q", "-m", "submodule"])
    {code, lines} = PushRepeatsPr.check(String.trim(git!(dir, ["rev-parse", "HEAD"])), cd: dir)

    assert {code, Enum.drop(lines, -1)} ==
             {1, ["tools/act: a submodule, whose files this check cannot read"]}
  end

  # A gitlink is neither a file nor a folder of this tree, so a link to it leads where the scan
  # cannot read.
  test "a symbolic link to a submodule" do
    {dir, sha} = repo!(%{"scripts/act" => {:link, "../tools/act"}})
    git!(dir, ["update-index", "--add", "--cacheinfo", "160000,#{sha},tools/act"])
    git!(dir, ["commit", "-q", "-m", "submodule"])
    {code, lines} = PushRepeatsPr.check(String.trim(git!(dir, ["rev-parse", "HEAD"])), cd: dir)

    assert {code, Enum.drop(lines, -1)} ==
             {1,
              [
                "scripts/act: a symbolic link through or to a path where the tree holds no " <>
                  "file or folder, which the scan cannot read",
                "tools/act: a submodule, whose files this check cannot read"
              ]}
  end

  # IO cannot print bytes that are not UTF-8, and U+FFFD in their place would name the twin.
  test "main/2 prints a file name that is not UTF-8 apart from its U+FFFD twin" do
    push_only = ci_with("      - run: echo build\n        if: github.event_name == 'push'\n")
    name = ".forgejo/workflows/a" <> <<0xFF>> <> ".yml"
    twin = ".forgejo/workflows/a�.yml"
    {dir, sha} = repo!(%{name => push_only, twin => ci()})
    output = capture_io(fn -> assert PushRepeatsPr.main([sha], cd: dir) == 1 end)

    assert output =~
             ".forgejo/workflows/a\\xFF.yml:#{appended() + 1}: jobs.container.steps[5].if: " <>
               "an if: github.event_name == 'push'\n"

    refute output =~ twin
  end

  describe "an allowed text at another key" do
    test "github.ref outside the workflow-level concurrency.group" do
      for {ci, fragment} <- [
            {ci_edit(
               "  container:\n",
               "  container:\n    concurrency:\n      group: c-${{ github.ref }}\n"
             ), "jobs.container.concurrency.group: an expression: ${{ github.ref }}"},
            {ci_edit("cancel-in-progress: true", "cancel-in-progress: ${{ github.ref }}"),
             "concurrency.cancel-in-progress: an expression: ${{ github.ref }}"},
            {ci_edit(
               "concurrency:\n  group: ci-${{ github.ref }}\n  cancel-in-progress: true\n",
               "concurrency: ci-${{ github.ref }}\n"
             ), "concurrency: an expression: ${{ github.ref }}"},
            {ci_with("      - run: echo ${{ github.ref }}\n"),
             "jobs.container.steps[5].run: an expression: ${{ github.ref }}"}
          ] do
        assert_reports(%{@ci => ci}, fragment)
      end
    end

    test "a cache key expression outside a cache step's key and restore-keys" do
      for {ci, fragment} <- [
            {ci_with(
               "      - uses: some/action@v1\n        with:\n          key: ${{ runner.os }}\n"
             ), "jobs.container.steps[5].with.key: an expression: ${{ runner.os }}"},
            {ci_edit("          path: deps\n", "          path: deps-${{ runner.os }}\n"),
             "jobs.test.steps[2].with.path: an expression: ${{ runner.os }}"},
            {ci_with(
               "      - env:\n          LOCK: ${{ hashFiles('**/mix.lock') }}\n        run: env\n"
             ),
             "jobs.container.steps[5].env.LOCK: an expression: ${{ hashFiles('**/mix.lock') }}"},
            {ci_edit("-mix-${{ hashFiles('**/mix.lock') }}", "-mix-${{ github.event_name }}"),
             "jobs.test.steps[2].with.key: an expression: ${{ github.event_name }}"}
          ] do
        assert_reports(%{@ci => ci}, fragment)
      end
    end

    test "a run name outside a job's or a step's env" do
      for {ci, fragment} <- [
            {ci_edit("concurrency:\n", "env:\n  RUN: ${{ github.run_id }}\n\nconcurrency:\n"),
             "env.RUN: an expression: ${{ github.run_id }}"},
            {ci_with(
               "      - uses: some/action@v1\n        with:\n          name: r-${{ github.run_id }}\n"
             ), "jobs.container.steps[5].with.name: an expression: ${{ github.run_id }}"},
            {ci_with("      - run: echo ${{ github.run_attempt }}\n"),
             "jobs.container.steps[5].run: an expression: ${{ github.run_attempt }}"},
            {ci_edit("RUN_ATTEMPT: ${{ github.run_attempt }}", "RUN_ATTEMPT: ${{ github.sha }}"),
             "jobs.container.steps[1].env.RUN_ATTEMPT: an expression: ${{ github.sha }}"},
            {ci_edit("cinder:ci-${{ github.run_id }}", "cinder:ci-${{ github.sha }}"),
             "jobs.container.env.CINDER_IMAGE: an expression: ${{ github.sha }}"}
          ] do
        assert_reports(%{@ci => ci}, fragment)
      end
    end

    test "env.CINDER_IMAGE outside the Trivy action's image-ref" do
      for {ci, fragment} <- [
            {ci_with(
               "      - uses: some/scan-action@v1\n        with:\n          image-ref: ${{ env.CINDER_IMAGE }}\n"
             ), "jobs.container.steps[5].with.image-ref: an expression: ${{ env.CINDER_IMAGE }}"},
            {ci_edit(
               "          image-ref: ${{ env.CINDER_IMAGE }}\n",
               "          image-ref: x\n          output: ${{ env.CINDER_IMAGE }}\n"
             ), "jobs.container.steps[3].with.output: an expression: ${{ env.CINDER_IMAGE }}"}
          ] do
        assert_reports(%{@ci => ci}, fragment)
      end
    end

    test "the token and workspace forms outside the Trivy DB step, or in it beside another key" do
      token = "env -u #{@gh}TOKEN"
      workspace = "$#{@gh}WORKSPACE/.cache/trivy"

      for {ci, decoded, line} <- [
            {ci_with("      - run: #{token} trivy --version\n"), "jobs.container.steps[5].run",
             "- run: #{token}"},
            {ci_with("      - name: Scan\n        run: #{token} trivy --version\n"),
             "jobs.container.steps[5].run", "run: #{token}"},
            {ci_with("      - run: ls #{workspace}\n"), "jobs.container.steps[5].run",
             "- run: ls #{workspace}"},
            {ci_edit(
               "      - name: Download the Trivy vulnerability DB\n",
               "      - name: Download the Trivy vulnerability DB\n        shell: bash\n"
             ), "jobs.container.steps[2].run", "if #{token} timeout"}
          ] do
        assert_reports(%{@ci => ci}, [
          "#{decoded}: names a runner variable or reads the event",
          "names a runner variable or reads the event: #{line}"
        ])
      end
    end

    test "another runner name, or a longer one, in the Trivy DB step" do
      for {old, new, line} <- [
            {"          exit 1\n", "          echo $#{@gh}REF\n          exit 1\n",
             "echo $#{@gh}REF"},
            {"env -u #{@gh}TOKEN timeout", "env -u #{@gh}TOKEN_X timeout",
             "if env -u #{@gh}TOKEN_X timeout"},
            {"          exit 1\n", "          ls $#{@gh}WORKSPACE/src\n          exit 1\n",
             "ls $#{@gh}WORKSPACE/src"}
          ] do
        assert_reports(%{@ci => ci_edit(old, new)}, [
          "jobs.container.steps[2].run: names a runner variable or reads the event",
          "names a runner variable or reads the event: " <> line
        ])
      end
    end

    test "the token's forms in a Trivy DB step whose dash stands on a line of its own" do
      ci =
        ci_edit(
          "      - name: Download the Trivy vulnerability DB\n        run: |\n",
          "      -\n        name: Download the Trivy vulnerability DB\n        run: |\n"
        )

      # Every line of the step and its comment that names one, and no decoded value.
      expected =
        for {text, number} <- ci |> String.split("\n") |> Enum.with_index(1),
            text =~ @gh,
            do:
              "#{@ci}:#{number}: names a runner variable or reads the event: #{String.trim(text)}"

      {code, lines} = check(%{@ci => ci})
      assert {code, Enum.filter(lines, &(&1 =~ "names a runner variable"))} == {1, expected}
      assert length(expected) == 3
    end

    test "the token's name in a comment that is not right above the Trivy DB step at its dash's indentation" do
      comment = "      # The download unsets #{@gh}TOKEN, and writes under #{@gh}WORKSPACE.\n"

      for {ci, line} <- [
            {ci_edit(comment, "      # The download unsets #{@gh}TOKEN, and #{@gh}REF.\n"),
             "# The download unsets #{@gh}TOKEN, and #{@gh}REF."},
            {ci_edit(comment, "      # The download unsets #{@gh}TOKEN_X.\n"),
             "# The download unsets #{@gh}TOKEN_X."},
            {ci_edit(comment, "      # The download unsets X#{@gh}TOKEN.\n"),
             "# The download unsets X#{@gh}TOKEN."},
            {ci_edit(comment, "        " <> String.trim_leading(comment)), "# The download"},
            {ci_edit(comment, comment <> "\n"), "# The download"},
            {ci_with("      # Unset #{@gh}TOKEN.\n      - run: mix docs\n"),
             "# Unset #{@gh}TOKEN."}
          ] do
        assert_reports(%{@ci => ci}, "names a runner variable or reads the event: " <> line)
      end
    end

    test "the release token outside release.yml's login password, or while release.yml has another trigger" do
      password = "password: ${{ secrets.#{@gh}TOKEN }}"
      login = "      - uses: docker/login-action@v4\n        with:\n          #{password}\n"

      for {files, line} <- [
            {%{@release => edit(release(), password, "token: ${{ secrets.#{@gh}TOKEN }}")},
             "token: ${{ secrets."},
            {%{
               @release =>
                 edit(
                   release(),
                   "      - uses: docker/login-action@v4",
                   "      - uses: some/login@v4"
                 )
             }, password},
            {%{
               @release =>
                 edit(
                   release(),
                   "    tags:\n      - \"v*.*.*\"\n",
                   "    tags: [v*]\n  workflow_dispatch:\n"
                 )
             }, password},
            {%{
               ".github/workflows/publish.yml" =>
                 "on:\n  push:\n    tags: [v*]\njobs:\n  p:\n    steps:\n" <> login
             }, password},
            {%{@ci => ci_with(login)}, password}
          ] do
        assert_reports(files, "names a runner variable or reads the event: " <> line)
      end
    end
  end

  describe "exit 2" do
    test "an unknown SHA" do
      {dir, _sha} = repo!(%{})

      assert PushRepeatsPr.check("0123456789abcdef", cd: dir) ==
               {2, ["check-push-repeats-pr: unknown commit: 0123456789abcdef"]}
    end

    test "outside a git repo" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "cinder-push-repeats-pr-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      assert {2, [line]} = PushRepeatsPr.check("HEAD", cd: dir)
      assert line =~ "check-push-repeats-pr: git rev-parse --show-toplevel failed (exit 128)"
    end

    test "a YAML reader that does not start" do
      {dir, sha} = repo!(%{})

      assert {2, ["check-push-repeats-pr: cannot start no_such_reader, the YAML reader: " <> _]} =
               PushRepeatsPr.check(sha, cd: dir, yaml_app: :no_such_reader)
    end

    test "a check that raises" do
      assert {2, ["check-push-repeats-pr: the check raised: " <> _]} =
               PushRepeatsPr.check("HEAD", cd: :not_a_path)
    end
  end
end

defmodule Cinder.PushRepeatsPrEnvTest do
  # The cases that set a GIT_ variable or capture stderr, both global to the VM.
  use ExUnit.Case, async: false

  import Cinder.PushRepeatsPrTest.Fixtures
  import ExUnit.CaptureIO

  alias Cinder.PushRepeatsPr

  setup do
    on_exit(fn ->
      System.delete_env("GIT_DIR")
      System.delete_env("GIT_ICASE_PATHSPECS")
    end)
  end

  test "a GIT_DIR that names another repo" do
    {dir, sha} = repo!(%{})
    {other, _other_sha} = repo!(%{})
    System.put_env("GIT_DIR", Path.join(other, ".git"))
    assert {0, [_summary]} = PushRepeatsPr.check(sha, cd: dir)
  end

  test "GIT_ICASE_PATHSPECS, which would skip a .MD file with the Markdown" do
    {dir, sha} = repo!(%{"README.MD" => "Read $#{gh()}REF.\n"})
    System.put_env("GIT_ICASE_PATHSPECS", "1")
    {code, lines} = PushRepeatsPr.check(sha, cd: dir)

    assert {code, hd(lines)} ==
             {1, "README.MD:1: names a runner variable or reads the event: Read $#{gh()}REF."}
  end

  test "main/2 prints the summary and returns the exit code" do
    {dir, sha} = repo!(%{})
    output = capture_io(fn -> assert PushRepeatsPr.main([sha], cd: dir) == 0 end)
    assert output =~ ~r/\Acheck-push-repeats-pr: \w{8}: the push run repeats the PR run .*\n\z/
  end

  test "main/2 prints the usage on stderr and returns 2 without exactly one argument" do
    for argv <- [[], ["a", "b"]] do
      stderr = capture_io(:stderr, fn -> assert PushRepeatsPr.main(argv) == 2 end)
      assert stderr =~ "usage: MIX_ENV=test mix run --no-start scripts/check-push-repeats-pr.exs"
    end
  end
end
