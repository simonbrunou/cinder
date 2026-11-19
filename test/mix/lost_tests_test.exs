defmodule Cinder.LostTestsTest do
  # The guards against a run whose Result line leaves out tests it never ran (#1475). The child
  # VM tests run ExUnit in `elixir -e`, wired the way test/test_helper.exs wires this run, and
  # each has a control without the guard that shows the loss it fixes.
  use ExUnit.Case, async: true

  alias Cinder.LostTests
  alias Cinder.Test.ChildVM

  # A test module ExUnit never queues, for the never-started check. It is compiled here and
  # unloaded after the module's tests: loaded at the end of this run, it would trip that same
  # check in this run's own formatter.
  setup_all do
    [{module, _binary}] =
      Code.compile_string(
        """
        defmodule Cinder.LostTestsTest.Unqueued do
          use ExUnit.Case, register: false, parameterize: [%{kind: :a}, %{kind: :b}]

          test "one", do: :ok
          test "two", do: :ok
        end
        """,
        "test/mix/lost_tests_test.exs"
      )

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    %{unqueued: module.__ex_unit__()}
  end

  @unqueued Cinder.LostTestsTest.Unqueued

  describe "report/2" do
    test "is nil when every started instance finished", ctx do
      state =
        [{@unqueued, %{kind: :a}}, {@unqueued, %{kind: :b}}]
        |> started(ctx.unqueued)
        |> finish({@unqueued, %{kind: :a}}, ["test one", "test two"])
        |> finish({@unqueued, %{kind: :b}}, ["test one", "test two"])

      assert LostTests.report(state, [@unqueued]) == nil
    end

    test "names each test of an unfinished instance that sent no result", ctx do
      state =
        [{@unqueued, %{kind: :a}}, {@unqueued, %{kind: :b}}]
        |> started(ctx.unqueued)
        |> finish({@unqueued, %{kind: :a}}, ["test one", "test two"])
        |> finish_test({@unqueued, %{kind: :b}}, "test one")

      report = LostTests.report(state, [@unqueued])

      assert report =~
               "Cinder.LostTestsTest.Unqueued %{kind: :b} started and never finished, " <>
                 "with no result for 1 tests:\n    test two (test/mix/lost_tests_test.exs:"

      refute report =~ "test one ("
      refute report =~ "%{kind: :a} started"
      refute report =~ "never started"
    end

    test "names each loaded instance that never started", ctx do
      state =
        [{@unqueued, %{kind: :a}}]
        |> started(ctx.unqueued)
        |> finish_module({@unqueued, %{kind: :a}})

      report = LostTests.report(state, [@unqueued])

      assert report =~ "  Cinder.LostTestsTest.Unqueued %{kind: :b} never started (2 tests)"
      refute report =~ "%{kind: :a} never started"
      refute report =~ "never finished"
    end

    test "counts each start, so a second start of one instance needs a second finish", ctx do
      state =
        [{@unqueued, %{kind: :a}}, {@unqueued, %{kind: :a}}, {@unqueued, %{kind: :b}}]
        |> started(ctx.unqueued)
        |> finish_module({@unqueued, %{kind: :a}})
        |> finish_module({@unqueued, %{kind: :b}})

      assert LostTests.report(state, [@unqueued]) =~ "%{kind: :a} started and never finished"
    end

    # ExUnit reports an excluded test with the module's default parameters, whatever its instance.
    test "counts an excluded or skipped test as finished for every instance", ctx do
      for result <- [{:excluded, "due to x filter"}, {:skipped, "due to skip tag"}] do
        state =
          [{@unqueued, %{kind: :a}}, {@unqueued, %{kind: :b}}]
          |> started(ctx.unqueued)
          |> finish_test({@unqueued, %{}}, "test one", result)
          |> finish_test({@unqueued, %{}}, "test one", result)
          |> finish({@unqueued, %{kind: :a}}, ["test two"])

        report = LostTests.report(state, [@unqueued])

        assert report =~ "%{kind: :b} started and never finished, with no result for 1 tests:",
               inspect(result)

        assert report =~ "    test two (", inspect(result)
        refute report =~ "test one (", inspect(result)
      end
    end

    test "counts a test a failed setup_all made invalid for its own instance only", ctx do
      invalid = {:invalid, %{ctx.unqueued | name: @unqueued, parameters: %{kind: :b}}}

      state =
        [{@unqueued, %{}}, {@unqueued, %{kind: :b}}]
        |> started(ctx.unqueued)
        |> finish_test({@unqueued, %{}}, "test one", invalid)
        |> finish_test({@unqueued, %{}}, "test two", invalid)
        |> finish_module({@unqueued, %{kind: :b}})
        |> finish_test({@unqueued, %{}}, "test one")

      report = LostTests.report(state, [])

      assert report =~
               "  Cinder.LostTestsTest.Unqueued started and never finished, with no result for 1 tests:"

      assert report =~ "    test two ("
      refute report =~ "test one ("
      refute report =~ "%{kind: :b}"
    end

    test "names, under each of two unfinished instances, only the tests it did not finish", ctx do
      state =
        [{@unqueued, %{kind: :a}}, {@unqueued, %{kind: :b}}]
        |> started(ctx.unqueued)
        |> finish_test({@unqueued, %{kind: :a}}, "test two")
        |> finish_test({@unqueued, %{kind: :b}}, "test one")

      report = LostTests.report(state, [@unqueued])

      assert report =~
               "%{kind: :a} started and never finished, with no result for 1 tests:\n" <>
                 "    test one ("

      assert report =~
               "%{kind: :b} started and never finished, with no result for 1 tests:\n" <>
                 "    test two ("
    end

    test "counts only the tests --failed selected in an instance that never started", ctx do
      selected = MapSet.new([{@unqueued, :"test two"}])

      state =
        [{@unqueued, %{kind: :a}}]
        |> started(ctx.unqueued, only_test_ids: selected)
        |> finish({@unqueued, %{kind: :a}}, ["test two"])

      assert LostTests.report(state, [@unqueued]) =~ "%{kind: :b} never started (1 tests)"
    end

    test "names only the tests --failed selected", ctx do
      selected = MapSet.new([{@unqueued, :"test two"}])

      state =
        [{@unqueued, %{kind: :a}}, {@unqueued, %{kind: :b}}]
        |> started(ctx.unqueued, only_test_ids: selected)
        |> finish({@unqueued, %{kind: :a}}, ["test two"])

      report = LostTests.report(state, [@unqueued])

      assert report =~ "%{kind: :b} started and never finished, with no result for 1 tests:"
      assert report =~ "    test two ("
      refute report =~ "test one ("
    end
  end

  describe "the formatter" do
    test "reports nothing after --max-failures stopped the run", ctx do
      key = {__MODULE__, make_ref()}
      {:ok, state} = LostTests.init(report_key: key)

      {:noreply, state} =
        LostTests.handle_cast({:module_started, %{ctx.unqueued | parameters: %{}}}, state)

      {:noreply, cut} = LostTests.handle_cast(:max_failures_reached, state)

      LostTests.terminate(:normal, state)
      assert {text, nil} = :persistent_term.get(key, nil)
      assert text =~ "never finished"
      :persistent_term.erase(key)

      LostTests.terminate(:normal, cut)
      assert :persistent_term.get(key, nil) == nil
    end
  end

  describe "a child VM" do
    @tag :tmp_dir
    test "fails the run and names the tests when a module's runner dies", ctx do
      {output, status} = run_child(ctx.tmp_dir, :guarded, :kill)

      assert status == 1, output
      assert output =~ "Result: 1 passed"
      assert output =~ "  Killer started and never finished, with no result for"
      assert output =~ "    test kills its runner (nofile:"
      assert output =~ "  Queued never started (1 tests)"
      refute output =~ "Bystander"
      assert ExUnit.Filters.failure_info(Path.join(ctx.tmp_dir, "failures")) == :all
    end

    @tag :tmp_dir
    test "without the guard, the same run passes with the tests left out", ctx do
      {output, status} = run_child(ctx.tmp_dir, :unguarded, :kill)

      assert status == 0, output
      assert output =~ "Result: 1 passed"
      refute output =~ "Lost tests"
      # ExUnit wrote the manifest: no failure, so `mix test --failed` would run nothing.
      assert {files, ids} = ExUnit.Filters.failure_info(Path.join(ctx.tmp_dir, "failures"))
      assert {MapSet.size(files), MapSet.size(ids)} == {0, 0}
      assert File.exists?(Path.join(ctx.tmp_dir, "failures"))
    end

    @tag :tmp_dir
    test "a SIGTERM halts the run with status 143 before any Result line", ctx do
      {output, status} = run_child(ctx.tmp_dir, :guarded, :sigterm)

      assert status == 143, output
      assert output =~ "mix test: stopped by SIGTERM before the suite ended"
      refute output =~ "Result:"
    end

    @tag :tmp_dir
    test "without the guard, a SIGTERM ends the run with status 0", ctx do
      {output, status} = run_child(ctx.tmp_dir, :unguarded, :sigterm)

      assert status == 0, output
      refute output =~ "stopped by SIGTERM"
    end
  end

  describe "test/test_helper.exs" do
    test "wired this run's guards" do
      assert LostTests in ExUnit.configuration()[:formatters]
      assert (&LostTests.after_suite/1) in Application.fetch_env!(:ex_unit, :after_suite)
      assert sigterm_trapped?()
    end
  end

  # Starts `elixir -e` on this build's code with ExUnit wired as `guard` says, `:guarded` the way
  # test/test_helper.exs wires it, and runs the `case` fixtures. Returns its output and its exit
  # status. On `:sigterm` it sends SIGTERM to the child's VM, and to no other process, once a
  # test says it runs.
  defp run_child(dir, guard, case) do
    code = """
    formatters =
      if #{guard == :guarded}, do: [ExUnit.CLIFormatter, Cinder.LostTests], else: [ExUnit.CLIFormatter]

    ExUnit.start(
      autorun: false,
      formatters: formatters,
      seed: 0,
      max_cases: 1,
      failures_manifest_path: "failures"
    )

    if #{guard == :guarded} do
      {:ok, _} = Cinder.LostTests.halt_on_sigterm()
      ExUnit.after_suite(&Cinder.LostTests.after_suite/1)
    end

    IO.puts("os pid \#{System.pid()}")
    #{fixtures(case)}
    ExUnit.run()
    """

    ChildVM.run(code, dir, Path.dirname(:code.which(LostTests)), on_line: &on_line(case, &1, &2))
  end

  defp on_line(:sigterm, "running", lines) do
    {:ok, os_pid} = os_pid(lines)
    {_, 0} = System.cmd("kill", ["-TERM", os_pid])
  end

  defp on_line(_case, _line, _lines), do: :ok

  defp os_pid(lines) do
    Enum.find_value(lines, :error, fn
      "os pid " <> pid -> {:ok, pid}
      _ -> nil
    end)
  end

  # `Killer` and `Queued` share one async group, so ExUnit runs them in one process, `Killer`
  # first. `Bystander` runs in its own.
  defp fixtures(:kill) do
    """
    defmodule Killer do
      use ExUnit.Case, async: true, group: :lost

      test "kills its runner" do
        {:parent, runner} = Process.info(self(), :parent)
        Process.exit(runner, :kill)
      end
    end

    defmodule Queued do
      use ExUnit.Case, async: true, group: :lost
      test "never runs", do: :ok
    end

    defmodule Bystander do
      use ExUnit.Case, async: true
      test "runs", do: :ok
    end
    """
  end

  # The test sleeps longer than the parent waits for the child's exit, and two modules wait in
  # the sync queue behind it, as on #1445's run.
  defp fixtures(:sigterm) do
    for n <- 1..3, into: "" do
      """
      defmodule Waits#{n} do
        use ExUnit.Case
        setup_all do: :ok

        test "waits" do
          IO.puts("running")
          Process.sleep(#{2 * ChildVM.timeout_ms()})
        end
      end
      """
    end
  end

  defp started(instances, unqueued, opts \\ []) do
    {:ok, state} = LostTests.init([report_key: {__MODULE__, make_ref()}] ++ opts)

    Enum.reduce(instances, state, fn {name, params}, state ->
      module = %{unqueued | name: name, parameters: params}
      {:noreply, state} = LostTests.handle_cast({:module_started, module}, state)
      state
    end)
  end

  defp finish(state, instance, names) do
    state = Enum.reduce(names, state, &finish_test(&2, instance, &1))
    finish_module(state, instance)
  end

  defp finish_test(state, {name, params}, test_name, result \\ nil) do
    test = %ExUnit.Test{
      module: name,
      parameters: params,
      name: String.to_atom(test_name),
      state: result
    }

    {:noreply, state} = LostTests.handle_cast({:test_finished, test}, state)
    state
  end

  defp finish_module(state, {name, params}) do
    module = %ExUnit.TestModule{name: name, parameters: params}
    {:noreply, state} = LostTests.handle_cast({:module_finished, module}, state)
    state
  end

  defp sigterm_trapped? do
    {System.SignalHandler, {:sigterm, LostTests}} in :gen_event.which_handlers(:erl_signal_server)
  end
end

defmodule Cinder.LostTestsPartitionsTest do
  # Not async: the test takes this VM's SIGTERM trap away while it runs, and ExUnit runs no other
  # module beside a sync one.
  use ExUnit.Case, async: false

  alias Cinder.LostTests
  alias Cinder.TestPartitions

  @tag :tmp_dir
  test "the parent of a partitioned run traps SIGTERM once its partitions start", ctx do
    :ok = System.untrap_signal(:sigterm, LostTests)
    on_exit(fn -> LostTests.halt_on_sigterm() end)
    build = Path.join([ctx.tmp_dir, "_build", "test"])
    File.mkdir_p!(build)
    me = self()

    ExUnit.CaptureIO.capture_io(fn ->
      :ok =
        TestPartitions.run([], "2", fn _args -> flunk("ran one process") end,
          build: build,
          start: fn partition, _total, _args ->
            send(me, {:trapped, partition.n, trapped?()})
            File.write!(partition.log, "Result: 1 passed\n")
            0
          end
        )
    end)

    assert_receive {:trapped, 1, true}
    assert_receive {:trapped, 2, true}
  end

  defp trapped? do
    {System.SignalHandler, {:sigterm, LostTests}} in :gen_event.which_handlers(:erl_signal_server)
  end
end
