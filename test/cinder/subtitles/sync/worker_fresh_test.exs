defmodule Cinder.Subtitles.Sync.WorkerFreshTest do
  # DataCase: `enqueue_after_download/3` resolves the video's catalog unit first.
  use Cinder.DataCase, async: false

  alias Cinder.Subtitles.Sync.Worker

  setup do
    :persistent_term.erase({Worker, :status})
    on_exit(fn -> :persistent_term.erase({Worker, :status}) end)
  end

  # A new sidecar should be right the first time: it runs ahead of queued library work and finds
  # the video's shot changes, while routine library work only reads cached ones.
  test "a fresh download runs before queued library work and finds the video's cuts" do
    owner = self()

    analyze = fn video, opts ->
      send(owner, {:started, video, opts, self()})

      receive do
        :release -> [%{status: :aligned, label: video}]
      end
    end

    worker =
      start_supervised!(
        {Worker, initial_scan: false, interval: :timer.hours(1), analyze: analyze}
      )

    library = [
      %{video_path: "/library/a.mkv", label: "A"},
      %{video_path: "/library/b.mkv", label: "B"}
    ]

    assert :ok = Worker.enqueue_units(library, worker)
    assert_receive {:started, "/library/a.mkv", [shot_changes: :cached], first}

    assert :ok = Worker.enqueue_after_download("/library/fresh.mkv", :movies, worker)
    send(first, :release)
    assert_receive {:started, "/library/fresh.mkv", [shot_changes: :detect], fresh}

    send(fresh, :release)
    assert_receive {:started, "/library/b.mkv", [shot_changes: :cached], last}
    send(last, :release)
  end
end
