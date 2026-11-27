defmodule Cinder.Test.BoundedRequestWait do
  @moduledoc """
  Waits for a task that calls `Cinder.HTTPPolicy.bounded_request/2,3`, as `Task.await/2` does, and
  says where the wait stalled when it times out (#1717).

  Call `watch/0` before the test starts the task, then `await/3` on the task:

      watch = BoundedRequestWait.watch()
      task = Task.async(fn -> HTTPPolicy.bounded_request(request, 64) end)
      assert {:ok, _response} = BoundedRequestWait.await(watch, task, 10_000)

  `watch/0` attaches a handler to the `[:cinder, :http, :request_task]` event, which
  `bounded_request/2,3` emits in its caller as soon as the request task exists. The handler sees
  every process's events and forwards each one to the process that called `watch/0`. `await/3`
  keeps those whose `caller` is the awaited task.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @event [:cinder, :http, :request_task]

  @doc """
  Attaches the handler that `await/3` reads, under the id `{#{inspect(__MODULE__)}, ref}`.
  Returns the watch to pass to `await/3`. `await/3` detaches it, and so does the end of the test
  when the test never calls `await/3`.
  """
  def watch do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, @event, &__MODULE__.handle_event/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
    %{id: id}
  end

  @doc false
  def handle_event(_event, _measurements, metadata, watcher),
    do: send(watcher, {__MODULE__, metadata})

  @doc """
  Waits up to `timeout_ms` for `task`'s reply and returns it. A task that exits first makes the
  caller exit, as `Task.await/2` does.

  When no reply came within `timeout_ms`, it fails with a message that names:

  - how many milliseconds the wait took, by `System.monotonic_time/1`, so a wait far past
    `timeout_ms` shows that the calling process itself ran late;
  - the task, with its `:status`, `:current_stacktrace` and `:message_queue_len` when it is alive,
    or that it had exited with its reply not yet received;
  - each request task the task's `bounded_request/2,3` calls started since `watch/0`, in the order
    their events came by the time of the report, with the same three fields when it is alive or
    that it had exited. With no such event, it says so: with the handler attached before the task
    started, the task had not reached that point of `bounded_request/2,3` by then.

  The handler is detached when the function returns or fails.
  """
  def await(%{id: id}, %Task{} = task, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)

    try do
      case Task.yield(task, timeout_ms) do
        {:ok, reply} ->
          reply

        {:exit, reason} ->
          exit({reason, {__MODULE__, :await, [task, timeout_ms]}})

        nil ->
          elapsed_ms = System.monotonic_time(:millisecond) - started_at
          flunk(timeout_message(task, timeout_ms, elapsed_ms))
      end
    after
      :telemetry.detach(id)
      drain_events()
    end
  end

  defp timeout_message(task, timeout_ms, elapsed_ms) do
    caller_state = process_state(task.pid, "had exited, its reply not yet received")

    request_tasks =
      case drain_events() |> Enum.filter(&(&1.caller == task.pid)) do
        [] ->
          "No request task event: no #{inspect(@event)} event names the task as its caller, " <>
            "so the task had not yet reached the point where bounded_request/2,3 starts its " <>
            "request task."

        events ->
          Enum.map_join(events, " ", fn %{task_pid: request_task} ->
            "The request task #{inspect(request_task)} " <>
              "#{process_state(request_task, "had exited")}."
          end)
      end

    "#{inspect(__MODULE__)}.await/3: no reply from the task #{inspect(task.pid)} within " <>
      "#{timeout_ms} ms; the wait took #{elapsed_ms} ms. The task #{caller_state}. " <>
      request_tasks
  end

  defp process_state(pid, exited) do
    case Process.info(pid, [:status, :current_stacktrace, :message_queue_len]) do
      nil -> exited
      info -> "is alive, #{inspect(info, limit: :infinity, printable_limit: :infinity)}"
    end
  end

  # The forwarded events' metadata, in arrival order.
  defp drain_events do
    receive do
      {__MODULE__, metadata} -> [metadata | drain_events()]
    after
      0 -> []
    end
  end
end
