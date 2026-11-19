defmodule Cinder.PrePushHookTest do
  # Runs `.githooks/pre-push` against a stub `mix` on PATH, and runs `scripts/seed-worktree` in a
  # fixture repo with a linked worktree, then pushes from it to a bare remote, so each exit path of
  # the hook and of the runner the seed writes stays covered without a real `mix format` or Credo
  # run. The stub logs its arguments to $HOOK_LOG and fails the task named in $HOOK_FAIL.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @hook Path.expand(".githooks/pre-push")
  @seed Path.expand("scripts/seed-worktree")

  @stub """
  #!/usr/bin/env bash
  echo "$*" >> "$HOOK_LOG"
  case "$1 ${HOOK_FAIL:-}" in
    "format "*format*) printf 'The following files are not formatted:\\n  * lib/bad.ex\\n'; exit 1 ;;
    "credo "*credo*) printf 'lib/long.ex:2:121 Line is too long\\n'; exit 1 ;;
  esac
  """

  @marker "# Cinder's pre-push runner, written by scripts/seed-worktree."

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "mix"), @stub)
    File.chmod!(Path.join(bin, "mix"), 0o755)
    File.ln_s!(System.find_executable("bash"), Path.join(bin, "bash"))
    %{dir: dir, bin: bin, log: Path.join(dir, "hook.log")}
  end

  defp hook(ctx, path, fail \\ "") do
    env = [{"PATH", path}, {"HOOK_LOG", ctx.log}, {"HOOK_FAIL", fail}]

    System.cmd(System.find_executable("bash"), [@hook],
      cd: ctx.dir,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp mix_calls(ctx) do
    case File.read(ctx.log) do
      {:ok, log} -> String.split(log, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  describe ".githooks/pre-push" do
    test "exits 0 after both gates pass", ctx do
      assert {_out, 0} = hook(ctx, ctx.bin)
      assert mix_calls(ctx) == ["format --check-formatted", "credo --strict"]
    end

    test "fails on a format failure, names the file, and still runs Credo", ctx do
      {out, code} = hook(ctx, ctx.bin, "format")

      assert code == 1, out
      assert out =~ "* lib/bad.ex"
      assert out =~ "pre-push: mix format --check-formatted failed (output above)"
      assert mix_calls(ctx) == ["format --check-formatted", "credo --strict"]
    end

    test "fails on a Credo failure", ctx do
      {out, code} = hook(ctx, ctx.bin, "credo")

      assert code == 1, out
      assert out =~ "lib/long.ex:2:121 Line is too long"
      assert out =~ "pre-push: mix credo --strict failed (output above)"
    end

    test "names both gates when both fail", ctx do
      {out, code} = hook(ctx, ctx.bin, "format credo")

      assert code == 1, out
      assert out =~ "pre-push: mix format --check-formatted and mix credo --strict failed"
    end

    test "exits 0 with one skip line when no mix is on PATH", ctx do
      only_bash = Path.join(ctx.dir, "only_bash")
      File.mkdir_p!(only_bash)
      File.ln_s!(System.find_executable("bash"), Path.join(only_bash, "bash"))

      {out, code} = hook(ctx, only_bash)

      assert code == 0, out

      assert out ==
               "pre-push: mix is not on PATH; skipped mix format --check-formatted and " <>
                 "mix credo --strict\n"

      assert mix_calls(ctx) == []
    end
  end

  # A main checkout `main` holding the hook, with the deps/ and _build/test/lib the seed checks
  # for, a linked worktree `wt` on branch `topic`, and a bare remote. GIT_CONFIG_GLOBAL and
  # GIT_CONFIG_NOSYSTEM keep the host's git config out of the runs.
  defp repo!(ctx) do
    main = Path.join(ctx.dir, "main")
    wt = Path.join(ctx.dir, "wt")
    remote = Path.join(ctx.dir, "remote.git")
    File.mkdir_p!(Path.join(main, ".githooks"))
    File.cp!(@hook, Path.join(main, ".githooks/pre-push"))
    File.chmod!(Path.join(main, ".githooks/pre-push"), 0o755)
    git!(ctx, ctx.dir, ["init", "-q", "--bare", remote])
    git!(ctx, main, ["init", "-q", "-b", "main"])
    git!(ctx, main, ["add", "-A"])
    git!(ctx, main, ["commit", "-q", "-m", "base"])
    git!(ctx, main, ["remote", "add", "origin", remote])
    git!(ctx, main, ["worktree", "add", "-q", "-b", "topic", wt])
    File.mkdir_p!(Path.join(main, "deps"))
    File.mkdir_p!(Path.join(main, "_build/test/lib"))
    %{main: main, wt: wt, remote: remote, hook_file: Path.join(main, ".git/hooks/pre-push")}
  end

  defp env(ctx, fail) do
    names = for k <- ~w(AUTHOR COMMITTER), f <- ~w(NAME EMAIL), do: {"GIT_#{k}_#{f}", "t"}

    [
      {"HOME", ctx.dir},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
      {"HOOK_LOG", ctx.log},
      {"HOOK_FAIL", fail}
      | names
    ]
  end

  defp git!(ctx, cwd, args) do
    {out, 0} = git(ctx, cwd, args)
    out
  end

  defp git(ctx, cwd, args, fail \\ "") do
    System.cmd("git", args, cd: cwd, env: env(ctx, fail), stderr_to_stdout: true)
  end

  defp seed(ctx, repo) do
    System.cmd(System.find_executable("bash"), [@seed],
      cd: repo.wt,
      env: env(ctx, ""),
      stderr_to_stdout: true
    )
  end

  describe "scripts/seed-worktree's pre-push runner" do
    test "goes in the shared hooks folder, and a push from a worktree runs its hook", ctx do
      repo = repo!(ctx)
      assert {out, 0} = seed(ctx, repo)

      assert File.read!(repo.hook_file) =~ @marker, out
      File.rm!(ctx.log)

      {out, code} =
        git(ctx, Path.join(repo.wt, ".githooks"), ["push", "origin", "topic"], "credo")

      assert code == 1, out
      assert out =~ "pre-push: mix credo --strict failed"
      assert mix_calls(ctx) == ["format --check-formatted", "credo --strict"]
      assert git!(ctx, repo.remote, ["branch"]) == ""

      assert {_out, 0} = git(ctx, repo.wt, ["push", "origin", "topic"])
      assert git!(ctx, repo.remote, ["branch"]) =~ "topic"
    end

    test "runs the hook of the checkout that pushes, not the main checkout's", ctx do
      repo = repo!(ctx)
      assert {_out, 0} = seed(ctx, repo)

      File.write!(
        Path.join(repo.wt, ".githooks/pre-push"),
        "#!/bin/sh\necho hook of wt\nexit 3\n"
      )

      {out, code} = git(ctx, repo.wt, ["push", "origin", "topic"])

      assert code != 0, out
      assert out =~ "hook of wt"
    end

    test "lets a push from a checkout without .githooks/pre-push go on unchecked", ctx do
      repo = repo!(ctx)
      assert {_out, 0} = seed(ctx, repo)
      git!(ctx, repo.wt, ["rm", "-q", ".githooks/pre-push"])
      git!(ctx, repo.wt, ["commit", "-q", "-m", "drop the hook"])
      File.rm!(ctx.log)

      assert {_out, 0} = git(ctx, repo.wt, ["push", "origin", "topic"], "format credo")
      assert mix_calls(ctx) == []
    end

    test "fails a push from a checkout whose hook lost its exec bit", ctx do
      repo = repo!(ctx)
      assert {_out, 0} = seed(ctx, repo)
      File.chmod!(Path.join(repo.wt, ".githooks/pre-push"), 0o644)

      {out, code} = git(ctx, repo.wt, ["push", "origin", "topic"])

      assert code != 0, out
      assert out =~ "Permission denied"
      assert git!(ctx, repo.remote, ["branch"]) == ""
    end

    test "rewrites its own runner", ctx do
      repo = repo!(ctx)
      File.write!(repo.hook_file, "#!/bin/sh\n#{@marker}\nexit 7\n")

      assert {_out, 0} = seed(ctx, repo)
      assert File.read!(repo.hook_file) =~ "exec .githooks/pre-push"
    end

    test "keeps a pre-push hook that is not its runner, with a WARNING line", ctx do
      repo = repo!(ctx)
      File.write!(repo.hook_file, "#!/bin/sh\nexit 0\n")

      assert {out, 0} = seed(ctx, repo)
      assert File.read!(repo.hook_file) == "#!/bin/sh\nexit 0\n"
      assert out =~ "WARNING: kept #{repo.hook_file}, which is not Cinder's runner"
    end

    test "writes no runner while core.hooksPath is set, with a WARNING line", ctx do
      repo = repo!(ctx)
      git!(ctx, repo.main, ["config", "core.hooksPath", ".githooks"])

      assert {out, 0} = seed(ctx, repo)
      assert out =~ "WARNING: core.hooksPath is set (.githooks); wrote no pre-push runner"
      refute File.exists?(repo.hook_file)
      assert File.read!(Path.join(repo.wt, ".githooks/pre-push")) == File.read!(@hook)
    end
  end
end
