defmodule Cinder.Subtitles.FetcherTest do
  # async: false — the Fetcher is a single app-wide process and this drives it directly, plus it
  # mutates the shared OpenSubtitles :languages config (blank by default so other suites don't fetch).
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Subtitles

  # Global mode: each fetch runs on its own isolated task, not the test process, so it must see
  # these stubs. set_mox_global (not private) allows any process to use the expectations.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    saved = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved)
    end)

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    # Every fetch searches (no manifest, sidecar absent), hashes nothing, and finds no local
    # embedded/sidecar fallback — an empty provider result runs the fallback path too.
    stub(Cinder.Library.FilesystemMock, :read, fn _ -> {:error, :enoent} end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:error, :enoent} end)
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    :ok
  end

  defp enqueue(tmdb_id, dest),
    do:
      Subtitles.fetch_after_import(fn -> %{tmdb_id: tmdb_id, imdb_id: nil} end, dest, :movies, [])

  test "serializes: the second fetch does not start until the first finishes" do
    test = self()

    # Each search reports which unit it is and the worker running it, then blocks until released
    # (bounded, so a failed assertion can't wedge the shared Fetcher for the rest of the suite).
    stub(Cinder.Subtitles.ProviderMock, :search, fn %{tmdb_id: id} ->
      send(test, {:search_started, id, self()})

      receive do
        :release -> :ok
      after
        2_000 -> :ok
      end

      {:ok, []}
    end)

    enqueue(1, "/lib/a.mkv")
    enqueue(2, "/lib/b.mkv")

    assert_receive {:search_started, 1, worker_1}, 1_000
    # The burst-prevention guarantee: unit 2's request is queued, NOT fired concurrently.
    refute_receive {:search_started, 2, _worker}, 200

    send(worker_1, :release)
    assert_receive {:search_started, 2, worker_2}, 1_000
    send(worker_2, :release)

    # Drain before the next test resets Mox's global stubs out from under a lingering fetch.
    :sys.get_state(Cinder.Subtitles.Fetcher)
  end

  test "a crashing fetch doesn't kill the Fetcher; the next queued fetch still runs" do
    test = self()
    fetcher = Process.whereis(Cinder.Subtitles.Fetcher)

    stub(Cinder.Subtitles.ProviderMock, :search, fn
      %{tmdb_id: 1} -> raise "provider boom"
      %{tmdb_id: 2} -> send(test, :second_ran) && {:ok, []}
    end)

    enqueue(1, "/lib/a.mkv")
    enqueue(2, "/lib/b.mkv")

    assert_receive :second_ran, 1_000
    assert Process.alive?(fetcher)

    # Drain before the next test resets Mox's global stubs out from under a lingering fetch.
    :sys.get_state(Cinder.Subtitles.Fetcher)
  end
end
