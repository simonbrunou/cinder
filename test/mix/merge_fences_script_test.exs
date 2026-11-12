defmodule Cinder.MergeFencesScriptTest do
  # Runs `scripts/merge-fences` on fixture repos, with stubs for `nix`, `mix` and the fixture's
  # own committed `scripts/seed-worktree`, so each selection rule and each exit path stays covered
  # without a nested `mix test` run (#1153). The stubs log each call to $FENCE_LOG. The `mix` stub
  # logs its arguments, MIX_ENV, and which side files the tree it runs in holds, so a case can
  # tell it ran on the merge. It fails two tests of its first file when the tree holds FAIL_FENCE,
  # fails before any test (as a gate does) when it holds GATE_FENCE, fails nine tests of its first
  # file, one of its second (numbered ` 10)`) and a setup_all when it holds MANY_FENCE, fails only
  # two setup_all callbacks (numbered `  0)`) when it holds SETUP_FENCE, fails one
  # test with 20000
  # lines of output when it holds BIG_FENCE, and sleeps when it holds
  # SLEEP_FENCE, ignoring SIGINT as the BEAM does, after writing its pid to $FENCE_STARTED. PATH
  # holds only the stubs and links to the tools the script calls, so the real `mix` and `nix` are
  # never found.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("scripts/merge-fences")

  @tools ~w(bash env git sed sort mktemp rm grep cut tail head wc cp sleep touch seq cat ls)

  # Built from parts so this file does not hold the text it stands for, and so is no fence.
  @lib_ref ~s("lib) <> "/"

  @mix_stub """
  #!/usr/bin/env bash
  echo "mix $* MIX_ENV=${MIX_ENV:-} sides=$(ls -d side_* 2>/dev/null | tr '\\n' ' ')" >> "$FENCE_LOG"
  if [[ -e SLEEP_FENCE ]]; then trap '' INT; echo $$ > "$FENCE_STARTED"; sleep 30; fi
  if [[ -e FAIL_FENCE ]]; then
    printf 'debug noise\\n  1) test the fence (Fence)\\n     %s:3\\n     lib/a.ex:3\\n' "$2"
    printf '  2) test the fence again (Fence)\\n     %s:9\\nResult: 1/3 passed\\n' "$2"
    exit 2
  fi
  if [[ -e GATE_FENCE ]]; then echo "** (Mix) the gate failed"; exit 1; fi
  if [[ -e MANY_FENCE ]]; then
    for i in $(seq 1 9); do printf '  %s) test fence %s (Fence)\\n     %s:%s\\n' $i $i "$2" $i; done
    printf ' 10) test fence 10 (Fence)\\n     %s:10\\n' "$3"
    printf ' 11) Cinder.SetupTest: failure on setup_all callback, all tests have been invalidated\\n'
    printf '     ** (RuntimeError) oops\\nResult: 0/10 passed, 1 invalid\\n'
    exit 2
  fi
  if [[ -e SETUP_FENCE ]]; then
    printf 'debug noise\\n  0) Cinder.SetupTest: failure on setup_all callback, all tests have been invalidated\\n'
    printf '     ** (RuntimeError) oops\\n'
    printf '  0) :"Odd.Mod Test": failure on setup_all callback, all tests have been invalidated\\n'
    printf '     ** (RuntimeError) oops\\nResult: 0 tests, 2 invalid\\n'
    exit 2
  fi
  if [[ -e BIG_FENCE ]]; then
    printf '  1) test the fence (Fence)\\n     %s:3\\n' "$2"
    for i in $(seq 1 20000); do echo "     failure detail line $i"; done
    exit 2
  fi
  echo "Result: 1 passed"
  """

  @nix_stub """
  #!/usr/bin/env bash
  echo "nix $1 $2 $3" >> "$FENCE_LOG"
  [[ $1 == develop && $3 == -c ]] || exit 9
  shift 3
  exec "$@"
  """

  @seed_stub """
  #!/usr/bin/env bash
  echo "seed $(basename "$PWD")" >> "$FENCE_LOG"
  if [[ -e SEED_FAIL ]]; then echo "seed broke"; exit 1; fi
  """

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    stub!(bin, "mix", @mix_stub)
    stub!(bin, "nix", @nix_stub)

    for tool <- @tools ++ ["tr", "basename"],
        do: File.ln_s!(System.find_executable(tool), Path.join(bin, tool))

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])

    write!(repo, %{
      "scripts/seed-worktree" => @seed_stub,
      "test/code_health_test.exs" => "# health\n",
      "test/code_health/old_test.exs" => "# old fence\n",
      "test/code_health/other_test.exs" => "# other fence\n",
      "test/cinder/scan_test.exs" => "# scans #{@lib_ref}\n",
      "test/cinder/plain_test.exs" => "# plain\n",
      "app/a.ex" => "a\n"
    })

    File.chmod!(Path.join(repo, "scripts/seed-worktree"), 0o755)
    commit!(repo, "base")
    git!(repo, ["branch", "pr"])

    temp = Path.join(dir, "var")
    File.mkdir_p!(temp)
    shell_tmp = Path.join(dir, "nix-shell")
    File.mkdir_p!(shell_tmp)

    %{
      dir: dir,
      bin: bin,
      repo: repo,
      temp: temp,
      shell_tmp: shell_tmp,
      log: Path.join(dir, "fence.log")
    }
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp write!(repo, files) do
    for {path, body} <- files do
      full = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end
  end

  defp git!(repo, args) do
    env = for k <- ~w(AUTHOR COMMITTER), f <- ~w(NAME EMAIL), do: {"GIT_#{k}_#{f}", "t"}

    {out, 0} =
      System.cmd("git", args, cd: repo, env: [{"HOME", repo} | env], stderr_to_stdout: true)

    String.trim(out)
  end

  defp commit!(repo, message) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "--allow-empty", "-m", message])
  end

  # Commits on one side: `files` to write, `deletes` to remove, and a side_<name> file that the
  # mix stub reports, so a case sees both sides in the tree it ran on.
  defp side!(repo, branch, files, deletes \\ []) do
    git!(repo, ["checkout", "-q", branch])
    write!(repo, Map.put(files, "side_#{branch}", branch))
    Enum.each(deletes, &File.rm!(Path.join(repo, &1)))
    commit!(repo, branch)
  end

  defp env(ctx, extra) do
    [
      {"PATH", ctx.bin},
      {"FENCE_LOG", ctx.log},
      {"FENCE_STARTED", Path.join(ctx.dir, "started")},
      {"MERGE_FENCES_TMPDIR", ctx.temp},
      # The dev shell's TMPDIR, on the shared /tmp tmpfs: the script never writes there.
      {"TMPDIR", ctx.shell_tmp},
      {"HOME", ctx.dir},
      {"IN_NIX_SHELL", nil},
      {"MIX_TAILWIND_PATH", nil},
      {"MIX_ENV", "dev"},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_BUILD_PATH", nil},
      {"MIX_DEPS_PATH", nil}
    ] ++ extra
  end

  defp run(ctx, extra \\ []) do
    head = git!(ctx.repo, ["rev-parse", "pr"])
    base = git!(ctx.repo, ["rev-parse", "main"])

    # An Erlang port unsets a variable given as "", so an empty one goes through env(1).
    {empty, set} = Enum.split_with(extra, &match?({_, ""}, &1))
    assigns = for {name, ""} <- empty, do: name <> "="

    System.cmd("env", assigns ++ ["bash", @script, head, base],
      cd: ctx.repo,
      env: env(ctx, set),
      stderr_to_stdout: true
    )
  end

  defp log(ctx) do
    case File.read(ctx.log) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp mix_calls(ctx), do: Enum.filter(log(ctx), &String.starts_with?(&1, "mix "))

  defp assert_no_worktree(ctx) do
    assert git!(ctx.repo, ["worktree", "list"]) |> String.split("\n") |> length() == 1
    assert File.ls!(ctx.temp) |> Enum.reject(&String.ends_with?(&1, ".log")) == []
    assert File.ls!(ctx.shell_tmp) == []
  end

  test "selects a fence file the PR side adds and runs it on the merge, through nix", ctx do
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new fence\n"})
    side!(ctx.repo, "main", %{"app/a.ex" => "b\n"})

    {out, code} = run(ctx)

    assert code == 0, out
    assert out =~ "fences: passed on the merge of "
    assert out =~ ": test/code_health/new_test.exs\n"
    assert ["nix develop " <> nix_seed, "seed merge", "nix develop " <> _, mix] = log(ctx)
    assert nix_seed == "#{ctx.repo} -c"
    assert mix == "mix test test/code_health/new_test.exs MIX_ENV= sides=side_main side_pr "
    assert_no_worktree(ctx)
  end

  test "selects test/code_health_test.exs when the main side changed it since the merge-base",
       ctx do
    side!(ctx.repo, "pr", %{"app/a.ex" => "b\n"})
    side!(ctx.repo, "main", %{"test/code_health_test.exs" => "# health, changed\n"})

    {out, code} = run(ctx)

    assert code == 0, out
    assert ["mix test test/code_health_test.exs " <> _] = mix_calls(ctx)
  end

  test "selects a test file outside test/code_health that names lib/, and not one that does not",
       ctx do
    side!(ctx.repo, "pr", %{
      "test/cinder/scan_test.exs" => "# scans #{@lib_ref} still\n",
      "test/cinder/plain_test.exs" => "# plain, changed\n"
    })

    side!(ctx.repo, "main", %{"test/cinder/new_scan_test.exs" => "x = #{@lib_ref}\n"})

    {out, code} = run(ctx)

    assert code == 0, out

    assert ["mix test test/cinder/new_scan_test.exs test/cinder/scan_test.exs " <> _] =
             mix_calls(ctx)
  end

  test "selects no fence file that either side deleted", ctx do
    side!(ctx.repo, "pr", %{"app/a.ex" => "b\n"}, ["test/code_health/old_test.exs"])

    side!(ctx.repo, "main", %{"test/code_health_test.exs" => "# changed\n"}, [
      "test/code_health/other_test.exs",
      "test/cinder/scan_test.exs"
    ])

    {out, code} = run(ctx)

    assert code == 0, out
    assert ["mix test test/code_health_test.exs " <> _] = mix_calls(ctx)
  end

  test "prints a selected file it cannot run as a test, and runs nothing when no test is left",
       ctx do
    side!(ctx.repo, "pr", %{"test/code_health/helper.ex" => "# helper\n"})
    side!(ctx.repo, "main", %{"app/a.ex" => "b\n"})

    {out, code} = run(ctx)

    assert code == 0, out
    assert out =~ "fences: not run, not test files: test/code_health/helper.ex\n"
    assert out =~ "fences: none changed on either side of the merge of "
    assert log(ctx) == []
  end

  test "skips the check when the head already contains the base", ctx do
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new fence\n"})

    {out, code} = run(ctx)

    assert code == 0, out
    assert out =~ ~r/^fences: skipped, \w+ already contains \w+/
    assert log(ctx) == []
  end

  test "stops with FAIL: naming the failing files when the fences fail on the merge", ctx do
    side!(ctx.repo, "pr", %{
      "test/code_health/new_test.exs" => "# new\n",
      "test/code_health/second_test.exs" => "# second\n"
    })

    side!(ctx.repo, "main", %{"FAIL_FENCE" => "x"})

    {out, code} = run(ctx)

    assert code == 1, out
    refute out =~ "debug noise"

    assert out =~
             "  1) test the fence (Fence)\n     test/code_health/new_test.exs:3\n" <>
               "     lib/a.ex:3\n  2) test the fence again (Fence)\n" <>
               "     test/code_health/new_test.exs:9\nResult: 1/3 passed\n"

    assert out =~
             ~r"FAIL: the fences fail on the merge of \w+ with \w+: test/code_health/new_test.exs \(out"

    assert out =~
             "fix what each failure names, run mix test, push with " <>
               "git push origin HEAD:<branch>, and wait for CI."

    [kept] = File.ls!(ctx.temp)
    assert out =~ Path.join(ctx.temp, kept)
    assert_no_worktree(ctx)
  end

  test "names each failing file and setup_all module, from failure 10 on too", ctx do
    side!(ctx.repo, "pr", %{
      "test/code_health/new_test.exs" => "# new\n",
      "test/code_health/second_test.exs" => "# second\n"
    })

    side!(ctx.repo, "main", %{"MANY_FENCE" => "x"})

    {out, code} = run(ctx)

    assert code == 1, out

    named =
      "test/code_health/new_test.exs test/code_health/second_test.exs; " <>
        "setup_all in Cinder.SetupTest (output above"

    assert out =~ ~r"FAIL: the fences fail on the merge of \w+ with \w+: #{Regex.escape(named)}"
  end

  test "names the setup_all modules when only setup_all failed, from the `  0)` line on", ctx do
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
    side!(ctx.repo, "main", %{"SETUP_FENCE" => "x"})

    {out, code} = run(ctx)

    assert code == 1, out
    refute out =~ "debug noise"
    assert out =~ "\n  0) Cinder.SetupTest: failure on setup_all callback"
    named = ~s(: setup_all in Cinder.SetupTest :"Odd.Mod Test" \(output above)
    assert out =~ ~r"FAIL: the fences fail on the merge of \w+ with \w+#{Regex.escape(named)}"
  end

  test "prints 200 lines of a long failure and still ends on its FAIL: line", ctx do
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
    side!(ctx.repo, "main", %{"BIG_FENCE" => "x"})

    {out, code} = run(ctx)

    assert code == 1, String.slice(out, -2000, 2000)
    assert out =~ "     failure detail line 198\n"
    refute out =~ "     failure detail line 199\n"

    assert out =~
             ~r"FAIL: the fences fail on the merge of \w+ with \w+: test/code_health/new_test"

    assert_no_worktree(ctx)
  end

  test "stops with FAIL: saying no test failed by name when a gate fails on the merge", ctx do
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
    side!(ctx.repo, "main", %{"GATE_FENCE" => "x"})

    {out, code} = run(ctx)

    assert code == 1, out
    assert out =~ "** (Mix) the gate failed\n"

    assert out =~
             ~r"FAIL: mix test test/code_health/new_test.exs fails on the merge of \w+ with \w+ before"

    assert out =~ "fix what the output names, run mix test"
    assert_no_worktree(ctx)
  end

  test "stops with FAIL: when the seed fails, and runs no fence", ctx do
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
    side!(ctx.repo, "main", %{"SEED_FAIL" => "x"})

    {out, code} = run(ctx)

    assert code == 1, out
    assert out =~ "seed broke"
    assert out =~ "FAIL: seeding the merge worktree failed"
    assert mix_calls(ctx) == []
    assert_no_worktree(ctx)
  end

  test "stops with FAIL: when there is no nix and no dev shell", ctx do
    File.rm!(Path.join(ctx.bin, "nix"))
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
    side!(ctx.repo, "main", %{"app/a.ex" => "b\n"})

    {out, code} = run(ctx)

    assert code == 1, out
    assert out =~ "FAIL: no nix on PATH"
    assert log(ctx) == []
    assert_no_worktree(ctx)
  end

  test "runs seed and mix without nix inside the flake's dev shell", ctx do
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
    side!(ctx.repo, "main", %{"app/a.ex" => "b\n"})

    {out, code} =
      run(ctx, [{"IN_NIX_SHELL", "impure"}, {"MIX_TAILWIND_PATH", "/nix/store/x/tailwindcss"}])

    assert code == 0, out
    assert ["seed merge", "mix test test/code_health/new_test.exs " <> _] = log(ctx)
  end

  for {state, value} <- [unset: nil, empty: ""] do
    test "puts its worktree under /var/tmp when MERGE_FENCES_TMPDIR is #{state}, never TMPDIR",
         ctx do
      side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
      side!(ctx.repo, "main", %{"app/a.ex" => "b\n"})
      # Logs the template the script asks for, and makes the directory in the test's temp dir.
      File.rm!(Path.join(ctx.bin, "mktemp"))

      stub!(ctx.bin, "mktemp", """
      #!/usr/bin/env bash
      echo "mktemp $*" >> "$FENCE_LOG"
      exec #{System.find_executable("mktemp")} -d "$FENCE_TEMP/cinder-merge-fences.XXXXXX"
      """)

      {out, code} =
        run(ctx, [{"MERGE_FENCES_TMPDIR", unquote(value)}, {"FENCE_TEMP", ctx.temp}])

      assert code == 0, out
      assert ["mktemp -d /var/tmp/cinder-merge-fences.XXXXXX" | _] = log(ctx)
      assert_no_worktree(ctx)
    end
  end

  test "stops with FAIL: on a merge with a conflict", ctx do
    side!(ctx.repo, "pr", %{"app/a.ex" => "pr\n"})
    side!(ctx.repo, "main", %{"app/a.ex" => "main\n"})

    {out, code} = run(ctx)

    assert code == 1, out
    assert out =~ "(1 is a conflict)"
    assert log(ctx) == []
  end

  # Swaps the linked git for a wrapper that fails each call whose arguments contain `broken`.
  defp break_git!(ctx, broken) do
    real = System.find_executable("git")
    git = Path.join(ctx.bin, "git")
    File.rm!(git)

    stub!(ctx.bin, "git", """
    #!/usr/bin/env bash
    if [[ "$*" == *"#{broken}"* ]]; then echo "git $* broke" >&2; exit 128; fi
    exec #{real} "$@"
    """)
  end

  for call <- [:head_side_diff, :base_side_diff, :grep] do
    test "stops with FAIL: when #{call} fails while it selects the fences", ctx do
      side!(ctx.repo, "pr", %{"test/cinder/scan_test.exs" => "# scans #{@lib_ref} more\n"})
      side!(ctx.repo, "main", %{"app/a.ex" => "b\n"})
      [head, base] = for b <- ~w(pr main), do: git!(ctx.repo, ["rev-parse", b])
      [h, b] = for sha <- [head, base], do: git!(ctx.repo, ["rev-parse", "--short", sha])

      {broken, message} =
        case unquote(call) do
          :head_side_diff -> {"#{base}...#{head}", "FAIL: git diff #{b}...#{h} failed"}
          :base_side_diff -> {"#{head}...#{base}", "FAIL: git diff #{h}...#{b} failed"}
          :grep -> {"grep", "FAIL: git grep on test/cinder/scan_test.exs in the merged tree"}
        end

      break_git!(ctx, broken)

      {out, code} = run(ctx)

      assert code == 1, out
      assert out =~ message
      assert log(ctx) == []
    end
  end

  test "keeps the worktree and names it when git cannot remove it", ctx do
    side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
    side!(ctx.repo, "main", %{"app/a.ex" => "b\n"})
    break_git!(ctx, "worktree remove")

    {out, code} = run(ctx)

    assert code == 0, out
    assert [_] = mix_calls(ctx)
    [left] = File.ls!(ctx.temp)
    wt = Path.join([ctx.temp, left, "merge"])
    assert out =~ "WARNING: could not remove the worktree #{wt}; remove it with: "
    assert File.dir?(wt)
  end

  test "exits 2 on wrong arguments and 1 on a SHA that is no commit", ctx do
    assert {_, 2} =
             System.cmd("bash", [@script, "x"],
               cd: ctx.repo,
               env: env(ctx, []),
               stderr_to_stdout: true
             )

    {out, 1} =
      System.cmd("bash", [@script, "nope", "main"],
        cd: ctx.repo,
        env: env(ctx, []),
        stderr_to_stdout: true
      )

    assert out =~ "FAIL: nope is not a commit"
  end

  for {signal, code} <- [{"INT", 130}, {"TERM", 143}] do
    test "removes the worktree when SIG#{signal} reaches its process group mid-run", ctx do
      side!(ctx.repo, "pr", %{"test/code_health/new_test.exs" => "# new\n"})
      side!(ctx.repo, "main", %{"SLEEP_FENCE" => "x"})
      head = git!(ctx.repo, ["rev-parse", "pr"])
      base = git!(ctx.repo, ["rev-parse", "main"])

      # Job control gives the script its own process group, which the signal reaches whole, as a
      # terminal's Ctrl-C does.
      driver = """
      set -m
      bash "$0" "$1" "$2" > "$FENCE_OUT" 2>&1 &
      pid=$!
      for i in $(seq 1 300); do [[ -e $FENCE_STARTED ]] && break; sleep 0.1; done
      [[ -e $FENCE_STARTED ]] || { echo "never started"; exit 3; }
      git worktree list | wc -l
      start=$SECONDS
      kill -#{unquote(signal)} -- "-$pid"
      wait "$pid"
      echo "exit $? after $((SECONDS - start)) s"
      if kill -0 "$(cat "$FENCE_STARTED")" 2>/dev/null; then echo "the step still runs"; fi
      """

      out_file = Path.join(ctx.dir, "out")

      {out, 0} =
        System.cmd("bash", ["-c", driver, @script, head, base],
          cd: ctx.repo,
          env: env(ctx, [{"FENCE_OUT", out_file}]),
          stderr_to_stdout: true
        )

      found = Regex.run(~r/^\s*2\nexit #{unquote(code)} after (\d+) s\n$/, out)
      assert match?([_, _], found), out <> File.read!(out_file)
      [_, seconds] = found

      # The stub sleeps 30 s, so a step left running would hold the script that long.
      assert String.to_integer(seconds) < 10
      assert_no_worktree(ctx)
    end
  end
end
