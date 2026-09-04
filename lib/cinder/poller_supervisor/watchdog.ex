defmodule Cinder.PollerSupervisor.Watchdog do
  @moduledoc """
  Logs loudly, once, if `Cinder.PollerSupervisor` terminates (#456).

  `Cinder.PollerSupervisor` is started with `restart: :temporary` (see
  `Cinder.Application.start/2`) precisely so a permanently crash-looping poller can exhaust that
  supervisor's own restart budget without `Cinder.Supervisor` ever attempting — and eventually
  exhausting its own budget over — repeated restarts of it. The tradeoff: once
  `Cinder.PollerSupervisor` is gone, nothing brings it back automatically, and nothing else in the
  supervision tree would otherwise notice that every background worker (search pollers,
  refreshers, sweeps, backups, the janitor) has silently stopped. This process exists solely to
  make that loud instead of silent, at `:error`, so an operator reading logs — or alerting on them
  — can see it and act (fix the underlying cause, e.g. a bad `interval` config value, then restart
  the application).
  """
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.monitor(Cinder.PollerSupervisor)
    {:ok, []}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.error(
      "Cinder.PollerSupervisor terminated (#{inspect(reason)}) and will not be restarted " <>
        "(restart: :temporary) — every background worker (search, refresh, cleanup, backups) " <>
        "has stopped. Fix the underlying cause and restart the application."
    )

    {:noreply, state}
  end
end
