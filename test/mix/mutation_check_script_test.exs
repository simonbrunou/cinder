defmodule Cinder.MutationCheckScriptTest do
  # Runs `scripts/mutation-check` against a stub `mix` on PATH, so each verdict and exit path
  # stays covered without a nested `mix test` run. The stub logs each call with the failure
  # record path the script gave it, writes that record folder's mode to a second log, and reads
  # the target file: a marker word in it picks the output a real run would print, and the failure
  # blocks it appends to that record, as `Cinder.MutationFailures` does. The unchanged target
  # holds no marker, so the control run passes unless a case puts one there. PATH holds only the
  # stub and links to the tools the stub and the shell cases call, so the real `mix` is never
  # found. MUTATION_CHECK_TMPDIR is a folder of the test's own, so a case can check that the
  # script removes its record.
  use ExUnit.Case, async: true

  alias Cinder.Test.OsProcess

  @tools ~w(bash cat cp rm mkdir sleep seq stat python3)

  @script Path.expand("scripts/mutation-check")

  @record "$" <> Cinder.MutationFailures.env_var()

  @stub """
  #!/usr/bin/env bash
  echo "call #{@record}" >> "$MUT_LOG"
  stat -c %a "${#{Cinder.MutationFailures.env_var()}%/*}" >> "$MUT_MODES" 2> /dev/null
  rec() { cat >> "#{@record}"; }
  # A block with `$1` message lines, and its `code:` line.
  msg() {
    printf '  1) test m (Cinder.XTest)\\n     test/x_test.exs:4\\n'
    for i in $(seq "$1"); do printf '     line %s\\n' "$i"; done
    printf '     code: assert m()\\n     stacktrace:\\n       test/x_test.exs:5: (test)\\n'
  }
  killed() { printf '\\nResult: 1/2 passed\\nFailed: 1 test\\n'; exit 2; }
  body=$(cat "$MUT_TARGET")
  case "$body" in
    *RESULTHANG*) printf '\\nResult: 1/2 passed\\n'; exec sleep 30 ;;
    *PASSHANG*) printf '\\nResult: 2 passed\\n'; exec sleep 30 ;;
    *HANG*)
      # A grandchild in the run's process group, then a wait on it. The test reads its pid.
      printf 'hang start\\n'; sleep 30 & echo $! > "$MUT_CHILD"
      cp "$MUT_TARGET" "$MUT_SEEN"; wait ;;
    *SLOWKILL*) sleep 1; killed ;;
    *SLOWPASS*) sleep 3; printf '\\nResult: 2 passed\\n' ;;
    # A process left behind that writes a failing result into the output it inherited.
    *LATE*) (sleep 1; printf 'Result: 1/2 passed\\n') & printf '\\nResult: 2 passed\\n' ;;
    *STDERR*) printf 'err line\\n' >&2; printf 'out line\\n'; exit 1 ;;
    *SYNTAX*) printf 'noise\\n** (SyntaxError) invalid syntax\\n'; exit 1 ;;
    *ZERO*) printf '\\nResult: 0 tests, 4 excluded\\n'; exit 1 ;;
    *NONE*) printf '\\nResult: 0 tests\\n' ;;
    *PASSEXIT1*) printf '\\nResult: 2 passed\\n'; exit 1 ;;
    *VANISH*) rm "$0"; printf '\\nResult: 2 passed\\n' ;;
    *SWAPDIR*) rm "$MUT_TARGET"; mkdir "$MUT_TARGET"; printf '\\nResult: 2 passed\\n' ;;
    *CTRLSWAP*) rm "$MUT_TARGET"; mkdir "$MUT_TARGET"; printf '\\nResult: 1/2 passed\\n'; exit 2 ;;
    *INVALID*)
      rec <<'OUT'
    1) Cinder.XTest: failure on setup_all callback, all tests have been invalidated
       ** (RuntimeError) oops
       stacktrace:
         test/x_test.exs:3: Cinder.XTest.__ex_unit_setup_all_0/1
  OUT
      printf '\\nResult: 1 passed, 2 invalid\\n'
      exit 2 ;;
    *COMPILE*)
      printf 'noise\\n'
      for i in $(seq 6); do printf '    error: e%s\\n' "$i"; done
      printf '** (CompileError) x\\n'; exit 1 ;;
    *TAIL*) for i in $(seq 7); do printf 'l%s\\n\\n' "$i"; done; exit 1 ;;
    *BROKEN*)
      printf '  1) test x (Cinder.XTest)\\n     test/x_test.exs:3\\n     boom\\n' | rec
      killed ;;
    *FAKEHEAD*)
      # A passing test prints a header-shaped block; ExUnit prints the real one too.
      cat <<'OUT'
    9) test fake (Fake.Mod)
       test/fake.exs:1
       Assertion with == failed
  .
    1) test real (Cinder.XTest)
       test/x_test.exs:4
       Assertion with == failed
       code:  assert 1 == 2
  OUT
      rec <<'OUT'
    1) test real (Cinder.XTest)
       test/x_test.exs:4
       Assertion with == failed
       code:  assert 1 == 2
       left:  1
       right: 2
       stacktrace:
         test/x_test.exs:5: (test)
  OUT
      killed ;;
    *NOREC*) killed ;;
    *RMREC*) rm "#{@record}"; killed ;;
    *DIRREC*) rm "#{@record}"; mkdir "#{@record}"; killed ;;
    *BADBYTES*)
      printf '  1) test b (Cinder.XTest)\\n     test/x_test.exs:3\\n     bad \\377 byte\\n' | rec
      killed ;;
    *CAPTEN*) msg 10 | rec; killed ;;
    *CAPMORE1*) msg 11 | rec; killed ;;
    *CAPMORE3*) msg 13 | rec; killed ;;
    *LABELS*)
      # A `Failure #N` line ends a message, and so does a line ExUnit does not indent. Then a
      # block per label that ends a message: a line after the label is no message line, and a
      # `code:` line after it still prints.
      {
        printf '  1) test bare (Cinder.XTest)\\n     test/x_test.exs:1\\n'
        printf '\\n     Failure #1\\n     bare one\\n\\n     Failure #2\\n     bare two\\n'
        printf 'stray\\n     after stray\\n'
        n=1
        for label in doctest arguments left right mailbox stacktrace; do
          n=$((n + 1))
          printf '  %s) test %s (Cinder.XTest)\\n     test/x_test.exs:%s\\n' "$n" "$label" "$n"
          printf '     ends at %s\\n     %s: 1\\n     after %s\\n' "$label" "$label" "$label"
          printf '     code: c %s\\n' "$label"
        done
      } | rec
      killed ;;
    *PARAMS*)
      # Plain `setup_all` blocks whose message starts `Parameters: `, a `setup_all` of a module
      # parameterized with a struct, then a test and a `setup_all` of modules parameterized with
      # a struct whose derived Inspect prints `#Mod<...>`.
      rec <<'OUT'
    5) Cinder.UTest: failure on setup_all callback, all tests have been invalidated
       Parameters: %d{n} unset
       stacktrace:
         test/u_test.exs:3: Cinder.UTest.__ex_unit__/2
    1) Cinder.PTest: failure on setup_all callback, all tests have been invalidated
       Parameters: missing
       stacktrace:
         test/p_test.exs:3: Cinder.PTest.__ex_unit__/2
    2) Cinder.QTest: failure on setup_all callback, all tests have been invalidated
       Parameters: %Cinder.S{a: 1}
       ** (RuntimeError) q
       stacktrace:
         test/q_test.exs:3: Cinder.QTest.__ex_unit__/2
    3) test s (Cinder.STest)
       Parameters: #Cinder.S<a: 1, ...>
       test/s_test.exs:4
       s failed
       code: flunk("s failed")
       stacktrace:
         test/s_test.exs:4: (test)
    4) Cinder.RTest: failure on setup_all callback, all tests have been invalidated
       Parameters: #Cinder.S<a: 1, ...>
       ** (RuntimeError) r
       stacktrace:
         test/r_test.exs:3: Cinder.RTest.__ex_unit__/2
  OUT
      printf '\\nResult: 0/1 passed, 4 invalid\\n'
      exit 2 ;;
    *MATCHFAIL*)
      rec <<'OUT'
    1) test t (Cinder.XTest)
       test/my dir/x_test.exs:4
       match (=) failed
       code:  assert {:ok, _} = call()
       left:  {:ok, _}
       right: {:error, :timeout}
       stacktrace:
         test/x_test.exs:5: (test)
  OUT
      killed ;;
    *LTFAIL*)
      rec <<'OUT'
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
       stacktrace:
         test/x_test.exs:10: (test)
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
       stacktrace:
         test/x_test.exs:13: (test)
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
       stacktrace:
         test/x_test.exs:29: anonymous fn/1 in Cinder.XTest."test x"/1
   10) test y (Cinder.XTest)
       test/x_test.exs:31
       could not reach localhost:4000
       code: flunk("could not reach localhost:4000")
       stacktrace:
         test/x_test.exs:32: (test)
   11) Cinder.ZTest: failure on setup_all callback, all tests have been invalidated
       Parameters: %{kind: :a}
       ** (RuntimeError) zz
       stacktrace:
         test/x_test.exs:3: Cinder.ZTest.__ex_unit_setup_all_0/1
  100) Cinder.YTest: failure on setup_all callback, all tests have been invalidated
       ** (RuntimeError) oops
       stacktrace:
         test/x_test.exs:3: Cinder.YTest.__ex_unit_setup_all_0/1
  OUT
      printf '\\n  Finished in 0.01 seconds\\n\\nResult: 0/7 passed, 1 invalid\\n'
      exit 2 ;;
    # Compiler warnings as Elixir prints them, above a passing run or a kill, and a Logger
    # `[warning]` line, which is none. `*WARNAB*` comes before `*WARNA*`, which also matches it.
    *WARNAB*) printf '    warning: a\\n    warning: b\\n\\nResult: 2 passed\\n' ;;
    *WARNSIX*) for i in $(seq 6); do printf '    warning: w%s\\n' "$i"; done; printf '\\nResult: 2 passed\\n' ;;
    *WARNKILL*) printf '    warning: k\\n'; killed ;;
    *LOGWARN*) printf '19:31:26.395 [warning] movie 3 search failed\\n\\nResult: 2 passed\\n' ;;
    *WARNA*) printf '    warning: a\\n    │\\n\\nResult: 2 passed\\n' ;;
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
    tmp = Path.join(dir, "tmp")
    File.mkdir_p!(tmp)
    %{dir: dir, bin: bin, target: target, log: Path.join(dir, "calls.log"), tmp: tmp}
  end

  # The record env var is unset: under `scripts/mutation-check`, this test run has it, and a
  # script that failed to set its own would hand the stub the outer run's record.
  defp env(ctx) do
    [
      {"PATH", ctx.bin},
      {"MUTATION_CHECK_TMPDIR", ctx.tmp},
      {Cinder.MutationFailures.env_var(), nil},
      {"MUTATION_CHECK_TIMEOUT", nil},
      {"MUT_TARGET", ctx.target},
      {"MUT_CHILD", Path.join(ctx.dir, "child.pid")},
      {"MUT_LOG", ctx.log},
      {"MUT_SEEN", Path.join(ctx.dir, "seen.ex")},
      {"MUT_MODES", Path.join(ctx.dir, "modes.log")}
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

  defp run(ctx, args, limit \\ nil) do
    env = List.keystore(env(ctx), "MUTATION_CHECK_TIMEOUT", 0, {"MUTATION_CHECK_TIMEOUT", limit})
    System.cmd("python3", ["-I", @script | args], env: env, stderr_to_stdout: true)
  end

  # Whether the grandchild the HANG marker starts in the run's process group is dead.
  defp grandchild_dead?(ctx) do
    ctx.dir
    |> Path.join("child.pid")
    |> File.read!()
    |> String.trim()
    |> String.to_integer()
    |> OsProcess.dead?()
  end

  # The failure record path the script gave each call of the stub.
  defp records(ctx) do
    case File.read(ctx.log) do
      {:ok, log} -> for "call " <> path <- String.split(log, "\n", trim: true), do: path
      {:error, :enoent} -> []
    end
  end

  defp calls(ctx), do: length(records(ctx))

  # Every call got a record in the test's MUTATION_CHECK_TMPDIR, in a folder only its owner can
  # open, and the script removed them all.
  defp assert_records_removed(ctx) do
    assert [_ | _] = paths = records(ctx)
    assert Enum.all?(paths, &String.starts_with?(&1, ctx.tmp <> "/")), inspect(paths)
    modes = ctx.dir |> Path.join("modes.log") |> File.read!() |> String.split()
    assert modes == List.duplicate("700", length(paths))
    assert File.ls!(ctx.tmp) == []
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
    assert_records_removed(ctx)
  end

  # On #1975, a mutant that read `@titles_key` above the attribute's definition compiled to nil,
  # warned `undefined module attribute`, changed nothing and read SURVIVED.
  @tag :tmp_dir
  test "a passing mutant whose run prints a compiler warning is WARNED, with the warning", ctx do
    list = mutants(ctx, [{"w", "x + 1", "x + 1 # WARNA"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 1, out

    assert out =~
             "w: WARNED, Result: 2 passed\n    -def rule(x), do: x + 1\n" <>
               "    +def rule(x), do: x + 1 # WARNA\n    output: warning: a\n0 of 1 killed\n"

    assert File.read!(ctx.target) == @base
  end

  @tag :tmp_dir
  test "a warning the control run printed too leaves a mutant SURVIVED and is not listed", ctx do
    File.write!(ctx.target, @base <> "# WARNA\n")
    list = mutants(ctx, [{"same", ":ok", ":ok "}, {"new", "WARNA", "WARNAB"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 1, out

    assert out =~
             "same: SURVIVED, Result: 2 passed\n    -def other, do: :ok\n    +def other, do: :ok \nnew: "

    assert out =~
             "new: WARNED, Result: 2 passed\n    -# WARNA\n    +# WARNAB\n" <>
               "    output: warning: b\n0 of 2 killed\n"
  end

  @tag :tmp_dir
  test "a warned mutant lists 5 warnings, a killed one stays killed, a log line warns nothing",
       ctx do
    list =
      mutants(ctx, [
        {"six", "x + 1", "x + 1 # WARNSIX"},
        {"kill", "x + 1", "x + 1 # WARNKILL"},
        {"log", "x + 1", "x + 1 # LOGWARN"}
      ])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 1, out
    listed = Enum.map_join(1..5, &"    output: warning: w#{&1}\n")
    assert out =~ "+def rule(x), do: x + 1 # WARNSIX\n" <> listed <> "kill: "
    assert out =~ "kill: killed, Result: 1/2 passed\n"
    assert out =~ "log: SURVIVED, Result: 2 passed\n"
    assert out =~ "1 of 3 killed\n"
  end

  @tag :tmp_dir
  test "prints each failure from the record under a kill and the run's errors under no result",
       ctx do
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
               "    +def rule(x), do: x + 1 # BROKEN\n    failed: 1) test x (Cinder.XTest)\n" <>
               "      boom\ni: "

    assert out =~
             "i: killed, Result: 1 passed, 2 invalid\n    -def other, do: :ok\n" <>
               "    +def other, # INVALID do: :ok\n" <>
               "    failed: 1) Cinder.XTest: failure on setup_all callback, all tests have been " <>
               "invalidated\n      ** (RuntimeError) oops\nn: "

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
  test "lists only the record's failures, not a header-shaped line a passing test prints", ctx do
    list = mutants(ctx, [{"f", "x + 1", "x + 1 # FAKEHEAD"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 0, out

    assert out =~
             "f: killed, Result: 1/2 passed\n    -def rule(x), do: x + 1\n" <>
               "    +def rule(x), do: x + 1 # FAKEHEAD\n" <>
               "    failed: 1) test real (Cinder.XTest)\n      Assertion with == failed\n" <>
               "      code:  assert 1 == 2\n1 of 1 killed\n"

    refute out =~ "fake"
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

    # The two kills fail test t on different assertions. The parameters of a test and of a
    # `setup_all`, the location, the values, the stacktraces and the `code:` lines inside a value
    # stay out. Each non-blank line of a message prints, a deeper one as indented as ExUnit has
    # it, up to its first label. Headers come with a number of 1, 2 and 3 digits.
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
               "      Showing 1 of 1 message in the mailbox\n" <>
               "      code: assert_receive {:response, %{code: 200}}\n" <>
               "    failed: 4) test w (Cinder.XTest)\n" <>
               "      ** (MatchError) no match of right hand side value:\n" <>
               "          %{\n" <>
               "            code: 404,\n" <>
               "            body: \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"\n" <>
               "          }\n" <>
               "      code: %{code: 200} = v\n" <>
               "    failed: 5) test x (Cinder.XTest)\n" <>
               "      Failure #1\n      Assertion with > failed\n      code:  assert number > 2\n" <>
               "      Failure #2\n      Assertion with > failed, both sides are exactly equal\n" <>
               "      code: assert number > 2\n" <>
               "    failed: 10) test y (Cinder.XTest)\n      could not reach localhost:4000\n" <>
               "      code: flunk(\"could not reach localhost:4000\")\n" <>
               "    failed: 11) Cinder.ZTest: failure on setup_all callback, all tests have been " <>
               "invalidated\n      ** (RuntimeError) zz\n" <>
               "    failed: 100) Cinder.YTest: failure on setup_all callback, all tests have been " <>
               "invalidated\n      ** (RuntimeError) oops\ns: "

    assert out =~
             "s: SURVIVED, Result: 2 passed\n    -def other, do: :ok\n" <>
               "    +def  other, do: :ok\n2 of 3 killed\n"
  end

  @tag :tmp_dir
  test "a setup_all leaves out only a %{ or %Alias{ parameters line, a test each Parameters line",
       ctx do
    {out, code} = run(ctx, [ctx.target, mutants(ctx, [{"p", "x + 1", "PARAMS"}]), "t.exs"])

    assert code == 0, out

    # A `setup_all` block prints a first line that starts `Parameters: ` without a `{` or a
    # capital after the `%`, and a `#Mod<...>` parameters line, the limit the script's header
    # names. A struct's parameters line stays out of it. A test block leaves out a `#Mod<...>`
    # parameters line and its `file:line`.
    assert out =~
             "    +def rule(x), do: PARAMS\n" <>
               "    failed: 5) Cinder.UTest: failure on setup_all callback, all tests have " <>
               "been invalidated\n      Parameters: %d{n} unset\n" <>
               "    failed: 1) Cinder.PTest: failure on setup_all callback, all tests have " <>
               "been invalidated\n      Parameters: missing\n" <>
               "    failed: 2) Cinder.QTest: failure on setup_all callback, all tests have " <>
               "been invalidated\n      ** (RuntimeError) q\n" <>
               "    failed: 3) test s (Cinder.STest)\n      s failed\n" <>
               "      code: flunk(\"s failed\")\n" <>
               "    failed: 4) Cinder.RTest: failure on setup_all callback, all tests have " <>
               "been invalidated\n      Parameters: #Cinder.S<a: 1, ...>\n" <>
               "      ** (RuntimeError) r\n1 of 1 killed\n"
  end

  @tag :tmp_dir
  test "ends a message at each label ExUnit prints after one, a failure line or a block's end",
       ctx do
    {out, code} = run(ctx, [ctx.target, mutants(ctx, [{"b", "x + 1", "LABELS"}]), "t.exs"])

    assert code == 0, out

    bare =
      "    failed: 1) test bare (Cinder.XTest)\n      Failure #1\n      bare one\n" <>
        "      Failure #2\n      bare two\n"

    blocks =
      ~w(doctest arguments left right mailbox stacktrace)
      |> Enum.with_index(2)
      |> Enum.map_join(fn {label, n} ->
        "    failed: #{n}) test #{label} (Cinder.XTest)\n      ends at #{label}\n" <>
          "      code: c #{label}\n"
      end)

    assert out =~ "    +def rule(x), do: LABELS\n" <> bare <> blocks <> "1 of 1 killed\n"
  end

  @tag :tmp_dir
  test "prints up to 10 message lines, then how many it left out", ctx do
    list =
      mutants(ctx, [
        {"ten", "x + 1", "CAPTEN"},
        {"eleven", ":ok", "CAPMORE1"},
        {"thirteen", "def other", "def CAPMORE3 other"}
      ])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 0, out
    lines = fn n -> Enum.map_join(1..n, &"      line #{&1}\n") end
    header = "    failed: 1) test m (Cinder.XTest)\n"
    code_line = "      code: assert m()\n"

    assert out =~
             "    +def rule(x), do: CAPTEN\n" <> header <> lines.(10) <> code_line <> "eleven: "

    assert out =~
             "    +def other, do: CAPMORE1\n" <>
               header <> lines.(10) <> "      (1 more message line left out)\n" <> code_line

    assert out =~
             "    +def CAPMORE3 other, do: :ok\n" <>
               header <> lines.(10) <> "      (3 more message lines left out)\n" <> code_line
  end

  @tag :tmp_dir
  test "a mutant's run never lists the failures of the run before it", ctx do
    list = mutants(ctx, [{"m", "x + 1", "x + 1 # MATCHFAIL"}, {"n", ":ok", ":ok # NOREC"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 0, out

    assert out =~
             "    +def rule(x), do: x + 1 # MATCHFAIL\n    failed: 1) test t (Cinder.XTest)\n"

    assert out =~
             "n: killed, Result: 1/2 passed\n    -def other, do: :ok\n" <>
               "    +def other, do: :ok # NOREC\n" <>
               "    no failure record: Cinder.MutationFailures wrote no failure block\n" <>
               "2 of 2 killed\n"

    assert length(String.split(out, "failed: 1) test t")) == 2, out
  end

  @tag :tmp_dir
  test "a kill whose record the run removed prints the no-record line", ctx do
    {out, code} = run(ctx, [ctx.target, mutants(ctx, [{"r", "x + 1", "RMREC"}]), "t.exs"])

    assert code == 0, out

    assert out =~
             "    +def rule(x), do: RMREC\n" <>
               "    no failure record: Cinder.MutationFailures wrote no failure block\n"

    assert_records_removed(ctx)
  end

  @tag :tmp_dir
  test "a record it cannot read prints the no-record line, and one it cannot empty exits 2",
       ctx do
    list = mutants(ctx, [{"d", "x + 1", "DIRREC"}, {"next", ":ok", ":error"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 2, out

    assert out =~
             "    +def rule(x), do: DIRREC\n" <>
               "    no failure record: Cinder.MutationFailures wrote no failure block\n"

    assert out =~ "cannot run mix or write"
    refute out =~ "next:"
    assert calls(ctx) == 2
    assert File.read!(ctx.target) == @base
    assert_records_removed(ctx)
  end

  @tag :tmp_dir
  test "replaces a record's bytes that are not UTF-8", ctx do
    {out, code} = run(ctx, [ctx.target, mutants(ctx, [{"b", "x + 1", "BADBYTES"}]), "t.exs"])

    assert code == 0, out
    assert out =~ "    failed: 1) test b (Cinder.XTest)\n      bad � byte\n1 of 1 killed\n"
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

  @tag :tmp_dir
  test "runs nothing on a file:line off a test or describe, naming the test above", ctx do
    tests = Path.join(ctx.dir, "t_test.exs")

    File.write!(tests, """
    defmodule T do
      test "a" do
        test_helper()
      end

      describe "d" do
        test "b", do: :ok
      end
    end
    """)

    list = mutants(ctx, [{"k", "x + 1", "BROKEN"}])
    latin1 = Path.join(ctx.dir, "latin1_test.exs")
    File.write!(latin1, <<"# caf", 0xE9, "\n">>)

    # A test line, a describe line, both in one argument, a path it cannot read, and a file
    # that is not UTF-8: the last two pass on to mix.
    for arg <- [
          "#{tests}:2",
          "#{tests}:6",
          "#{tests}:2:7",
          "#{ctx.dir}/missing_test.exs:3",
          "#{latin1}:1"
        ] do
      {out, code} = run(ctx, [ctx.target, list, arg])
      assert code == 0, "#{arg}: #{out}"
    end

    {out, code} =
      run(ctx, [ctx.target, list, "#{tests}:5", "#{tests}:1", "#{tests}:7:99", "#{tests}:3"])

    assert code == 2, out

    assert out =~
             "select the test by name: #{tests}:5 (closest test above: 2), " <>
               "#{tests}:1 (closest test above: none), #{tests}:99 (closest test above: 7), " <>
               "#{tests}:3 (closest test above: 2)"

    # The five runs above made a control and a mutant call each; the refused one made none.
    assert calls(ctx) == 10
  end

  @tag :tmp_dir
  test "exits 2 when the control passes fewer tests than its --only test: names", ctx do
    list = mutants(ctx, [{"k", "x + 1", "BROKEN"}])
    two = ["t.exs", "--only", "test:test a", "--only=test:test b", "--only", "slow"]

    {out, code} = run(ctx, [ctx.target, list | two])
    assert code == 0, out

    for third <- [["--only", "test:test c"], ["--only=test:test c"]] do
      {out, code} = run(ctx, [ctx.target, list | two ++ third])

      assert code == 2, out
      assert out =~ "control passed fewer tests than its 3 --only test: names"
      assert out =~ "Result: 2 passed"
    end

    assert calls(ctx) == 4
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
      assert_records_removed(ctx)
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
    env = [{"PATH", ctx.dir} | tl(env(ctx))]

    {out, code} = System.cmd("python3", args, env: env, stderr_to_stdout: true)

    assert code == 2, out
    assert out =~ "cannot run mix"
    assert File.read!(ctx.target) == @base
    assert File.ls!(ctx.tmp) == []
  end

  @tag :tmp_dir
  test "exits 2 and runs nothing when it cannot make the record's folder", ctx do
    list = mutants(ctx, [{"k", "x + 1", "x"}])
    none = {"MUTATION_CHECK_TMPDIR", Path.join(ctx.dir, "none")}
    env = List.keyreplace(env(ctx), "MUTATION_CHECK_TMPDIR", 0, none)

    {out, code} =
      System.cmd("python3", ["-I", @script, ctx.target, list, "t.exs"],
        env: env,
        stderr_to_stdout: true
      )

    assert code == 2, out

    assert out =~
             "cannot make a folder for the failure record: [Errno 2] No such file or directory"

    assert calls(ctx) == 0
  end

  # The default folder is outside the test's own, so the case checks each record path the stub
  # got and that none is left, not the folder's listing.
  @tag :tmp_dir
  test "makes the record's folder in /var/tmp when MUTATION_CHECK_TMPDIR is unset or empty",
       ctx do
    env = List.keyreplace(env(ctx), "MUTATION_CHECK_TMPDIR", 0, {"MUTATION_CHECK_TMPDIR", nil})
    list = mutants(ctx, [{"k", "x + 1", "BROKEN"}])

    # A port's env option unsets a variable given an empty value, so bash sets the empty one.
    for prefix <- ["", "MUTATION_CHECK_TMPDIR= "] do
      shell = ~s(#{prefix}exec python3 -I "$0" "$@")
      args = ["-c", shell, @script, ctx.target, list, "t.exs"]
      {out, code} = System.cmd("bash", args, env: env, stderr_to_stdout: true)
      assert code == 0, out
    end

    assert [_, _, _, _] = paths = records(ctx)
    record = ~r|\A/var/tmp/mutation-check\.\d+\.[0-9a-f]{8}/failures\.txt\z|
    assert Enum.all?(paths, &(&1 =~ record)), inspect(paths)
    refute Enum.any?(paths, &File.exists?(Path.dirname(&1)))
  end

  @tag :tmp_dir
  test "exits 2 and restores the file when mix disappears after a mutant's run", ctx do
    list = mutants(ctx, [{"gone", "x + 1", "x + 1 # VANISH"}, {"next", ":ok", ":error"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 2, out
    assert out =~ "cannot run mix or write"
    assert File.read!(ctx.target) == @base
    assert_records_removed(ctx)
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
      assert_records_removed(ctx)
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
    test "restores the file, kills the run's group and exits 130 on SIG#{signal}", ctx do
      list = mutants(ctx, [{"slow", "x + 1", "x + 1 # HANG"}])
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
      assert File.read!(seen) =~ "# HANG"
      assert File.read!(ctx.target) == @base
      assert_records_removed(ctx)
      assert grandchild_dead?(ctx)
    end
  end

  # The control run of the stub takes milliseconds, so a 5 s limit leaves it seconds on a
  # loaded host, and a HANG run outlives it by 25 s.
  @tag :tmp_dir
  test "a mutant's run past the limit is HUNG, and the next mutant runs on the original", ctx do
    list = mutants(ctx, [{"hang", "x + 1", "x + 1 # HANG"}, {"next", ":ok", ":ok # BROKEN"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"], "5")

    assert code == 1, out
    assert out =~ "control: Result: 2 passed (limit 5 s a run)\n"
    assert out =~ "hang: HUNG, past the 5 s limit\n"
    assert out =~ "    output: hang start\n"
    assert out =~ "next: killed, Result: 1/2 passed\n"
    assert out =~ "1 of 2 killed"
    assert calls(ctx) == 3
    assert File.read!(ctx.target) == @base
    assert_records_removed(ctx)
  end

  @tag :tmp_dir
  test "a run that printed a failing result before the limit is HUNG", ctx do
    list = mutants(ctx, [{"late", "x + 1", "x + 1 # RESULTHANG"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"], "5")

    assert code == 1, out
    assert out =~ "late: HUNG, past the 5 s limit\n"
    assert out =~ "0 of 1 killed"
  end

  # The HANG run would end by itself after 30 s. The script ends within 5 s of the 5 s limit,
  # counted from the HANG run's pid file, so the control run's time does not count.
  @tag :tmp_dir
  test "the kill at the limit reaches the run's whole process group", ctx do
    list = mutants(ctx, [{"hang", "x + 1", "x + 1 # HANG"}])

    {out, 1} = run(ctx, [ctx.target, list, "t.exs"], "5")

    started = File.stat!(Path.join(ctx.dir, "child.pid"), time: :posix).mtime
    assert out =~ "hang: HUNG"
    assert System.os_time(:second) - started < 10
    assert grandchild_dead?(ctx)
  end

  # PASSHANG prints a passing result before it hangs, as a VM that never exits after ExUnit.
  for marker <- ["HANG", "PASSHANG"] do
    @tag :tmp_dir
    test "exits 2 when the control run passes the limit after #{marker}", ctx do
      File.write!(ctx.target, unquote(marker) <> " " <> @base)

      {out, code} = run(ctx, [ctx.target, mutants(ctx, [{"k", "x + 1", "x"}]), "t.exs"], "2")

      assert code == 2, out
      assert out =~ "control run on the unchanged file did not pass: past the 2 s limit"
      assert calls(ctx) == 1
      assert_records_removed(ctx)
    end
  end

  @tag :tmp_dir
  test "a run that takes a second under a 60 s limit keeps its verdict", ctx do
    list = mutants(ctx, [{"slow", "x + 1", "x + 1 # SLOWKILL"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"], "60")

    assert code == 0, out
    assert out =~ "slow: killed, Result: 1/2 passed\n"
  end

  # The first run leaves a process that writes a failing result 1 s later; the second run
  # passes after 3 s.
  @tag :tmp_dir
  test "a process an earlier run left behind cannot change a later run's verdict", ctx do
    list = mutants(ctx, [{"late", "x + 1", "x + 1 # LATE"}, {"next", ":ok", ":ok # SLOWPASS"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 1, out
    assert out =~ "late: SURVIVED, Result: 2 passed\n"
    assert out =~ "next: SURVIVED, Result: 2 passed\n"
  end

  @tag :tmp_dir
  test "reads a run's stderr after its stdout", ctx do
    list = mutants(ctx, [{"err", "x + 1", "x + 1 # STDERR"}])

    {out, code} = run(ctx, [ctx.target, list, "t.exs"])

    assert code == 1, out
    assert out =~ "+def rule(x), do: x + 1 # STDERR\n    output: out line\n    output: err line\n"
  end

  @tag :tmp_dir
  test "takes a limit from 1 to 86400, leading zeros allowed", ctx do
    list = mutants(ctx, [{"k", "x + 1", "BROKEN"}])

    for {limit, shown} <- [{"1", "1"}, {"05", "5"}, {"86400", "86400"}] do
      {out, code} = run(ctx, [ctx.target, list, "t.exs"], limit)
      assert {limit, code} == {limit, 0}, out
      assert out =~ "control: Result: 2 passed (limit #{shown} s a run)\n"
    end
  end

  @tag :tmp_dir
  test "takes 600 s a run when MUTATION_CHECK_TIMEOUT is unset or empty", ctx do
    list = mutants(ctx, [{"k", "x + 1", "BROKEN"}])
    env = env(ctx)

    # A port's env option unsets a variable given an empty value, so bash sets the empty one.
    for prefix <- ["", "MUTATION_CHECK_TIMEOUT= "] do
      shell = ~s(#{prefix}exec python3 -I "$0" "$@")
      args = ["-c", shell, @script, ctx.target, list, "t.exs"]
      {out, code} = System.cmd("bash", args, env: env, stderr_to_stdout: true)
      assert code == 0, out
      assert out =~ "control: Result: 2 passed (limit 600 s a run)\n"
    end
  end

  @tag :tmp_dir
  test "exits 2 and runs nothing on a limit that is not a whole number from 1 to 86400", ctx do
    list = mutants(ctx, [{"k", "x + 1", "BROKEN"}])
    huge = String.duplicate("9", 309)

    for limit <- ["0", "00", "86401", huge, "-5", "1.5", "abc", " 5", "5 "] do
      {out, code} = run(ctx, [ctx.target, list, "t.exs"], limit)
      assert {limit, code} == {limit, 2}, out
      assert out =~ "MUTATION_CHECK_TIMEOUT is not a whole number of seconds from 1 to 86400"
    end

    assert calls(ctx) == 0
  end
end
