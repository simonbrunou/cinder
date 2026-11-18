defmodule Cinder.SyncWorkerHelpers do
  @moduledoc """
  Shared helpers for the tests that drive `Cinder.Subtitles.Sync.Worker`.
  """

  alias Cinder.Subtitles.Sync.Worker

  @doc """
  Sends `units` to the worker as the background enqueue that
  `Worker.enqueue_in_background/3` casts, and returns once the worker has handled it.

  A running worker handles its mailbox in order, so the `:sys.get_state/1` call that follows the
  cast replies only after the cast ran. The queue, the status the worker publishes and any log
  line about dropped units are then in place, and a cast that took the worker down surfaces here.
  A worker suspended with `:sys.suspend/1` answers `:sys.get_state/1` with the cast still queued,
  so call this only on a worker that is not suspended.
  Unlike `enqueue_in_background/3`, it takes any payload, malformed units included, and resolves
  no catalog unit.
  """
  def cast_units(units, server \\ Worker) do
    GenServer.cast(server, {:enqueue_units, units})
    _state = :sys.get_state(server)
    :ok
  end
end
