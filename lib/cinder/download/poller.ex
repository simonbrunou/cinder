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
      {:ok, %{state: :completed, content_path: path}} when path not in [nil, ""] ->
        Catalog.transition(movie, %{status: :downloaded, file_path: path, import_attempts: 0})

      {:ok, %{state: :completed}} ->
        # Completed but no usable content_path. A genuinely-slow download is
        # :downloading (not :completed), so this is anomalous — bound it so it
        # can't sit at :downloading and re-poll forever (normally the path
        # appears within a tick or two and the clause above fires).
        retry_or_fail(movie, :no_content_path)

      # Still downloading, stalled, in transit, or a client error: leave it and
      # retry next tick (a slow download must not count toward the bound).
      _ ->
        :ok
    end
  end

  # Deterministic failures — the release itself is unusable, so retrying can't
  # help. Park them at :import_failed immediately. Other (transient) failures
  # are retried up to @max_attempts before being parked, so a permanent-but-not-
  # pre-classified condition (a read-only mount, a completed torrent that never
  # yields a path) can't loop and re-log forever.
  @permanent_import_errors [:no_file_path, :no_video_file]
  @max_attempts 10

  defp import_one(movie) do
    case Library.import_movie(movie) do
      {:ok, _dest} ->
        Catalog.transition(movie, %{status: :available})

      {:error, reason} when reason in @permanent_import_errors ->
        Logger.warning("import permanently failed for movie #{movie.id}: #{inspect(reason)}")
        Catalog.transition(movie, %{status: :import_failed})

      {:error, reason} ->
        retry_or_fail(movie, reason)
    end
  end

  # Bounded retry: keep the movie where it is and try again next tick, but after
  # @max_attempts park it at :import_failed so a persistent failure surfaces a
  # terminal state instead of looping (and re-logging) forever.
  defp retry_or_fail(movie, reason) do
    attempts = (movie.import_attempts || 0) + 1

    if attempts >= @max_attempts do
      Logger.warning("movie #{movie.id} failed after #{attempts} attempts: #{inspect(reason)}")
      Catalog.transition(movie, %{status: :import_failed})
    else
      Logger.info(
        "movie #{movie.id} attempt #{attempts}/#{@max_attempts} failed (#{inspect(reason)}); will retry"
      )

      Catalog.transition(movie, %{status: movie.status, import_attempts: attempts})
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
