defmodule Cinder.TestRunnerHelpers do
  @moduledoc """
  Helpers for the tests that start a per-indexer Test through
  `Cinder.Acquisition.IndexerSource.Native.TestRunner`, an app-wide process whose tasks outlive
  the test that started them.

  `block_tests/0` stubs `Cinder.Acquisition.IndexerAdapterMock`'s `test/3` so each Test reports
  `{:test_started, task_pid, indexer_id}` to the test process and waits for
  `{:answer, answer}`, which `answer/2` sends: `:raise` raises, any other answer goes through the
  Test's own record function (`Cinder.Acquisition.IndexerSource.Native.IndexerStatus.record_test/3`).
  `stop_tests_on_exit/0` kills every Test still running when the test ends and waits until the
  runner holds no mark, so no task reaches the database after the sandbox owner stops and no
  mark carries over to a later test that reuses an indexer id.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Cinder.Acquisition.IndexerAdapterMock
  alias Cinder.Acquisition.IndexerSource.Native.TestRunner
  alias Cinder.ConfigCase

  @doc """
  Points the Newznab type at the adapter mock and stubs its Test as the moduledoc says. It puts
  `:indexer_adapters` whole, so Torznab loses its adapter. A search then asks no Torznab
  indexer, a Test of one whose secrets decrypt refuses with `{:error, {:not_supported,
  :torznab}}` and no request, and an enabled one whose secrets decrypt reads `{:not_supported,
  :torznab}` in `IndexerState.list/1`. A test that needs a Torznab indexer to work puts
  `torznab:` back in the map after this call.
  """
  def block_tests do
    ConfigCase.put_env(:indexer_adapters, %{newznab: IndexerAdapterMock})
    test_pid = self()

    Mox.stub(IndexerAdapterMock, :test, fn indexer, _context, record ->
      send(test_pid, {:test_started, self(), indexer.id})

      receive do
        {:answer, :raise} -> raise "Test stub raised"
        {:answer, answer} -> {:ran, record.(answer)}
      end
    end)

    :ok
  end

  @doc "Lets the blocked Test in `task_pid` answer `answer`."
  def answer(task_pid, answer), do: send(task_pid, {:answer, answer})

  @doc "Kills every running Test when the test ends and waits for the runner to clear its marks."
  def stop_tests_on_exit do
    on_exit(fn ->
      for pid <- Task.Supervisor.children(TestRunner.TaskSupervisor),
          do: Process.exit(pid, :kill)

      await_no_test()
    end)
  end

  @doc "Waits, up to 5 s, until the runner holds no mark."
  def await_no_test(rounds \\ 500) do
    cond do
      TestRunner.running() == MapSet.new() -> :ok
      rounds == 0 -> flunk("a Test still holds its mark: #{inspect(TestRunner.running())}")
      true -> sleep_then(fn -> await_no_test(rounds - 1) end)
    end
  end

  defp sleep_then(next) do
    Process.sleep(10)
    next.()
  end
end
