defmodule Cinder.Download.TvPoller do
  @moduledoc """
  The TV sibling of `Cinder.Download.Poller`. Polls the episode pipeline on each tick:

  1. **advance** — checks in-flight grabs (`list_grabs_downloading`); a completed download with a
     `content_path` is marked downloaded, an anomalous/errored one is bounded-retried and parked.
  2. **import** — imports downloaded grabs (`list_grabs_downloaded`) via `Library.import_episodes`,
     mapping each file to its episode; on success the grab is finalized, on a transient FS error
     it is bounded-retried, on a deterministic empty import it is parked (its episodes re-search).
  3. **search** — sweeps `wanted_episodes`, skipping search-parked and backed-off episodes, then
     searches Standard series by season and Anime series by stable episode IDs.

  Holds no in-flight state: every tick re-derives its work from the DB, so it recovers cleanly
  after a crash/restart — the same OTP payoff the movie poller proves. State and the download
  client are shared with the movie pipeline (`Cinder.Download.client_for/1`); episode/grab writes
  go through `Cinder.Catalog` choke-points, so the WAL + `busy_timeout` correctness holds.

  Bounded retry uses the grab's `download_attempts` counter; `mark_grab_downloaded` resets it at
  the download→import boundary, so the advance and import phases each get a fresh `@max_attempts`
  budget (a download's blips don't starve its import). An unavailable policy probe preserves the
  content in a durable verification hold at that bound. The search phase backs off per
  `episode.search_attempts`/`updated_at` exactly like the movie poller, and an episode parks
  (derived `:search_parked`) at `Catalog.max_search_attempts/0` — the crossing is warned +
  announced by Catalog at the counter's write site, covering every bump path.
  """
  require Logger

  alias Cinder.{Acquisition, Catalog, Download, Library, Notifier, Settings}
  alias Cinder.Acquisition.AnimePreferences
  alias Cinder.Catalog.Grab
  alias Cinder.HTTPPolicy

  @default_interval 5_000
  @search_retry_after 60
  @max_attempts 10

  # Download-side failures that only reach park after exhausting @max_attempts retries
  # (advance_with/2) — symmetric with the movie poller's @download_failure_errors. Past
  # exhaustion the release itself is the problem, so the grab's release is blocklisted.
  @download_failure_errors [:download_error, :torrent_not_found, :no_content_path]

  use Cinder.Download.PollerSkeleton, log_prefix: "tv poller"

  defp do_poll(state) do
    Library.reconcile_stages()
    Download.reconcile_pending_intents([:episode, :season_pack])
    advance_grabs()
    import_grabs()
    search_wanted(state.search_retry_after)
    :ok
  end

  # --- advance: in-flight downloads ------------------------------------------------------------

  defp advance_grabs do
    for grab <- Catalog.list_grabs_downloading(),
        do: isolate("grab #{grab.id}", fn -> advance(grab) end)
  end

  defp advance(grab) do
    case Download.client_for(grab.download_protocol) do
      {:ok, client} -> advance_with(grab, client)
      # No client for this grab's protocol (e.g. removed from config mid-download): bound it so
      # it parks instead of re-raising every tick.
      :error -> retry_or_park(grab, :no_client)
    end
  end

  defp advance_with(grab, client) do
    case client.status(grab.download_id) do
      {:ok, %{state: :completed, content_path: path}} when path not in [nil, ""] ->
        Catalog.mark_grab_downloaded(grab, path)

      # Completed but no usable path / errored / vanished: anomalous, so bound it rather than
      # re-polling forever. A still-downloading or transient client error just waits (no bump).
      {:ok, %{state: :completed}} ->
        retry_or_park(grab, :no_content_path)

      {:ok, %{state: :error}} ->
        retry_or_park(grab, :download_error)

      {:error, :not_found} ->
        retry_or_park(grab, :torrent_not_found)

      {:ok, %{state: :downloading} = status} ->
        Catalog.update_grab_download_metrics(grab, %{
          download_progress: Map.get(status, :progress),
          download_speed: Map.get(status, :speed),
          download_eta: Map.get(status, :eta)
        })

      {:error, _reason} ->
        Catalog.update_grab_download_metrics(grab, %{
          download_progress: nil,
          download_speed: nil,
          download_eta: nil
        })

      _ ->
        :ok
    end
  end

  # --- import: downloaded grabs ----------------------------------------------------------------

  defp import_grabs do
    for grab <- Catalog.list_grabs_downloaded(),
        do: isolate("grab #{grab.id}", fn -> import_grab(grab) end)
  end

  defp import_grab(%Grab{mapping_snapshot: nil} = grab), do: import_standard_grab(grab)

  defp import_grab(%Grab{} = grab) do
    case Library.preflight_anime_grab(grab) do
      {:ok, preflight} ->
        import_preflighted_grab(preflight)

      {:needs_mapping, _result} ->
        :ok

      {:error, :library_not_configured} ->
        hold_for_configuration(grab, :tv_library_path)

      {:error, :download_roots_not_configured} ->
        hold_for_configuration(grab, :download_import_roots)

      {:error, reason} ->
        retry_or_park(grab, reason)
    end
  end

  defp import_preflighted_grab(preflight) do
    case Library.stage_anime_episodes(preflight.grab, preflight) do
      {:ok, staged} ->
        finalize_staged_grab(preflight.grab, staged)

      {:restart_preflight, :inventory_changed} ->
        :ok

      {:error, {:release_policy_mismatch, evidence}} ->
        reject_release(preflight.grab, evidence)

      {:error, {:release_policy_unavailable, reason}} ->
        retry_or_hold_verification(preflight.grab, reason)

      {:error, reason} ->
        retry_or_park(preflight.grab, reason)
    end
  end

  # A provable policy violation (mismatch) is a discard, not a hold: the grab is blocklisted and
  # deleted (Catalog.reject_grab_release), so its download-side source is no longer needed and is
  # deleted the same way a successful import's is (issue #115's gap) — the verification-hold path
  # (retry_or_hold_verification) never reaches here and must keep the files for operator inspection.
  # download_id is nil here on purpose: reject_grab_release already fences + cleans up the
  # client-tracked job, so passing the real id would remove it a second time.
  defp reject_release(grab, evidence) do
    case Catalog.reject_grab_release(grab, evidence) do
      {:ok, _grab} ->
        Download.remove_after_import(grab.download_protocol, nil, grab.content_path)
        :ok

      {:error, :stale_release} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_standard_grab(grab) do
    case Library.stage_episodes(grab.content_path, grab.episodes) do
      {:ok, [], _unmatched} ->
        # Deterministic: nothing in content_path mapped to a grab episode. Re-importing can't
        # help, so park — the episodes re-search (bounded), rather than re-importing forever.
        Logger.warning(
          "tv grab #{grab.id} imported nothing from #{HTTPPolicy.sanitize_log(grab.content_path)}; parking"
        )

        park(grab, :no_files_matched)

      {:ok, staged, _unmatched} ->
        finalize_staged_grab(grab, staged)

      # A missing TV root is a config error, not a transient one: leave the grab downloaded
      # (no bump, no park) so the already-downloaded content imports as soon as tv_library_path
      # is set — parking would delete the download and re-search the episode for nothing.
      {:error, :library_not_configured} ->
        hold_for_configuration(grab, :tv_library_path)

      {:error, :download_roots_not_configured} ->
        hold_for_configuration(grab, :download_import_roots)

      # Every remaining error is transient (a filesystem hiccup): the one deterministic
      # "unusable content" case surfaces as {:ok, [], _} above and is parked immediately, so
      # unlike the movie poller there is no @permanent_*_errors set to classify here.
      {:error, reason} ->
        retry_or_park(grab, reason)
    end
  end

  defp finalize_staged_grab(grab, staged) do
    imported =
      Enum.map(staged, fn {episode_id, stage} -> {episode_id, stage.dest, stage.quality} end)

    case Catalog.finish_grab(
           grab,
           imported,
           Library.stage_ids(Enum.map(staged, &elem(&1, 1)))
         ) do
      {:ok, _grab} ->
        commit_stages(staged)
        Download.remove_after_import(grab.download_protocol, grab.download_id, grab.content_path)

      {:error, :stale_grab} ->
        rollback_stages(staged)

      {:error, reason} ->
        rollback_stages(staged)
        retry_or_park(grab, {:finish_grab, reason})
    end
  end

  defp hold_for_configuration(grab, :tv_library_path) do
    Logger.warning(
      "tv grab #{grab.id}: tv_library_path not set; holding the download until it is configured"
    )
  end

  defp hold_for_configuration(grab, :download_import_roots) do
    Logger.warning(
      "tv grab #{grab.id}: download import roots not configured; holding the download until they are configured"
    )
  end

  defp commit_stages(staged) do
    staged
    |> unique_stages()
    |> Enum.each(&finish_stage(&1, :commit))
  end

  defp rollback_stages(staged) do
    staged
    |> unique_stages()
    |> Enum.each(&finish_stage(&1, :rollback))
  end

  defp finish_stage(stage, action) do
    result =
      case action do
        :commit -> Library.commit_stage(stage)
        :rollback -> Library.rollback_stage(stage)
      end

    if match?({:error, _}, result),
      do: Logger.warning("TV import stage cleanup remains pending")

    result
  end

  defp unique_stages(staged),
    do: staged |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.dest)

  # --- search: wanted episodes -----------------------------------------------------------------

  defp search_wanted(retry_after) do
    pending = Download.pending_episode_ids()

    Catalog.wanted_episodes()
    |> Enum.reject(
      &(MapSet.member?(pending, &1.id) or
          &1.search_attempts >= Catalog.max_search_attempts())
    )
    |> Enum.filter(&search_due?(&1, retry_after))
    |> Enum.group_by(& &1.season.series.id)
    |> Enum.each(fn {series_id, episodes} ->
      isolate("series #{series_id}", fn -> search_series(episodes) end)
    end)
  end

  defp search_series(episodes) do
    series = hd(episodes).season.series

    case Catalog.media_profile_summary(series).effective do
      :anime ->
        search_anime_series(series, episodes)

      :standard ->
        # A profile switched back to Standard must not keep a stale Anime hold marker.
        Catalog.set_anime_hold(series, nil)
        search_standard_series(series, episodes)
    end
  end

  defp search_standard_series(series, episodes) do
    episodes
    |> Enum.group_by(& &1.season.season_number)
    |> Enum.each(fn {season_number, group} ->
      isolate("series #{series.id} s#{season_number}", fn -> search_standard_group(group) end)
    end)
  end

  defp search_standard_group(episodes) do
    series = hd(episodes).season.series
    season_number = hd(episodes).season.season_number
    numbers = Enum.map(episodes, & &1.episode_number)

    case Acquisition.best_releases(series, season_number, numbers, search_opts(series)) do
      {:ok, assignments} ->
        grabbed = Enum.flat_map(assignments, &grab_assignment(&1, episodes))
        bump_not_grabbed(episodes, grabbed)

      :no_match ->
        bump_not_grabbed(episodes, [])

      {:error, reason} ->
        Logger.info(
          "tv search failed for series #{series.id} season #{season_number}: #{HTTPPolicy.sanitize_log(reason)}"
        )

        bump_not_grabbed(episodes, [])
    end
  end

  defp search_anime_series(series, episodes) do
    wanted_ids = Enum.map(episodes, & &1.id)
    context = Catalog.anime_series_acquisition_context(series)

    case AnimePreferences.resolve(series, Settings.anime_defaults()) do
      {:ok, policy} ->
        Catalog.set_anime_hold(series, nil)
        search_anime_with_policy(series, episodes, context, wanted_ids, policy)

      {:error, reason} ->
        # DB-visible hold (surfaced on /activity), re-evaluated every sweep: the next
        # tick with satisfiable preferences clears it and searches normally.
        Catalog.set_anime_hold(series, reason)
        Logger.info("anime search held for series #{series.id}: invalid preferences")
        :ok
    end
  end

  defp search_anime_with_policy(series, episodes, context, wanted_ids, policy) do
    opts = search_opts(series) ++ AnimePreferences.selection_opts(policy)

    case Acquisition.best_anime_releases(context, wanted_ids, opts) do
      {:ok, %{assignments: assignments, waiting: waiting}} ->
        grabbed = Enum.flat_map(assignments, &grab_anime_assignment/1)
        held = if waiting, do: waiting.episode_ids, else: []
        bump_not_grabbed(episodes, grabbed ++ held)

      {:waiting_for_preferred_group, waiting} ->
        bump_not_grabbed(episodes, waiting.episode_ids)

      :no_match ->
        bump_not_grabbed(episodes, [])

      {:error, reason} ->
        Logger.info(
          "anime search failed for series #{series.id}: #{HTTPPolicy.sanitize_log(reason)}"
        )

        bump_not_grabbed(episodes, [])
    end
  end

  defp search_opts(series) do
    [
      protocols: Download.available_protocols(),
      preferred_language: series.preferred_language,
      original_language: series.original_language,
      release_blocklist: Catalog.blocked_release_titles_for_series(series.id)
    ] ++ Acquisition.band_opts(:tv)
  end

  # Add one chosen release to its client and create the grab linking exactly the episodes it
  # covers. Returns the linked episode ids (so the caller backs off only the rest).
  defp grab_assignment({release, covered_numbers}, episodes) do
    episode_ids =
      episodes |> Enum.filter(&(&1.episode_number in covered_numbers)) |> Enum.map(& &1.id)

    case Download.grab_episodes(release, episode_ids) do
      {:ok, _grab} ->
        episode_ids

      other ->
        Logger.warning(
          "tv grab failed (#{HTTPPolicy.sanitize_log(release.title)}): #{HTTPPolicy.sanitize_log(other)}"
        )

        []
    end
  end

  defp grab_anime_assignment(%{release: release, episode_ids: episode_ids}) do
    case Download.grab_episodes(release, episode_ids) do
      {:ok, _grab} -> episode_ids
      _failure -> []
    end
  end

  # Crossing the search cap is announced by Catalog.increment_search_attempts itself (at the
  # write site, so the finish_grab/park_grab bump path announces too — not just this sweep).
  defp bump_not_grabbed(episodes, grabbed) do
    episodes
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 in grabbed))
    |> Catalog.increment_search_attempts()
  end

  # --- shared helpers --------------------------------------------------------------------------

  # Bounded retry on the grab's single lifetime counter: keep it where it is and retry next tick,
  # but after @max_attempts park it (delete + bump its episodes' search_attempts) so a persistent
  # failure surfaces instead of looping forever.
  defp retry_or_park(%Grab{} = grab, reason) do
    attempts = (grab.download_attempts || 0) + 1

    if attempts >= @max_attempts do
      Logger.warning(
        "tv grab #{grab.id} exhausted after #{attempts}: #{HTTPPolicy.sanitize_log(reason)}"
      )

      park(grab, reason)
    else
      Logger.info(
        "tv grab #{grab.id} attempt #{attempts}/#{@max_attempts} failed (#{HTTPPolicy.sanitize_log(reason)}); will retry"
      )

      Catalog.increment_grab_attempts(grab)
    end
  end

  defp retry_or_hold_verification(%Grab{} = grab, reason) do
    attempts = (grab.download_attempts || 0) + 1

    if attempts == @max_attempts do
      Logger.warning(
        "tv grab #{grab.id} verification held after #{attempts}: #{HTTPPolicy.sanitize_log(reason)}"
      )

      case Catalog.hold_grab_verification(grab) do
        {:ok, _held} -> :ok
        {:error, :stale_grab} -> :ok
      end
    else
      Logger.info(
        "tv grab #{grab.id} verification attempt #{attempts}/#{@max_attempts} unavailable (#{HTTPPolicy.sanitize_log(reason)}); will retry"
      )

      Catalog.increment_grab_attempts(grab)
    end
  end

  # Single terminal-park choke-point: drop the grab and notify, mirroring the movie poller's
  # park/3. Both TV terminal-park sites (empty import, retry exhaustion) route through here so a
  # failed grab is never silent — symmetric with {:movie_failed, _, _}.
  defp park(grab, reason) do
    # Block BEFORE park_grab deletes the grab: block_grab_release resolves the series from the
    # grab's still-linked episodes (the grab_id FK nilifies them on delete). It is non-raising,
    # so it cannot abort the park (a raise here would re-park the grab every tick). :no_files_matched
    # is the deterministic empty-import; the download-side reasons only reach park post-exhaustion.
    if reason == :no_files_matched or reason in @download_failure_errors do
      Catalog.block_grab_release(grab, reason)
    end

    # park_grab IS finish_grab(grab, []) — if the finalize transaction itself is what keeps
    # failing, notifying here would fire {:grab_failed} every 5s tick forever. Warn instead;
    # the grab stays visible in /activity and the warning names why it won't finalize.
    case Catalog.park_grab(grab) do
      {:ok, _} ->
        Notifier.notify({:grab_failed, grab, reason})

      {:error, park_error} ->
        Logger.warning(
          "tv grab #{grab.id} could not be parked (#{HTTPPolicy.sanitize_log(park_error)}); will retry next tick"
        )
    end
  end
end
