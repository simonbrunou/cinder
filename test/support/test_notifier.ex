defmodule Cinder.TestNotifier do
  @moduledoc """
  Test notifier: re-broadcasts each event on the `"notifications"` PubSub topic so
  tests can `assert_receive {:notify, event}`. Cross-process safe (the poller calls
  the notifier from its own process), and avoids fighting the suite's `:warning`
  log level. The production default is `Cinder.Notifier.Log`.
  """
  @behaviour Cinder.Notifier

  @topic "notifications"

  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @impl true
  def notify(event) do
    Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, {:notify, event})
    :ok
  end
end
