defmodule Cinder.TestPartitionsTest do
  # The runner a bare `mix test` hands the suite to after its gates (#1473). Every test but the
  # last describe passes a `:start` stub, so no test here starts a suite inside the suite.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Cinder.TestPartitions
  alias Cinder.TestPartitions.Partition

  describe "plan/2" do
    test "a bare run splits into 4 partitions when CINDER_TEST_PARTITIONS is unset" do
      assert TestPartitions.plan([], nil) == {:partitions, 4}
    end

    test "CINDER_TEST_PARTITIONS sets the count" do
      assert TestPartitions.plan([], "3") == {:partitions, 3}
    end

    test "CINDER_TEST_PARTITIONS=1 runs one process" do
      assert TestPartitions.plan([], "1") == :one_process
    end

    test "a path argument runs one process" do
      for args <- [["test/mix"], ["test/mix/aliases_test.exs:9"], ["--seed", "0", "test/mix"]] do
        assert TestPartitions.plan(args, nil) == :one_process, inspect(args)
      end
    end

    test "each pass-through switch keeps the partitions" do
      for args <- [
            ["--warnings-as-errors"],
            ["--all-warnings"],
            ["--seed", "0"],
            ["--exclude", "slow", "--include", "slow"],
            ["--trace"],
            ["--timeout", "1000"],
            ["--max-cases", "2"],
            ["--color"],
            ["--no-color"],
            ["--slowest", "5"],
            ["--slowest-modules", "5"],
            ["--dry-run"],
            ["--raise"]
          ] do
        assert TestPartitions.plan(args, nil) == {:partitions, 4}, inspect(args)
      end
    end

    test "a switch that cannot work across partitions runs one process" do
      for args <- [
            ["--failed"],
            ["--stale"],
            ["--partitions", "2"],
            ["--cover"],
            ["--export-coverage", "x"],
            ["--max-failures", "1"],
            ["--listen-on-stdin"],
            ["--breakpoints"],
            ["-b"],
            ["--repeat-until-failure", "3"],
            ["--force"],
            ["--formatter", "ExUnit.CLIFormatter"],
            ["--exit-status", "0"],
            # Mix fails a partition these leave with no test (`no test was executed`).
            ["--only", "gettext_extract"],
            ["--name-pattern", "mix"],
            ["-n", "mix"],
            ["--no-start"],
            ["--warnings-as-errors", "--failed"]
          ] do
        assert TestPartitions.plan(args, nil) == :one_process, inspect(args)
      end
    end

    test "a switch Mix does not know, or a switch value that does not parse, runs one process" do
      for args <- [["--frobnicate"], ["--seed", "zero"], ["--max-cases"]] do
        assert TestPartitions.plan(args, nil) == :one_process, inspect(args)
      end
    end

    test "a CINDER_TEST_PARTITIONS that is not a positive integer stops the run" do
      for value <- ["0", "-2", "four", "4x", ""] do
        message =
          "mix test: CINDER_TEST_PARTITIONS must be a positive integer, got: #{inspect(value)}"

        assert_raise Mix.Error, message, fn -> TestPartitions.plan([], value) end
        assert_raise Mix.Error, message, fn -> TestPartitions.plan(["test/mix"], value) end
      end
    end
  end

  describe "run/4 in one process" do
    test "calls the alias's own ExUnit step with the arguments as given" do
      for {args, count} <- [{["test/mix"], nil}, {[], "1"}, {["--failed"], "4"}] do
        assert TestPartitions.run(args, count, &{:ran, &1}, start: &unexpected_start/3) ==
                 {:ran, args}
      end
    end
  end

  describe "run/4 in partitions" do
    @describetag :tmp_dir

    test "starts each partition once, with its number, the count and the arguments", ctx do
      build = build!(ctx.tmp_dir)
      me = self()

      output =
        capture_io(fn ->
          assert :ok =
                   TestPartitions.run(["--seed", "0"], "3", &unexpected_one_process/1,
                     build: build,
                     start: fn partition, total, args ->
                       send(me, {:started, partition.n, total, args, partition.build})
                       File.write!(partition.log, "Result: #{partition.n} passed\n")
                       0
                     end
                   )
        end)

      started =
        for _ <- 1..3 do
          assert_receive {:started, n, 3, ["--seed", "0"], dir}
          {n, dir}
        end

      refute_received {:started, _, _, _, _}
      assert started |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [1, 2, 3]

      for {n, dir} <- started do
        assert dir == Path.join([ctx.tmp_dir, "_build", "test-partitions", "#{n}"])
      end

      assert output =~ "mix test: partition 1 of 3: exit 0, Result: 1 passed\n"
      assert output =~ "mix test: partition 2 of 3: exit 0, Result: 2 passed\n"
      assert output =~ "mix test: partition 3 of 3: exit 0, Result: 3 passed\n"

      assert output
             |> String.trim_trailing()
             |> String.ends_with?("mix test: 3 of 3 partitions passed")
    end

    test "starts every partition at once", ctx do
      build = build!(ctx.tmp_dir)
      room = start_supervised!({Agent, fn -> [] end})

      # Each partition waits until all of them have started: run one at a time, the first waits
      # out the 2 s and fails.
      start = fn partition, total, _args ->
        File.write!(partition.log, "Result: 1 passed\n")
        me = self()
        started = Agent.get_and_update(room, &{[me | &1], [me | &1]})
        if length(started) == total, do: Enum.each(started, &send(&1, :all_started))

        receive do
          :all_started -> 0
        after
          2_000 -> 1
        end
      end

      capture_io(fn ->
        assert :ok =
                 TestPartitions.run([], "3", &unexpected_one_process/1,
                   build: build,
                   start: start
                 )
      end)
    end

    test "gives each partition a fresh copy of the build folder", ctx do
      build = build!(ctx.tmp_dir)
      stale = Path.join([ctx.tmp_dir, "_build", "test-partitions", "2", "stale.beam"])
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "old")
      me = self()

      capture_io(fn ->
        TestPartitions.run([], "2", &unexpected_one_process/1,
          build: build,
          start: fn partition, _total, _args ->
            beam = File.read(Path.join(partition.build, "lib/cinder/ebin/Elixir.Cinder.beam"))

            send(
              me,
              {:copy, partition.n, beam, File.exists?(Path.join(partition.build, "stale.beam"))}
            )

            File.write!(partition.log, "Result: 1 passed\n")
            0
          end
        )
      end)

      assert_receive {:copy, 1, {:ok, "beam"}, false}
      assert_receive {:copy, 2, {:ok, "beam"}, false}
    end

    test "a failed partition stops the run after every partition ends, its output printed last",
         ctx do
      build = build!(ctx.tmp_dir)
      room = start_supervised!({Agent, fn -> nil end})

      start = fn partition, _total, _args ->
        case partition.n do
          1 ->
            File.write!(partition.log, "  1) test broken (Cinder.FooTest)\nResult: 4/5 passed\n")
            me = self()
            Agent.update(room, fn _ -> me end)
            2

          2 ->
            # Ends once partition 1's process is gone, so after its result reached the run: a run
            # that printed partition 1 as it ended prints it first.
            ref = Process.monitor(await_pid(room))

            receive do
              {:DOWN, ^ref, :process, _, _} -> :ok
            end

            File.write!(partition.log, "partition two output\nResult: 7 passed\n")
            0
        end
      end

      output =
        capture_io(fn ->
          assert_raise Mix.Error, "mix test: 1 of 2 partitions failed: 1", fn ->
            TestPartitions.run([], "2", &unexpected_one_process/1, build: build, start: start)
          end
        end)

      {two, _} = :binary.match(output, "partition two output")
      {one, _} = :binary.match(output, "1) test broken (Cinder.FooTest)")
      assert two < one
      assert output =~ "==> mix test: partition 1 of 2 exited 2\n"
      assert output =~ "mix test: partition 1 of 2: exit 2, Result: 4/5 passed\n"
      assert output =~ "mix test: partition 2 of 2: exit 0, Result: 7 passed\n"
    end

    test "a partition fails on its exit status, whatever its Result: line counts", ctx do
      build = build!(ctx.tmp_dir)

      # ci.md "Test-file warning": the run aborts after a Result: line that counts no failure.
      start = fn partition, _total, _args ->
        File.write!(partition.log, "Result: 3 passed\nERROR! Test suite aborted\n")
        if partition.n == 2, do: 1, else: 0
      end

      output =
        capture_io(fn ->
          assert_raise Mix.Error, "mix test: 1 of 2 partitions failed: 2", fn ->
            TestPartitions.run([], "2", &unexpected_one_process/1, build: build, start: start)
          end
        end)

      assert output =~ "mix test: partition 2 of 2: exit 1, Result: 3 passed\n"
    end

    test "a partition with no Result: line says so in the summary", ctx do
      build = build!(ctx.tmp_dir)

      start = fn partition, _total, _args ->
        File.write!(partition.log, "** (CompileError) test/foo_test.exs:1\n")
        1
      end

      output =
        capture_io(fn ->
          assert_raise Mix.Error, "mix test: 2 of 2 partitions failed: 1, 2", fn ->
            TestPartitions.run([], "2", &unexpected_one_process/1, build: build, start: start)
          end
        end)

      assert output =~ "mix test: partition 1 of 2: exit 1, ExUnit printed no result line\n"
      assert output =~ "mix test: partition 2 of 2: exit 1, ExUnit printed no result line\n"
      assert output =~ "** (CompileError) test/foo_test.exs:1\n"
    end

    test "folds a failed partition's failures into the build folder's manifest", ctx do
      build = build!(ctx.tmp_dir)
      base = Path.join(build, "lib/cinder/.mix/.mix_test_failures")

      start = fn partition, _total, _args ->
        manifest = Path.join(partition.build, "lib/cinder/.mix/.mix_test_failures")
        if partition.n == 2, do: write_manifest!(manifest, {1, %{{B, :"test b"} => "test/b.exs"}})
        File.write!(partition.log, "Result: 1/2 passed\n")
        if partition.n == 2, do: 2, else: 0
      end

      capture_io(fn ->
        assert_raise Mix.Error, "mix test: 1 of 2 partitions failed: 2", fn ->
          TestPartitions.run([], "2", &unexpected_one_process/1, build: build, start: start)
        end
      end)

      assert read_manifest(base) == {1, %{{B, :"test b"} => "test/b.exs"}}
    end

    test "folds each partition's failures into the build folder's manifest", ctx do
      build = build!(ctx.tmp_dir)
      base = Path.join(build, "lib/cinder/.mix/.mix_test_failures")
      write_manifest!(base, {1, %{{A, :"test a"} => "test/a_test.exs"}})

      start = fn partition, _total, _args ->
        manifest = Path.join(partition.build, "lib/cinder/.mix/.mix_test_failures")

        case partition.n do
          # Partition 1 ran A's file: A passed, B failed.
          1 -> write_manifest!(manifest, {1, %{{B, :"test b"} => "test/b_test.exs"}})
          # Partition 2 ran neither file, so it kept the copy's entry for A.
          2 -> :ok
        end

        File.write!(partition.log, "Result: 1 passed\n")
        0
      end

      capture_io(fn ->
        TestPartitions.run([], "2", &unexpected_one_process/1, build: build, start: start)
      end)

      assert read_manifest(base) == {1, %{{B, :"test b"} => "test/b_test.exs"}}
    end
  end

  describe "merge_failures!/2" do
    @describetag :tmp_dir

    test "drops what a partition passed and adds what one failed", ctx do
      a = {{A, :"test a"}, "test/a_test.exs"}
      b = {{B, :"test b"}, "test/b_test.exs"}
      c = {{C, :"test c"}, "test/c_test.exs"}
      d = {{D, :"test d"}, "test/d_test.exs"}

      # A and B failed before. A passes in partition 1, B fails again in partition 2, C fails in
      # partition 2, D fails in partition 3.
      base = manifest!(ctx.tmp_dir, "base", {1, Map.new([a, b])})
      one = manifest!(ctx.tmp_dir, "1", {1, Map.new([b])})
      two = manifest!(ctx.tmp_dir, "2", {1, Map.new([a, b, c])})
      three = manifest!(ctx.tmp_dir, "3", {1, Map.new([a, b, d])})

      assert :ok = TestPartitions.merge_failures!(base, [one, two, three])
      assert read_manifest(base) == {1, Map.new([b, c, d])}
    end

    test "a partition that marked its whole suite failed marks the merged one failed", ctx do
      base = manifest!(ctx.tmp_dir, "base", {1, %{}})
      one = manifest!(ctx.tmp_dir, "1", {1, %{{A, :"test a"} => "test/a_test.exs"}})
      two = manifest!(ctx.tmp_dir, "2", {1, :all})

      TestPartitions.merge_failures!(base, [one, two])
      assert read_manifest(base) == {1, :all}
    end

    test "a whole-suite failure before the run counts as no failure, as ExUnit reads it", ctx do
      base = manifest!(ctx.tmp_dir, "base", {1, :all})
      one = manifest!(ctx.tmp_dir, "1", {1, %{{A, :"test a"} => "test/a_test.exs"}})
      two = manifest!(ctx.tmp_dir, "2", {1, %{}})

      TestPartitions.merge_failures!(base, [one, two])
      assert read_manifest(base) == {1, %{{A, :"test a"} => "test/a_test.exs"}}
    end

    test "a missing manifest holds no failure", ctx do
      base = Path.join(ctx.tmp_dir, "base/.mix_test_failures")
      one = manifest!(ctx.tmp_dir, "1", {1, %{{A, :"test a"} => "test/a_test.exs"}})

      TestPartitions.merge_failures!(base, [one, Path.join(ctx.tmp_dir, "2/.mix_test_failures")])
      assert read_manifest(base) == {1, %{{A, :"test a"} => "test/a_test.exs"}}
    end

    test "reads the manifest ExUnit itself writes", ctx do
      base = Path.join(ctx.tmp_dir, "base/.mix_test_failures")
      one = Path.join(ctx.tmp_dir, "1/.mix_test_failures")
      # A file that exists: write!/2 drops a test whose file is gone.
      file = "test/mix/test_partitions_test.exs"
      test = %ExUnit.Test{module: A, name: :"test a", state: {:failed, []}, tags: %{file: file}}

      ExUnit.FailuresManifest.new()
      |> ExUnit.FailuresManifest.put_test(test)
      |> ExUnit.FailuresManifest.write!(one)

      TestPartitions.merge_failures!(base, [one])
      assert ExUnit.FailuresManifest.read(base) == %{{A, :"test a"} => file}
    end

    test "a manifest of another shape stops the run and names the file", ctx do
      base = manifest!(ctx.tmp_dir, "base", {1, %{}})

      for {name, binary} <- [
            {"2", :erlang.term_to_binary({2, %{}})},
            {"3", :erlang.term_to_binary(%{})},
            {"4", "not a term"}
          ] do
        file = Path.join([ctx.tmp_dir, name, ".mix_test_failures"])
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, binary)

        assert_raise Mix.Error,
                     "mix test: #{file} is not a version 1 ExUnit failures manifest",
                     fn -> TestPartitions.merge_failures!(base, [file]) end
      end
    end
  end

  describe "start/4" do
    @describetag :tmp_dir

    test "runs mix test.unchecked with the partition's number, build folder and env", ctx do
      mix = Path.join(ctx.tmp_dir, "mix")

      File.write!(mix, """
      #!/bin/sh
      echo "args: $*"
      echo "env: $MIX_ENV $MIX_TEST_PARTITION $MIX_BUILD_PATH"
      echo "to stderr" >&2
      exit 3
      """)

      File.chmod!(mix, 0o755)
      log = Path.join(ctx.tmp_dir, "2.log")
      partition = %Partition{n: 2, build: Path.join(ctx.tmp_dir, "build/2"), log: log}

      assert TestPartitions.start(partition, 4, ["--seed", "0"], mix) == 3

      assert File.read!(log) ==
               "args: test.unchecked --partitions 4 --seed 0\n" <>
                 "env: test 2 #{partition.build}\n" <> "to stderr\n"
    end
  end

  # The pid partition 1 left in `room`, once it is there.
  defp await_pid(room) do
    case Agent.get(room, & &1) do
      nil -> await_pid(room)
      pid -> pid
    end
  end

  defp unexpected_start(_partition, _total, _args), do: flunk("started a partition")
  defp unexpected_one_process(_args), do: flunk("ran one process")

  # A build folder as the gates leave it, with one compiled module.
  defp build!(dir) do
    build = Path.join([dir, "_build", "test"])
    beam = Path.join(build, "lib/cinder/ebin/Elixir.Cinder.beam")
    File.mkdir_p!(Path.dirname(beam))
    File.write!(beam, "beam")
    build
  end

  defp manifest!(dir, name, term) do
    file = Path.join([dir, name, ".mix_test_failures"])
    write_manifest!(file, term)
    file
  end

  defp write_manifest!(file, term) do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, :erlang.term_to_binary(term))
  end

  defp read_manifest(file), do: file |> File.read!() |> :erlang.binary_to_term()
end
