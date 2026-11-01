defmodule Cinder.DataCaseDrainCheckTest do
  # `Cinder.DataCase.setup_sandbox/1` drains the shared `Cinder.Subtitles.Fetcher` with
  # `drain_subtitle_fetcher!/1` when a test ends. For a sync test it flunks when a fetch it ran
  # logged a warning (#1047). These tests call it from their own bodies, so the drain at each
  # test's end finds nothing queued. Each held fetch runs its criteria only once the drain's
  # request reaches the Fetcher, so the fetch can only log inside the drain. A held fetch that
  # never sees the request skips its criteria, and `drain_held/2` fails the test. The module is
  # sync because the drain's log capture sees every process, and because the tests hold the
  # shared Fetcher.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cinder.DataCase
  alias Cinder.Subtitles

  # 500 polls 10 ms apart: a drain that never reaches the Fetcher holds it for 5 s at most.
  @polls 500

  setup tags do
    DataCase.setup_sandbox(tags)
  end

  test "a sync test's drain flunks on a fetch that crashed, and names the in-body await", tags do
    seen = hold_until_drained("/lib/crash.mkv", fn -> raise "boom" end)

    assert {:flunked, message} = drain_held(tags, seen)

    assert message =~
             ~s(subtitle fetch crashed for /lib/crash.mkv: %RuntimeError{message: "boom"})

    assert message =~ "Cinder.LibraryStubs.await_subtitle_tasks/0"
    assert message =~ "capture_log/1"
    assert message =~ "docs/agents/testing.md"
  end

  # A refused manifest write logs `subtitle manifest write failed ...`, not a crash. The drain
  # matches every warning-or-above line, as this throw's line shows.
  test "a sync test's drain flunks on any warning, not only a fetch crash", tags do
    seen = hold_until_drained("/lib/throw.mkv", fn -> throw(:boom) end)

    assert {:flunked, message} = drain_held(tags, seen)
    assert message =~ "subtitle fetch throw for /lib/throw.mkv: :boom"
    refute message =~ "subtitle fetch crashed"
  end

  test "a sync test's drain returns once a fetch that logs nothing has run", tags do
    ran = :atomics.new(1, [])

    # Subtitle languages are off and the import recorded no sidecar, so once this thunk returns
    # the fetch logs nothing.
    seen =
      hold_until_drained("/lib/quiet.mkv", fn ->
        :atomics.put(ran, 1, 1)
        %{tmdb_id: 1}
      end)

    assert drain_held(tags, seen) == :ok
    assert :atomics.get(ran, 1) == 1
  end

  test "an async test's drain only waits, even on a fetch that crashed", tags do
    seen = hold_until_drained("/lib/async.mkv", fn -> raise "boom" end)

    log = capture_log(fn -> assert drain_held(%{tags | async: true}, seen) == :ok end)

    assert log =~ "subtitle fetch crashed for /lib/async.mkv"
  end

  # Queues a fetch for `video` whose criteria thunk runs `criteria` once the drain's request is in
  # the Fetcher's mailbox, and returns the `:atomics` array it marks then. The request waits there
  # while the Fetcher runs this fetch. Without the request, the thunk returns criteria that log
  # nothing.
  defp hold_until_drained(video, criteria) do
    test = self()
    fetcher = Process.whereis(Subtitles.Fetcher)
    seen = :atomics.new(1, [])

    Subtitles.fetch_after_import(
      fn ->
        send(test, :held)

        if drain_requested?(fetcher, @polls) do
          :atomics.put(seen, 1, 1)
          criteria.()
        else
          %{tmdb_id: 1}
        end
      end,
      video,
      :movies,
      []
    )

    assert_receive :held
    seen
  end

  # Runs the drain with `tags`, and returns `:ok` or `{:flunked, message}`. Fails the test when
  # the held fetch never saw the drain's request, since that fetch skipped its criteria.
  defp drain_held(tags, seen) do
    result =
      try do
        DataCase.drain_subtitle_fetcher!(tags)
      rescue
        error in ExUnit.AssertionError -> {:flunked, error.message}
      end

    assert :atomics.get(seen, 1) == 1,
           "The held fetch never saw the drain's request reach the Fetcher."

    result
  end

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
