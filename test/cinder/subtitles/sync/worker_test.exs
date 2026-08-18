defmodule Cinder.Subtitles.Sync.WorkerTest do
  use ExUnit.Case, async: false

  alias Cinder.Subtitles.Sync.Worker

  setup do
    :persistent_term.erase({Worker, :status})
    on_exit(fn -> :persistent_term.erase({Worker, :status}) end)
  end

  test "serializes CPU work, deduplicates video paths, and keeps status responsive" do
    owner = self()

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), analyze: analyze}
      )

    scopes = MapSet.new([{:movie, 1}])
    a = %{video_path: "/library/a.mkv", label: "A", scopes: scopes}
    b = %{video_path: "/library/b.mkv", label: "B"}
    assert :ok = Worker.enqueue_units([a, a, b], worker)
    assert_receive {:started, "/library/a.mkv", first}
    refute_receive {:started, "/library/b.mkv", _}, 100

    assert %{state: :running, queued: 1, current: %{video_path: "/library/a.mkv"}} =
             Worker.status()

    send(first, :release)
    assert_receive {:started, "/library/b.mkv", second}
    send(second, :release)
    assert_eventually(fn -> Worker.status().state == :idle end)
    assert Worker.status().counts.aligned == 2
    assert Enum.find(Worker.status().recent, &(&1.label == "/library/a.mkv")).scopes == scopes
  end

  test "an enqueue for the current video retains exactly one follow-up pass" do
    owner = self()

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), analyze: analyze}
      )

    unit = %{video_path: "/library/current.mkv", label: "Current"}
    assert :ok = Worker.enqueue_units([unit], worker)
    assert_receive {:started, "/library/current.mkv", first}

    assert :ok = Worker.enqueue_units([unit, unit], worker)
    assert :ok = Worker.enqueue_units([unit], worker)
    assert Worker.status().queued == 1

    send(first, :release)
    assert_receive {:started, "/library/current.mkv", second}
    refute second == first
    send(second, :release)

    assert_eventually(fn -> Worker.status().state == :idle end)
    refute_receive {:started, "/library/current.mkv", _}, 100
    assert Worker.status().counts.aligned == 2
  end

  test "initial scan re-derives pending work instead of relying on an in-memory queue" do
    owner = self()

    scan = fn :library ->
      send(owner, :scanned)
      [%{video_path: "/library/recovered.mkv", label: "Recovered"}]
    end

    analyze = fn video ->
      send(owner, {:recovered, video})
      []
    end

    start_supervised!({Worker, scan: scan, analyze: analyze, interval: :timer.hours(1)})
    assert_receive :scanned
    assert_receive {:recovered, "/library/recovered.mkv"}
  end

  test "slow scans do not block enqueue callers or worker status" do
    owner = self()

    scan = fn scope ->
      send(owner, {:scan_started, scope, self()})

      receive do
        :release -> []
      end
    end

    worker =
      start_supervised!({Worker, initial_scan: false, scan: scan, interval: :timer.hours(1)})

    enqueue = Task.async(fn -> Worker.enqueue_library(worker) end)
    assert_receive {:scan_started, :library, scanner}
    assert {:ok, :ok} = Task.yield(enqueue, 100)
    assert %{state: :idle} = Worker.status()

    send(scanner, :release)
  end

  test "scan exceptions are recorded as failures without crashing the worker" do
    scan = fn :library -> raise "catalog unavailable" end

    worker =
      start_supervised!({Worker, initial_scan: false, scan: scan, interval: :timer.hours(1)})

    assert :ok = Worker.enqueue_library(worker)

    assert_eventually(fn -> Worker.status().counts.failed == 1 end)
    assert Process.alive?(worker)
    assert [%{status: :failed, reason: reason} | _] = Worker.status().recent
    assert inspect(reason) =~ "catalog unavailable"
  end

  test "malformed scan units are recorded as failures without crashing the worker" do
    scan = fn :library -> [:invalid, %{label: "missing path"}] end

    worker =
      start_supervised!({Worker, initial_scan: false, scan: scan, interval: :timer.hours(1)})

    assert :ok = Worker.enqueue_library(worker)

    assert_eventually(fn -> Worker.status().counts.failed == 1 end)
    assert Process.alive?(worker)
    assert [%{status: :failed, reason: reason} | _] = Worker.status().recent
    assert inspect(reason) =~ "invalid_scan_result"
  end

  test "post-download enqueue is best effort when no named worker is alive" do
    refute Process.whereis(Worker)
    assert :ok = Worker.enqueue_after_download("/library/downloaded.mkv")
  end

  defp assert_eventually(fun, attempts \\ 20)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
