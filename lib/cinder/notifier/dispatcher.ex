defmodule Cinder.Notifier.Dispatcher do
  @moduledoc """
  The configured `:cinder, :notifier` default: fans one event out to every transport —
  `Log` (always), `Discord` (webhook, best-effort), `Email` (per-requester, best-effort)
  — each isolated so one transport's failure can't skip another's. `Cinder.Notifier.notify/1`
  also catches on top of this; that outer rescue is the last resort, this is what stops a
  single misbehaving transport from silently skipping its siblings before it's ever reached.
  """
  @behaviour Cinder.Notifier

  alias Cinder.Notifier.{Discord, Email, Log}

  require Logger

  @impl true
  def notify(event) do
    isolate(Log, event)
    isolate(Discord, event)
    isolate(Email, event)
    :ok
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
