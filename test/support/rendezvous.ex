defmodule Cinder.Test.Rendezvous do
  @moduledoc """
  Proves that a fan-out runs its calls at once without timing it. A wall-clock bound on such a
  sweep failed on a loaded runner, whose overhead around the sweep has no known ceiling (#1046).

  Each stubbed call runs `arrive/1`: it counts itself in, then waits until all `expected` calls
  have arrived. A concurrent fan-out releases every call as soon as the last one arrives, however
  loaded the runner. In a serial fan-out the first call never sees the others: it gives up at the
  deadline and returns `{:error, :rendezvous_missed}`, and every later call fails at once. The
  deadline is shared and set by the first arrival, so a serial fan-out costs one wait, even when
  a waiting call is killed before it can give up. The test then asserts on `result/1`.

  The wait is 5 s, the house bound for a load flake (`docs/agents/ci.md` "Wall-clock tests"). It
  stays well under the test env's 15 s `:health_probe_timeout_ms`, so a missed rendezvous reads
  as the stub's own error rather than as a killed probe task.
  """

  @wait_ms 5_000
  @poll_ms 5

  @arrived 1
  @met 2
  @missed 3
  @deadline 4

  @doc """
  A rendezvous for `expected` calls. One call proves nothing about concurrency, so `expected`
  is at least 2.
  """
  def new(expected) when is_integer(expected) and expected > 1 do
    %{expected: expected, ref: :atomics.new(4, [])}
  end

  @doc """
  Counts the caller in and waits for the other calls. Returns `:ok` once all `expected` calls
  have arrived, or `{:error, :rendezvous_missed}` once the shared deadline passed or another
  call gave up.
  """
  def arrive(%{ref: ref} = rendezvous) do
    :atomics.add(ref, @arrived, 1)
    :atomics.compare_exchange(ref, @deadline, 0, now() + @wait_ms)
    await(rendezvous)
  end

  @doc """
  How many calls arrived, and how many of them saw all `expected` arrivals. A concurrent fan-out
  of exactly `expected` calls gives `%{arrived: expected, met: expected}`.
  """
  def result(%{ref: ref}),
    do: %{arrived: :atomics.get(ref, @arrived), met: :atomics.get(ref, @met)}

  defp await(%{expected: expected, ref: ref} = rendezvous) do
    cond do
      :atomics.get(ref, @missed) == 1 ->
        {:error, :rendezvous_missed}

      :atomics.get(ref, @arrived) >= expected ->
        :atomics.add(ref, @met, 1)
        :ok

      now() >= :atomics.get(ref, @deadline) ->
        :atomics.put(ref, @missed, 1)
        {:error, :rendezvous_missed}

      true ->
        Process.sleep(@poll_ms)
        await(rendezvous)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
