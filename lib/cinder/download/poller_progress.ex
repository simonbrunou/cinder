defmodule Cinder.Download.PollerProgress do
  @moduledoc """
  Whether a stateful poller (`Cinder.Download.PollerSkeleton`, `stateful: true`) has a tick in
  flight, and when that tick last made progress. `CinderWeb.HealthController` reads it through
  each poller's `status/0` to judge a tick in flight by its progress instead of by the end of its
  last tick (#1294).

  Progress is a stamp in monotonic milliseconds (`now_ms/0`). These write one:

  - the tick's start (`tick_started/2`);
  - each `isolate/2` unit's start and finish, nested units and units that raise included
    (`mark/2`);
  - each `Cinder.HTTPPolicy.bounded_request/2,3` call's start and finish in the process running
    the tick (`beat/0`). A unit can make many such calls in series, as the anime episode search
    makes up to 24 indexer queries, so these stamps bound the stretch between two stamps by one
    request's deadline. A request made from another process, such as a `Task` the unit starts,
    writes no stamp.

  The store is one `:atomics` array per poller module: slot 1 holds 1 while a tick is in flight
  and 0 otherwise, slot 2 the last progress stamp. Its reference sits in `:persistent_term` under
  `{module, :progress}`, written once per module, so a stamp is an atomic write and never a
  `:persistent_term.put/2`, which copies the table of persistent terms and, when it replaces a
  complex term, starts a global garbage collection (the Erlang `persistent_term` docs).

  `reset/1` runs in the poller's `init/1`, so a (re)started poller drops the in-flight state a
  killed process left behind, and a crash mid-tick falls back to the idle rule. `mark/2` and
  `beat/0` write nothing for a module whose store does not exist yet.
  """

  @in_flight 1
  @progress_at 2
  @ambient {__MODULE__, :ambient}

  @typedoc "What `read/1` returns: `progress_at` is a `now_ms/0` stamp, `nil` while idle."
  @type snapshot :: %{in_flight?: boolean(), progress_at: integer() | nil}

  @doc "The clock every stamp uses: `System.monotonic_time/1` in milliseconds."
  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  @doc """
  Clears `module`'s in-flight state, creating its store when missing. The poller's `init/1` calls
  it, and so does every test setup that erases the poller's `:last_run` and `:started_at`.
  """
  @spec reset(module()) :: :ok
  def reset(module) do
    ref = store!(module)
    :atomics.put(ref, @in_flight, 0)
    :atomics.put(ref, @progress_at, 0)
  end

  @doc """
  Starts a tick in the calling process: stamps progress at `at`, then flags the tick in flight,
  in that order, so a reader that sees the flag also sees the stamp. `beat/0` in this process
  stamps `module` until `tick_finished/1`.
  """
  @spec tick_started(module(), integer()) :: :ok
  def tick_started(module, at \\ now_ms()) do
    ref = store!(module)
    :atomics.put(ref, @progress_at, at)
    :atomics.put(ref, @in_flight, 1)
    Process.put(@ambient, module)
    :ok
  end

  @doc """
  Ends the calling process's tick. The poller writes `{module, :last_run}` before this, so a
  reader that sees the tick idle also sees its new last run.
  """
  @spec tick_finished(module()) :: :ok
  def tick_finished(module) do
    Process.delete(@ambient)

    case store(module) do
      nil -> :ok
      ref -> :atomics.put(ref, @in_flight, 0)
    end
  end

  @doc "Stamps progress for `module` at `at`. Writes nothing when its store does not exist."
  @spec mark(module(), integer()) :: :ok
  def mark(module, at \\ now_ms()) do
    case store(module) do
      nil -> :ok
      ref -> :atomics.put(ref, @progress_at, at)
    end
  end

  @doc """
  Stamps progress for the tick the calling process runs, if any. Writes nothing in a process that
  runs no tick, such as a LiveView or a stateless sweep.
  """
  @spec beat() :: :ok
  def beat do
    case Process.get(@ambient) do
      nil -> :ok
      module -> mark(module)
    end
  end

  @doc """
  `module`'s in-flight state: the flag, then the stamp, the reverse of `tick_started/2`'s write
  order. Reads no process, so it never waits on a busy poller. A module with no store reads idle.
  """
  @spec read(module()) :: snapshot()
  def read(module) do
    with ref when ref != nil <- store(module),
         1 <- :atomics.get(ref, @in_flight) do
      %{in_flight?: true, progress_at: :atomics.get(ref, @progress_at)}
    else
      _ -> %{in_flight?: false, progress_at: nil}
    end
  end

  defp store(module), do: :persistent_term.get({module, :progress}, nil)

  # Only a writer creates the store, and each poller module has one writer process.
  defp store!(module) do
    case store(module) do
      nil ->
        ref = :atomics.new(2, signed: true)
        :persistent_term.put({module, :progress}, ref)
        ref

      ref ->
        ref
    end
  end
end
