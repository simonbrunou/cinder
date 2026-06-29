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
  require Logger

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Download
  alias Cinder.Library
  alias Cinder.Notifier

  @default_interval 5_000
  @search_retry_after 60

  use Cinder.Download.PollerSkeleton, log_prefix: "poller"

  defp do_poll(state) do
    advance_downloading()
    import_downloaded()
    search_requested(state.search_retry_after)
    :ok
  end

  defp advance_downloading do
    # :upgrading is swept alongside :downloading — an :available movie re-downloading a chosen
    # replacement. It dispatches to its OWN advance clause (never the :downloading one, which would
    # overwrite the live file_path with the download path before the swap).
    movies = Catalog.list_by_status(:downloading) ++ Catalog.list_by_status(:upgrading)
    for movie <- movies, do: isolate("movie #{movie.id}", fn -> advance(movie) end)
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

  # An :upgrading movie re-downloads a user-chosen replacement while its file_path STILL points at
  # the live library file. It must never reuse the clause below (which writes file_path: content_path
  # on completion) — that would destroy the live pointer. Its own path swaps the file atomically.
  defp advance(%Movie{status: :upgrading} = movie), do: advance_upgrade(movie)

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

  # Download-side failures that only reach park AFTER exhausting @max_attempts retries (see
  # advance_with/2): a reason that has burned 10 retries is, by definition, not transient — it's
  # the "repeatedly-failing torrents/usenet" the blocklist is meant to bound. So a single network
  # blip can never block a good release; only post-exhaustion does park record it.
  @download_failure_errors [:download_error, :torrent_not_found, :no_content_path]
  @max_attempts 10

  defp import_one(movie) do
    case Library.import_movie(movie) do
      {:ok, dest, q} ->
        # On the (rare) transition error, leave the movie :downloaded for next-tick
        # retry rather than raising — matching the poller's ignore-and-retry convention.
        # file_path moves from the download source to the library destination (the imported
        # hardlink) so delete_files unlinks the actual library file, not the download copy.
        with {:ok, available} <-
               Catalog.transition(movie, %{
                 status: :available,
                 file_path: dest,
                 imported_resolution: q.resolution,
                 imported_size: q.size,
                 imported_language: q.language,
                 imported_source: q.source
               }) do
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
    with {:ok, parked} <- Catalog.transition(movie, %{status: status}) do
      Notifier.notify({:movie_failed, parked, reason})

      # Best-effort, AFTER the park commits (a side effect like the notify above): record the
      # failed release so the next search/Retry doesn't re-grab it. Only deterministic import
      # failures and exhausted download-side failures qualify; block_release is a nil-guarded
      # no-op for pre-grab parks (no release_title was ever written) and never raises.
      if reason in @permanent_import_errors or reason in @download_failure_errors do
        Catalog.block_release(parked, reason)
      end
    end
  end

  # --- upgrade: re-download + atomic replace of an :available movie's file -----------------------
  #
  # An :upgrading movie keeps its live file_path the entire time; only the success transition
  # (after Library.import_movie's atomic replace) rewrites it. Every failure reverts to :available
  # with the live file untouched. Mirrors the :downloading advance bound (@max_attempts via
  # import_attempts) but reverts instead of parking — the movie already has a usable file.

  defp advance_upgrade(movie) do
    case Download.client_for(movie.download_protocol) do
      {:ok, client} -> advance_upgrade_with(movie, client)
      # No client for this protocol (a config glitch, not a release failure): revert without
      # blocklisting (revert_upgrade gates the blocklist), live file untouched.
      :error -> revert_upgrade(movie, :no_client)
    end
  end

  defp advance_upgrade_with(movie, client) do
    case client.status(movie.download_id) do
      {:ok, %{state: :completed, content_path: path}} when path not in [nil, ""] ->
        finish_upgrade(movie, path)

      {:ok, %{state: :completed}} ->
        retry_or_revert(movie, :no_content_path)

      {:ok, %{state: :error}} ->
        retry_or_revert(movie, :download_error)

      {:error, :not_found} ->
        retry_or_revert(movie, :torrent_not_found)

      # Still downloading / stalled / transient client error: wait, no write, live file untouched.
      _ ->
        :ok
    end
  end

  # Import the completed download by FORCED replace (the user chose this release). On success the
  # library file is swapped (replace/2) and the movie returns :available carrying the new quality;
  # if the new dest filename differs (a different container) the old file is removed best-effort so
  # the library never holds two files. Any failure reverts to :available, live file intact.
  defp finish_upgrade(movie, content_path) do
    case Library.import_movie(%{movie | file_path: content_path}, replace: true) do
      {:ok, dest, q} ->
        with {:ok, available} <-
               Catalog.transition(movie, %{
                 status: :available,
                 file_path: dest,
                 imported_resolution: q.resolution,
                 imported_size: q.size,
                 imported_language: q.language,
                 imported_source: q.source
               }),
             do: finalize_upgrade(movie, available, dest)

      {:error, :library_not_configured} ->
        # Hold (no attempt bump, no revert) until the movie library root is configured: the file is
        # downloaded and waiting, so don't burn the retry budget on a fixable misconfig.
        Logger.warning(
          "holding upgrade for movie #{movie.id}: movies_library_path not set; configure it in /settings"
        )

      {:error, reason} when reason in @permanent_import_errors ->
        revert_upgrade(movie, reason)

      {:error, reason} ->
        retry_or_revert(movie, reason)
    end
  end

  # Post-commit side effects, all best-effort (none can unwind the committed upgrade): remove the
  # superseded file only when the dest path actually changed (a same-path replace already overwrote
  # it), drop the source download, and notify.
  defp finalize_upgrade(movie, available, dest) do
    if dest != movie.file_path, do: best_effort_remove_old(movie.file_path)
    Download.remove_after_import(movie.download_protocol, movie.download_id)
    Notifier.notify({:movie_available, available})
  end

  # Bounded retry on the upgrade's download/transient-import side; after @max_attempts, revert.
  defp retry_or_revert(movie, reason) do
    attempts = (movie.import_attempts || 0) + 1

    if attempts >= @max_attempts do
      revert_upgrade(movie, reason)
    else
      Logger.info(
        "movie #{movie.id} upgrade #{attempts}/#{@max_attempts} failed (#{inspect(reason)}); will retry"
      )

      Catalog.transition(movie, %{import_attempts: attempts, status: :upgrading})
    end
  end

  # Abort the upgrade WITHOUT touching the live file: blocklist the failed release (read off the
  # still-present release_title BEFORE the revert clears it), then revert to :available clearing the
  # upgrade's download fields. Blocklist only genuine release failures (mirrors park/3) so a config
  # glitch (:no_client) doesn't blocklist a good release.
  defp revert_upgrade(movie, reason) do
    if reason in @permanent_import_errors or reason in @download_failure_errors,
      do: Catalog.block_release(movie, :upgrade_failed)

    with {:ok, reverted} <-
           Catalog.transition(movie, %{
             status: :available,
             download_id: nil,
             download_protocol: nil,
             release_title: nil
           }) do
      Logger.warning("movie #{movie.id} upgrade reverted to :available (#{inspect(reason)})")
      Notifier.notify({:movie_upgrade_failed, reverted, reason})
    end
  end

  defp best_effort_remove_old(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("upgrade: couldn't remove old file #{inspect(path)}: #{inspect(reason)}")
    end
  end
end
