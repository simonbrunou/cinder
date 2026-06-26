defmodule Cinder.Download.Poller do
  @moduledoc """
  Polls the pipeline on each tick:

  1. **advance_downloading** — checks in-flight downloads; `:downloading` →
     `:downloaded` (or `:import_failed` if the torrent completes with no path).
  2. **import_downloaded** — imports `:downloaded` movies into the library →
     `:available` (or `:import_failed` for a release with no usable file).
  3. **search_requested** — sweeps `:requested` and `:searching` movies through
     `Download.start/1` (indexer search + client add), advancing them toward
     `:downloading`. Backoff: a just-failed movie is skipped until
     `search_retry_after` seconds have elapsed. Bounded retry: after
     `@max_attempts` transient failures the movie parks at `:search_failed`.
     Permanent errors (`:unsupported_download_url`, `:bad_torrent`) park
     immediately.

  Holds no in-flight state: every tick re-derives its work from the DB, so it
  recovers cleanly after a crash/restart. That is the OTP payoff Phase 3 proves.
  """
  use GenServer

  require Logger

  alias Cinder.Catalog
  alias Cinder.Download
  alias Cinder.Library
  alias Cinder.Notifier

  @default_interval 5_000
  @search_retry_after 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one poll pass synchronously. The scheduled timer path is asynchronous."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config_interval())
    retry_after = Keyword.get(opts, :search_retry_after, @search_retry_after)
    {:ok, %{interval: interval, search_retry_after: retry_after}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    do_poll(state)
    {:reply, :ok, state}
  end

  defp do_poll(state) do
    advance_downloading()
    import_downloaded()
    search_requested(state.search_retry_after)
    :ok
  end

  defp advance_downloading do
    for movie <- Catalog.list_by_status(:downloading),
        do: isolate("movie #{movie.id}", fn -> advance(movie) end)
  end

  defp import_downloaded do
    for movie <- Catalog.list_by_status(:downloaded),
        do: isolate("movie #{movie.id}", fn -> import_one(movie) end)
  end

  defp search_requested(retry_after) do
    movies = Catalog.list_by_status(:requested) ++ Catalog.list_by_status(:searching)

    for movie <- movies, search_due?(movie, retry_after) do
      isolate("movie #{movie.id}", fn -> search_one(movie) end)
    end
  end

  # Permanent search failures — retrying can't help, so park immediately (mirrors
  # @permanent_import_errors). :unsupported_download_url = unknown URL scheme;
  # :bad_torrent = the fetched .torrent was malformed/not bencode.
  @permanent_search_errors [:unsupported_download_url, :bad_torrent]

  defp search_one(movie) do
    case Download.start(movie) do
      {:ok, _movie} ->
        :ok

      {:error, :no_imdb_id} ->
        park(movie, :no_match, :no_imdb_id)

      {:error, reason} when reason in @permanent_search_errors ->
        Logger.warning("movie #{movie.id} search failed permanently: #{inspect(reason)}")
        park(movie, :search_failed, reason)

      {:error, reason} ->
        # Re-read so the counter write preserves start/1's current status
        # (e.g. :searching after an indexer/client failure) instead of the stale
        # struct's, which would revert :searching -> :requested.
        movie |> reread() |> retry_or_fail(reason, :search_attempts, :search_failed)
    end
  end

  defp reread(movie), do: Catalog.get_movie_by_id(movie.id) || movie

  # Fresh movies (search_attempts == 0) attempt immediately; failed ones back off
  # to once per `retry_after` seconds (external services — don't hammer). retry_after
  # 0 (test) makes everything due.
  defp search_due?(_movie, 0), do: true
  defp search_due?(%{search_attempts: 0}, _retry_after), do: true

  defp search_due?(movie, retry_after),
    do: DateTime.diff(DateTime.utc_now(), movie.updated_at) >= retry_after

  defp advance(movie) do
    case Download.client_for(movie.download_protocol) do
      {:ok, client} ->
        advance_with(movie, client)

      # No client configured for this movie's protocol (e.g. a protocol removed
      # from config mid-download). Bound it through retry_or_fail so it parks at
      # a terminal state instead of re-raising every tick forever.
      :error ->
        retry_or_fail(movie, :no_client, :import_attempts, :import_failed)
    end
  end

  defp advance_with(movie, client) do
    case client.status(movie.download_id) do
      {:ok, %{state: :completed, content_path: path}} when path not in [nil, ""] ->
        Catalog.transition(movie, %{status: :downloaded, file_path: path, import_attempts: 0})

      {:ok, %{state: :completed}} ->
        # Completed but no usable content_path. A genuinely-slow download is
        # :downloading (not :completed), so this is anomalous — bound it so it
        # can't sit at :downloading and re-poll forever (normally the path
        # appears within a tick or two and the clause above fires).
        retry_or_fail(movie, :no_content_path, :import_attempts, :import_failed)

      {:ok, %{state: :error}} ->
        retry_or_fail(movie, :download_error, :import_attempts, :import_failed)

      {:error, :not_found} ->
        retry_or_fail(movie, :torrent_not_found, :import_attempts, :import_failed)

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
  # :wrong_audio_language is the MediaInfo check rejecting a confirmed wrong-language file — the
  # file's audio won't change, so re-importing it can't help; park at :import_failed. A /status
  # Retry re-searches and the name filter usually then prefers a correctly-tagged release; a soft
  # Original/Any pick whose only candidates are wrong-language can re-grab the same file, but Retry
  # is manual so that can't loop on its own.
  @permanent_import_errors [:no_file_path, :no_video_file, :wrong_audio_language]
  @max_attempts 10

  defp import_one(movie) do
    case Library.import_movie(movie) do
      {:ok, _dest} ->
        # On the (rare) transition error, leave the movie :downloaded for next-tick
        # retry rather than raising — matching the poller's ignore-and-retry convention.
        with {:ok, available} <- Catalog.transition(movie, %{status: :available}) do
          Notifier.notify({:movie_available, available})
          # After the DB commit (the file is recorded as imported): a best-effort, gated
          # remove of the source download. Failure is logged, never strands or re-imports.
          Download.remove_after_import(movie.download_protocol, movie.download_id)
        end

      {:error, :library_not_configured} ->
        # Hold (no attempt bump, no park) until the movie library root is configured: the file is
        # downloaded and waiting, so don't burn the retry budget on a fixable misconfig. The cause
        # is visible — /status shows the library red (Health.check_service({:library, :movies})).
        Logger.warning(
          "holding import for movie #{movie.id}: movies_library_path not set; configure it in /settings"
        )

      {:error, reason} when reason in @permanent_import_errors ->
        Logger.warning("import permanently failed for movie #{movie.id}: #{inspect(reason)}")
        park(movie, :import_failed, reason)

      {:error, reason} ->
        retry_or_fail(movie, reason, :import_attempts, :import_failed)
    end
  end

  # Bounded retry: keep the movie where it is and try again next tick, but after
  # @max_attempts park it at `terminal_status` so a persistent failure surfaces a
  # terminal state instead of looping (and re-logging) forever.
  defp retry_or_fail(movie, reason, attempts_field, terminal_status) do
    attempts = (Map.get(movie, attempts_field) || 0) + 1

    if attempts >= @max_attempts do
      Logger.warning(
        "movie #{movie.id} #{attempts_field} exhausted after #{attempts}: #{inspect(reason)}"
      )

      park(movie, terminal_status, reason)
    else
      Logger.info(
        "movie #{movie.id} #{attempts_field} #{attempts}/#{@max_attempts} failed (#{inspect(reason)}); will retry"
      )

      # Dynamic key MUST come before keyword pairs in a map literal.
      Catalog.transition(movie, %{attempts_field => attempts, status: movie.status})
    end
  end

  # A terminal failure park: transition once (the choke-point) then notify. Keeps
  # every "movie gave up" path emitting the same event with no per-site duplication.
  defp park(movie, status, reason) do
    with {:ok, parked} <- Catalog.transition(movie, %{status: status}),
         do: Notifier.notify({:movie_failed, parked, reason})
  end

  # Per-unit isolation: an unexpected raise OR exit (e.g. a DBConnection checkout
  # timeout under two-poller write contention — not rescue-able) skips that one unit
  # (leaving it at its current status for retry) instead of crashing the tick for the
  # rest. Mirrors `Cinder.Download.TvPoller.isolate/2`.
  defp isolate(label, fun) do
    fun.()
  rescue
    e -> Logger.error("poller skipped #{label}: #{Exception.message(e)}")
  catch
    kind, value -> Logger.error("poller skipped #{label}: #{inspect({kind, value})}")
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval, @default_interval)
  end
end
