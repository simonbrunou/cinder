defmodule Cinder.Notifier.Dispatcher do
  @moduledoc """
  The configured `:cinder, :notifier` default: fans one event out to every transport —
  `Log` (always), `Discord` (webhook, best-effort), `Email` (per-requester, best-effort),
  `Webhook` (generic JSON POST, best-effort)
  — each isolated so one transport's failure can't skip another's. `Cinder.Notifier.notify/1`
  also catches on top of this; that outer rescue is the last resort, this is what stops a
  single misbehaving transport from silently skipping its siblings before it's ever reached.

  Delivery runs **off the emitting pipeline's critical path**: each transport is dispatched as a
  supervised task under `Cinder.Notifier.TaskSupervisor`, bounded by a per-delivery timeout, so a
  slow SMTP relay or hung webhook can't wedge a poller tick (which would make `/healthz` report
  stale). `notify/1` returns as soon as the tasks are started. Set `config :cinder,
  :notifier_dispatch, :sync` to run inline instead (the test env does this so log/email assertions
  stay deterministic).
  """
  @behaviour Cinder.Notifier

  alias Cinder.Notifier.{Discord, Email, Log, Webhook}

  require Logger

  @transports [Log, Discord, Email, Webhook]
  @task_supervisor Cinder.Notifier.TaskSupervisor
  # Belt to each transport's own bound (Discord's 3s HTTP timeout, the mailer's SMTP timeout): a
  # genuinely wedged delivery is killed rather than piling zombie tasks under the supervisor.
  @delivery_timeout 30_000

  @impl true
  def notify(event) do
    case Application.get_env(:cinder, :notifier_dispatch, :async) do
      :sync -> Enum.each(@transports, &isolate(&1, event))
      _ -> Enum.each(@transports, &dispatch(&1, event))
    end

    :ok
  end

  # Fire-and-forget so the caller (a poller tick, the admin Approve handler) returns immediately;
  # the started task bounds the delivery itself with a nolink sub-task + timeout so nothing hangs.
  defp dispatch(transport, event) do
    Task.Supervisor.start_child(@task_supervisor, fn -> deliver_bounded(transport, event) end)
  end

  defp deliver_bounded(transport, event) do
    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> isolate(transport, event) end)

    case Task.yield(task, @delivery_timeout) || Task.shutdown(task, :brutal_kill) do
      nil ->
        Logger.warning("#{inspect(transport)} notify timed out for #{event_summary(event)}")

      _ ->
        :ok
    end
  end

  defp isolate(transport, event) do
    transport.notify(event)
  rescue
    _e ->
      Logger.warning("#{inspect(transport)} notify failed for #{event_summary(event)}")
  catch
    kind, _value ->
      Logger.warning("#{inspect(transport)} notify #{kind} for #{event_summary(event)}")
  end

  defp event_summary({type, payload, _reason}) when is_atom(type),
    do: event_summary({type, payload})

  defp event_summary({:user_registered, %{id: id}}) when is_integer(id),
    do: "user_registered user ##{id}"

  defp event_summary({type, %{id: id, user_id: user_id}})
       when is_atom(type) and is_integer(id) and is_integer(user_id),
       do: "#{type} ##{id} user ##{user_id}"

  defp event_summary({type, %{id: id}}) when is_atom(type) and is_integer(id),
    do: "#{type} ##{id}"

  defp event_summary({type, _payload}) when is_atom(type), do: Atom.to_string(type)
  defp event_summary(_event), do: "unknown_event"
end
