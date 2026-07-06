defmodule Cinder.Notifier do
  @moduledoc """
  Out-of-band notification seam. `notify/1` dispatches a typed event to the
  configured impl (default `Cinder.Notifier.Discord`, which delegates to `Cinder.Notifier.Log`
  and posts to Discord only when a webhook is configured). A side-effect that must never
  break the pipeline: a raising/exiting impl is caught, logged, and swallowed.

  In-app reactivity (My-requests, per-title badges) rides the existing
  `"requests"`/`"movies"` PubSub topics, so the default impl only logs. This
  behaviour is the seam for real transports (Discord/email) later.
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
