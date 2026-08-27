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
    assert Worker.managed_video_paths(worker) == MapSet.new([a.video_path, b.video_path])
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

  test "an explicit request promotes queued work ahead of the background library backlog" do
    owner = self()

    backlog =
      for index <- 1..50,
          do: %{video_path: "/library/backlog-#{index}.mkv", label: "Backlog #{index}"}

    target = %{video_path: "/library/backlog-40.mkv", label: "S01E01 · Target"}

    scan = fn
      :library -> backlog
      {:series, 7} -> [target]
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), scan: scan, analyze: analyze}
      )

    assert :ok = Worker.enqueue_library(worker)
    assert_receive {:started, "/library/backlog-1.mkv", first}
    assert_eventually(fn -> Worker.status().queued == 49 end)

    assert :ok = Worker.enqueue_series(7, worker)
    # Promotion never interrupts the in-flight unit.
    refute_receive {:started, "/library/backlog-40.mkv", _}, 100
    # Promotion moves the unit rather than duplicating it.
    assert_eventually(fn -> Worker.status().queued == 49 end)

    send(first, :release)
    assert_receive {:started, "/library/backlog-40.mkv", promoted}
    send(promoted, :release)

    # The backlog then resumes in order, with the promoted unit not repeated.
    assert_receive {:started, "/library/backlog-2.mkv", third}
    send(third, :release)
  end

  test "repeated explicit requests stay idempotent and the promoted unit runs once" do
    owner = self()

    target = %{video_path: "/library/target.mkv", label: "Target"}

    scan = fn
      :library -> [%{video_path: "/library/head.mkv", label: "Head"}, target]
      {:movie, 3} -> [target]
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), scan: scan, analyze: analyze}
      )

    assert :ok = Worker.enqueue_library(worker)
    assert_receive {:started, "/library/head.mkv", first}
    assert_eventually(fn -> Worker.status().queued == 1 end)

    assert :ok = Worker.enqueue_movie(3, worker)
    assert_eventually(fn -> Worker.status().queued == 1 end)
    assert :ok = Worker.enqueue_movie(3, worker)
    assert_eventually(fn -> Worker.status().queued == 1 end)

    # A later library scan must not re-add the already-prioritized target. It does re-add the
    # in-flight head as a follow-up pass, which is existing behavior, so the queue goes to 2.
    assert :ok = Worker.enqueue_library(worker)
    assert_eventually(fn -> Worker.status().queued == 2 end)

    send(first, :release)
    # The prioritized target runs before the freshly queued background follow-up.
    assert_receive {:started, "/library/target.mkv", promoted}
    send(promoted, :release)
    assert_receive {:started, "/library/head.mkv", follow_up}
    send(follow_up, :release)

    assert_eventually(fn -> Worker.status().state == :idle end)
    # Three explicit enqueues of the same target produced exactly one analysis.
    refute_receive {:started, "/library/target.mkv", _}, 100
    assert Worker.status().counts.aligned == 3
  end

  test "priority work drains before background work regardless of arrival order" do
    owner = self()

    scan = fn
      :library -> [%{video_path: "/library/background.mkv", label: "Background"}]
      {:episode, 9} -> [%{video_path: "/library/explicit.mkv", label: "Explicit"}]
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), scan: scan, analyze: analyze}
      )

    blocker = %{video_path: "/library/blocker.mkv", label: "Blocker"}
    assert :ok = Worker.enqueue_units([blocker], worker)
    assert_receive {:started, "/library/blocker.mkv", first}

    assert :ok = Worker.enqueue_library(worker)
    assert_eventually(fn -> Worker.status().queued == 1 end)
    assert :ok = Worker.enqueue_episode(9, worker)
    assert_eventually(fn -> Worker.status().queued == 2 end)

    send(first, :release)
    assert_receive {:started, "/library/explicit.mkv", explicit}
    send(explicit, :release)
    assert_receive {:started, "/library/background.mkv", background}
    send(background, :release)
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
