defmodule Cinder.MixAliasesTest do
  # `mix test` is the only "done" gate, and `mix test.unchecked` is the same run without its
  # gates, for red runs and mutation checks (docs/agents/testing.md). What each alias does was
  # checked by hand on #851; these tests pin the definitions that behaviour rests on.
  use ExUnit.Case, async: true

  test "the test alias runs its three gates before ExUnit" do
    assert aliases()[:test] |> Enum.take(3) == [
             "compile --warnings-as-errors",
             "format --check-formatted",
             "credo --strict"
           ]
  end

  # A closure hides its body and arguments, so the next two tests read mix.exs's source.
  test "both aliases end on the path guard, the test alias with --warnings-as-errors" do
    aliases = mix_exs_def(:aliases)

    assert Macro.to_string(List.last(aliases[:test])) ==
             ~S'&run_suite(["--warnings-as-errors" | &1])'

    assert Macro.to_string(List.last(aliases[:"test.unchecked"])) == "&run_test_paths/1"
  end

  # #1473: the partitions get the alias's arguments, --warnings-as-errors included, and one
  # process runs the path guard.
  test "the test alias hands its arguments and CINDER_TEST_PARTITIONS to the partition runner" do
    assert Macro.to_string(mix_exs_def(:run_suite)) ==
             ~S'Cinder.TestPartitions.run(args, System.get_env("CINDER_TEST_PARTITIONS"), &run_test_paths/1)'
  end

  test "the path guard calls the ExUnit task itself" do
    # `Mix.Task.run("test", args)` would resolve to the gated alias, gates included.
    {_ast, calls} =
      Macro.prewalk(mix_exs_def(:run_test_paths), [], fn
        {{:., _, [{:__aliases__, _, mod}, fun]}, _, args} = node, acc ->
          {node, [{Module.concat(mod), fun, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    assert {Mix.Tasks.Test, :run, 1} in calls
    refute Enum.any?(calls, &match?({Mix.Task, _, _}, &1))
  end

  test "test.unchecked runs no gate" do
    entries = aliases()[:"test.unchecked"]
    tasks = for entry <- entries, is_binary(entry), do: entry |> OptionParser.split() |> hd()

    # A "test" entry would resolve to the gated alias, gates included.
    assert tasks == ["ecto.create", "ecto.migrate"]
    assert is_function(List.last(entries), 1)
  end

  describe "the path guard both aliases end on (#786)" do
    # Mix fails on given paths only when none matches, so a mistyped file among real ones ran
    # nothing for it and the run exited 0.
    test "names each test path no file or directory matches" do
      assert Cinder.MixProject.missing_test_paths([
               "test/mix/aliases_test.exs",
               "test/cinder/no_such_test.exs",
               "test/cinder/no_such_test.exs:12",
               "test/cinder/no_such_test.exs:12:30",
               "test/no_such_dir",
               "./test/no_such_test.exs",
               Path.expand("test/no_such_abs_test.exs")
             ]) == [
               "test/cinder/no_such_test.exs",
               "test/cinder/no_such_test.exs:12",
               "test/cinder/no_such_test.exs:12:30",
               "test/no_such_dir",
               "./test/no_such_test.exs",
               Path.expand("test/no_such_abs_test.exs")
             ]
    end

    test "passes real files, lines and directories, switches, and paths outside test/" do
      assert Cinder.MixProject.missing_test_paths([
               "test/mix/aliases_test.exs",
               "test/mix/aliases_test.exs:9",
               "./test/mix/aliases_test.exs:9:20",
               Path.expand("test/mix"),
               "test/mix",
               "test",
               "--seed",
               "1",
               "--only",
               "integration",
               "lib/no_such_file.ex"
             ]) == []
    end

    test "each alias raises on a missing path before ExUnit runs" do
      for name <- [:test, :"test.unchecked"] do
        run = List.last(aliases()[name])

        assert_raise Mix.Error, "mix test: no such test path: test/cinder/no_such_test.exs", fn ->
          run.(["test/mix/aliases_test.exs", "test/cinder/no_such_test.exs"])
        end
      end
    end
  end

  test "test.unchecked runs in the test env without MIX_ENV" do
    assert Mix.Project.get!().cli()[:preferred_envs][:"test.unchecked"] == :test
  end

  defp aliases, do: Mix.Project.config()[:aliases]

  # The body of the one `defp name` in mix.exs, as quoted source.
  defp mix_exs_def(name) do
    {:ok, ast} = "mix.exs" |> File.read!() |> Code.string_to_quoted()

    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {:defp, _, [{^name, _, _}, [do: body]]} = node, acc -> {node, [body | acc]}
        node, acc -> {node, acc}
      end)

    [body] = bodies
    body
  end
end
