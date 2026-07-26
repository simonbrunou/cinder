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
    e ->
      Logger.warning(
        "#{inspect(transport)} notify failed for #{inspect(event)}: #{Exception.message(e)}"
      )
  catch
    kind, value ->
      Logger.warning(
        "#{inspect(transport)} notify #{kind} for #{inspect(event)}: #{inspect(value)}"
      )
  end
end
