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

    # The target sits at the BACK of the background queue, behind filler. Only promotion can make
    # it run next; pre-fix code would run the filler first.
    filler = for i <- 1..5, do: %{video_path: "/library/filler-#{i}.mkv", label: "Filler #{i}"}

    # Two distinct scopes resolving to the same video defeat same-scope scan coalescing, so the
    # priority queue's own deduplication is what has to keep the unit single.
    scan = fn
      :library -> [%{video_path: "/library/head.mkv", label: "Head"} | filler] ++ [target]
      {:movie, 3} -> [target]
      {:episode, 9} -> [target]
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
    # head is in flight; filler + target wait.
    assert_eventually(fn -> Worker.status().queued == 6 end)

    # Three explicit requests for the same video across two different scopes.
    assert :ok = Worker.enqueue_movie(3, worker)
    assert :ok = Worker.enqueue_movie(3, worker)
    assert :ok = Worker.enqueue_episode(9, worker)

    # Promotion moves the unit between queues; it must never duplicate it.
    assert_eventually(fn -> Worker.status().queued == 6 end)
    Process.sleep(50)
    assert Worker.status().queued == 6

    # A later library scan must not re-add a path that is already waiting in the priority queue.
    # Without the `prioritized` guard in add_units/3 the same video would be analyzed twice.
    assert :ok = Worker.enqueue_library(worker)
    assert_eventually(fn -> Worker.status().queued == 7 end)
    Process.sleep(50)
    assert Worker.status().queued == 7

    send(first, :release)
    # The promoted target jumps the five filler units.
    assert_receive {:started, "/library/target.mkv", promoted}
    send(promoted, :release)

    # It ran once: the next unit is filler, not the target again.
    assert_receive {:started, "/library/filler-1.mkv", next}
    send(next, :release)
    refute_receive {:started, "/library/target.mkv", _}, 100
  end

  test "background work waits for an outstanding explicit scan instead of taking its slot" do
    owner = self()

    scan = fn {:series, 5} ->
      send(owner, {:scan_started, self()})

      receive do
        :release_scan -> [%{video_path: "/library/explicit.mkv", label: "Explicit"}]
      end
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

    # The operator clicks first; the scan that will produce the explicit unit is still running.
    assert :ok = Worker.enqueue_series(5, worker)
    assert_receive {:scan_started, scanner}

    # Background work arriving inside that window must not claim the idle slot.
    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    refute_receive {:started, "/library/bg.mkv", _}, 100

    send(scanner, :release_scan)
    assert_receive {:started, "/library/explicit.mkv", explicit}
    send(explicit, :release)

    assert_receive {:started, "/library/bg.mkv", background}
    send(background, :release)
  end

  test "a hung explicit scan cannot park background work forever" do
    owner = self()

    scan = fn {:series, 5} ->
      send(owner, :scan_started)
      Process.sleep(:infinity)
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})
      [%{status: :aligned, label: video}]
    end

    worker =
      start_supervised!(
        {Worker,
         initial_scan: false,
         interval: :timer.hours(1),
         scan: scan,
         analyze: analyze,
         explicit_scan_hold: 50}
      )

    # This scan never returns and never raises, so only the bounded hold can release the queue.
    assert :ok = Worker.enqueue_series(5, worker)
    assert_receive :scan_started

    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    refute_receive {:started, "/library/bg.mkv", _}, 20

    assert_receive {:started, "/library/bg.mkv", _}, 1000
  end

  test "an explicit scope waiting behind a hung library scan still releases background work" do
    owner = self()

    scan = fn
      :library ->
        send(owner, :library_scan_started)
        Process.sleep(:infinity)

      {:series, 5} ->
        [%{video_path: "/library/explicit.mkv", label: "Explicit"}]
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})
      [%{status: :aligned, label: video}]
    end

    worker =
      start_supervised!(
        {Worker,
         initial_scan: false,
         interval: :timer.hours(1),
         scan: scan,
         analyze: analyze,
         explicit_scan_hold: 50}
      )

    # The library scan hangs, so the explicit scope sits in pending_scans and its units never
    # materialize. The hold must still expire rather than stranding the background queue.
    assert :ok = Worker.enqueue_library(worker)
    assert_receive :library_scan_started
    assert :ok = Worker.enqueue_series(5, worker)

    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    # Prove the hold was actually applied to the pending scope, otherwise this test would pass
    # even if a pending explicit scope received no hold at all.
    refute_receive {:started, "/library/bg.mkv", _}, 20
    assert_receive {:started, "/library/bg.mkv", _}, 1000
  end

  test "a failed explicit scan releases background work that was waiting for it" do
    owner = self()

    scan = fn {:series, 5} ->
      send(owner, {:scan_started, self()})

      receive do
        :release_scan -> raise "catalog unavailable"
      end
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})
      [%{status: :aligned, label: video}]
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), scan: scan, analyze: analyze}
      )

    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    assert_receive {:started, "/library/bg.mkv", _}

    # Rendezvous with the scan so the hold is provably active before the background unit is
    # enqueued — otherwise this could pass on message ordering alone rather than on the fix.
    assert :ok = Worker.enqueue_series(5, worker)
    assert_receive {:scan_started, scanner}

    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg2.mkv", label: "BG2"}], worker)
    refute_receive {:started, "/library/bg2.mkv", _}, 50

    # The scan raises rather than yielding units; the queue must not stay stranded behind it.
    send(scanner, :release_scan)
    assert_receive {:started, "/library/bg2.mkv", _}, 1000
    assert_eventually(fn -> Worker.status().counts.failed == 1 end)
  end

  test "a second explicit request keeps its hold after the first one starts running" do
    owner = self()

    scan = fn
      {:movie, 1} ->
        [%{video_path: "/library/first.mkv", label: "First"}]

      {:series, 2} ->
        # Still outstanding when the first explicit unit starts: this is what the hold protects.
        send(owner, {:scan_started, self()})

        receive do
          :release_scan -> [%{video_path: "/library/second.mkv", label: "Second"}]
        end
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker,
         initial_scan: false,
         interval: :timer.hours(1),
         scan: scan,
         analyze: analyze,
         explicit_scan_hold: 5000}
      )

    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    assert_receive {:started, "/library/bg.mkv", blocker}

    # First explicit request resolves immediately and lands in the priority queue.
    assert :ok = Worker.enqueue_movie(1, worker)
    assert_eventually(fn -> Worker.status().queued == 1 end)

    # Second explicit request's scan blocks, so its units do not exist yet.
    assert :ok = Worker.enqueue_series(2, worker)
    assert_receive {:scan_started, scanner}

    # Starting the first explicit unit must not drop the hold the second one still needs.
    send(blocker, :release)
    assert_receive {:started, "/library/first.mkv", first}

    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg2.mkv", label: "BG2"}], worker)
    send(first, :release)
    refute_receive {:started, "/library/bg2.mkv", _}, 50

    send(scanner, :release_scan)
    assert_receive {:started, "/library/second.mkv", second}
    send(second, :release)

    assert_receive {:started, "/library/bg2.mkv", bg2}
    send(bg2, :release)
  end

  test "an expired hold is cleared so a later explicit request arms a fresh one" do
    owner = self()

    scan = fn {:movie, id} ->
      send(owner, {:scan_started, id})
      Process.sleep(:infinity)
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker,
         initial_scan: false,
         interval: :timer.hours(1),
         scan: scan,
         analyze: analyze,
         explicit_scan_hold: 50}
      )

    # First explicit request hangs, so its hold expires and background work proceeds.
    assert :ok = Worker.enqueue_movie(1, worker)
    assert_receive {:scan_started, 1}
    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    assert_receive {:started, "/library/bg.mkv", bg}, 1000
    send(bg, :release)

    # A later explicit request must arm a FRESH hold. If the expired deadline were left in place,
    # hold_explicitly/2 would decline to re-arm and this background unit would start immediately.
    assert :ok = Worker.enqueue_movie(2, worker)
    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg2.mkv", label: "BG2"}], worker)
    refute_receive {:started, "/library/bg2.mkv", _}, 20

    # That fresh hold is itself bounded, so background work still resumes.
    assert_receive {:started, "/library/bg2.mkv", bg2}, 1000
    send(bg2, :release)
  end

  test "a library request racing an expired hold preserves the queue wake-up" do
    owner = self()

    scan = fn
      {:series, 5} ->
        send(owner, :explicit_scan_started)
        Process.sleep(:infinity)

      :library ->
        []
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})
      [%{status: :aligned, label: video}]
    end

    worker =
      start_supervised!(
        {Worker,
         initial_scan: false,
         interval: :timer.hours(1),
         scan: scan,
         analyze: analyze,
         explicit_scan_hold: 500}
      )

    assert :ok = Worker.enqueue_series(5, worker)
    assert_receive :explicit_scan_started

    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    refute_receive {:started, "/library/bg.mkv", _}, 20

    # Freeze the GenServer before expiry, queue the library cast first, then let the hold timer
    # arrive. On resume the cast observes an expired deadline whose release message is already
    # next in the mailbox — the precise ordering that used to clear and lose the only wake-up.
    assert :ok = :sys.suspend(worker)
    assert :ok = Worker.enqueue_library(worker)
    Process.sleep(550)
    assert :ok = :sys.resume(worker)

    assert_receive {:started, "/library/bg.mkv", _}, 1000
  end

  test "a crashed explicit scan releases background work that was waiting for it" do
    owner = self()

    # Exiting rather than raising: run_scan/2 rescues raises, so only a process exit reaches the
    # scan-task :DOWN handler. That handler must restart the queue too.
    scan = fn {:series, 5} ->
      send(owner, {:scan_started, self()})

      receive do
        :release_scan -> Process.exit(self(), :kill)
      end
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})
      [%{status: :aligned, label: video}]
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), scan: scan, analyze: analyze}
      )

    assert :ok = Worker.enqueue_series(5, worker)
    assert_receive {:scan_started, scanner}

    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    refute_receive {:started, "/library/bg.mkv", _}, 50

    send(scanner, :release_scan)
    assert_receive {:started, "/library/bg.mkv", _}, 1000
    assert Process.alive?(worker)
  end

  test "a stale deadline does not leak when the background queue is empty at expiry" do
    owner = self()

    scan = fn {:movie, id} ->
      send(owner, {:scan_started, id})
      Process.sleep(:infinity)
    end

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker,
         initial_scan: false,
         interval: :timer.hours(1),
         scan: scan,
         analyze: analyze,
         explicit_scan_hold: 50}
      )

    # The hold expires with NOTHING queued, so the only chance to clear the deadline is a
    # start_next/1 that dequeues nothing at all. No sleep here: the point is that the request
    # below arrives while the expired deadline is still sitting in state, before its release
    # message has been processed.
    assert :ok = Worker.enqueue_movie(1, worker)
    assert_receive {:scan_started, 1}

    # A later explicit request must still arm a fresh hold rather than inherit that dead deadline.
    Process.sleep(60)
    assert :ok = Worker.enqueue_movie(2, worker)
    assert :ok = Worker.enqueue_units([%{video_path: "/library/bg.mkv", label: "BG"}], worker)
    refute_receive {:started, "/library/bg.mkv", _}, 20

    assert_receive {:started, "/library/bg.mkv", bg}, 1000
    send(bg, :release)
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

  test "a result without :status still publishes a snapshot instead of crashing the worker" do
    owner = self()

    analyze = fn video ->
      send(owner, {:started, video, self()})

      receive do
        :release -> [%{label: video}, %{status: :review, label: video, reason: "misaligned"}]
      end
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), analyze: analyze}
      )

    Worker.subscribe()

    assert :ok = Worker.enqueue_units([%{video_path: "/library/a.mkv", label: "A"}], worker)
    assert_receive {:started, "/library/a.mkv", task}
    send(task, :release)

    assert_receive {:subtitle_sync_status, %{state: :idle, recent: [_, _]} = snapshot}
    assert [%{label: "/library/a.mkv"}, %{status: :review}] = snapshot.recent
    assert [%{status: :review, label: "/library/a.mkv"}] = snapshot.review_items

    assert Process.alive?(worker)
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
