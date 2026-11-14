defmodule Cinder.Download.PollerProgressTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.PollerProgress

  # A module name of this test's own, so no poller or other test shares its store.
  @module __MODULE__.Tick

  setup do
    on_exit(fn -> :persistent_term.erase({@module, :progress}) end)
  end

  test "a module with no store reads idle, and a mark or a beat creates none" do
    assert PollerProgress.read(@module) == %{in_flight?: false, progress_at: nil}

    # A tick started in this process, then its store erased, as a test setup can.
    PollerProgress.tick_started(@module)
    :persistent_term.erase({@module, :progress})

    PollerProgress.mark(@module)
    PollerProgress.beat()

    assert :persistent_term.get({@module, :progress}, nil) == nil
    assert PollerProgress.read(@module) == %{in_flight?: false, progress_at: nil}
  end

  test "a tick reads in flight with its last stamp until it finishes, and reset clears it" do
    PollerProgress.tick_started(@module, 100)
    assert PollerProgress.read(@module) == %{in_flight?: true, progress_at: 100}

    PollerProgress.mark(@module, 250)
    assert PollerProgress.read(@module) == %{in_flight?: true, progress_at: 250}

    PollerProgress.tick_finished(@module)
    assert PollerProgress.read(@module) == %{in_flight?: false, progress_at: nil}

    PollerProgress.tick_started(@module, 300)
    PollerProgress.reset(@module)
    assert PollerProgress.read(@module) == %{in_flight?: false, progress_at: nil}
  end

  test "a beat stamps the tick its own process runs, and nothing once that tick finished" do
    # Monotonic time can be negative, so the old stamps are relative to now.
    old = PollerProgress.now_ms() - :timer.minutes(11)
    PollerProgress.tick_started(@module, old)

    Task.await(Task.async(fn -> PollerProgress.beat() end))
    assert PollerProgress.read(@module).progress_at == old

    PollerProgress.beat()
    assert PollerProgress.read(@module).progress_at > old

    # This process's tick ends, and another process's tick is in flight.
    PollerProgress.tick_finished(@module)
    Task.await(Task.async(fn -> PollerProgress.tick_started(@module, old) end))

    PollerProgress.beat()
    assert PollerProgress.read(@module) == %{in_flight?: true, progress_at: old}
  end
end
