defmodule Cinder.Download.TvPoller do
  @moduledoc """
  The TV sibling of `Cinder.Download.Poller`. Polls the episode pipeline on each tick:

  1. **advance** — checks in-flight grabs (`list_grabs_downloading`); a completed download with a
     `content_path` is marked downloaded, an anomalous/errored one is bounded-retried and parked.
  2. **import** — stages downloaded grabs (`list_grabs_downloaded`), commits clean standard-TV
     matches immediately, and durably holds unmatched videos on the grab for operator review.
     A clean grab closes normally; transient FS errors are bounded-retried, and content with no
     usable video is parked so its episodes re-search.
  3. **search** — sweeps `wanted_episodes`, skipping search-parked and backed-off episodes, then
     searches Standard series by season and Anime series by stable episode IDs.

  Holds no in-flight state: every tick re-derives its work from the DB, so it recovers cleanly
  after a crash/restart — the same OTP payoff the movie poller proves. State and the download
  watch are shared with the movie pipeline (`Cinder.Download.Watch.check/2`); episode/grab writes
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
  import Ecto.Query

  alias Cinder.{Acquisition, Catalog, Disk, Download, Library, Notifier, Settings}
  alias Cinder.Acquisition.{AnimePreferences, HouseholdPolicy, ReleaseJudge}
  alias Cinder.Catalog.{Episode, Grab, Grabs, MediaProfile}
  alias Cinder.Download.Watch
  alias Cinder.HTTPPolicy
  alias Cinder.Library.StagedImport
  alias Cinder.Repo

  @default_interval 5_000
  @search_retry_after 60
  @max_attempts 10

  use Cinder.Download.PollerSkeleton, log_prefix: "tv poller"

  defp do_poll(state) do
    # Isolated like every per-unit pass below: a persistent raise here must not crash-loop the
    # whole GenServer forever with nothing parked and no signal (issue: preamble reliability).
    isolate("stage reconciliation", fn -> StagedImport.reconcile() end)

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

  # `Download.Watch` owns everything up to the verdict (client, status, content vetting, metrics,
  # the stall reaper); this maps each verdict onto the grab's own transition.
  defp advance(grab) do
    case Watch.check(grab, &Catalog.update_grab_download_metrics/2) do
      {:completed, path} ->
        Catalog.mark_grab_downloaded(grab, path)

      # Completed but no usable path / errored / vanished: anomalous, so bound it rather than
      # re-polling forever.
      {:failed, reason} ->
        retry_or_park(grab, reason)

      # Deterministic: a fake's file list won't improve, so a blocked verdict skips retry_or_park's
      # attempt budget and parks on the first sighting. #413: the client removal used to be a bare
      # best-effort call fired BEFORE the park deleted the grab (the grab's only durable record of
      # `download_id`/`download_protocol`) — a transient removal failure leaked the remote job
      # forever. `park/2` now routes `:blocked_content` through `Catalog.park_grab_and_remove/1`,
      # which fences a `:cleanup_pending` intent and deletes the grab in the SAME transaction (no
      # crash window between them), then makes the immediate best-effort removal attempt after
      # commit; a crash or failure there just leaves the fenced row for the next tick's
      # `reconcile_pending_intents/1` to retry. The delete still lands before the removal attempt,
      # so the payload still stops arriving as soon as this tick's cleanup runs.
      {:blocked_content, _detail} = reason ->
        park(grab, reason)

      :stalled ->
        reap(grab)

      # No client for this grab's protocol (e.g. removed from config mid-download): bound it so
      # it parks instead of re-raising every tick.
      :no_client ->
        retry_or_park(grab, :no_client)

      # Still in transit, or a transient client error: wait, no bump.
      :downloading ->
        :ok

      {:unreachable, _reason} ->
        :ok
    end
  end

  defp reap(grab) do
    case Catalog.reap_stalled_grab(grab) do
      {:ok, _reaped} ->
        Logger.warning(
          "tv grab #{grab.id} reaped: stalled download removed; episodes re-searching"
        )

      {:error, _reason} ->
        :ok
    end
  end

  # --- import: downloaded grabs ----------------------------------------------------------------

  defp import_grabs do
    for grab <- Catalog.list_grabs_downloaded(),
        do: isolate("grab #{grab.id}", fn -> import_under_lock(grab) end)
  end

  defp import_under_lock(grab),
    do: StagedImport.run(fn -> import_grab(grab) end)

  defp import_grab(%Grab{mapping_snapshot: nil, grab_files: [_ | _]} = grab) do
    if Enum.all?(grab.grab_files, & &1.decision),
      do: finalize_residual_grab(grab),
      else: :ok
  end

  defp import_grab(%Grab{} = grab) do
    # Pre-import disk guard on the TV library root. Hold (no attempt bump, no park) on a full disk —
    # the download is done and waiting, so don't burn the retry budget on a fixable condition.
    if Disk.import_space_available?(:tv, grab.episodes) do
      import_grab_content(grab)
    else
      warn_throttled(
        {:disk_import, grab.id},
        "tv grab #{grab.id} import held: tv library root is nearly full; will retry when space frees"
      )
    end
  end

  defp import_grab_content(%Grab{mapping_snapshot: nil} = grab), do: import_standard_grab(grab)

  defp import_grab_content(%Grab{} = grab) do
    case Library.preflight_anime_grab(grab) do
      {:ok, preflight} ->
        import_preflighted_grab(preflight)

      {:needs_mapping, _result} ->
        :ok

      {:error, :library_not_configured} ->
        hold_for_configuration(grab, :tv_library_path)

      {:error, :download_roots_not_configured} ->
        hold_for_configuration(grab, :download_import_roots)

      {:error, :timeout} ->
        hold_for_mount(grab)

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

      {:error, :timeout} ->
        hold_for_mount(preflight.grab)

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
  # `:stale_release` means the grab moved on concurrently: nothing is left to reject.
  defp reject_release(%Grab{} = grab, evidence) do
    case Catalog.reject_grab_release(grab, evidence) do
      {:ok, _deleted} ->
        Download.remove_after_import(grab.download_protocol, nil, grab.content_path)

      {:error, :stale_release} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_standard_grab(grab) do
    case Library.stage_episodes(grab.content_path, grab.episodes,
           arbitrate: grab.arbitrate_at_import,
           already_held: already_held_episodes(grab),
           release_title: grab.release_title
         ) do
      {:ok, staged, unmatched} ->
        finalize_standard_staging(grab, staged, unmatched)

      # A missing TV root is a config error, not a transient one: leave the grab downloaded
      # (no bump, no park) so the already-downloaded content imports as soon as tv_library_path
      # is set — parking would delete the download and re-search the episode for nothing.
      {:error, :library_not_configured} ->
        hold_for_configuration(grab, :tv_library_path)

      {:error, :download_roots_not_configured} ->
        hold_for_configuration(grab, :download_import_roots)

      {:error, :timeout} ->
        hold_for_mount(grab)

      # Every remaining error is transient (a filesystem hiccup): the one deterministic
      # "unusable content" case surfaces as {:ok, [], _} above and is parked immediately, so
      # unlike the movie poller there is no @permanent_*_errors set to classify here.
      {:error, reason} ->
        retry_or_park(grab, reason)
    end
  end

  # This grab's own series, so a pack's files for episodes we already hold are recognised instead
  # of inventoried as operator decisions (#251). The grab's own episodes are excluded: an upgrade
  # grab links episodes that DO have a file, and they must stay claimable by the staging pass.
  defp already_held_episodes(grab) do
    case grab.episodes do
      [%{season: %{series_id: series_id}} | _] ->
        linked = MapSet.new(grab.episodes, & &1.id)

        series_id
        |> Catalog.list_episodes_with_file()
        |> Enum.reject(&MapSet.member?(linked, &1.id))

      _no_episodes ->
        []
    end
  end

  defp finalize_standard_staging(grab, staged, unmatched) do
    if StagedImport.record(staged) == [] do
      # Deterministic: nothing in content_path mapped to a grab episode. Re-importing can't
      # help, so park — the episodes re-search (bounded), rather than re-importing forever.
      Logger.warning(
        "tv grab #{grab.id} imported nothing from #{HTTPPolicy.sanitize_log(grab.content_path)}; parking"
      )

      park(grab, :no_files_matched)
    else
      case inventory_standard_residuals(grab, unmatched) do
        {:ok, residuals} ->
          finalize_standard_grab(grab, staged, residuals)

        {:error, reason} ->
          StagedImport.rollback(staged)
          retry_or_park(grab, {:grab_file_inventory, reason})
      end
    end
  end

  defp inventory_standard_residuals(grab, unmatched) do
    Library.inventory_grab_files(grab.content_path, unmatched, grab.episodes)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, value -> {:error, {kind, value}}
  end

  # #415: `Catalog.commit_grab_imports/4`'s `:closed` branch deletes `grab` — the only durable
  # record of `download_id`/`download_protocol` (episodes carry no such column) — inside its own
  # already-committed transaction, before `remove_after_import` ever runs. `imported` (already
  # computed below) names exactly the episodes that got a file THIS round — the same set
  # `commit_grab_imports/4` itself derives internally to decide which episodes are "missing" and
  # bumps back into the wanted pool. Fencing only those (not every episode the grab ever linked)
  # matters: `commit_grab_imports/4` releases the missing ones with `grab_id: nil` for
  # `search_wanted/1` to re-pick up, and `Download.pending_episode_ids/0` excludes anything the
  # cleanup carrier still reserves — over-reserving a missed episode would silently stop
  # re-searching it for as long as the (unrelated) remote-cleanup intent lives.
  defp finalize_standard_grab(grab, staged, residuals) do
    imported_ids = staged |> StagedImport.record() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    case StagedImport.commit(staged, &Catalog.commit_grab_imports(grab, &1, residuals, &2)) do
      {:ok, :closed, _grab} ->
        remove_superseded_episode_files(grab.episodes)

        Download.remove_after_import(grab.download_protocol, grab.download_id, grab.content_path,
          fence: episode_cleanup_fence(grab, imported_ids)
        )

      {:ok, :open, _grab} ->
        remove_superseded_episode_files(grab.episodes)

      {:error, :stale_grab} ->
        :ok

      {:error, reason} ->
        retry_or_park(grab, {:commit_grab_imports, reason})
    end
  end

  @doc """
  Applies one explicit residual-file decision and attempts the existing guarded close.

  Part staging happens before the Catalog transaction; any rejected/racing decision rolls it
  back. A committed decision is restart-safe because the next poll tick retries the close.
  """
  def resolve_grab_file(file_id, episode_id, decision)
      when is_integer(file_id) and is_integer(episode_id) and decision in [:fold, :part] do
    case Grabs.get_grab_file_resolution(file_id, episode_id) do
      {:ok, :noop, file} ->
        finalize_residual_grab(file.grab)
        {:ok, :noop, file}

      {:ok, :pending, file, episode} ->
        apply_grab_file_decision(file, episode, decision)

      {:error, _reason} = error ->
        error
    end
  end

  def resolve_grab_file(_file_id, _episode_id, _decision),
    do: {:error, :invalid_grab_file_decision}

  @doc """
  Discards one residual file and attempts the existing guarded close.

  The file-only counterpart of `resolve_grab_file/3`: no episode is named, so nothing is staged
  before the Catalog transaction and nothing needs rolling back after it. Restart-safe the same
  way — a committed decision is closed by the next poll tick.
  """
  def discard_grab_file(file_id) when is_integer(file_id) do
    case Grabs.get_grab_file(file_id) do
      {:ok, :noop, file} ->
        finalize_residual_grab(file.grab)
        {:ok, :noop, file}

      {:ok, :pending, file} ->
        case Catalog.discard_grab_file(file) do
          {:ok, _state, _file} = result ->
            finalize_residual_grab(file.grab)
            result

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_grab_file_decision(file, episode, :fold) do
    case Catalog.decide_grab_file(file, episode, :fold, nil) do
      {:ok, _state, _file} = result ->
        finalize_residual_grab(file.grab)
        result

      {:error, _reason} = error ->
        error
    end
  end

  # A `:noop` decision (another operator already decided this file) commits nothing, so the
  # staged part rolls back with it.
  defp apply_grab_file_decision(file, episode, :part) do
    with {:ok, staged} <- Library.stage_grab_file_part(file.grab, file, episode) do
      case StagedImport.commit(staged, &Catalog.decide_grab_file(file, episode, :part, {&1, &2})) do
        {:ok, _state, _file} = result ->
          finalize_residual_grab(file.grab)
          result

        {:error, _reason} = error ->
          error
      end
    end
  end

  # #415: `Catalog.close_grab/1` deletes `grab` inside its own already-committed transaction,
  # before `remove_after_import` ever runs. Unlike `finalize_standard_grab/3`/
  # `finalize_staged_grab/2`, no local `imported` list is available here (residual decisions are
  # applied one file at a time, elsewhere) — `imported_episode_ids/1` reads which of `grab`'s
  # episodes already carry a file BEFORE `close_grab` runs. `close_grab/1` never adds a file to an
  # episode that doesn't already have one at this point (fold/part/discard decisions already ran
  # against it); it only finalizes bookkeeping and bumps whatever's left bare back to the wanted
  # pool — so this snapshot exactly matches what `close_grab/1` itself will keep as "imported"
  # once it returns.
  @doc false
  def finalize_residual_grab(%Grab{} = grab) do
    imported_ids = imported_episode_ids(grab.id)

    case Catalog.close_grab(grab) do
      {:ok, :closed, _grab} ->
        Download.remove_after_import(grab.download_protocol, grab.download_id, grab.content_path,
          fence: episode_cleanup_fence(grab, imported_ids)
        )

        {:ok, :closed}

      {:error, :unresolved_grab_files} ->
        {:ok, :open}

      {:error, :stale_grab} ->
        {:ok, :stale}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_staged_grab(%Grab{arbitrate_at_import: true} = grab, staged),
    do: finalize_standard_grab(grab, staged, [])

  # #415: `Catalog.finish_grab/3` deletes `grab` inside its own already-committed transaction,
  # before `remove_after_import` ever runs. `imported` (already computed below) names exactly the
  # episodes that got a file this round — same reasoning as `finalize_standard_grab/3`.
  defp finalize_staged_grab(grab, staged) do
    imported_ids = staged |> StagedImport.record() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    # `finish_grab/3` takes `{episode_id, dest, quality}`: an anime grab that is not arbitrated
    # never declines, so every row's `placed?` is true.
    finish = fn rows, stage_ids ->
      imported =
        Enum.map(rows, fn {episode_id, dest, quality, _placed?} -> {episode_id, dest, quality} end)

      Catalog.finish_grab(grab, imported, stage_ids)
    end

    case StagedImport.commit(staged, finish) do
      {:ok, _grab} ->
        remove_superseded_episode_files(grab.episodes)

        Download.remove_after_import(grab.download_protocol, grab.download_id, grab.content_path,
          fence: episode_cleanup_fence(grab, imported_ids)
        )

      {:error, :stale_grab} ->
        :ok

      {:error, reason} ->
        retry_or_park(grab, {:finish_grab, reason})
    end
  end

  # Shared by all three `#415` fence sites above. `nil` (no fence) when nothing survived to fence
  # — an empty `episode_ids` would crash `Download.fence_episode_cleanup/2`'s carrier insert on
  # `hd([])` (mirroring `Catalog.Grabs.fence_client_intent_ids/1`'s own empty-list guard); it
  # degrades to `remove_after_import/4`'s legacy one-shot removal instead, exactly like a genuine
  # fence-vs-unrelated-intent mismatch.
  defp episode_cleanup_fence(_grab, []), do: nil

  defp episode_cleanup_fence(grab, episode_ids),
    do: {:episode, episode_ids, Catalog.grab_cleanup_spec(grab, episode_ids)}

  # Episodes still linked to `grab_id` that already carry a file — read BEFORE the caller's
  # Catalog call finalizes the grab (which nilifies every linked episode's `grab_id`, imported or
  # not, so this can't be reconstructed afterward). See `finalize_residual_grab/1`'s doc comment.
  defp imported_episode_ids(grab_id) do
    Repo.all(
      from e in Episode,
        where: e.grab_id == ^grab_id and not is_nil(e.file_path) and e.file_path != "",
        select: e.id
    )
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

  # The download folder's walk is past its deadline (`Cinder.Library.BoundedWalk`, #779). A wedged
  # mount says nothing about the release, so hold without a strike: parking would delete the
  # grab and re-search the episodes for content that imports once the mount answers.
  defp hold_for_mount(grab) do
    warn_throttled(
      {:walk_timeout, grab.id},
      "tv grab #{grab.id}: its download folder did not answer in time; a mount may be wedged. " <>
        "Holding the download until it answers"
    )
  end

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
    summary = Catalog.media_profile_summary(series)

    case summary.effective do
      :anime -> search_anime_series(series, episodes)
      :standard -> search_standard_series(series, episodes, summary)
    end
  end

  defp search_standard_series(series, episodes, summary) do
    groups = Enum.group_by(episodes, & &1.season.season_number)

    outcomes =
      Enum.map(groups, fn {season_number, group} ->
        result =
          isolate("series #{series.id} s#{season_number}", fn ->
            search_standard_group(group)
          end)

        {group, result}
      end)

    grabbed =
      Enum.flat_map(outcomes, fn
        {_group, {:ok, ids}} -> ids
        {_group, _other} -> []
      end)

    skipped =
      Enum.flat_map(outcomes, fn
        {_group, {:ok, _ids}} -> []
        {_group, {:error, _reason}} -> []
        {group, _exception} -> Enum.map(group, & &1.id)
      end)

    search_failed? = Enum.any?(outcomes, &match?({_group, {:error, _reason}}, &1))

    # One decision on the Anime hold per visit: the anime fallback makes it when it runs, otherwise
    # a stale marker goes the way the operator's fix would take it (#791).
    if grabbed == [] and skipped == [] and not search_failed? and
         MediaProfile.auto_anime_fallback?(summary) do
      search_anime_series(series, episodes)
    else
      Catalog.reresolve_anime_hold(series)
      bump_not_grabbed(episodes, grabbed ++ skipped)
    end
  end

  # The season's release list is the manual panel's (`Acquisition.judge_season/3`); the sweep
  # claims only the episodes due this tick.
  defp search_standard_group(episodes) do
    series = hd(episodes).season.series
    season_number = hd(episodes).season.season_number
    numbers = Enum.map(episodes, & &1.episode_number)
    context = Catalog.season_acquisition_context(series, season_number)

    with {:ok, judged} <-
           Acquisition.judge_season(context, numbers, HouseholdPolicy.for_target(series)),
         {:ok, assignments} <- ReleaseJudge.pick(judged) do
      {:ok, Enum.flat_map(assignments, &grab_assignment(&1, episodes))}
    else
      :no_match ->
        {:ok, []}

      {:error, reason} ->
        Logger.info(
          "tv search failed for series #{series.id} season #{season_number}: #{HTTPPolicy.sanitize_log(reason)}"
        )

        {:error, reason}
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
    opts = HouseholdPolicy.for_target(series) ++ [anime_policy: policy]

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

  # Add one chosen release to its client and create the grab linking exactly the episodes it
  # covers. Returns the linked episode ids (so the caller backs off only the rest).
  defp grab_assignment({release, covered_numbers}, episodes) do
    episode_ids =
      episodes |> Enum.filter(&(&1.episode_number in covered_numbers)) |> Enum.map(& &1.id)

    grab_release(release, episode_ids)
  end

  defp grab_anime_assignment(%{release: release, episode_ids: episode_ids}) do
    grab_release(release, episode_ids)
  end

  # Add one chosen release to its client, guarded on free disk. Returns the episode ids the caller
  # must NOT bump: those actually grabbed, and — on a disk skip — those held for next tick (space
  # may free up, so a full disk never burns a search attempt or parks the title). A genuine grab
  # failure returns `[]`, so those episodes back off normally.
  defp grab_release(release, episode_ids) do
    if Disk.grab_space_available?(release.size) do
      case Download.grab_episodes(release, episode_ids) do
        {:ok, _grab} ->
          episode_ids

        failure ->
          Logger.warning(
            "tv grab failed (#{HTTPPolicy.sanitize_log(release.title)}): #{HTTPPolicy.sanitize_log(failure)}"
          )

          []
      end
    else
      warn_throttled(
        {:disk_grab, release.title},
        "tv grab skipped for #{HTTPPolicy.sanitize_log(release.title)}: insufficient free disk space " <>
          "(~#{Disk.human_gb(release.size)} GB); will retry when space frees"
      )

      episode_ids
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

  # Single terminal-park choke-point: drop the grab and notify, mirroring the movie lifecycle's
  # park. Both TV terminal-park sites (empty import, retry exhaustion) route through here so a
  # failed grab is never silent — symmetric with {:movie_failed, _, _}.
  defp park(grab, reason) do
    # `reason` may carry a human detail (`{:download_error, "paused"}`) — it rode through the retry
    # log so the operator sees it; the grab itself is transient (deleted here), so only the
    # classifying `code` is used for the blocklist/notify (a per-episode reason field would be the
    # only persistence surface, and that's out of scope for the transient grab model).
    code = Watch.reason_code(reason)

    # Block BEFORE park_grab deletes the grab: block_grab_release resolves the series from the
    # grab's still-linked episodes (the grab_id FK nilifies them on delete). It is non-raising,
    # so it cannot abort the park (a raise here would re-park the grab every tick). :no_files_matched
    # is the deterministic empty-import; :blocked_content is the deterministic fake-content check
    # (both park on first sighting); a download failure (`Watch.failure?/1`) only reaches park
    # once retry_or_park/2 has spent @max_attempts on it.
    blocked? = code in [:no_files_matched, :blocked_content] or Watch.failure?(code)
    if blocked?, do: Catalog.block_grab_release(grab, code)

    # park_grab IS finish_grab(grab, []) — if the finalize transaction itself is what keeps
    # failing, notifying here would fire {:grab_failed} every 5s tick forever. Warn instead;
    # the grab stays visible in /activity and the warning names why it won't finalize.
    #
    # A blocklisted release is never re-picked, so its download is dead weight: the grab's client
    # job is fenced+removed in the same transaction as the grab delete (`park_grab_and_remove/1`),
    # and its payload deleted afterwards — under the same `move_on_import` / usenet-only rule as
    # `Download.remove_after_import/4`, so a torrent keeps seeding (#684). `:blocked_content` is
    # the exception that already removed its job (and files) from any client. The other, non-
    # blocklisted reasons only ever delete the grab.
    remove_payload? = blocked? and Download.move_on_import_removal?(grab.download_protocol)

    park_result =
      if code == :blocked_content or remove_payload?,
        do: Catalog.park_grab_and_remove(grab),
        else: Catalog.park_grab(grab)

    case park_result do
      {:ok, _} ->
        # The client job is already fenced and removed above; only the payload is left, and
        # `remove_after_import/4` with no download id deletes exactly that. A non-blocklisted
        # park may be re-picked, so its payload stays.
        if remove_payload?,
          do: Download.remove_after_import(grab.download_protocol, nil, grab.content_path)

        :telemetry.execute([:cinder, :park], %{count: 1}, %{kind: :episode, reason: code})
        Notifier.notify({:grab_failed, grab, code})

      {:error, park_error} ->
        Logger.warning(
          "tv grab #{grab.id} could not be parked (#{HTTPPolicy.sanitize_log(park_error)}); will retry next tick"
        )
    end
  end
end
