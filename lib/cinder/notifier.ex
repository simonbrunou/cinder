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
      Logger.warning("notifier failed for #{summary(event)}: #{Exception.message(e)}")
      :ok
  catch
    kind, value ->
      Logger.warning("notifier #{kind} for #{summary(event)}: #{inspect(value)}")
      :ok
  end

  @doc """
  The event named for a warning line: its type and its subject's ids (`"sign_in_refused #7"`),
  never the subject itself. A `User` subject's email and Plex username are not redacted, so
  `inspect/1` would print them.
  """
  @spec summary(term()) :: String.t()
  def summary({type, payload, _reason}) when is_atom(type), do: summary({type, payload})

  def summary({:user_registered, %{id: id}}) when is_integer(id),
    do: "user_registered user ##{id}"

  def summary({type, %{id: id, user_id: user_id}})
      when is_atom(type) and is_integer(id) and is_integer(user_id),
      do: "#{type} ##{id} user ##{user_id}"

  def summary({type, %{id: id}}) when is_atom(type) and is_integer(id), do: "#{type} ##{id}"
  def summary({type, _payload}) when is_atom(type), do: Atom.to_string(type)
  def summary(_event), do: "unknown_event"

  defp impl, do: Application.fetch_env!(:cinder, :notifier)
end
