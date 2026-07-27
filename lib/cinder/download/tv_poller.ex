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
  alias Cinder.Acquisition.{Anime, AnimePreferences}
  alias Cinder.Catalog.{Episode, Grab}
  alias Cinder.Download.StallReaper
  alias Cinder.HTTPPolicy

  @default_interval 5_000
  @search_retry_after 60

  # Download-side failures that only reach park after exhausting @max_attempts retries
  # (advance_with/2) — symmetric with the movie poller's @download_failure_errors. Past
  # exhaustion the release itself is the problem, so the grab's release is blocklisted.
  @download_failure_errors [:download_error, :torrent_not_found, :no_content_path]

  use Cinder.Download.PollerSkeleton, log_prefix: "tv poller"

  defp do_poll(state) do
    # Isolated like every per-unit pass below: a persistent raise here must not crash-loop the
    # whole GenServer forever with nothing parked and no signal (issue: preamble reliability).
    isolate("stage reconciliation", fn -> Library.reconcile_stages() end)

    isolate("pending intent reconciliation", fn ->
      Download.reconcile_pending_intents([:episode, :season_pack])
    end)

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

      {:ok, %{state: :error} = status} ->
        retry_or_park(grab, download_error_reason(status))

      {:error, :not_found} ->
        retry_or_park(grab, :torrent_not_found)

      {:ok, %{state: :downloading} = status} ->
        Catalog.update_grab_download_metrics(grab, %{
          download_progress: Map.get(status, :progress),
          download_speed: Map.get(status, :speed),
          download_eta: Map.get(status, :eta)
        })

        maybe_reap(grab, status)

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

  # ponytail: the stall clock is DERIVED from grab.updated_at — Catalog.update_grab_download_metrics
  # is change-gated, so a stalled grab (progress frozen, speed a hard 0, eta sentinel → nil) writes
  # nothing and updated_at freezes at the stall onset. Same coupling to @download_metric_fields + the
  # eta normalization as the movie poller (see StallReaper's moduledoc).
  defp maybe_reap(grab, status) do
    if StallReaper.enabled?() and StallReaper.reap?(grab.updated_at, status, DateTime.utc_now()) do
      case Catalog.reap_stalled_grab(grab) do
        {:ok, _reaped} ->
          Logger.warning(
            "tv grab #{grab.id} reaped: stalled download removed; episodes re-searching"
          )

        {:error, _reason} ->
          :ok
      end
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
        reject_release(
          preflight.grab,
          evidence,
          preflight.grab.content_path,
          &Catalog.reject_grab_release/2
        )

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
  # `reject_release/4` (the shared movie/TV helper) lives in `Cinder.Download.PollerSkeleton`.

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
        remove_superseded_episode_files(grab.episodes)
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

  defp unique_stages(staged),
    do: staged |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.dest)

  # The Catalog commit has moved every imported row to its verified new destination. Remove old
  # primary/part files only now, and only when no episode still references them (a multi-episode
  # file may also belong to an uncovered sibling).
  defp remove_superseded_episode_files(episodes) do
    referenced =
      Catalog.list_episodes_with_file()
      |> Enum.flat_map(&Episode.file_paths/1)
      |> MapSet.new()

    episodes
    |> Enum.flat_map(&Episode.file_paths/1)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(referenced, &1))
    |> Enum.each(&best_effort_remove_old/1)
  end

  defp best_effort_remove_old(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("tv upgrade: couldn't remove #{path}: #{inspect(reason)}")
    end
  end

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
    context = Catalog.anime_series_acquisition_context(series)
    groups = Enum.group_by(episodes, & &1.season.season_number)
    native_seasons = MapSet.new(Map.keys(groups))

    groups
    |> Enum.each(fn {season_number, group} ->
      isolate("series #{series.id} s#{season_number}", fn ->
        search_standard_group(group, context, native_seasons)
      end)
    end)
  end

  defp search_standard_group(episodes, context, native_seasons) do
    series = hd(episodes).season.series
    season_number = hd(episodes).season.season_number
    numbers = Enum.map(episodes, & &1.episode_number)
    opts = search_opts(series)
    numbering = alternate_numbering(context, episodes, native_seasons)

    opts =
      if map_size(numbering) == 0,
        do: opts,
        else: Keyword.put(opts, :alternate_numbering, numbering)

    case Acquisition.best_releases(series, season_number, numbers, opts) do
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

  defp alternate_numbering(context, episodes, native_seasons) do
    wanted_by_id = Map.new(episodes, &{&1.id, &1.episode_number})
    wanted_ids = MapSet.new(Map.keys(wanted_by_id))
    scene_seasons = MapSet.new(Anime.scene_seasons(context, Map.keys(wanted_by_id)))

    context.mappings
    |> Enum.filter(fn mapping ->
      mapping.identity.scheme == "scene" and
        not MapSet.disjoint?(MapSet.new(mapping.episode_ids), wanted_ids)
    end)
    |> Enum.map(& &1.identity.canonical_value)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn value, numbering ->
      with {alternate_season, alternate_episode} <-
             Episode.season_and_episode_from_code(value),
           false <- MapSet.member?(native_seasons, alternate_season),
           true <- MapSet.member?(scene_seasons, alternate_season),
           {:ok, episode_ids, _evidence} <-
             Anime.resolve_episode_coordinate("standard", value, context.mappings),
           true <- MapSet.subset?(MapSet.new(episode_ids), wanted_ids) do
        canonical_numbers = Enum.map(episode_ids, &Map.fetch!(wanted_by_id, &1))

        Map.update(
          numbering,
          alternate_season,
          %{alternate_episode => canonical_numbers},
          &Map.put(&1, alternate_episode, canonical_numbers)
        )
      else
        _unusable -> numbering
      end
    end)
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
      {:ok, _grab} ->
        episode_ids

      failure ->
        Logger.warning(
          "anime grab failed (#{HTTPPolicy.sanitize_log(release.title)}): #{HTTPPolicy.sanitize_log(failure)}"
        )

        []
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
    # `reason` may carry a human detail (`{:download_error, "paused"}`) — it rode through the retry
    # log so the operator sees it; the grab itself is transient (deleted here), so only the
    # classifying `code` is used for the blocklist/notify (a per-episode reason field would be the
    # only persistence surface, and that's out of scope for the transient grab model).
    code = reason_code(reason)

    # Block BEFORE park_grab deletes the grab: block_grab_release resolves the series from the
    # grab's still-linked episodes (the grab_id FK nilifies them on delete). It is non-raising,
    # so it cannot abort the park (a raise here would re-park the grab every tick). :no_files_matched
    # is the deterministic empty-import; the download-side reasons only reach park post-exhaustion.
    if code == :no_files_matched or code in @download_failure_errors do
      Catalog.block_grab_release(grab, code)
    end

    # park_grab IS finish_grab(grab, []) — if the finalize transaction itself is what keeps
    # failing, notifying here would fire {:grab_failed} every 5s tick forever. Warn instead;
    # the grab stays visible in /activity and the warning names why it won't finalize.
    case Catalog.park_grab(grab) do
      {:ok, _} ->
        :telemetry.execute([:cinder, :park], %{count: 1}, %{kind: :episode, reason: code})
        Notifier.notify({:grab_failed, grab, code})

      {:error, park_error} ->
        Logger.warning(
          "tv grab #{grab.id} could not be parked (#{HTTPPolicy.sanitize_log(park_error)}); will retry next tick"
        )
    end
  end
end
