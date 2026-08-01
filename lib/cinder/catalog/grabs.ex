defmodule Cinder.Catalog.Grabs do
  @moduledoc """
  The TV grab lifecycle: reserving a release as a `%Grab{}` (manual or sweep-driven),
  tracking it through download/import (create/mark/commit/close/finish/park/reap), the
  release blocklist, and per-episode search-attempt bookkeeping. Carved out of
  `Cinder.Catalog` as plain code motion — broadcast/PubSub behaviour is unchanged
  (delegated back to `Cinder.Catalog.broadcast_series/1`); every public function here
  is re-exported unchanged via `defdelegate` in `Cinder.Catalog`.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Acquisition.Release

  alias Cinder.Catalog.{
    Adoption,
    BlockedRelease,
    Episode,
    Grab,
    GrabFile,
    Identity,
    Movie,
    Season,
    Series
  }

  alias Cinder.Catalog.SeriesCatalog
  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Library.ImportStage
  alias Cinder.Notifier
  alias Cinder.Repo

  @download_metric_fields [:download_progress, :download_speed, :download_eta]
  @max_search_attempts 10

  # Parked terminal states a user can re-queue (mirrors Cinder.Catalog's own copy —
  # manual_grab_movie/2's guard needs it here too).
  @retryable [:no_match, :search_failed, :import_failed]

  @doc """
  Grabs a specific user-chosen `release` for `movie`. An `:available` movie enters `:upgrading`
  (its library `file_path` and `imported_*` are preserved — the poller's upgrade clause swaps the
  file only on a successful re-import). A parked movie (`#{inspect(@retryable)}`) enters
  `:downloading` on the normal import path. Any other status returns `{:error, :not_grabbable}`
  (rejecting in-flight/`:upgrading`/`:cancelled`, which also blocks a double-click). A movie deleted
  mid-action surfaces `{:error, :stale_entry}`.
  """
  def manual_grab_movie(%Movie{status: :available} = movie, %Release{} = release) do
    Download.grab_movie(movie, release)
  end

  def manual_grab_movie(
        %Movie{status: status, verification_hold_origin: nil} = movie,
        %Release{} = release
      )
      when status in @retryable do
    Download.grab_movie(movie, release)
  end

  def manual_grab_movie(%Movie{}, %Release{}), do: {:error, :not_grabbable}

  @doc """
  Grabs a user-chosen `release` for one `season_number` of `series`. Recomputes the season's
  manually searchable episodes server-side (don't trust a stale panel snapshot) and creates the
  grab over exactly the missing or available episodes the release covers (`episodes: nil` = a
  whole-season pack covers them all). `create_grab/5` never links an episode that already has a
  grab, and rolls the whole thing back if any of them was taken meanwhile, so a concurrent sweep
  grab can't be double-linked; `Download.reconcile_episodes/1` flattens that rollback to
  `{:error, :no_episodes_linked}` on this path. `{:error, :nothing_wanted}` when the season has
  nothing to grab.
  """
  def manual_grab_tv(%Series{} = series, season_number, %Release{} = release) do
    case Cinder.Catalog.media_profile_summary(series).effective do
      :anime -> manual_grab_anime_tv(series, season_number, release)
      :standard -> manual_grab_standard_tv(series, season_number, release)
    end
  end

  defp manual_grab_anime_tv(
         %Series{id: series_id},
         season_number,
         %Release{} = release
       ) do
    candidate_ids =
      SeriesCatalog.manual_search_episodes(series_id, season_number)
      |> Enum.map(& &1.id)

    with true <- safe_anime_mapping?(release),
         true <-
           MapSet.subset?(
             MapSet.new(release.resolved_episode_ids),
             MapSet.new(candidate_ids)
           ) do
      case grab_and_create_grab(release, release.resolved_episode_ids) do
        {:error, :invalid_mapping_snapshot} -> {:error, :unsafe_anime_mapping}
        result -> result
      end
    else
      false -> {:error, :unsafe_anime_mapping}
    end
  end

  defp safe_anime_mapping?(%Release{
         resolved_episode_ids: ids,
         mapping_snapshot: %{"version" => 2} = snapshot
       })
       when is_list(ids) and ids != [] do
    kind = if length(ids) == 1, do: :episode, else: :season_pack
    Intent.valid_mapping_snapshot?(snapshot, kind, ids)
  end

  defp safe_anime_mapping?(_release), do: false

  defp manual_grab_standard_tv(_series, _season_number, %Release{mapping_snapshot: snapshot})
       when not is_nil(snapshot),
       do: {:error, :unsafe_anime_mapping}

  defp manual_grab_standard_tv(
         _series,
         _season_number,
         %Release{resolution_evidence: :conflicting_standard_numbering}
       ),
       do: {:error, :conflicting_standard_numbering}

  defp manual_grab_standard_tv(%Series{id: series_id}, season_number, %Release{} = release) do
    candidates = SeriesCatalog.manual_search_episodes(series_id, season_number)

    case standard_manual_episode_ids(release, season_number, candidates) do
      {:ok, []} -> {:error, :nothing_wanted}
      {:ok, ids} -> grab_and_create_grab(release, ids)
      :error -> {:error, :conflicting_standard_numbering}
    end
  end

  defp standard_manual_episode_ids(
         %Release{resolved_episode_ids: ids},
         _season_number,
         candidates
       )
       when is_list(ids) and ids != [] do
    candidate_ids = MapSet.new(candidates, & &1.id)

    if Enum.uniq(ids) == ids and MapSet.subset?(MapSet.new(ids), candidate_ids),
      do: {:ok, ids},
      else: :error
  end

  # An alternate-season release that reached here UNRESOLVED (no frozen episode ids — an unmapped
  # value in a bridged season, an alt season past the cap, or a mapping outside the current
  # candidates) must never fall through to the native intersection below: grabbing "S02E11" while
  # browsing native season 1 would reserve native S01E11. Refuse instead (never-guess).
  defp standard_manual_episode_ids(%Release{season: release_season}, season_number, _candidates)
       when is_integer(release_season) and release_season != season_number,
       do: :error

  defp standard_manual_episode_ids(%Release{} = release, _season_number, candidates) do
    covered = cover_numbers(release, Enum.map(candidates, & &1.episode_number))
    {:ok, candidates |> Enum.filter(&(&1.episode_number in covered)) |> Enum.map(& &1.id)}
  end

  # Grabs the release (a client.add side-effect returning a download_id), then links the grab over
  # `episode_ids`. If create_grab/5 rolls back — a concurrent sweep grabbed the episodes first
  # (:no_episodes_linked, or :episode_ownership_changed for some of them) or the insert failed —
  # best-effort remove the just-added download so it isn't orphaned in the client, then surface the
  # error.
  defp grab_and_create_grab(%Release{} = release, episode_ids) do
    Download.grab_episodes(release, episode_ids, operator_initiated: true)
  end

  # A whole-season pack (episodes: nil) covers every still-wanted number; an episode list covers its
  # intersection with what's wanted. Mirrors Scorer.coverage/2.
  defp cover_numbers(%Release{episodes: nil}, wanted_numbers), do: wanted_numbers

  defp cover_numbers(%Release{episodes: eps}, wanted_numbers),
    do: Enum.filter(wanted_numbers, &(&1 in eps))

  @doc "Updates an in-flight grab's progress snapshot and broadcasts its owning series."
  def update_grab_download_metrics(%Grab{} = grab, attrs) do
    changes = metric_changes(grab, attrs)

    if changes == %{} do
      if Repo.exists?(from(g in Grab, where: g.id == ^grab.id and is_nil(g.content_path))) do
        {:ok, grab}
      else
        {:error, :stale_grab}
      end
    else
      now = Cinder.Catalog.now()

      changes =
        if progress_advanced?(grab.download_progress, Map.get(changes, :download_progress)),
          do: Map.put(changes, :download_progress_at, now),
          else: changes

      case Repo.update_all(
             from(g in Grab,
               where: g.id == ^grab.id and is_nil(g.content_path),
               select: g
             ),
             set: Map.to_list(changes) ++ [updated_at: now]
           ) do
        {1, [updated]} ->
          Cinder.Catalog.broadcast_series(series_id_for_grab(grab.id))
          {:ok, updated}

        {0, _} ->
          {:error, :stale_grab}
      end
    end
  end

  defp metric_changes(record, attrs) do
    attrs =
      attrs
      |> Map.take(@download_metric_fields)
      |> keep_progress_high_water(record.download_progress)

    Map.reject(attrs, fn {field, value} -> Map.get(record, field) == value end)
  end

  defp keep_progress_high_water(%{download_progress: progress} = attrs, previous)
       when is_number(progress) and (is_nil(previous) or progress >= previous),
       do: attrs

  defp keep_progress_high_water(attrs, _previous), do: Map.delete(attrs, :download_progress)

  defp progress_advanced?(previous, current) when is_number(current),
    do: current > (previous || 0)

  defp progress_advanced?(_previous, _current), do: false

  @doc """
  Creates a grab for `episode_ids` (a non-empty list of episodes in one series — a single
  episode or a season pack) and links them in one transaction, then broadcasts
  `{:series_updated, series_id}`. `release_title` (optional) records the chosen release's name
  on the grab so the blocklist can skip it if this download later parks. A changeset failure
  (e.g. a missing `download_id`) rolls the whole thing back as `{:error, changeset}` rather than
  raising, mirroring `set_season_monitored/2`.

  `opts` — `reset_attempts: true` zeroes the linked episodes' `search_attempts` in the same
  transaction (the manual-grab path uses it, mirroring `manual_grab_movie/2`): the user-chosen
  release gets a fresh search budget, and new grabs never carry a counter at/above the cap.
  `allow_available: true` is reserved for the durable manual-upgrade path.
  `arbitrate_at_import: true` marks the grab so the import, not the grab, decides each episode's
  swap — the unattended upgrade sweep sets it; the manual path leaves it off and forces (#250).
  """
  def create_grab(download_id, protocol, episode_ids, release_title \\ nil, opts \\ []) do
    result =
      Repo.transaction(fn ->
        insert_and_link_grab(download_id, protocol, episode_ids, release_title, opts)
      end)

    with {:ok, grab} <- result do
      broadcast_grab_series(grab)
      {:ok, grab}
    end
  end

  @doc "Atomically transfers an anime intent's frozen mapping snapshot and episode ownership."
  def create_grab_from_intent(%Cinder.Download.Intent{} = intent) do
    result =
      Repo.transaction(fn ->
        fresh = Repo.get(Cinder.Download.Intent, intent.id)
        if is_nil(fresh), do: Repo.rollback(:stale_intent)

        attrs = %{
          download_id: fresh.remote_id,
          download_protocol: fresh.protocol,
          release_title: fresh.release["title"],
          mapping_snapshot: fresh.mapping_snapshot,
          release_policy_snapshot: fresh.release_policy_snapshot,
          mapping_status: :resolved
        }

        grab =
          %Grab{}
          |> Grab.reservation_changeset(attrs)
          |> Repo.insert()
          |> case do
            {:ok, grab} -> grab
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {linked, _rows} = link_intent_episodes(fresh, grab)

        if linked != length(fresh.episode_ids), do: Repo.rollback(:episode_ownership_changed)

        Repo.delete!(fresh)
        grab
      end)

    with {:ok, grab} <- result do
      broadcast_grab_series(grab)
      {:ok, grab}
    end
  end

  defp link_intent_episodes(intent, grab) do
    allow_available? = intent.release["operator_initiated"] == true

    Repo.update_all(
      from(e in Episode,
        where:
          e.id in ^intent.episode_ids and is_nil(e.grab_id) and
            ((e.monitored == true and is_nil(e.file_path)) or
               (^allow_available? and not is_nil(e.file_path)))
      ),
      set: [grab_id: grab.id, updated_at: Cinder.Catalog.now()]
    )
  end

  @doc "Persists an anime mapping preflight outcome (resolved, or held with its reason) and broadcasts."
  def record_mapping_result(%Grab{} = grab, {:ok, _preflight}) do
    persist_mapping_result(grab, %{mapping_status: :resolved, mapping_issue: nil})
  end

  def record_mapping_result(
        %Grab{mapping_status: prior} = grab,
        {:needs_mapping, %{issue: issue}}
      ) do
    with {:ok, held} <-
           persist_mapping_result(grab, %{mapping_status: :needs_mapping, mapping_issue: issue}) do
      # Emit only on a fresh hold (resolved → needs_mapping), never on a re-observation of a grab
      # already held — the operator hears once per hold, not once per import tick.
      if prior != :needs_mapping, do: Notifier.notify({:operator_hold, held, :needs_mapping})
      {:ok, held}
    end
  end

  defp persist_mapping_result(grab, attrs) do
    case grab |> Grab.mapping_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        broadcast_grab_series(updated)
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  defp broadcast_grab_series(grab) do
    # Post-commit side effect, best-effort: once the txn committed the grab is
    # real, and a blip here (a pool-checkout timeout on the series lookup) must
    # not surface as {:error, _} — the TvPoller's cleanup branch would then
    # remove the client download out from under a live grab and eventually
    # blocklist a good release.
    Cinder.Catalog.broadcast_series(series_id_for_grab(grab.id))
  rescue
    e -> Logger.warning("post-commit broadcast for grab #{grab.id} failed: #{inspect(e)}")
  catch
    kind, value ->
      Logger.warning("post-commit broadcast for grab #{grab.id} #{kind}: #{inspect(value)}")
  end

  defp insert_and_link_grab(download_id, protocol, episode_ids, release_title, opts) do
    case %Grab{arbitrate_at_import: Keyword.get(opts, :arbitrate_at_import, false)}
         |> Grab.changeset(%{
           download_id: download_id,
           download_protocol: protocol,
           release_title: release_title
         })
         |> Repo.insert() do
      {:ok, grab} -> link_grab_episodes(grab, episode_ids, opts)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # No episodes to link is a rollback, not a vacuous success — `linked == length(episode_ids)`
  # below is satisfied by 0 == 0, and would leave an orphan grab owning nothing.
  defp link_grab_episodes(_grab, [], _opts), do: Repo.rollback(:no_episodes_linked)

  defp link_grab_episodes(grab, episode_ids, opts) do
    # reset_attempts: the manual-grab path zeroes search_attempts (mirroring manual_grab_movie),
    # giving the user-chosen release a fresh budget — and keeping the counter from ever exceeding
    # the cap, which announce_search_exhausted's == max crossing check relies on.
    reset = if Keyword.get(opts, :reset_attempts, false), do: [search_attempts: 0], else: []
    allow_available? = Keyword.get(opts, :allow_available, false)
    # Guard `is_nil(grab_id)`: never re-link an episode another grab already owns (defends against
    # a same-tick double-link silently overwriting an earlier grab). Missing episodes must remain
    # monitored; an available episode may be manually upgraded even when monitoring is off.
    {linked, _} =
      Repo.update_all(
        from(e in Episode,
          where:
            e.id in ^episode_ids and is_nil(e.grab_id) and
              ((e.monitored == true and is_nil(e.file_path)) or
                 (^allow_available? and not is_nil(e.file_path)))
        ),
        set: [grab_id: grab.id, updated_at: Cinder.Catalog.now()] ++ reset
      )

    # All or nothing, as `create_grab_from_intent/1` already does for the anime path. A partial link
    # used to be tolerated, and it silently manufactured operator work: the release still downloads
    # in full, so every episode that slipped away between the search and this write arrives at
    # import with no owner and becomes an undecided `grab_file` — a residual hold keeping the grab
    # open (#247). Rolling back gets the just-added download removed
    # (`Download.cleanup_failed_ownership/2`) and the next sweep re-searches for what is still
    # wanted.
    if linked == length(episode_ids), do: grab, else: Repo.rollback(link_failure(linked))
  end

  defp link_failure(0), do: :no_episodes_linked
  defp link_failure(_partial), do: :episode_ownership_changed

  @doc """
  Marks a grab downloaded (records `content_path`, the at-rest path to import) and broadcasts.
  Also resets `download_attempts` at the download→import boundary (mirrors the movie poller's
  `import_attempts: 0` reset, `poller.ex:140`) so download-phase blips don't starve the shared
  grab-lifetime retry budget the import pass then draws from.
  """
  def mark_grab_downloaded(%Grab{} = grab, content_path) do
    changeset =
      Grab.changeset(grab, %{
        content_path: content_path,
        download_attempts: 0,
        download_progress: nil,
        download_speed: nil,
        download_eta: nil
      })

    with {:ok, grab} <- Repo.update(changeset) do
      Cinder.Catalog.broadcast_series(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  @doc """
  Bumps a grab's `download_attempts` — the single grab-lifetime retry counter the TV poller
  uses for both the advance and import passes — and broadcasts. The caller compares the
  pre-bump count against its bound to decide retry-vs-park.
  """
  def increment_grab_attempts(%Grab{} = grab) do
    Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
      inc: [download_attempts: 1],
      set: [
        download_speed: nil,
        download_eta: nil,
        updated_at: Cinder.Catalog.now()
      ]
    )

    Cinder.Catalog.broadcast_series(series_id_for_grab(grab.id))
    :ok
  end

  @doc """
  Aborts one grab as a user action. Its delete and durable cleanup fence commit together; remote
  cleanup runs afterward and retries from the fence on failure. Its episodes then re-enter the
  wanted sweep and re-search cleanly.
  """
  def cancel_grab(%Grab{} = grab), do: cancel_grab(grab, :any_state)

  @doc """
  Aborts a grab only while it is still held for mapping. The held-state claim, cleanup fence, and
  delete share one transaction so a concurrent mapping resume cannot be cancelled afterward.
  """
  def cancel_mapping_grab(%Grab{} = grab), do: cancel_grab(grab, :needs_mapping)

  defp cancel_grab(grab, required_state) do
    result =
      Repo.transaction(fn ->
        case Repo.update_all(cancel_grab_query(grab.id, required_state),
               set: [updated_at: Cinder.Catalog.now()]
             ) do
          {0, _} when required_state == :needs_mapping ->
            Repo.rollback(:mapping_not_held)

          {0, _} ->
            {grab, [], nil}

          {1, _} ->
            episode_ids = episode_ids_for_grab(grab.id)
            series_id = series_id_for_grab(grab.id)

            intent_ids =
              Download.fence_episode_cleanup(episode_ids, [grab_cleanup_spec(grab, episode_ids)])

            {:ok, deleted} = Repo.delete(grab, allow_stale: true)
            {deleted, intent_ids, series_id}
        end
      end)

    with {:ok, {deleted, intent_ids, series_id}} <- result do
      Download.cleanup_intents(intent_ids)
      Cinder.Catalog.broadcast_series(series_id)
      {:ok, deleted}
    end
  end

  defp cancel_grab_query(id, :any_state), do: from(g in Grab, where: g.id == ^id)

  defp cancel_grab_query(id, :needs_mapping),
    do: from(g in Grab, where: g.id == ^id and g.mapping_status == :needs_mapping)

  @doc """
  Records `movie`'s current `release_title` as blocked for that movie, so release selection
  skips it on the next search. A nil `release_title` (e.g. a pre-grab park) is a no-op.

  **Non-raising**: runs inside the poller's isolated park path, where a raise would re-fire
  every tick (`isolate` never parks). So it uses a non-bang insert, logs and swallows any
  `{:error, _}`, and always returns `:ok` (mirrors `Download.best_effort_remove/2`). No broadcast.
  """
  def block_release(%Movie{release_title: nil}, _reason), do: :ok

  def block_release(%Movie{release_title: title, id: movie_id}, reason),
    do:
      insert_blocked_release(fn ->
        %{release_title: title, reason: to_string(reason), movie_id: movie_id}
      end)

  @doc """
  `block_release/2`, then confirms the row is readable back under the movie's exact
  `release_title`: `:ok` if it landed, `:error` if it did not.

  For the one caller that cannot proceed without the row —
  `Cinder.Download.Poller.requeue_failed/2`, where the blocklist is the only bound on a re-queue
  loop, so a missing row means re-grabbing the same dead release every cycle forever. Everyone
  else calls `block_release/2` and ignores the outcome, which is the right default: it is
  deliberately non-raising (see above), and for a park the blocklist is a nicety, not a bound.

  A nil `release_title` is `:error` — nothing to block means nothing to bound the loop.
  """
  def block_release_and_confirm(%Movie{release_title: title} = movie, reason) do
    block_release(movie, reason)

    if not is_nil(title) and title in blocked_release_titles(movie), do: :ok, else: :error
  end

  @doc """
  Deletes the `:stalled`-reason blocklist rows for a movie or series so a manual re-search can give
  the reaped release a fresh chance. Scoped to `[movie: id]` or `[series: id]`; only `"stalled"`
  rows are removed, so deterministic blocks (wrong-language, bad-torrent, …) still persist. A nil id
  is a no-op. The series scope clears the whole series' `:stalled` rows (the table is series-keyed).
  """
  def clear_stalled_blocklist(movie: id) when is_integer(id) do
    Repo.delete_all(from b in BlockedRelease, where: b.movie_id == ^id and b.reason == "stalled")

    :ok
  end

  def clear_stalled_blocklist(series: id) when is_integer(id) do
    Repo.delete_all(from b in BlockedRelease, where: b.series_id == ^id and b.reason == "stalled")

    :ok
  end

  def clear_stalled_blocklist(_scope), do: :ok

  @doc """
  Records `grab`'s `release_title` as blocked for its series. Resolves the series from the grab's
  still-linked episodes, so call it **before** `park_grab/1` deletes the grab (the FK nilifies the
  links on delete). A nil `release_title` is a no-op. **Non-raising** — see `block_release/2`.
  """
  def block_grab_release(%Grab{release_title: nil}, _reason), do: :ok

  def block_grab_release(%Grab{release_title: title, id: grab_id}, reason),
    do:
      insert_blocked_release(fn ->
        # series_id_for_grab is a DB query: building attrs lazily keeps it INSIDE the catch below,
        # so the TV park path's series resolution can't raise/exit out and abort park_grab.
        %{release_title: title, reason: to_string(reason), series_id: series_id_for_grab(grab_id)}
      end)

  # Non-raising on every path (mirrors `Download.best_effort_remove/2`): the attrs thunk is run
  # inside the try, so a changeset/constraint `{:error, _}` is logged-and-swallowed AND a
  # raised/exited DB failure (in the insert OR the lazy series-id query) is caught — because the
  # TV caller blocks BEFORE `park_grab` deletes the grab, a raise here would stop the park and
  # hot-loop the grab every tick.
  defp insert_blocked_release(build_attrs) do
    attrs = build_attrs.()

    case %BlockedRelease{} |> BlockedRelease.changeset(attrs) |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("block_release failed for #{inspect(attrs)}: #{inspect(changeset.errors)}")
        :ok
    end
  catch
    kind, value ->
      Logger.warning("block_release raised: #{inspect({kind, value})}")
      :ok
  end

  @doc "Downcased-or-not release titles blocked for `movie` (the exact strings stored)."
  def blocked_release_titles(%Movie{id: movie_id}),
    do:
      Repo.all(from b in BlockedRelease, where: b.movie_id == ^movie_id, select: b.release_title)

  @doc "Release titles blocked for the series `series_id`."
  def blocked_release_titles_for_series(series_id),
    do:
      Repo.all(
        from b in BlockedRelease, where: b.series_id == ^series_id, select: b.release_title
      )

  @doc """
  Bumps `search_attempts` (and `updated_at`, for the poller's search backoff) on the given
  episodes in one write, then broadcasts each affected series. Used by the search pass on
  no-match / client-add failure / indexer error (no grab exists yet on that path).
  """
  def increment_search_attempts([]), do: :ok

  def increment_search_attempts(episode_ids) when is_list(episode_ids) do
    Repo.update_all(from(e in Episode, where: e.id in ^episode_ids),
      inc: [search_attempts: 1],
      set: [updated_at: Cinder.Catalog.now()]
    )

    for series_id <- series_ids_for_episodes(episode_ids),
        do: Cinder.Catalog.broadcast_series(series_id)

    announce_search_exhausted(episode_ids)
    :ok
  end

  # After any search_attempts bump: episodes that just crossed the cap leave the sweep
  # permanently, and that moment must never be silent (the movie analogue parks visibly at
  # :search_failed). Lives at the write site so BOTH bump paths announce — the sweep's
  # increment_search_attempts and finish_grab/park_grab's non-imported bump. Re-selecting
  # fresh rows also makes the check immune to stale in-memory counters. Monitored-only: a
  # parked grab of a just-cancelled series bumps unmonitored episodes the sweep doesn't own.
  # Single-series by construction (both callers pass one grab/season group); the notifier
  # payload's episodes carry season: :series for the transports' summary line.
  defp announce_search_exhausted([]), do: :ok

  # Best-effort like create_grab's post-commit broadcast (and guarded the same way): it runs
  # AFTER the bump/finalize committed, so a re-select raise here (pool-checkout timeout,
  # SQLITE_BUSY) must not escape — in finish_grab's caller that would skip the client-download
  # removal and the availability notification for a grab row that is already gone.
  #
  # >= rather than ==: crossings normally land exactly at the cap (new grabs reset or start
  # below it), but pre-existing data can sit at the cap inside an in-flight grab and get
  # bumped past it. A capped episode can't re-announce — the sweep skips it and every grab
  # path resets — so >= adds no duplicates, only catches the above-cap stragglers.
  defp announce_search_exhausted(episode_ids) do
    exhausted =
      Repo.all(
        from e in Episode,
          where:
            e.id in ^episode_ids and e.search_attempts >= ^@max_search_attempts and
              is_nil(e.file_path) and is_nil(e.grab_id) and e.monitored == true,
          preload: [season: :series]
      )

    case exhausted do
      [] ->
        :ok

      [%{season: %{series: series, season_number: season}} | _] = episodes ->
        numbers = Enum.map(episodes, & &1.episode_number)

        Logger.warning(
          "tv search exhausted for #{series.title} season #{season} episode(s) " <>
            "#{inspect(numbers)}; the sweep will skip them until a manual Search"
        )

        Notifier.notify({:episodes_search_exhausted, episodes})
    end
  rescue
    e -> Logger.warning("search-exhaustion announce failed: #{inspect(e)}")
  catch
    kind, value -> Logger.warning("search-exhaustion announce #{kind}: #{inspect(value)}")
  end

  defp series_ids_for_episodes(episode_ids) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.id in ^episode_ids,
        select: s.series_id,
        distinct: true
    )
  end

  @doc "Grabs still downloading (no `content_path` yet)."
  def list_grabs_downloading, do: Repo.all(from g in Grab, where: is_nil(g.content_path))

  @doc "Count of grabs still downloading (no `content_path` yet)."
  def count_grabs_downloading,
    do: Repo.aggregate(from(g in Grab, where: is_nil(g.content_path)), :count)

  # --- grab hold classification --------------------------------------------------------------
  #
  # The one definition of "this grab needs an operator": `grab_hold/1` is the per-grab
  # authority, `count_grab_holds/0` is the same predicate in query form for the nav badge, and
  # `CinderWeb.ActivityLive` renders whatever `grab_hold/1` / `unresolved_grab_files/1` say
  # instead of re-deriving the classes — the view and the count once each kept their own copy,
  # synced by hand. `operator_holds_test.exs` pins the SQL count to classifying `list_grabs/0`.

  @doc """
  The undecided residual videos of a standard-TV grab: inventoried at import time with no
  fold/part decision yet. A non-empty result is what makes a `:residual_files` hold
  (`grab_hold/1`), and these are exactly the rows `/activity` renders resolution actions
  for. Tolerates an unloaded `grab_files` association (classifies as none).
  """
  def unresolved_grab_files(%{grab_files: files}) when is_list(files),
    do: Enum.filter(files, &is_nil(&1.decision))

  def unresolved_grab_files(_grab), do: []

  @doc """
  Which operator-action hold a grab sits in, or `nil` when it needs no operator: a mapping
  hold (`:needs_mapping`), a verification hold (`:verification_blocked`), or a standard
  residual grab with at least one undecided `grab_file` (`:residual_files`) — the same
  reason atoms `{:operator_hold, grab, reason}` notifies with. A flagged `mapping_status`
  wins over residual files, so a grab in two classes classifies once.
  """
  def grab_hold(%{mapping_status: :needs_mapping}), do: :needs_mapping
  def grab_hold(%{mapping_status: :verification_blocked}), do: :verification_blocked
  def grab_hold(grab), do: if(unresolved_grab_files(grab) == [], do: nil, else: :residual_files)

  @doc """
  Count of grabs sitting in an operator-action hold — `grab_hold/1` in query form (a grab
  counts iff it classifies non-nil), kept SQL-side so the nav badge doesn't load every grab
  with its files on each mount. Feeds `Catalog.count_operator_holds/0`;
  `operator_holds_test.exs` asserts it agrees with classifying the listed grabs.
  """
  def count_grab_holds do
    from(g in Grab,
      as: :grab,
      where:
        g.mapping_status in [:needs_mapping, :verification_blocked] or
          exists(
            from f in GrabFile, where: f.grab_id == parent_as(:grab).id and is_nil(f.decision)
          )
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Grabs downloaded and awaiting import (`content_path` set), with `episodes: [season: :series]`
  preloaded so the TV poller's import pass can map files → episodes and build library paths
  without reaching past the Catalog boundary.
  """
  def list_grabs_downloaded do
    Repo.all(
      from g in Grab,
        where: not is_nil(g.content_path) and g.mapping_status == :resolved,
        # scene coordinates preloaded so the import-time subtitle fetch can query the provider
        # with A6 scene numbering (issue #143).
        preload: [:grab_files, episodes: [:episode_coordinates, season: :series]]
    )
  end

  @doc "All grabs newest-first, with `episodes: [season: :series]` preloaded for the admin /grabs view."
  def list_grabs do
    Repo.all(
      from g in Grab,
        order_by: [desc: g.id],
        preload: [:grab_files, episodes: [season: :series]]
    )
  end

  @doc "Lists held mapping grabs for one series, oldest first, with their series tree preloaded."
  def list_mapping_grabs_for_series(series_id) do
    Repo.all(
      from g in Grab,
        join: episode in assoc(g, :episodes),
        join: season in assoc(episode, :season),
        where: season.series_id == ^series_id and g.mapping_status == :needs_mapping,
        distinct: true,
        order_by: [asc: g.id],
        preload: [episodes: [season: :series]]
    )
  end

  @doc """
  Fetches one grab by id, or `nil`. User-initiated grab actions (e.g. /activity's
  delete) must re-read before acting: a grab resolved from a rendered snapshot may
  have finished importing meanwhile, and cancelling THAT would remove a completed,
  already-imported torrent from the client (stopping seeding) for nothing.
  """
  def get_grab(id), do: Repo.get(Grab, id)

  @doc """
  Loads an unresolved residual file and one explicitly selected episode from its grab.

  A decided row returns `:noop` before episode validation so resubmission stays idempotent.
  """
  def get_grab_file_resolution(file_id, episode_id) do
    case Repo.get(GrabFile, file_id) do
      nil ->
        {:error, :grab_file_not_found}

      %GrabFile{decision: decision} = file when not is_nil(decision) ->
        {:ok, :noop, Repo.preload(file, :grab)}

      %GrabFile{} = file ->
        file = Repo.preload(file, :grab)

        episode =
          Repo.one(
            from e in Episode,
              join: season in assoc(e, :season),
              where: e.id == ^episode_id and e.grab_id == ^file.grab_id,
              preload: [season: :series]
          )

        if episode,
          do: {:ok, :pending, file, episode},
          else: {:error, :episode_not_in_grab}
    end
  end

  @doc """
  Commits the clean matches from one standard-TV staging pass and durably inventories every
  unmatched video. A clean pass closes the grab in this transaction; a residual pass leaves the
  grab and its unimported episodes intact for explicit per-file decisions.
  """
  def commit_grab_imports(%Grab{} = grab, imported, residuals, stage_ids \\ []) do
    series_id = series_id_for_grab(grab.id)
    imported_ids = imported |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    episodes = Map.new(grab.episodes, &{&1.id, &1})

    result =
      Repo.transaction(fn ->
        claim_standard_grab!(grab)

        if Repo.exists?(from f in GrabFile, where: f.grab_id == ^grab.id),
          do: Repo.rollback(:grab_has_residual_files)

        imported_episodes =
          Enum.map(imported, fn entry ->
            {episode_id, dest, quality, placed?} = normalize_imported(entry)
            episode = Map.get(episodes, episode_id) || Repo.rollback(:stale_grab)

            transition_imported_episode!(
              grab.id,
              episode,
              dest,
              quality,
              residuals != [],
              placed?
            )
          end)

        insert_grab_files(grab.id, residuals)
        ImportStage.mark_committed!(stage_ids)

        if residuals == [] do
          missing = Enum.reject(grab.episodes, &(&1.id in imported_ids))
          bumped = Enum.map(missing, &transition_missing_episode!(grab.id, &1))
          completed = completed_seasons_for_imported_episodes(imported_ids)
          Repo.delete!(grab)
          {:closed, imported_episodes ++ bumped, Enum.map(bumped, & &1.id), completed}
        else
          completed = completed_seasons_for_imported_episodes(imported_ids)
          {:open, imported_episodes, [], completed}
        end
      end)

    publish_grab_import_result(result, grab, series_id)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_grab}
  end

  @doc """
  Closes a standard-TV grab only after every residual file has an explicit fold/part decision.
  Imported episodes are released unchanged; genuinely missing episodes are released and backed off.
  """
  def close_grab(%Grab{} = grab) do
    grab = Repo.preload(grab, :episodes, force: true)
    series_id = series_id_for_grab(grab.id)

    result =
      Repo.transaction(fn ->
        claim_standard_grab!(grab)

        if Repo.exists?(from f in GrabFile, where: f.grab_id == ^grab.id and is_nil(f.decision)),
          do: Repo.rollback(:unresolved_grab_files)

        bumped_ids =
          for %Episode{id: id, file_path: path} <- grab.episodes, path in [nil, ""], do: id

        closed = Enum.map(grab.episodes, &transition_closed_episode!(grab.id, &1))
        Repo.delete!(grab)
        {:closed, closed, bumped_ids, []}
      end)

    publish_grab_import_result(result, grab, series_id)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_grab}
  end

  # A 3-tuple is a placement, the shape every caller used before #250 added the keep case.
  defp normalize_imported({episode_id, dest, quality}), do: {episode_id, dest, quality, true}
  defp normalize_imported({_id, _dest, _quality, _placed?} = entry), do: entry

  defp claim_standard_grab!(grab) do
    query =
      from g in Grab,
        where:
          g.id == ^grab.id and is_nil(g.mapping_snapshot) and g.mapping_status == :resolved and
            g.content_path == ^grab.content_path

    case Repo.update_all(query, set: [updated_at: Cinder.Catalog.now()]) do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:stale_grab)
    end
  end

  # `placed?` false is the arbitrated keep (#250): nothing was written, the episode is committed
  # only to release its grab_id. Parts belong to the primary they were folded onto, so a NEW
  # primary drops them — but here the primary is unchanged, and clearing them would orphan the
  # row's parts and hand them to `remove_superseded_episode_files/1` to delete off disk.
  defp transition_imported_episode!(grab_id, episode, dest, quality, retain_grab?, placed?) do
    if episode.monitored or not is_nil(episode.file_path) do
      attrs =
        Map.new(
          [
            file_path: dest,
            part_file_paths: if(placed?, do: [], else: episode.part_file_paths),
            grab_id: if(retain_grab?, do: grab_id)
          ] ++ imported_attrs(quality)
        )

      expected = %{
        grab_id: grab_id,
        file_path: episode.file_path,
        monitored: episode.monitored
      }

      case Cinder.Catalog.transition_episode(episode, attrs,
             expect: expected,
             publish: false
           ) do
        {:ok, updated} -> updated
        {:error, _reason} -> Repo.rollback(:stale_grab)
      end
    else
      Repo.rollback(:stale_grab)
    end
  end

  defp transition_missing_episode!(grab_id, episode) do
    attrs = %{grab_id: nil, search_attempts: episode.search_attempts + 1}

    expected = %{
      grab_id: grab_id,
      file_path: episode.file_path,
      monitored: episode.monitored,
      search_attempts: episode.search_attempts
    }

    case Cinder.Catalog.transition_episode(episode, attrs,
           expect: expected,
           publish: false
         ) do
      {:ok, updated} -> updated
      {:error, _reason} -> Repo.rollback(:stale_grab)
    end
  end

  defp transition_closed_episode!(grab_id, %Episode{file_path: path} = episode)
       when is_binary(path) and path != "" do
    expected = %{
      grab_id: grab_id,
      file_path: episode.file_path,
      part_file_paths: episode.part_file_paths,
      monitored: episode.monitored
    }

    case Cinder.Catalog.transition_episode(episode, %{grab_id: nil},
           expect: expected,
           publish: false
         ) do
      {:ok, updated} -> updated
      {:error, _reason} -> Repo.rollback(:stale_grab)
    end
  end

  defp transition_closed_episode!(grab_id, episode),
    do: transition_missing_episode!(grab_id, episode)

  @doc """
  Atomically records one Fold/Part decision. The guarded file claim makes a decided row a no-op;
  coordinate, episode-part, and import-stage writes roll back together on any failure.
  """
  def decide_grab_file(file, episode, decision, stage \\ nil)

  def decide_grab_file(%GrabFile{} = file, %Episode{} = episode, decision, stage)
      when decision in [:fold, :part] do
    result =
      Repo.transaction(fn ->
        attrs = decision_attrs(decision, episode.id, stage)

        case Repo.update_all(
               from(f in GrabFile,
                 where: f.id == ^file.id and is_nil(f.decision),
                 select: f
               ),
               set: Map.to_list(attrs) ++ [updated_at: Cinder.Catalog.now()]
             ) do
          {0, _} ->
            existing_grab_file_decision(file.id)

          {1, [decided]} ->
            apply_grab_file_decision!(decided, episode.id, decision, stage)
        end
      end)

    publish_grab_file_decision(result)
  end

  def decide_grab_file(%GrabFile{}, %Episode{}, _decision, _stage),
    do: {:error, :invalid_grab_file_decision}

  defp existing_grab_file_decision(file_id) do
    case Repo.get(GrabFile, file_id) do
      %GrabFile{} = decided -> {:noop, decided, nil}
      nil -> Repo.rollback(:grab_file_not_found)
    end
  end

  defp decision_attrs(:fold, episode_id, nil),
    do: %{decision: :fold, episode_id: episode_id, destination: nil, import_stage_id: nil}

  defp decision_attrs(:part, episode_id, %{dest: dest, rollback: %{stage_id: stage_id}})
       when is_binary(dest) and is_integer(stage_id),
       do: %{
         decision: :part,
         episode_id: episode_id,
         destination: dest,
         import_stage_id: stage_id
       }

  defp decision_attrs(_decision, _episode_id, _stage), do: Repo.rollback(:invalid_import_stage)

  defp apply_grab_file_decision!(file, episode_id, decision, stage) do
    grab = Repo.get(Grab, file.grab_id) || Repo.rollback(:stale_grab)
    claim_standard_grab!(grab)

    episode =
      Repo.one(
        from e in Episode,
          join: season in assoc(e, :season),
          where: e.id == ^episode_id and e.grab_id == ^file.grab_id,
          preload: [season: :series]
      ) || Repo.rollback(:episode_not_in_grab)

    updated_episode =
      case decision do
        :fold ->
          bind_grab_file_coordinate!(file, episode)
          nil

        :part ->
          adopt_grab_file_part!(episode, stage.dest)
      end

    ImportStage.mark_committed!(stage_ids(stage))
    {:decided, file, updated_episode, episode.season.series_id}
  end

  defp bind_grab_file_coordinate!(file, episode) do
    case grab_file_coordinate(file) do
      nil ->
        :ok

      attrs ->
        case Identity.bind_manual_coordinate(episode.season.series, attrs, episode) do
          {:ok, _coordinate} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  @provider_fields [:source, :scheme, :namespace, :canonical_value]

  defp grab_file_coordinate(file) do
    values = Map.take(file, @provider_fields)

    cond do
      Enum.all?(@provider_fields, &(Map.get(values, &1) in [nil, ""])) ->
        nil

      Enum.all?(@provider_fields, fn field ->
        value = Map.get(values, field)
        is_binary(value) and value != ""
      end) ->
        values

      true ->
        Repo.rollback(:invalid_provider_evidence)
    end
  end

  defp adopt_grab_file_part!(episode, destination) do
    case Adoption.adopt_episode_part(episode, destination) do
      {:ok, %Episode{} = updated} -> updated
      {:ok, nil} -> episode
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp stage_ids(nil), do: []
  defp stage_ids(%{rollback: %{stage_id: id}}), do: [id]

  defp publish_grab_file_decision({:ok, {:noop, file, nil}}), do: {:ok, :noop, file}

  defp publish_grab_file_decision({:ok, {:decided, file, updated_episode, series_id}}) do
    if updated_episode,
      do: Cinder.Catalog.publish_episode_transition_batch([updated_episode], series_id),
      else: Cinder.Catalog.broadcast_series(series_id)

    {:ok, :decided, file}
  end

  defp publish_grab_file_decision({:error, reason}), do: {:error, reason}

  defp insert_grab_files(_grab_id, []), do: :ok

  defp insert_grab_files(grab_id, residuals) do
    timestamp = Cinder.Catalog.now()

    rows =
      Enum.map(residuals, fn residual ->
        @provider_fields
        |> Map.new(&{&1, Map.get(residual, &1)})
        |> Map.merge(Map.take(residual, [:relative_path, :size, :device, :inode]))
        |> Map.merge(%{
          grab_id: grab_id,
          inserted_at: timestamp,
          updated_at: timestamp
        })
      end)

    Repo.insert_all(GrabFile, rows, on_conflict: :nothing)
    :ok
  end

  defp publish_grab_import_result(
         {:ok, {state, episodes, bumped_ids, completed_seasons}},
         grab,
         series_id
       ) do
    Cinder.Catalog.publish_episode_transition_batch(episodes, series_id)
    announce_search_exhausted(bumped_ids)
    Enum.each(completed_seasons, &Notifier.notify({:season_available, &1}))

    # `:open` means residual files were just inventoried with no decision — a fresh operator hold
    # (this commit runs once per grab, guarded against re-entry, so no per-tick re-emit).
    if state == :open, do: Notifier.notify({:operator_hold, grab, :residual_files})
    {:ok, state, grab}
  end

  defp publish_grab_import_result({:error, reason}, _grab, _series_id), do: {:error, reason}

  @doc """
  Finalizes a grab after import, in **one transaction**: sets `file_path`, clears
  `part_file_paths` and `grab_id` on each imported episode, bumps `search_attempts` on the grab's
  non-imported episodes, then deletes the grab. `imported` is `[{episode_id, dest_path}]`.
  Broadcasts `{:series_updated, _}` and announces any season the import completes.

  The search_attempts bump on the non-imported episodes makes a pack that never yields a wanted
  episode re-search with backoff and eventually search-park, rather than re-grabbing forever. It
  **must** run before the delete: the `grab_id` FK nilifies on delete, after which the predicate
  would match nothing. Each imported episode is written individually (a single `update_all set:`
  could not give each its own dest); `n` is one season pack, so the per-row writes are cheap.
  """
  def finish_grab(%Grab{} = grab, imported \\ []), do: finish_grab(grab, imported, [])

  def finish_grab(%Grab{} = grab, imported, stage_ids) do
    imported_ids = imported |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    series_id = series_id_for_grab(grab.id)

    result =
      Repo.transaction(fn ->
        ts = Cinder.Catalog.now()

        for {episode_id, dest, q} <- imported do
          update_imported_episode!(grab.id, episode_id, dest, q, ts)
        end

        # select: in the update_all (RETURNING) hands the bumped ids to the post-commit
        # exhaustion announce without a leading SELECT — a read-then-write transaction is
        # the SQLITE_BUSY class busy_timeout can't rescue (see config/test.exs), and the
        # delete below nilifies grab_id so the ids can't be re-derived afterwards.
        {_count, bumped_ids} =
          Repo.update_all(
            missing_episodes_query(grab.id, imported_ids) |> select([e], e.id),
            inc: [search_attempts: 1],
            set: [updated_at: ts]
          )

        completed_seasons = completed_seasons_for_imported_episodes(imported_ids)

        ImportStage.mark_committed!(stage_ids)
        Repo.delete!(grab)
        {bumped_ids, completed_seasons}
      end)

    with {:ok, {bumped_ids, completed_seasons}} <- result do
      Cinder.Catalog.broadcast_series(series_id)
      announce_search_exhausted(bumped_ids)
      Enum.each(completed_seasons, &Notifier.notify({:season_available, &1}))
      {:ok, grab}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_grab}
  end

  defp update_imported_episode!(grab_id, episode_id, dest, quality, timestamp) do
    query =
      from e in Episode,
        where:
          e.id == ^episode_id and e.grab_id == ^grab_id and
            (e.monitored == true or not is_nil(e.file_path))

    updates =
      [file_path: dest, part_file_paths: [], grab_id: nil] ++
        imported_attrs(quality) ++ [updated_at: timestamp]

    case Repo.update_all(query, set: updates) do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:stale_grab)
    end
  end

  defp imported_attrs(quality) do
    [
      imported_resolution: quality.resolution,
      imported_size: quality.size,
      imported_language: quality.language,
      imported_source: quality.source,
      imported_audio_languages: quality.audio_languages,
      imported_embedded_subtitles: quality.embedded_subtitles,
      imported_sidecar_subtitles: quality.sidecar_subtitles
    ]
  end

  # The grab's episodes that did not import. Branch on the empty case so we never interpolate
  # an empty list into `not in` (and so a park — empty `imported` — bumps every linked episode).
  defp missing_episodes_query(grab_id, []), do: from(e in Episode, where: e.grab_id == ^grab_id)

  defp missing_episodes_query(grab_id, imported_ids),
    do: from(e in Episode, where: e.grab_id == ^grab_id and e.id not in ^imported_ids)

  defp completed_seasons_for_imported_episodes([]), do: []

  defp completed_seasons_for_imported_episodes(imported_ids) do
    today = Date.utc_today()

    imported_season_ids =
      from e in Episode,
        where: e.id in ^imported_ids and not is_nil(e.air_date) and e.air_date <= ^today,
        select: e.season_id,
        distinct: true

    from([_episode, season, series] in SeriesCatalog.available_seasons_query(today),
      where: season.id in subquery(imported_season_ids),
      select: %{
        tmdb_id: series.tmdb_id,
        title: series.title,
        season_number: season.season_number,
        poster_path: series.poster_path
      }
    )
    |> Repo.all()
  end

  @doc """
  Parks a grab: deletes it and bumps every linked episode's `search_attempts` (so they re-search,
  bounded, then search-park). The terminal-failure case of `finish_grab/2` (nothing imported).
  """
  def park_grab(%Grab{} = grab), do: finish_grab(grab, [])

  @doc """
  Reaps a stalled downloading grab (the stall reaper): one transaction blocklists its release
  `:stalled`, bumps every linked episode's `search_attempts` (backoff), fences the client download
  for removal, then deletes the grab; after commit the remote job + reserved intent are torn down
  and the series is announced. The episodes re-enter the wanted sweep and re-search a *different*
  release next tick (the blocklist skips the dead one).

  Claims the grab with a compare-and-swap `update_all` **first** (like `cancel_grab/2`): the poller
  reaps off a tick-start snapshot, so a concurrent user Discard/cancel can delete the same grab in
  the `client.status/1` window. `{0, _}` ⇒ already gone ⇒ `{:error, :stale_grab}` no-op (no block,
  no notify, no `hd([])` on nilified episode links). After a `{1, _}` claim the grab still exists,
  so the block and the bump read its still-linked episodes before the `Repo.delete` (which nilifies
  `grab_id`) runs last. Combines `cancel_grab/2`'s claim+fence teardown with `finish_grab/3`'s bump.
  """
  def reap_stalled_grab(%Grab{} = grab) do
    series_id = series_id_for_grab(grab.id)

    result =
      Repo.transaction(fn ->
        case Repo.update_all(cancel_grab_query(grab.id, :any_state),
               set: [updated_at: Cinder.Catalog.now()]
             ) do
          {0, _} ->
            :already_gone

          {1, _} ->
            episode_ids = episode_ids_for_grab(grab.id)
            block_grab_release(grab, :stalled)

            Repo.update_all(missing_episodes_query(grab.id, []),
              inc: [search_attempts: 1],
              set: [updated_at: Cinder.Catalog.now()]
            )

            intent_ids =
              Download.fence_episode_cleanup(episode_ids, [grab_cleanup_spec(grab, episode_ids)])

            {:ok, _deleted} = Repo.delete(grab, allow_stale: true)
            {:reaped, intent_ids}
        end
      end)

    case result do
      {:ok, {:reaped, intent_ids}} ->
        Download.cleanup_intents(intent_ids)
        Cinder.Catalog.broadcast_series(series_id)
        Notifier.notify({:grab_failed, grab, :stalled})
        {:ok, grab}

      {:ok, :already_gone} ->
        {:error, :stale_grab}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def episode_ids_for_grab(grab_id) do
    Repo.all(from e in Episode, where: e.grab_id == ^grab_id, select: e.id)
  end

  @doc false
  def grab_cleanup_spec(grab, episode_ids) do
    %{
      remote_id: grab.download_id,
      protocol: grab.download_protocol,
      title: grab.release_title,
      episode_ids: episode_ids
    }
  end

  @doc false
  def series_id_for_grab(grab_id) do
    Repo.one(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.grab_id == ^grab_id,
        select: s.series_id,
        limit: 1
    )
  end
end
