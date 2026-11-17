defmodule Cinder.BoundedWalkHelpersTest do
  # Each test builds its own page, scan and walk, none of them under the app's guard, so the
  # tests share nothing.
  use ExUnit.Case, async: true

  import Cinder.BoundedWalkHelpers

  @delay_ms 20

  describe "close_page_during_walk/2 (#1361)" do
    test "returns once the scan exits with the page's {:shutdown, :closed}" do
      %{page: page, scan: scan, walk: walk} = page_scan_walk(:linked)
      ref = Process.monitor(scan)

      assert :ok = close_page_during_walk(page, walk)
      assert_received {:DOWN, ^ref, :process, ^scan, {:shutdown, :closed}}
    end

    test "fails at once, naming the reason, when the scan exits with another reason" do
      %{page: page, walk: walk} = page_scan_walk(:exits_on_close)

      error = assert_raise ExUnit.AssertionError, fn -> close_page_during_walk(page, walk) end

      assert error.message =~ "exited with :page_closed_badly, not {:shutdown, :closed}"
    end

    test "says the scan exited before the page closed, with the page still alive, when the " <>
           "scan is already gone" do
      before_walk = System.monotonic_time(:millisecond)
      %{page: page, scan: scan, walk: walk} = page_scan_walk(:unlinked)
      kill(scan)
      # A known delay between the walk's report and the helper, so the elapsed time has a floor.
      Process.sleep(@delay_ms)

      error = assert_raise ExUnit.AssertionError, fn -> close_page_during_walk(page, walk) end
      after_close = System.monotonic_time(:millisecond)

      assert error.message =~
               "the scan #{inspect(scan)} had already exited before the page closed"

      assert error.message =~ "The LiveView #{inspect(page)} was still alive at that point"

      after_walk =
        ~r/, (\d+) ms after the walk sent \{:walking, #{Regex.escape(inspect(walk))}\}\./

      assert [_match, elapsed] = Regex.run(after_walk, error.message)
      assert String.to_integer(elapsed) in @delay_ms..(after_close - before_walk)
    end

    test "says the page had exited too when the scan went down with it" do
      %{page: page, scan: scan, walk: walk} = page_scan_walk(:linked)
      scan_ref = Process.monitor(scan)
      kill(page)
      assert_receive {:DOWN, ^scan_ref, :process, ^scan, :killed}

      error = assert_raise ExUnit.AssertionError, fn -> close_page_during_walk(page, walk) end

      assert error.message =~
               "the scan #{inspect(scan)} had already exited before the page closed"

      assert error.message =~ "The LiveView #{inspect(page)} had already exited at that point"
    end
  end

  # A stand-in for a LiveView page, its scan task and the walk the scan started. The walk hangs
  # through `hang_walk/1` and carries the scan as the head of its `$callers`, as a walk
  # `Cinder.Library.BoundedWalk.run/3` starts from the scan does, and is not linked to the scan,
  # as that walk is not. `link` says how the scan hangs off the page: `:linked`, a task the page
  # starts linked, as `start_async` does; `:unlinked`, a task of the test's, so the scan can die
  # alone; `:exits_on_close`, linked, but exiting with `:page_closed_badly` when the page stops.
  defp page_scan_walk(link) do
    test = self()
    page = start_supervised!({Task, fn -> page(link, test) end}, id: make_ref())

    scan =
      if link == :unlinked do
        start_supervised!({Task, fn -> Process.sleep(:infinity) end}, id: make_ref())
      else
        assert_receive {:scan, scan}
        scan
      end

    walk =
      start_supervised!(
        {Task,
         fn ->
           Process.put(:"$callers", [scan])
           hang_walk(test)
         end},
        id: make_ref()
      )

    assert_receive {:walking, ^walk}
    %{page: page, scan: scan, walk: walk}
  end

  defp page(:unlinked, _test), do: Process.sleep(:infinity)

  defp page(link, test) do
    {:ok, _scan} = Task.start_link(fn -> scan(link, test) end)
    Process.sleep(:infinity)
  end

  defp scan(:linked, test) do
    send(test, {:scan, self()})
    Process.sleep(:infinity)
  end

  defp scan(:exits_on_close, test) do
    Process.flag(:trap_exit, true)
    send(test, {:scan, self()})

    receive do
      {:EXIT, _page, _reason} -> exit(:page_closed_badly)
    end
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
