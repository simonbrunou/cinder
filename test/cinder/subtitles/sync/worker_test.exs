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

    a = %{video_path: "/library/a.mkv", label: "A"}
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
