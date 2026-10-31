defmodule Cinder.DataCaseFetcherDrainTest do
  # `Cinder.DataCase.setup_sandbox/1` drains the shared `Cinder.Subtitles.Fetcher` when a test
  # ends, before the sandbox owner stops (#1028). This module calls it itself, after registering
  # the check in its setup, so the check runs once the drain and the owner's stop are done: ExUnit
  # runs `on_exit` callbacks last-registered first. ExUnit stops a test's supervised processes
  # before any `on_exit` runs, so the held fetch reports through an `:atomics` array that its
  # closure and the check both hold.
  use ExUnit.Case, async: false

  alias Cinder.Repo
  alias Cinder.Subtitles

  @drain_seen 1
  @finished 2

  # 500 polls 10 ms apart: a missing drain holds the shared Fetcher for 5 s at most.
  @polls 500

  setup tags do
    progress = :atomics.new(2, [])

    on_exit(fn ->
      assert :atomics.get(progress, @drain_seen) == 1,
             "The held fetch never saw the end-of-test drain's request reach the Fetcher."

      assert :atomics.get(progress, @finished) == 1,
             "The drain returned before the held fetch read the database and finished."
    end)

    Cinder.DataCase.setup_sandbox(tags)
    {:ok, progress: progress}
  end

  test "the end-of-test drain waits for a fetch still running when it starts", %{
    progress: progress
  } do
    test = self()
    fetcher = Process.whereis(Subtitles.Fetcher)

    # Subtitle languages are off and the import recorded no sidecar, so once this thunk returns
    # the fetch calls no mock. The test's stubs are gone by the time the drain runs.
    Subtitles.fetch_after_import(
      fn ->
        send(test, :held)
        if drain_requested?(fetcher, @polls), do: :atomics.put(progress, @drain_seen, 1)

        # Raises once the sandbox owner has stopped, so a drain that ran after the stop never
        # reaches the put below.
        Repo.query!("SELECT 1")
        :atomics.put(progress, @finished, 1)
        %{tmdb_id: 1}
      end,
      "/lib/held.mkv",
      :movies,
      []
    )

    # The fetch is running, so the test ends with it still on the Fetcher.
    assert_receive :held
  end

  # Whether the drain's `:sys.get_state` request reached the Fetcher's mailbox within `polls`
  # polls. The request waits there while the Fetcher runs this fetch.
  defp drain_requested?(_fetcher, 0), do: false

  defp drain_requested?(fetcher, polls) do
    {:messages, messages} = Process.info(fetcher, :messages)

    if Enum.any?(messages, &match?({:system, _from, :get_state}, &1)) do
      true
    else
      Process.sleep(10)
      drain_requested?(fetcher, polls - 1)
    end
  end
end
