defmodule Cinder.MutationFailuresTest do
  # The formatter that records each failure block for `scripts/mutation-check` (#1532). Each
  # child VM runs ExUnit in `elixir -e`, with the formatters test/test_helper.exs lists.
  use ExUnit.Case, async: true

  alias Cinder.MutationFailures

  @boot_ms 60_000

  describe "a child VM" do
    @tag :tmp_dir
    test "writes the block of each failed test and setup_all, and nothing a passing test prints",
         ctx do
      record = Path.join(ctx.tmp_dir, "failures.txt")
      {output, status} = run_child(ctx.tmp_dir, record, :failures)

      assert status == 2, output
      # The passing test printed a header-shaped line on stdout, and ExUnit printed every block.
      assert output =~ "  9) test fake (Fake.Mod)\n     test/fake.exs:1\n"
      # ExUnit.CLIFormatter gives the failed setup_all the number of the failure before it; the
      # record numbers it 3, below.
      assert output =~ "  2) BrokenSetup: failure on setup_all callback"
      text = File.read!(record)

      assert text =~
               ~r/\A  1\) test a two-line message \(Multi\)\n     fixtures.exs:\d+\n     first line\n     second line names the cause\n     code: assert false, "first line\\nsecond line names the cause"\n     stacktrace:\n/

      assert text =~
               ~r/\n  2\) test fails twice \(Twice\)\n     fixtures.exs:\d+\n\n     Failure #1\n     Assertion with > failed\n     code:  assert n > 2\n     left:  1\n     right: 2\n.*\n     Failure #2\n     Assertion with > failed, both sides are exactly equal\n     code: assert n > 2\n     left: 2\n/s

      assert text =~
               ~r/\n  3\) BrokenSetup: failure on setup_all callback, all tests have been invalidated\n     \*\* \(RuntimeError\) setup broke\n     stacktrace:\n.*\n\z/s

      refute text =~ "fake"
      refute text =~ "passes"
      # No colour, though the child's CLIFormatter prints in colour.
      assert output =~ "\e["
      refute text =~ "\e["
    end

    @tag :tmp_dir
    test "writes nothing when every test passes", ctx do
      record = Path.join(ctx.tmp_dir, "failures.txt")
      {output, status} = run_child(ctx.tmp_dir, record, :passing)

      assert status == 0, output
      assert output =~ "  9) test fake (Fake.Mod)"
      refute File.exists?(record)
    end

    @tag :tmp_dir
    test "writes nothing when the env var is unset or empty", ctx do
      for value <- [nil, ""] do
        {output, status} = run_child(ctx.tmp_dir, value, :failures)

        assert status == 2, output
        assert output =~ "1) test a two-line message (Multi)"
        assert File.ls!(ctx.tmp_dir) == ["fixtures.exs"]
        refute output =~ "cannot write"
        refute output =~ "terminating"
      end
    end

    @tag :tmp_dir
    test "a path it cannot write gets one line on stderr, and the run ends as it would", ctx do
      {output, status} = run_child(ctx.tmp_dir, ctx.tmp_dir, :failures, "stderr.log")
      stderr = File.read!(Path.join(ctx.tmp_dir, "stderr.log"))

      assert status == 2, output
      assert output =~ "Result: 1/3 passed, 1 invalid"

      assert stderr ==
               "Cinder.MutationFailures: cannot write #{ctx.tmp_dir}: " <>
                 "illegal operation on a directory\n"

      refute output =~ "cannot write"
      refute output =~ "terminating"
    end
  end

  describe "test/test_helper.exs" do
    test "lists the formatter in this run" do
      assert MutationFailures in ExUnit.configuration()[:formatters]
    end
  end

  # Starts `elixir -e` on this build's code with the formatters test/test_helper.exs lists, the
  # env var set to `record` (unset when nil), and runs the `case` fixtures in `dir`, from a file
  # there so that ExUnit prints their `code:` lines. Returns its output and its exit status. Its
  # stderr joins the output, or goes to the file `stderr` names in `dir`.
  defp run_child(dir, record, case, stderr \\ "") do
    File.write!(Path.join(dir, "fixtures.exs"), fixtures(case))

    code = """
    ExUnit.start(
      autorun: false,
      colors: [enabled: true],
      formatters: [ExUnit.CLIFormatter, Cinder.LostTests, Cinder.MutationFailures],
      seed: 0,
      max_cases: 1
    )

    Code.require_file("fixtures.exs")
    %{failures: failures} = ExUnit.run()
    System.halt(if failures > 0, do: 2, else: 0)
    """

    # `sh` sets the env var, since a port's `env:` option unsets one given an empty value.
    var = MutationFailures.env_var()

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :stderr_to_stdout,
        line: 4096,
        cd: dir,
        args: [
          "-c",
          ~s(if [ "$3" = set ]; then export #{var}="$4"; else unset #{var}; fi; ) <>
            ~s(if [ -n "$5" ]; then exec 2> "$5"; fi; "$0" -pa "$1" -e "$2"; echo "exit $?"),
          System.find_executable("elixir"),
          Path.dirname(:code.which(MutationFailures)),
          code,
          if(record, do: "set", else: "unset"),
          record || "",
          stderr
        ]
      ])

    collect(port, [])
  end

  defp collect(port, lines) do
    receive do
      {^port, {:data, {:eol, "exit " <> status}}} ->
        {lines |> Enum.reverse() |> Enum.join("\n"), String.to_integer(status)}

      {^port, {:data, {_eol, line}}} ->
        collect(port, [line | lines])
    after
      @boot_ms ->
        flunk(
          "the child printed no exit status within #{@boot_ms} ms:\n" <> Enum.join(lines, "\n")
        )
    end
  end

  @passing """
  defmodule Passing do
    use ExUnit.Case

    test "passes" do
      IO.puts("  9) test fake (Fake.Mod)\\n     test/fake.exs:1\\n     Assertion with == failed")
    end
  end
  """

  defp fixtures(:passing), do: @passing

  defp fixtures(:failures) do
    @passing <>
      """
      defmodule Multi do
        use ExUnit.Case

        test "a two-line message" do
          assert false, "first line\\nsecond line names the cause"
        end
      end

      defmodule Twice do
        use ExUnit.Case

        test "fails twice" do
          errors =
            for n <- [1, 2] do
              try do
                assert n > 2
              rescue
                error -> {:error, error, __STACKTRACE__}
              end
            end

          raise ExUnit.MultiError, errors: errors
        end
      end

      defmodule BrokenSetup do
        use ExUnit.Case

        setup_all do
          if :rand.uniform() > 0, do: raise("setup broke")
          :ok
        end

        test "never runs", do: :ok
      end
      """
  end
end
