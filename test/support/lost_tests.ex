defmodule Cinder.LostTests do
  @moduledoc """
  Fails a test run in which ExUnit never reported some of the tests it loaded (#1475).

  ExUnit runs each test module, or each group of async modules, in a process it monitors
  (`ExUnit.Runner.spawn_modules/4`, Elixir 1.20.5). When that process exits abnormally, the
  runner only drops it from its running set (`wait_until_available/2`). The module's tests that
  had not finished, and the modules queued after it in that process, send no event. The
  `Result:` line then counts only the tests that finished, and the run exits 0.

  A SIGTERM to the test VM loses tests that way. The VM stops its applications, ExUnit's own
  among them, so the module running crashes in `ExUnit.OnExitHandler.run/2` on ExUnit's ETS
  table, and the runner ends the suite with what had finished. On #1445 a run whose 600 s tool
  limit came during its sync modules logged that crash and then `Result: 7213 passed`, for a tree
  of 7243 tests.

  `test/test_helper.exs` sets two guards:

    * `halt_on_sigterm/0` halts the VM with status 143 on a SIGTERM that comes after
      `test/test_helper.exs` ran, after one line on stderr that says so. During the suite, that
      is before ExUnit can print a `Result:` line. That covers a one-process run and each
      partition of a bare `mix test`, and `Cinder.TestPartitions` traps it in the run that starts
      the partitions too. A SIGTERM before that, during the compile or the database setup, stops
      the VM with status 0 before any test ran. A SIGTERM to the whole process group, as
      `kill -- -<pgid>` sends, also stops `erl_child_setup`, and the VM then exits at once with
      no summary.
    * This module, listed as a formatter after `ExUnit.CLIFormatter`, records each module
      instance (a module, or one entry of its `parameterize:` list) that started and finished,
      and each test that finished. `after_suite/1` runs after ExUnit has stopped the formatters,
      so every event has been handled. When an instance started and never finished, or a loaded
      module's instance never started, it prints them, naming each test of an unfinished
      instance that sent no result. It then marks the whole suite failed in ExUnit's failures
      manifest (`ExUnit.Filters.fail_all!/1`), so `mix test --failed` runs every test again, and
      makes the run exit 1 with `System.at_exit/1`, where a failing test makes Mix exit 2 (its
      `--exit-status` default). It does not raise: ExUnit calls `after_suite` callbacks in the
      task `ExUnit.async_run/0` starts, so a raise would kill the `mix test` process before Mix
      can mark the manifest.

  It checks nothing when ExUnit stopped the run at `--max-failures`: the runner then starts no
  further module on purpose.

  What it cannot see:

    * a run whose `--formatter` switch replaces the formatters `test/test_helper.exs` lists;
    * a module that uses `ExUnit.Case` with `register: false`, which loads without ExUnit queuing
      it: the check would name it as never started;
    * tests that never load, such as tests a `for` generates from data that changes between runs;
    * a crash of this formatter, which ExUnit's event manager does not report: `after_suite/1`
      then finds no report and checks nothing;
    * a lost test under `--repeat-until-failure`, which does not stop the repeats, since ExUnit
      counts no failure.
  """

  use GenServer

  @report_key {__MODULE__, :report}
  @sigterm_status 143

  @doc """
  Traps SIGTERM in this VM: prints one line on stderr and halts with status #{@sigterm_status}.
  """
  @spec halt_on_sigterm() :: {:ok, term()} | {:error, term()}
  def halt_on_sigterm do
    System.trap_signal(:sigterm, __MODULE__, fn ->
      IO.puts(
        :stderr,
        "\nmix test: stopped by SIGTERM before the suite ended, so it halts with status " <>
          "#{@sigterm_status} and counts no test (#1475)"
      )

      System.halt(@sigterm_status)
    end)
  end

  @doc """
  The `ExUnit.after_suite/1` callback. When the formatter found lost tests, it prints them, marks
  the whole suite failed in the failures manifest and makes the run exit 1.
  """
  @spec after_suite(map()) :: :ok
  def after_suite(_result) do
    case :persistent_term.get(@report_key, nil) do
      nil ->
        :ok

      {text, manifest} ->
        :persistent_term.erase(@report_key)
        IO.puts(text)
        if manifest, do: ExUnit.Filters.fail_all!(manifest)
        System.at_exit(fn _status -> exit({:shutdown, 1}) end)
    end

    :ok
  end

  # ExUnit passes its configuration as `opts`. A test passes `:report_key`, so the report it
  # makes never reaches this run's own `after_suite/1`.
  @impl true
  def init(opts) do
    key = Keyword.get(opts, :report_key, @report_key)
    :persistent_term.erase(key)

    {:ok,
     %{
       key: key,
       manifest: opts[:failures_manifest_path],
       only_test_ids: opts[:only_test_ids],
       modules_started: %{},
       modules_finished: %{},
       tests_finished: %{},
       cut_short?: false
     }}
  end

  @impl true
  def handle_cast({:module_started, %ExUnit.TestModule{} = module}, state) do
    key = {module.name, module.parameters}
    started = Map.update(state.modules_started, key, {1, module.tests}, &bump/1)
    {:noreply, %{state | modules_started: started}}
  end

  # ExUnit reports an excluded or skipped test before the instance runs, with the module's
  # default parameters rather than the instance's. Its filters read no parameter, so such a test
  # is left out of every instance, and it counts as finished for all of them. A test made invalid
  # by its instance's failed `setup_all` also carries the default parameters, and its state holds
  # the instance.
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    key =
      case test.state do
        {left_out, _} when left_out in [:excluded, :skipped] -> {test.module, :all, test.name}
        {:invalid, %ExUnit.TestModule{parameters: params}} -> {test.module, params, test.name}
        _ -> {test.module, test.parameters, test.name}
      end

    {:noreply, %{state | tests_finished: Map.update(state.tests_finished, key, 1, &(&1 + 1))}}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{} = module}, state) do
    key = {module.name, module.parameters}
    {:noreply, %{state | modules_finished: Map.update(state.modules_finished, key, 1, &(&1 + 1))}}
  end

  def handle_cast(:max_failures_reached, state), do: {:noreply, %{state | cut_short?: true}}
  def handle_cast(_event, state), do: {:noreply, state}

  # ExUnit stops each formatter with `GenServer.stop/3` after `:suite_finished`, before it calls
  # the `after_suite` callbacks.
  @impl true
  def terminate(_reason, %{cut_short?: true}), do: :ok

  def terminate(_reason, state) do
    case report(state, loaded_test_modules()) do
      nil -> :ok
      text -> :persistent_term.put(state.key, {text, state.manifest})
    end
  end

  @doc """
  The text printed for the lost tests in `state`, or `nil` when none were lost. `loaded` lists
  the test modules loaded in the VM.
  """
  @spec report(map(), [module()]) :: String.t() | nil
  def report(state, loaded) do
    unfinished =
      for {{name, params} = key, {count, tests}} <- Enum.sort(state.modules_started),
          count > Map.get(state.modules_finished, key, 0) do
        missing =
          Enum.filter(tests, fn test ->
            selected?(state.only_test_ids, test) and
              not Map.has_key?(state.tests_finished, {name, :all, test.name}) and
              Map.get(state.tests_finished, {name, params, test.name}, 0) < count
          end)

        unfinished_lines(name, params, missing)
      end

    unstarted =
      for module <- Enum.sort(loaded),
          {params, expected} <- Enum.frequencies(instances(module)),
          {started, _tests} = Map.get(state.modules_started, {module, params}, {0, []}),
          started < expected do
        tests = Enum.count(module.__ex_unit__().tests, &selected?(state.only_test_ids, &1))
        "  #{label(module, params)} never started (#{tests} tests)"
      end

    if unfinished != [] or unstarted != [] do
      Enum.join(
        ["Lost tests: ExUnit never reported these, and the Result line leaves them out (#1475):"] ++
          unfinished ++
          unstarted ++
          [
            "The process that ran each module named above exited before its tests finished, " <>
              "or before the module started."
          ],
        "\n"
      )
    end
  end

  defp bump({count, tests}), do: {count + 1, tests}

  # `--failed` runs only the tests it names, and ExUnit sends no event for the others.
  defp selected?(nil, _test), do: true
  defp selected?(ids, test), do: MapSet.member?(ids, {test.module, test.name})

  defp unfinished_lines(name, params, tests) do
    Enum.join(
      [
        "  #{label(name, params)} started and never finished, with no result for " <>
          "#{length(tests)} tests:"
        | Enum.map(
            tests,
            &"    #{&1.name} (#{Path.relative_to_cwd(&1.tags.file)}:#{&1.tags.line})"
          )
      ],
      "\n"
    )
  end

  defp label(module, params) when params == %{}, do: inspect(module)
  defp label(module, params), do: "#{inspect(module)} #{inspect(params)}"

  defp instances(module) do
    case module.__ex_unit__(:config) do
      %{parameterize: nil} -> [%{}]
      %{parameterize: params} -> params
    end
  end

  defp loaded_test_modules do
    for {module, _} <- :code.all_loaded(), function_exported?(module, :__ex_unit__, 0), do: module
  end
end
