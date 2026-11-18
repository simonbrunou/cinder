defmodule Cinder.MutationCheckScriptTest do
  # Runs `scripts/mutation-check` against a stub `mix` on PATH, so each verdict and exit path
  # stays covered without a nested `mix test` run. The stub logs each call and reads the target
  # file: a marker word in it picks the output a real run would print. The unchanged target holds
  # no marker, so the control run passes unless a case puts one there. PATH holds only the stub
  # and links to the tools the stub and the shell cases call, so the real `mix` is never found.
  use ExUnit.Case, async: true

  @tools ~w(bash cat cp rm mkdir sleep seq python3)

  @script Path.expand("scripts/mutation-check")

  @stub """
  #!/usr/bin/env bash
  echo call >> "$MUT_LOG"
  body=$(cat "$MUT_TARGET")
  case "$body" in
    *SLEEP*) cp "$MUT_TARGET" "$MUT_SEEN"; exec sleep 30 ;;
    *SYNTAX*) printf 'noise\\n** (SyntaxError) invalid syntax\\n'; exit 1 ;;
    *ZERO*) printf '\\nResult: 0 tests, 4 excluded\\n'; exit 1 ;;
    *NONE*) printf '\\nResult: 0 tests\\n' ;;
    *PASSEXIT1*) printf '\\nResult: 2 passed\\n'; exit 1 ;;
    *VANISH*) rm "$0"; printf '\\nResult: 2 passed\\n' ;;
    *SWAPDIR*) rm "$MUT_TARGET"; mkdir "$MUT_TARGET"; printf '\\nResult: 2 passed\\n' ;;
    *CTRLSWAP*) rm "$MUT_TARGET"; mkdir "$MUT_TARGET"; printf '\\nResult: 1/2 passed\\n'; exit 2 ;;
    *INVALID*)
      printf '\\n  1) Cinder.XTest: failure on setup_all callback, all tests have been invalidated'
      printf '\\nResult: 1 passed, 2 invalid\\n'
      exit 2 ;;
    *COMPILE*)
      printf 'noise\\n'
      for i in $(seq 6); do printf '    error: e%s\\n' "$i"; done
      printf '** (CompileError) x\\n'; exit 1 ;;
    *TAIL*) for i in $(seq 7); do printf 'l%s\\n\\n' "$i"; done; exit 1 ;;
    *BROKEN*) printf '\\n  1) test x (Cinder.XTest)\\nResult: 1/2 passed\\nFailed: 1 test\\n'; exit 2 ;;
    *MATCHFAIL*)
      cat <<'OUT'
         indented output before any failure

    1) test t (Cinder.XTest)
       test/my dir/x_test.exs:4
       match (=) failed
       code:  assert {:ok, _} = call()
       left:  {:ok, _}
       right: {:error, :timeout}
       stacktrace:
         test/x_test.exs:5: (test)

  Result: 1/2 passed
  OUT
      exit 2 ;;
    *LTFAIL*)
      cat <<'OUT'

    1) test t (Cinder.XTest)
       Parameters: %{input: 1}
       test/x_test.exs:4
       Assertion with < failed
       code:  assert elapsed < 30_000
       left:  41_000
       right: 30_000
       stacktrace:
         test/x_test.exs:7: (test)

    2) test u (Cinder.XTest)
       test/x_test.exs:9
       Assertion with == failed
       code:  assert Enum.map(
                [1, 2, 3],
                fn n -> not is_integer(n) end
              ) == [true, true, true]
       left:  [false, false, false]
       right: [true, true, true]

    3) test v (Cinder.XTest)
       test/x_test.exs:12
       Assertion failed, no matching message after 10ms
       Showing 1 of 1 message in the mailbox
       code: assert_receive {:response, %{code: 200}}
       mailbox:
         pattern: {:response, %{code: 200}}
         value:   {:response,
                   %{
                     code: 404,
                     body: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                   }}

    4) test w (Cinder.XTest)
       test/x_test.exs:15
       ** (MatchError) no match of right hand side value:

           %{
             code: 404,
             body: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
           }

       code: %{code: 200} = v
       stacktrace:
         test/x_test.exs:17: (test)

    5) test x (Cinder.XTest)
       test/x_test.exs:25

       Failure #1
       Assertion with > failed
       code:  assert number > 2
       left:  1
       right: 2
       stacktrace:
         test/x_test.exs:29: anonymous fn/1 in Cinder.XTest."test x"/1

       Failure #2
       Assertion with > failed, both sides are exactly equal
       code: assert number > 2
       left: 2

    6) test y (Cinder.XTest)
       test/x_test.exs:31
       could not reach localhost:4000
       code: flunk("could not reach localhost:4000")
       stacktrace:
         test/x_test.exs:32: (test)

       The following output was logged:

       22:06:55.149 [error] request failed
       code: 503 from upstream

  1) step one (Cinder.Setup)
    2) step two

  100) Cinder.YTest: failure on setup_all callback, all tests have been invalidated
       ** (RuntimeError) oops
      └─ test/x_test.exs:3:5
       code: indented output outside a failure block

  Finished in 0.01 seconds

  Result: 0/7 passed, 1 invalid
  OUT
      exit 2 ;;
    *) printf '\\nResult: 2 passed\\n' ;;
  esac
  """

  @base "def rule(x), do: x + 1\ndef other, do: :ok\n"

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "mix"), @stub)
    File.chmod!(Path.join(bin, "mix"), 0o755)

    for tool <- @tools,
        do: File.ln_s!(System.find_executable(tool), Path.join(bin, tool))

    target = Path.join(dir, "target.ex")
    File.write!(target, @base)
    %{dir: dir, bin: bin, target: target, log: Path.join(dir, "calls.log")}
  end

  defp env(ctx) do
    [
      {"PATH", ctx.bin},
      {"MUT_TARGET", ctx.target},
      {"MUT_LOG", ctx.log},
      {"MUT_SEEN", Path.join(ctx.dir, "seen.ex")}
    ]
  end

  defp mutants(ctx, list) do
    path = Path.join(ctx.dir, "mutants.json")

    File.write!(
      path,
      JSON.encode!(Enum.map(list, fn {l, o, n} -> %{label: l, old: o, new: n} end))
    )

    path
  end

  defp run(ctx, args) do
    System.cmd("python3", ["-I", @script | args], env: env(ctx), stderr_to_stdout: true)
  end

  defp calls(ctx) do
    case File.read(ctx.log) do
      {:ok, log} -> log |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  @tag :tmp_dir
  test "gives each verdict, prints each edit's lines and restores the file", ctx do
    list =
      mutants(ctx, [
        {"k", "x + 1", "x + 1 # BROKEN"},
        {"s", ":ok", ":ok "},
        {"n", "def other", "def SYNTAX other"},
        {"z", "rule(x)", "rule(x) # ZERO"},
        {"e", "def rule", "def NONE rule"},
        {"p", "do: :ok", "do: :ok # PASSEXIT1"},
        {"i", "def other,", "def other, # INVALID"}
      ])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 1, out
    assert out =~ "control: Result: 2 passed"

    assert out =~
             "k: killed, Result: 1/2 passed\n    -def rule(x), do: x + 1\n" <>
               "    +def rule(x), do: x + 1 # BROKEN\n"

    assert out =~ "s: SURVIVED, Result: 2 passed\n"
    assert out =~ "n: NO RESULT, exit 1\n"
    assert out =~ "z: NO RESULT, Result: 0 tests, 4 excluded\n"
    assert out =~ "e: NO RESULT, Result: 0 tests\n"
    assert out =~ "p: NO RESULT, Result: 2 passed\n"
    assert out =~ "i: killed, Result: 1 passed, 2 invalid\n"
    assert out =~ "2 of 7 killed"
    assert calls(ctx) == 8
    assert File.read!(ctx.target) == @base
  end

  @tag :tmp_dir
  test "prints each failure's header under a kill and the run's errors under no result", ctx do
    list =
      mutants(ctx, [
        {"k", "x + 1", "x + 1 # BROKEN"},
        {"i", "def other,", "def other, # INVALID"},
        {"n", "def other", "def SYNTAX other"},
        {"c", "rule(x)", "rule(x) # COMPILE"},
        {"t", "def rule", "def TAIL rule"},
        {"s", ":ok", ":ok "}
      ])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 1, out

    assert out =~
             "k: killed, Result: 1/2 passed\n    -def rule(x), do: x + 1\n" <>
               "    +def rule(x), do: x + 1 # BROKEN\n    failed: 1) test x (Cinder.XTest)\ni: "

    assert out =~
             "i: killed, Result: 1 passed, 2 invalid\n    -def other, do: :ok\n" <>
               "    +def other, # INVALID do: :ok\n" <>
               "    failed: 1) Cinder.XTest: failure on setup_all callback, all tests have been " <>
               "invalidated\nn: "

    assert out =~
             "n: NO RESULT, exit 1\n    -def other, do: :ok\n    +def SYNTAX other, do: :ok\n" <>
               "    output: ** (SyntaxError) invalid syntax\nc: "

    # Only the error lines, and at most 5 of them.
    errors = Enum.map_join(1..5, &"    output: error: e#{&1}\n")

    assert out =~
             "c: NO RESULT, exit 1\n    -def rule(x), do: x + 1\n" <>
               "    +def rule(x) # COMPILE, do: x + 1\n" <> errors <> "t: "

    # No error line: the last 5 non-blank lines.
    tail = Enum.map_join(3..7, &"    output: l#{&1}\n")

    assert out =~
             "t: NO RESULT, exit 1\n    -def rule(x), do: x + 1\n" <>
               "    +def TAIL rule(x), do: x + 1\n" <> tail <> "s: "

    assert out =~
             "s: SURVIVED, Result: 2 passed\n    -def other, do: :ok\n" <>
               "    +def other, do: :ok \n2 of 6 killed\n"
  end

  @tag :tmp_dir
  test "prints the message and code lines of each failed assertion under a kill", ctx do
    list =
      mutants(ctx, [
        {"m", "x + 1", "x + 1 # MATCHFAIL"},
        {"l", ":ok", ":ok # LTFAIL"},
        {"s", "def other", "def  other"}
      ])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 1, out

    # The two kills fail test t on different assertions. The parameters, the location, the
    # values, the `code:` lines inside a value or a captured log, and the lines outside a failure
    # block, a test's own `1) ...` among them, stay out.
    assert out =~
             "m: killed, Result: 1/2 passed\n    -def rule(x), do: x + 1\n" <>
               "    +def rule(x), do: x + 1 # MATCHFAIL\n" <>
               "    failed: 1) test t (Cinder.XTest)\n      match (=) failed\n" <>
               "      code:  assert {:ok, _} = call()\nl: "

    assert out =~
             "l: killed, Result: 0/7 passed, 1 invalid\n    -def other, do: :ok\n" <>
               "    +def other, do: :ok # LTFAIL\n" <>
               "    failed: 1) test t (Cinder.XTest)\n      Assertion with < failed\n" <>
               "      code:  assert elapsed < 30_000\n" <>
               "    failed: 2) test u (Cinder.XTest)\n      Assertion with == failed\n" <>
               "      code:  assert Enum.map(\n" <>
               "               [1, 2, 3],\n" <>
               "               fn n -> not is_integer(n) end\n" <>
               "             ) == [true, true, true]\n" <>
               "    failed: 3) test v (Cinder.XTest)\n" <>
               "      Assertion failed, no matching message after 10ms\n" <>
               "      code: assert_receive {:response, %{code: 200}}\n" <>
               "    failed: 4) test w (Cinder.XTest)\n" <>
               "      ** (MatchError) no match of right hand side value:\n" <>
               "      code: %{code: 200} = v\n" <>
               "    failed: 5) test x (Cinder.XTest)\n" <>
               "      Failure #1\n      Assertion with > failed\n      code:  assert number > 2\n" <>
               "      Failure #2\n      Assertion with > failed, both sides are exactly equal\n" <>
               "      code: assert number > 2\n" <>
               "    failed: 6) test y (Cinder.XTest)\n      could not reach localhost:4000\n" <>
               "      code: flunk(\"could not reach localhost:4000\")\n" <>
               "    failed: 100) Cinder.YTest: failure on setup_all callback, all tests have been " <>
               "invalidated\n      ** (RuntimeError) oops\ns: "

    assert out =~
             "s: SURVIVED, Result: 2 passed\n    -def other, do: :ok\n" <>
               "    +def  other, do: :ok\n2 of 3 killed\n"
  end

  @tag :tmp_dir
  test "exits 0 when every mutant is killed", ctx do
    {out, code} = run(ctx, [ctx.target, mutants(ctx, [{"k", "x + 1", "BROKEN"}]), "t.exs"])

    assert code == 0, out
    assert out =~ "1 of 1 killed"
  end

  @tag :tmp_dir
  test "runs nothing when an old is missing, repeated or overlaps itself", ctx do
    File.write!(ctx.target, @base <> "aaa\n")

    list =
      mutants(ctx, [
        {"ok", "x + 1", "BROKEN"},
        {"twice", "def ", "defp "},
        {"nowhere", "no such text", "x"},
        {"overlap", "aa", "b"}
      ])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 2, out
    assert out =~ "twice (2), nowhere (0), overlap (2)"
    assert calls(ctx) == 0
  end

  for {marker, line} <- [
        {"BROKEN", "Result: 1/2 passed"},
        {"NONE", "Result: 0 tests"},
        {"PASSEXIT1", "Result: 2 passed"}
      ] do
    @tag :tmp_dir
    test "exits 2 when the control run on the unchanged file prints #{line}", ctx do
      File.write!(ctx.target, unquote(marker) <> " " <> @base)

      {out, code} = run(ctx, [ctx.target, mutants(ctx, [{"k", "x + 1", "x"}]), "t.exs"])

      assert code == 2, out
      assert out =~ "control run on the unchanged file did not pass: #{unquote(line)}"
      assert calls(ctx) == 1
    end
  end

  @tag :tmp_dir
  test "exits 2 on arguments or a mutant list it cannot read", ctx do
    bad = [
      {"missing list", Path.join(ctx.dir, "none.json")},
      {"not json", "{"},
      {"an object", ~s({"label": "a", "old": "x", "new": "y"})},
      {"no label", ~s([{"old": "x + 1", "new": "y"}])},
      {"empty old", ~s([{"label": "e", "old": "", "new": "y"}])},
      {"empty list", "[]"}
    ]

    for {name, content} <- bad do
      path =
        if String.ends_with?(content, ".json"),
          do: content,
          else: tap(Path.join(ctx.dir, "bad.json"), &File.write!(&1, content))

      {out, code} = run(ctx, [ctx.target, path, "t.exs"])
      assert {name, code} == {name, 2}, out
    end

    list = mutants(ctx, [{"k", "x + 1", "x"}])
    assert {_, 2} = run(ctx, [Path.join(ctx.dir, "none.ex"), list, "t.exs"])
    assert {_, 2} = run(ctx, [ctx.target, list])
    assert calls(ctx) == 0
  end

  @tag :tmp_dir
  test "exits 2 when no mix is on PATH", ctx do
    list = mutants(ctx, [{"k", "x + 1", "x"}])
    args = ["-I", @script, ctx.target, list, "t.exs"]

    {out, code} = System.cmd("python3", args, env: [{"PATH", ctx.dir}], stderr_to_stdout: true)

    assert code == 2, out
    assert out =~ "cannot run mix"
    assert File.read!(ctx.target) == @base
  end

  @tag :tmp_dir
  test "exits 2 and restores the file when mix disappears after a mutant's run", ctx do
    list = mutants(ctx, [{"gone", "x + 1", "x + 1 # VANISH"}, {"next", ":ok", ":error"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 2, out
    assert out =~ "cannot run mix or write"
    assert File.read!(ctx.target) == @base
  end

  @tag :tmp_dir
  test "exits 2 when it cannot write or restore the file", ctx do
    list = mutants(ctx, [{"swap", "x + 1", "x + 1 # SWAPDIR"}, {"next", ":ok", ":error"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 2, out
    assert out =~ "cannot run mix or write"
    assert out =~ "cannot restore"
    assert File.dir?(ctx.target)
  end

  # The harness hands the script a pipe whose read end is already closed, as `| head` leaves it
  # once head exits, so the first print fails. With "both", stderr goes there too (`2>&1 | head`).
  @harness """
  import os, subprocess, sys
  r, w = os.pipe()
  os.close(r)
  stderr = w if sys.argv[1] == "both" else None
  sys.exit(subprocess.run(sys.argv[2:], stdout=w, stderr=stderr).returncode)
  """

  for streams <- ["stdout", "both"] do
    @tag :tmp_dir
    test "exits 2 and restores the file when #{streams} closes early", ctx do
      list = mutants(ctx, [{"k", "x + 1", "x + 1 # BROKEN"}])
      script = ["python3", "-I", @script, ctx.target, list, "t.exs"]
      args = ["-I", "-c", @harness, unquote(streams) | script]

      {out, code} = System.cmd("python3", args, env: env(ctx), stderr_to_stdout: true)

      assert code == 2, out
      if unquote(streams) == "stdout", do: assert(out =~ "stdout closed early")
      refute out =~ "Traceback"
      assert File.read!(ctx.target) == @base
    end
  end

  @tag :tmp_dir
  test "a control run that fails leaves the file to the run that changed it", ctx do
    File.write!(ctx.target, "CTRLSWAP " <> @base)

    {out, code} = run(ctx, [ctx.target, mutants(ctx, [{"k", "x + 1", "x"}]), "t.exs"])

    assert code == 2, out
    assert out =~ "control run on the unchanged file did not pass"
    refute out =~ "cannot restore"
    assert File.dir?(ctx.target)
  end

  @tag :tmp_dir
  test "exits 2 when only the restore after the last mutant fails", ctx do
    list = mutants(ctx, [{"swap", "x + 1", "x + 1 # SWAPDIR"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 2, out
    assert out =~ "swap: SURVIVED"
    assert out =~ "cannot restore"
    refute out =~ "cannot run mix or write"
  end

  for signal <- ["TERM", "INT"] do
    @tag :tmp_dir
    test "restores the file and exits 130 on SIG#{signal} during a mutant's run", ctx do
      list = mutants(ctx, [{"slow", "x + 1", "x + 1 # SLEEP"}])
      seen = Path.join(ctx.dir, "seen.ex")

      # A background job in a non-interactive bash starts with SIGINT ignored, so the SIGINT
      # case passes only while the script installs its own handler for it.
      shell = """
      python3 -I "$0" "$1" "$2" t.exs > /dev/null 2>&1 & p=$!
      for i in $(seq 1 200); do [ -e "$MUT_SEEN" ] && break; sleep 0.1; done
      kill -#{unquote(signal)} $p; wait $p; echo "exit=$?"
      """

      {out, 0} = System.cmd("bash", ["-c", shell, @script, ctx.target, list], env: env(ctx))

      assert out =~ "exit=130"
      assert File.read!(seen) =~ "# SLEEP"
      assert File.read!(ctx.target) == @base
    end
  end
end
