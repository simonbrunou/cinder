defmodule Cinder.Acquisition.IndexerSource.Native.TestRunnerTest do
  # The runner of the per-indexer Test (#1660, #1625 point 11). Each Test runs the real
  # `Native.test_indexer/1` with the Newznab type pointed at `IndexerAdapterMock`, whose stub
  # blocks until the test answers (`Cinder.TestRunnerHelpers`), so the stored outcome is the one
  # `IndexerStatus.record_test/3` wrote.
  #
  # Not async: the runner, its supervisor and the adapter map are app-wide, its tasks reach the
  # database through the shared sandbox, and the Mox stub is global for them.
  use Cinder.DataCase, async: false

  import Cinder.NewznabFixtures, only: [indexer!: 2]
  import Cinder.TestRunnerHelpers

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerState, TestRunner}
  alias Cinder.ConfigCase
  alias Cinder.Indexers

  @now ~U[2026-11-26 12:00:00Z]

  setup {Mox, :set_mox_global}

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    block_tests()
    stop_tests_on_exit()
    :ok = TestRunner.subscribe()
    :ok
  end

  defp last_test(id), do: Enum.find(IndexerState.list(@now), &(&1.id == id)).last_test

  test "runs the Test in a child of its own supervisor and broadcasts its start and finish" do
    indexer = indexer!(:newznab, "nzb.example")

    assert TestRunner.start(indexer.id) == :ok
    assert_receive {TestRunner, :started, id}
    assert id == indexer.id
    assert_receive {:test_started, task_pid, ^id}
    assert task_pid in Task.Supervisor.children(TestRunner.TaskSupervisor)
    assert TestRunner.running() == MapSet.new([id])

    answer(task_pid, :test_success)

    assert_receive {TestRunner, :finished, ^id, {:ok, %{outcome: :success, at: @now}}}
    assert last_test(id) == %{outcome: :success, at: @now}
  end

  test "a second start while the Test runs starts nothing" do
    indexer = indexer!(:newznab, "nzb.example")

    assert TestRunner.start(indexer.id) == :ok
    assert_receive {:test_started, task_pid, _id}

    assert TestRunner.start(indexer.id) == {:error, :running}
    assert [^task_pid] = Task.Supervisor.children(TestRunner.TaskSupervisor)

    answer(task_pid, :test_success)
    assert_receive {TestRunner, :finished, _id, {:ok, _last_test}}
    refute_received {:test_started, _pid, _id}
  end

  test "a Test of another indexer runs beside a running one" do
    a = indexer!(:newznab, "a.example")
    b = indexer!(:newznab, "b.example")

    assert TestRunner.start(a.id) == :ok
    assert TestRunner.start(b.id) == :ok
    assert TestRunner.running() == MapSet.new([a.id, b.id])

    for _ <- 1..2 do
      assert_receive {:test_started, task_pid, _id}
      answer(task_pid, :test_success)
    end

    assert_receive {TestRunner, :finished, _first, {:ok, _}}
    assert_receive {TestRunner, :finished, _second, {:ok, _}}
  end

  describe "the mark clears and a new Test can start" do
    test "after a passing Test" do
      assert_clears(:test_success, {:ok, %{outcome: :success, at: @now}})
    end

    test "after a failing Test, whose outcome is stored" do
      assert_clears({:http_status, 503}, {:ok, %{outcome: {:http_status, 503}, at: @now}})
    end

    test "after a Test that raises, which stores nothing" do
      ExUnit.CaptureLog.capture_log(fn -> assert_clears(:raise, {:error, :crashed}) end)
    end
  end

  # Runs one Test that answers `answer`, checks its finish carries `result` and that the mark has
  # cleared by then, and that a second Test of the same indexer then starts.
  defp assert_clears(answer, result) do
    indexer = indexer!(:newznab, "nzb.example")
    id = indexer.id

    assert TestRunner.start(id) == :ok
    assert_receive {:test_started, task_pid, ^id}
    answer(task_pid, answer)

    assert_receive {TestRunner, :finished, ^id, ^result}
    assert TestRunner.running() == MapSet.new()

    if answer == :raise, do: assert(last_test(id) == nil)

    assert TestRunner.start(id) == :ok
    assert_receive {:test_started, second_pid, ^id}
    answer(second_pid, :test_success)
    assert_receive {TestRunner, :finished, ^id, {:ok, _}}
  end

  test "a Test killed in its task reads crashed and clears its mark" do
    indexer = indexer!(:newznab, "nzb.example")

    assert TestRunner.start(indexer.id) == :ok
    assert_receive {:test_started, task_pid, id}
    Process.exit(task_pid, :kill)

    assert_receive {TestRunner, :finished, ^id, {:error, :crashed}}
    assert TestRunner.running() == MapSet.new()
  end

  test "an edit that raises config_version while the Test runs leaves no outcome from it" do
    indexer = indexer!(:newznab, "nzb.example")

    assert TestRunner.start(indexer.id) == :ok
    assert_receive {:test_started, task_pid, id}

    {:ok, _edited} =
      Indexers.update(nil, id, indexer.lock_version, %{api_path: "/api/v2"})

    answer(task_pid, :test_success)

    assert_receive {TestRunner, :finished, ^id, {:error, :dropped}}
    assert last_test(id) == nil
  end

  test "a delete while the Test runs leaves no status row" do
    indexer = indexer!(:newznab, "nzb.example")

    assert TestRunner.start(indexer.id) == :ok
    assert_receive {:test_started, task_pid, id}
    :ok = Indexers.delete(nil, id)

    answer(task_pid, :test_success)

    assert_receive {TestRunner, :finished, ^id, {:error, :dropped}}
    assert Repo.get(Native.IndexerStatus, id) == nil
  end

  test "a restarted runner ends the Tests it no longer watches, holds no mark and says so" do
    indexer = indexer!(:newznab, "nzb.example")
    assert TestRunner.start(indexer.id) == :ok
    assert_receive {:test_started, task_pid, _id}
    task_ref = Process.monitor(task_pid)

    ref = Process.monitor(TestRunner)
    ExUnit.CaptureLog.capture_log(fn -> Process.exit(Process.whereis(TestRunner), :kill) end)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    assert_receive {TestRunner, :reset}
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :shutdown}
    assert TestRunner.running() == MapSet.new()
    assert Task.Supervisor.children(TestRunner.TaskSupervisor) == []
  end

  test "a Test keeps running after the process that started it exits, and stores its outcome" do
    indexer = indexer!(:newznab, "nzb.example")
    id = indexer.id

    # The starter waits for `:go`, so the monitor is in place before it can exit.
    starter =
      start_supervised!(
        {Task, fn -> receive(do: (:go -> TestRunner.start(id))) end},
        id: make_ref()
      )

    ref = Process.monitor(starter)
    send(starter, :go)
    assert_receive {:test_started, task_pid, ^id}
    assert_receive {:DOWN, ^ref, :process, ^starter, :normal}

    answer(task_pid, :test_success)

    assert_receive {TestRunner, :finished, ^id, {:ok, _}}
    assert last_test(id) == %{outcome: :success, at: @now}
  end
end
