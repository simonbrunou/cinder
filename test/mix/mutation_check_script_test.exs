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
    *SYNTAX*) echo "** (SyntaxError) invalid syntax"; exit 1 ;;
    *ZERO*) printf '\\nResult: 0 tests, 4 excluded\\n'; exit 1 ;;
    *NONE*) printf '\\nResult: 0 tests\\n' ;;
    *PASSEXIT1*) printf '\\nResult: 2 passed\\n'; exit 1 ;;
    *VANISH*) rm "$0"; printf '\\nResult: 2 passed\\n' ;;
    *SWAPDIR*) rm "$MUT_TARGET"; mkdir "$MUT_TARGET"; printf '\\nResult: 2 passed\\n' ;;
    *CTRLSWAP*) rm "$MUT_TARGET"; mkdir "$MUT_TARGET"; printf '\\nResult: 1/2 passed\\n'; exit 2 ;;
    *INVALID*) printf '\\nResult: 1 passed, 2 invalid\\n'; exit 2 ;;
    *BROKEN*) printf '\\n  1) test x\\nResult: 1/2 passed\\nFailed: 1 test\\n'; exit 2 ;;
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
