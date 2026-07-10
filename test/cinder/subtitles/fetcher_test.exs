defmodule Cinder.Subtitles.FetcherTest do
  # async: false — the Fetcher is a single app-wide process and this drives it directly, plus it
  # mutates the shared OpenSubtitles :languages config (blank by default so other suites don't fetch).
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Subtitles

  # Global mode: the fetch runs in the Fetcher process, not the test process, so it must see these
  # stubs. set_mox_global (not private) allows any process to use the expectations.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    saved = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    on_exit(fn ->
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, saved)
    end)

    Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, languages: "en")

    # Every fetch searches (sidecar absent) and hashes nothing.
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:error, :enoent} end)
    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn _ -> :too_small end)
    :ok
  end

  defp enqueue(tmdb_id, dest),
    do: Subtitles.fetch_after_import(fn -> %{tmdb_id: tmdb_id, imdb_id: nil} end, dest)

  test "serializes: the second fetch does not start until the first finishes" do
    test = self()
    fetcher = Process.whereis(Cinder.Subtitles.Fetcher)

    # Each search announces which unit it is, then blocks until released (bounded, so a failed
    # assertion can't wedge the shared Fetcher for the rest of the suite).
    stub(Cinder.Subtitles.ProviderMock, :search, fn %{tmdb_id: id} ->
      send(test, {:search_started, id})

      receive do
        :release -> :ok
      after
        2_000 -> :ok
      end

      {:ok, []}
    end)

    enqueue(1, "/lib/a.mkv")
    enqueue(2, "/lib/b.mkv")

    assert_receive {:search_started, 1}, 1_000
    # The burst-prevention guarantee: unit 2's request is queued, NOT fired concurrently.
    refute_receive {:search_started, 2}, 200

    send(fetcher, :release)
    assert_receive {:search_started, 2}, 1_000
    send(fetcher, :release)
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
  end
end
