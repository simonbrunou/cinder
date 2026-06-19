defmodule Cinder.Download.Poller do
  @moduledoc """
  Polls active (`:downloading`) movies via the download client and advances them
  to `:downloaded`, broadcasting each change (through `Catalog.transition/2`).

  Holds no in-flight state: every tick re-derives its work from the DB, so it
  recovers cleanly after a crash/restart. That is the OTP payoff Phase 3 proves.
  """
  use GenServer

  alias Cinder.Catalog

  @default_interval 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one poll pass synchronously. The scheduled timer path is asynchronous."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config_interval())
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    do_poll()
    {:reply, :ok, state}
  end

  defp do_poll do
    for movie <- Catalog.list_by_status(:downloading) do
      case client().status(movie.download_id) do
        {:ok, %{state: :completed}} -> Catalog.transition(movie, %{status: :downloaded})
        # Anything else (still downloading, stalled, error): leave it, retry next tick.
        _ -> :ok
      end
    end

    :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval, @default_interval)
  end

  defp client, do: Application.fetch_env!(:cinder, :download_client)
end
