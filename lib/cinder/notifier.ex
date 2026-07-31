defmodule Cinder.Notifier do
  @moduledoc """
  Out-of-band notification seam. `notify/1` dispatches a typed event to the configured impl
  (default `Cinder.Notifier.Dispatcher`, which fans out to `Log`, `Discord`, `Email`, and the
  generic `Webhook`). A
  side-effect that must never break the pipeline: a raising/exiting impl is caught, logged, and
  swallowed — the Dispatcher isolates each transport from the others the same way, so one
  transport failing can't skip its siblings.

  In-app reactivity (My-requests, per-title badges) rides the existing
  `"requests"`/`"movies"` PubSub topics, so the household-wide transports (Discord) exist for
  out-of-band awareness, and `Email` is the per-requester "get told when it's ready" channel.
  """
  require Logger

  @callback notify(event :: term()) :: :ok

  @spec notify(term()) :: :ok
  def notify(event) do
    impl().notify(event)
    :ok
  rescue
    e ->
      Logger.warning("notifier failed for #{inspect(event)}: #{Exception.message(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("notifier #{kind} for #{inspect(event)}: #{inspect(value)}")
      :ok
  end

  defp impl, do: Application.fetch_env!(:cinder, :notifier)
end
