defmodule Cinder.Download.Poller do
  @moduledoc """
  Polls active downloads and advances them through the pipeline: `:downloading`
  → `:downloaded` (capturing the on-disk path), then imports `:downloaded`
  movies into the library → `:available` (or `:import_failed` for a release with
  no usable file). Each change broadcasts through `Catalog.transition/2`.

  Holds no in-flight state: every tick re-derives its work from the DB, so it
  recovers cleanly after a crash/restart. That is the OTP payoff Phase 3 proves.
  """
  use GenServer

  require Logger

  alias Cinder.Catalog
  alias Cinder.Library

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
    advance_downloading()
    import_downloaded()
    :ok
  end

  defp advance_downloading do
    for movie <- Catalog.list_by_status(:downloading), do: isolate(movie, &advance/1)
  end

  defp import_downloaded do
    for movie <- Catalog.list_by_status(:downloaded), do: isolate(movie, &import_one/1)
  end

  defp advance(movie) do
    case client().status(movie.download_id) do
      {:ok, %{state: :completed} = status} ->
        Catalog.transition(movie, %{
          status: :downloaded,
          file_path: Map.get(status, :content_path)
        })

      # Still downloading / stalled / in transit / error: leave it, retry next tick.
      _ ->
        :ok
    end
  end

  # Deterministic failures — the release itself is unusable, so retrying can't
  # help. Park them at :import_failed instead of re-failing (and re-logging)
  # every tick. Transient failures (media server down, etc.) stay :downloaded.
  @permanent_import_errors [:no_file_path, :no_video_file]

  defp import_one(movie) do
    case Library.import_movie(movie) do
      {:ok, _dest} ->
        Catalog.transition(movie, %{status: :available})

      {:error, reason} when reason in @permanent_import_errors ->
        Logger.warning("import permanently failed for movie #{movie.id}: #{inspect(reason)}")
        Catalog.transition(movie, %{status: :import_failed})

      {:error, reason} ->
        Logger.warning("import failed for movie #{movie.id}, will retry: #{inspect(reason)}")
    end
  end

  # Per-movie isolation: an unexpected raise skips that one movie (leaving it at
  # its current status for retry) instead of crashing the tick for the rest.
  defp isolate(movie, fun) do
    fun.(movie)
  rescue
    e -> Logger.error("poller skipped movie #{movie.id}: #{Exception.message(e)}")
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval, @default_interval)
  end

  defp client, do: Application.fetch_env!(:cinder, :download_client)
end
