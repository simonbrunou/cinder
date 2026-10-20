defmodule Cinder.Download.Poller do
  @moduledoc """
  Polls the movie pipeline on each tick:

  1. **advance_downloading** — watches in-flight downloads (`:downloading`, and `:upgrading`
     replacements) through `Cinder.Download.Watch` and maps each verdict onto the movie
     lifecycle: a completed download is marked `:downloaded` (an upgrade imports at once), any
     trouble goes to `Cinder.Catalog.MovieLifecycle.record_failure/2`.
  2. **import_downloaded** — stages `:downloaded` movies into the library and records the result:
     `MovieLifecycle.import_staged/2`, `reject/2` for a proven policy mismatch, or
     `record_failure/2`.
  3. **search_requested** — sweeps `:requested` and `:searching` movies through
     `Download.start/1` (indexer search + client add). Backoff: a just-failed movie is skipped
     until `search_retry_after` seconds have elapsed; its failure is recorded once.

  What a failure means (count it, park, re-queue, revert or hold) is the lifecycle's decision,
  not the poller's. Holds no in-flight state: every tick re-derives its work from the DB, so it
  recovers cleanly after a crash/restart.
  """
  require Logger

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, MovieLifecycle}
  alias Cinder.Download
  alias Cinder.Download.Watch
  alias Cinder.Library
  alias Cinder.Library.StagedImport

  @default_interval 5_000
  @search_retry_after 60

  use Cinder.Download.PollerSkeleton, log_prefix: "poller"

  defp do_poll(state) do
    # Isolated like every per-unit pass below: a persistent raise here must not crash-loop the
    # whole GenServer forever with nothing parked and no signal (issue: preamble reliability).
    isolate("stage reconciliation", fn -> StagedImport.reconcile() end)

    isolate("pending intent reconciliation", fn ->
      Download.reconcile_pending_intents([:movie])
    end)

    advance_downloading()
    import_downloaded()
    search_requested(state.search_retry_after)
    :ok
  end

  defp advance_downloading do
    movies = Catalog.list_by_status(:downloading) ++ Catalog.list_by_status(:upgrading)
    for movie <- movies, do: isolate("movie #{movie.id}", fn -> advance(movie) end)
  end

  defp import_downloaded do
    for movie <- Catalog.list_by_status(:downloaded),
        do: isolate("movie #{movie.id}", fn -> import_under_lock(movie) end)
  end

  defp import_under_lock(movie),
    do: StagedImport.run(fn -> import_one(movie) end)

  defp search_requested(retry_after) do
    movies = Catalog.list_by_status(:requested) ++ Catalog.list_by_status(:searching)

    for movie <- movies, search_due?(movie, retry_after) do
      isolate("movie #{movie.id}", fn -> search_one(movie) end)
    end
  end

  defp search_one(movie) do
    case Download.start(movie) do
      {:ok, _movie} ->
        :ok

      {:error, :invalid_anime_preferences} ->
        Logger.info("movie #{movie.id} search held: invalid anime preferences")
        :ok

      # Not enough free disk for this release. Skip the grab this tick without bumping
      # search_attempts or parking — space may free up. The warning is throttled so a persistently
      # full disk doesn't flood the log every 5s tick.
      {:error, {:insufficient_disk_space, size}} ->
        warn_throttled(
          {:disk_grab, movie.id},
          "movie #{movie.id} grab skipped: insufficient free disk space for release " <>
            "(~#{Cinder.Disk.human_gb(size)} GB); will retry when space frees"
        )

        :ok

      # Nothing to retry — skip; the next tick re-derives. :stale_status means the movie was
      # cancelled/re-decided while this unit was in flight (the guarded transition skipped the
      # write); the rest are in-flight intent states.
      {:error, reason}
      when reason in [
             :stale_status,
             :intent_backoff,
             :cleanup_pending,
             :download_intent_busy,
             :intent_completed
           ] ->
        :ok

      {:error, reason} ->
        write_back_search(movie, reason)
    end
  end

  # Search-pass write-backs re-read the row first: Download.start advances it to
  # :searching mid-unit, and a concurrent user action (cancel/delete) may have taken
  # it out of the search pass entirely — then skip; the next tick re-derives. The
  # fresh row is the lifecycle's compare-and-swap expectation, preserving :searching
  # instead of reverting it to :requested.
  defp write_back_search(movie, reason) do
    case Catalog.get_movie_by_id(movie.id) do
      %Movie{status: status} = fresh when status in [:requested, :searching] ->
        MovieLifecycle.record_failure(fresh, reason)

      _ ->
        :ok
    end
  end

  # `Download.Watch` owns everything up to the verdict (client, status, content vetting, metrics,
  # the stall reaper); the lifecycle owns what each verdict does to the movie.
  defp advance(movie) do
    case Watch.check(movie, &MovieLifecycle.track/2) do
      {:completed, path} ->
        complete(movie, path)

      # Still in transit, or the client could not answer: leave it and retry next tick (a slow
      # download or a client blip must not count toward any budget).
      :downloading ->
        :ok

      {:unreachable, _reason} ->
        :ok

      failure ->
        MovieLifecycle.record_failure(movie, failure)
    end
  end

  # An :upgrading movie keeps its live file_path the whole time, so its completed replacement
  # imports at once by forced replace (the user chose this release) instead of passing through
  # :downloaded. The replacement's source is set on this local struct only; the row's
  # content_path stays nil through :upgrading.
  defp complete(%Movie{status: :upgrading} = movie, content_path) do
    StagedImport.run(fn ->
      upgrade = %{movie | content_path: content_path}
      upgrade |> Library.stage_movie(replace: true) |> record_import(upgrade)
    end)
  end

  defp complete(movie, content_path), do: MovieLifecycle.mark_downloaded(movie, content_path)

  defp import_one(movie) do
    # Pre-import disk guard on the movies library root. Hold (no attempt bump, no park) on a full
    # disk — the download is done and waiting, so don't burn the import budget on a fixable
    # condition. Throttled so a persistently full disk doesn't flood the log.
    if Cinder.Disk.import_space_available?(:movies, movie) do
      movie |> Library.stage_movie() |> record_import(movie)
    else
      warn_throttled(
        {:disk_import, movie.id},
        "movie #{movie.id} import held: movies library root is nearly full; will retry when space frees"
      )
    end
  end

  defp record_import({:ok, stage}, movie), do: MovieLifecycle.import_staged(movie, stage)

  # A provable policy violation: the lifecycle blocklists the release and moves the movie on.
  defp record_import({:error, {:release_policy_mismatch, evidence}}, movie),
    do: MovieLifecycle.reject(movie, evidence)

  # Hold (no attempt bump, no park) until the roots are configured: the file is downloaded and
  # waiting, so don't burn the retry budget on a fixable misconfig. The cause is visible — /status
  # shows the library red (Health.check("movies_library")).
  defp record_import({:error, :library_not_configured}, movie) do
    Logger.warning(
      "holding #{phase(movie)} for movie #{movie.id}: movies_library_path not set; configure it in /settings"
    )
  end

  defp record_import({:error, :download_roots_not_configured}, movie) do
    Logger.warning(
      "holding #{phase(movie)} for movie #{movie.id}: download import roots not configured; configure them in /settings"
    )
  end

  defp record_import({:error, reason}, movie), do: MovieLifecycle.record_failure(movie, reason)

  defp phase(%Movie{status: :upgrading}), do: "upgrade"
  defp phase(_movie), do: "import"
end
