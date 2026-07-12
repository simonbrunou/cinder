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
  alias Cinder.Download.Intent
  alias Cinder.Library
  alias Cinder.Notifier

  @default_interval 5_000
  @search_retry_after 60

  use Cinder.Download.PollerSkeleton, log_prefix: "poller"

  defp do_poll(state) do
    Library.reconcile_stages()

    Download.reconcile_pending_intents([:movie], fn intent, reason ->
      isolate("movie #{intent.target_id} intent retry", fn ->
        account_movie_intent_retry(intent, reason)
      end)
    end)

    advance_downloading()
    import_downloaded()
    search_requested(state.search_retry_after)
    :ok
  end

  defp account_movie_intent_retry(%Intent{target_id: movie_id}, reason) do
    case Catalog.get_movie_by_id(movie_id) do
      %Movie{status: status} = movie when status in [:requested, :searching] ->
        retry_or_fail(
          movie,
          reason,
          :search_attempts,
          :search_failed,
          &park_after_intent_exhaustion/3
        )

      _other ->
        :ok
    end
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

      # The movie was cancelled/re-decided while this unit was in flight; the guarded
      # transition skipped the write. Nothing to retry — the next tick re-derives.
      {:error, :stale_status} ->
        :ok

      {:error, reason}
      when reason in [:intent_backoff, :cleanup_pending, :download_intent_busy, :intent_completed] ->
        :ok

      {:error, :no_imdb_id} ->
        write_back_search(movie, &park(&1, :no_match, :no_imdb_id))

      {:error, reason} when reason in @permanent_search_errors ->
        Logger.warning("movie #{movie.id} search failed permanently: #{inspect(reason)}")
        write_back_search(movie, &park(&1, :search_failed, reason))

      {:error, reason} ->
        write_back_search(movie, &retry_or_fail(&1, reason, :search_attempts, :search_failed))
    end
  end

  # Search-pass write-backs re-read the row first: Download.start advances it to
  # :searching mid-unit, and a concurrent user action (cancel/delete) may have taken
  # it out of the search pass entirely — then skip; the next tick re-derives. The
  # fresh status feeds each guarded transition's expect:, preserving :searching
  # instead of reverting it to :requested.
  defp write_back_search(movie, fun) do
    case Catalog.get_movie_by_id(movie.id) do
      %Movie{status: status} = fresh when status in [:requested, :searching] -> fun.(fresh)
      _ -> :ok
    end
  end

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
        Catalog.transition(movie, %{status: :downloaded, file_path: path, import_attempts: 0},
          expect: movie.status
        )

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

      {:ok, %{state: :downloading} = status} ->
        Catalog.update_movie_download_metrics(movie, %{
          download_progress: Map.get(status, :progress),
          download_speed: Map.get(status, :speed),
          download_eta: Map.get(status, :eta)
        })

      {:error, _reason} ->
        Catalog.update_movie_download_metrics(movie, %{
          download_progress: nil,
          download_speed: nil,
          download_eta: nil
        })

      # Still stalled or in transit: leave it and retry next tick (a slow download
      # must not count toward the bound).
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
    case Library.stage_movie(movie) do
      {:ok, %{dest: dest, quality: q} = stage} ->
        # On the (rare) transition error, leave the movie :downloaded for next-tick
        # retry rather than raising — matching the poller's ignore-and-retry convention.
        # file_path moves from the download source to the library destination (the imported
        # hardlink) so delete_files unlinks the actual library file, not the download copy.
        case Catalog.transition(
               movie,
               %{
                 status: :available,
                 file_path: dest,
                 imported_resolution: q.resolution,
                 imported_size: q.size,
                 imported_language: q.language,
                 imported_source: q.source,
                 imported_audio_languages: q.audio_languages,
                 imported_embedded_subtitles: q.embedded_subtitles,
                 imported_sidecar_subtitles: q.sidecar_subtitles
               },
               expect: movie.status,
               import_stage_ids: Library.stage_ids([stage])
             ) do
          {:ok, available} ->
            finish_stage(stage, :commit)
            Notifier.notify({:movie_available, available})
            # After the DB commit (the file is recorded as imported): a best-effort, gated
            # remove of the source download. Failure is logged, never strands or re-imports.
            Download.remove_after_import(movie.download_protocol, movie.download_id)

          # Cancelled/deleted while the import unit was hardlinking: no row will ever
          # point at dest, so unlink it or the media server scans an orphaned file.
          {:error, :stale_status} ->
            Logger.info("movie #{movie.id} left the import pass mid-import; unlinking #{dest}")
            finish_stage(stage, :rollback)

          {:error, _} ->
            finish_stage(stage, :rollback)
        end

      {:error, :library_not_configured} ->
        # Hold (no attempt bump, no park) until the movie library root is configured: the file is
        # downloaded and waiting, so don't burn the retry budget on a fixable misconfig. The cause
        # is visible — /status shows the library red (Health.check_service({:library, :movies})).
        Logger.warning(
          "holding import for movie #{movie.id}: movies_library_path not set; configure it in /settings"
        )

      {:error, :download_roots_not_configured} ->
        Logger.warning(
          "holding import for movie #{movie.id}: download import roots not configured; configure them in /settings"
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
  defp retry_or_fail(movie, reason, attempts_field, terminal_status),
    do: retry_or_fail(movie, reason, attempts_field, terminal_status, &park/3)

  defp retry_or_fail(movie, reason, attempts_field, terminal_status, park_fun) do
    attempts = (Map.get(movie, attempts_field) || 0) + 1

    if attempts >= @max_attempts do
      Logger.warning(
        "movie #{movie.id} #{attempts_field} exhausted after #{attempts}: #{inspect(reason)}"
      )

      park_fun.(movie, terminal_status, reason)
    else
      Logger.info(
        "movie #{movie.id} #{attempts_field} #{attempts}/#{@max_attempts} failed (#{inspect(reason)}); will retry"
      )

      # Dynamic key MUST come before keyword pairs in a map literal.
      Catalog.transition(
        movie,
        %{
          attempts_field => attempts,
          status: movie.status,
          download_progress: nil,
          download_speed: nil,
          download_eta: nil
        },
        expect: movie.status
      )
    end
  end

  defp park_after_intent_exhaustion(movie, :search_failed, reason) do
    with {:ok, parked} <- Catalog.fail_movie_search(movie) do
      Notifier.notify({:movie_failed, parked, reason})
    end
  end

  # A terminal failure park: transition once (the choke-point) then notify. Keeps
  # every "movie gave up" path emitting the same event with no per-site duplication.
  defp park(movie, status, reason) do
    with {:ok, parked} <- Catalog.transition(movie, %{status: status}, expect: movie.status) do
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

      {:ok, %{state: :downloading} = status} ->
        Catalog.update_movie_download_metrics(movie, %{
          download_progress: Map.get(status, :progress),
          download_speed: Map.get(status, :speed),
          download_eta: Map.get(status, :eta)
        })

      {:error, _reason} ->
        Catalog.update_movie_download_metrics(movie, %{
          download_progress: nil,
          download_speed: nil,
          download_eta: nil
        })

      # Still stalled or in transit: wait, no write, live file untouched.
      _ ->
        :ok
    end
  end

  # Import the completed download by FORCED replace (the user chose this release). On success the
  # library file is swapped (replace/2) and the movie returns :available carrying the new quality;
  # if the new dest filename differs (a different container) the old file is removed best-effort so
  # the library never holds two files. Any failure reverts to :available, live file intact.
  defp finish_upgrade(movie, content_path) do
    case Library.stage_movie(%{movie | file_path: content_path}, replace: true) do
      {:ok, %{dest: dest, quality: q} = stage} ->
        movie
        |> Catalog.transition(
          %{
            status: :available,
            file_path: dest,
            imported_resolution: q.resolution,
            imported_size: q.size,
            imported_language: q.language,
            imported_source: q.source,
            imported_audio_languages: q.audio_languages,
            imported_embedded_subtitles: q.embedded_subtitles,
            imported_sidecar_subtitles: q.sidecar_subtitles
          },
          expect: movie.status,
          import_stage_ids: Library.stage_ids([stage])
        )
        |> case do
          {:ok, available} ->
            finish_stage(stage, :commit)
            finalize_upgrade(movie, available, dest)

          {:error, :stale_status} ->
            compensate_aborted_upgrade(movie, stage)

          {:error, _} ->
            finish_stage(stage, :rollback)
        end

      {:error, :library_not_configured} ->
        # Hold (no attempt bump, no revert) until the movie library root is configured: the file is
        # downloaded and waiting, so don't burn the retry budget on a fixable misconfig.
        Logger.warning(
          "holding upgrade for movie #{movie.id}: movies_library_path not set; configure it in /settings"
        )

      {:error, :download_roots_not_configured} ->
        Logger.warning(
          "holding upgrade for movie #{movie.id}: download import roots not configured; configure them in /settings"
        )

      {:error, reason} when reason in @permanent_import_errors ->
        revert_upgrade(movie, reason)

      {:error, reason} ->
        retry_or_revert(movie, reason)
    end
  end

  defp compensate_aborted_upgrade(movie, stage) do
    Logger.info("movie #{movie.id} upgrade aborted mid-swap; restoring the prior library file")
    finish_stage(stage, :rollback)
  end

  defp finish_stage(stage, action) do
    result =
      case action do
        :commit -> Library.commit_stage(stage)
        :rollback -> Library.rollback_stage(stage)
      end

    if match?({:error, _}, result),
      do: Logger.warning("movie import stage cleanup remains pending")

    result
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

      Catalog.transition(
        movie,
        %{
          import_attempts: attempts,
          status: :upgrading,
          download_progress: nil,
          download_speed: nil,
          download_eta: nil
        },
        expect: movie.status
      )
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
           Catalog.transition(
             movie,
             %{
               status: :available,
               download_id: nil,
               download_protocol: nil,
               release_title: nil
             },
             expect: movie.status
           ) do
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
