defmodule Cinder.Catalog.SeriesRefresh do
  @moduledoc """
  Periodic TMDB refresh + season/episode tree reconciliation for an already-added
  series (the `Cinder.Catalog.Refresher` GenServer's per-tick call). Existing
  episodes are matched by `tmdb_episode_id` and updated in place (preserving
  `monitored`/`file_path`/`grab_id`/counters) via a two-pass renumber that
  tolerates TMDB reorders/shifts. Carved out of `Cinder.Catalog` as plain code
  motion — every public function here is re-exported unchanged via `defdelegate`
  in `Cinder.Catalog`.
  """
  require Logger

  alias Cinder.Catalog.{Episode, Identity, Season, Series, SeriesCatalog}
  alias Cinder.Repo

  import Ecto.Query

  @doc """
  Re-fetches `series` from TMDB and reconciles its season/episode tree in one transaction, then
  broadcasts `{:series_updated, series.id}` once. Existing episodes are matched by
  `tmdb_episode_id` (series-wide, so a renumber that moves an episode across seasons is handled)
  and updated in place — preserving `monitored`, `file_path`, `grab_id`, and the attempt counters.
  Genuinely new regular episodes are inserted with `monitored` per the season flag; classified
  specials start unmonitored. New seasons are inserted; rows that vanished from TMDB are left
  untouched.

  Returns `{:ok, series}`, or `{:error, reason}` if a TMDB fetch fails (short-circuits before any
  write, mirroring `Cinder.Catalog.SeriesCatalog.create_series/4`).
  """
  def refresh_series(%Series{} = series) do
    with {:ok, info} <- tmdb().get_series(series.tmdb_id),
         {:ok, seasons} <- SeriesCatalog.fetch_seasons(series.tmdb_id, info.seasons),
         seasons = SeriesCatalog.put_episode_localizations(series.tmdb_id, seasons),
         {:ok, identity} <-
           SeriesCatalog.fetch_series_identity(series.tmdb_id, series.scene_numbering_group_id) do
      Repo.transaction(fn -> refresh_current_series(series.id, info, seasons, identity) end)
      |> finish_series_write()
    end
  end

  # Shared by refresh_series/1 and Cinder.Catalog.SceneNumbering.set_scene_numbering_group/3: a
  # `Repo.transaction` result whose ok value is the updated `%Series{}` broadcasts once on the
  # "series" topic and passes through; an error passes through untouched. Small enough to
  # duplicate rather than share (see the module notes).
  defp finish_series_write({:ok, updated}) do
    Cinder.Catalog.broadcast_series(updated.id)
    {:ok, updated}
  end

  defp finish_series_write({:error, reason}), do: {:error, reason}

  defp refresh_current_series(series_id, info, seasons, identity) do
    case Repo.get(Series, series_id) do
      %Series{} = current ->
        updated = update_series_row(current, info)
        reconcile_tree(updated, seasons)

        case SeriesCatalog.sync_series_identity(updated, seasons, identity) do
          :ok -> updated
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:stale_series)
    end
  end

  # Backfill the series row's TMDB-sourced fields (tvdb_id especially — the acquisition
  # disambiguation key, often nil at add time). Identity + user-controlled fields (tmdb_id,
  # monitored, monitor_strategy) are not cast, so they're preserved. On failure, log and keep the
  # existing row: a descriptive backfill failing must not abort the whole tree reconcile.
  defp update_series_row(series, info) do
    changeset =
      Series.refresh_changeset(series, %{
        tvdb_id: info.tvdb_id,
        title: info.title,
        year: info.year,
        poster_path: info.poster_path,
        original_language: info.original_language,
        # Descriptive backfill — Map.get (not dot) so a partial info map can't KeyError and abort
        # the whole tree reconcile. The real normalize_series always includes these.
        overview: Map.get(info, :overview),
        # Merge-over, not replace (see Cinder.Catalog.merge_localizations/2): a transient/partial
        # translations payload must never strip last-synced localizations.
        localizations:
          Cinder.Catalog.merge_localizations(
            series.localizations,
            Map.get(info, :localizations, %{})
          ),
        genres: Map.get(info, :genres),
        vote_average: Map.get(info, :vote_average),
        first_air_date: Map.get(info, :first_air_date)
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        updated

      {:error, cs} ->
        Logger.warning("refresh: series #{series.id} row update failed: #{inspect(cs.errors)}")
        series
    end
  end

  # Two-pass renumber. Building season targets first lets `ensure_season` insert any new seasons;
  # then we partition into matched (an existing row by tmdb_episode_id) vs new. PASS 1 parks every
  # matched row in a guaranteed-free slot, PASS 2 moves each to its final slot (now collision-free),
  # PASS 3 inserts the new rows. This handles within-season swaps and mid-season insertion shifts,
  # which the old one-at-a-time update couldn't (every move collided on the unique index).
  defp reconcile_tree(series, fetched_seasons) do
    existing_seasons = Map.new(seasons_for(series.id), &{&1.season_number, &1})
    by_tmdb = Map.new(episodes_for(series.id), &{&1.tmdb_episode_id, &1})

    # Step 1 — collect {fetched_episode, season} for each fetched season whose target season
    # exists (or was just inserted); skip a season ensure_season couldn't create. The full season
    # struct is carried so PASS 3 can use season.monitored as the source of truth for new
    # episodes (rather than the series-wide monitor_strategy, which is :none for per-season
    # requests even when a specific season is monitored).
    targets =
      Enum.flat_map(fetched_seasons, fn fs ->
        case ensure_season(series, existing_seasons, fs.season_number) do
          %Season{} = season -> Enum.map(fs.episodes, &{&1, season})
          nil -> []
        end
      end)

    # Step 2 — partition into matched (existing row found by tmdb_episode_id) vs new. Guard a nil
    # tmdb_episode_id (TMDB always sets it, but a nil never matches and must be treated as new).
    {matched, new} =
      Enum.split_with(targets, fn {fe, _season} ->
        not is_nil(fe.tmdb_episode_id) and Map.has_key?(by_tmdb, fe.tmdb_episode_id)
      end)

    matched =
      Enum.map(matched, fn {fe, season} ->
        {Map.fetch!(by_tmdb, fe.tmdb_episode_id), fe, season.id}
      end)

    # Never renumber an episode with an in-flight grab: its release's files are matched + named by
    # the episode's CURRENT SxxEyy at import, so moving it mid-download would mislabel them (or
    # leave them unmatched). Leave it untouched (like a vanished row); the next refresh after the
    # grab finishes reconciles it.
    matched = Enum.filter(matched, fn {existing, _fe, _season_id} -> is_nil(existing.grab_id) end)

    # PASS 1 — park each matched row's real slot with a unique non-colliding sentinel (-id) in its
    # current season (no season_id change here), so PASS 2 never collides matched-vs-matched. Carry
    # the parked struct forward: PASS 2's `cast` diffs against the struct's number, and a row whose
    # final number equals its *original* would otherwise be seen as unchanged and the SET would omit
    # episode_number, leaving it stuck at the sentinel. Diffing against the (negative) parked number
    # always fires.
    parked =
      Enum.map(matched, fn {existing, fe, season_id} ->
        {park_episode(existing), existing, fe, season_id}
      end)

    # PASS 2 — finalize each matched row to its final (season_id, episode_number). All matched slots
    # are now free, so matched-vs-matched never collides. The only residual is a target slot still
    # held by a *vanished* row (left untouched); finalize_or_restore then puts the row back at its
    # original positive slot rather than stranding it at the -id park sentinel.
    Enum.each(parked, fn {parked_ep, original, fe, season_id} ->
      finalize_or_restore(parked_ep, original, season_id, fe)
    end)

    # PASS 3 — insert new rows, after finalize so slots reflect final state. Use the season's
    # `monitored` flag as the source of truth: a per-season request sets monitor_strategy: :none
    # on the series but flips the requested season's monitored flag to true, so season.monitored
    # correctly reflects "do we want this season" while series.monitor_strategy does not.
    Enum.each(new, fn {fe, season} -> insert_episode(season, fe) end)
  end

  # Vacate a matched row's real slot before the finalize pass: -id never collides with a positive
  # TMDB number and is unique across the table (ids are unique). Returns the updated struct (number
  # = -id) for PASS 2 to diff against; on the should-never-happen failure, log and return the
  # original struct so the finalize pass still runs.
  defp park_episode(existing) do
    # Route through refresh_changeset (not raw change/2) so the (season_id, episode_number) unique
    # constraint is registered: a park can't realistically collide (-id is negative + unique), but
    # if it ever did it degrades to {:error} rather than raising and aborting the whole series.
    case existing
         |> Episode.refresh_changeset(%{episode_number: -existing.id})
         |> Repo.update() do
      {:ok, parked} ->
        parked

      {:error, changeset} ->
        log_reconcile_error({:error, changeset}, "park episode #{existing.id}")
        existing
    end
  end

  defp seasons_for(series_id), do: Repo.all(from s in Season, where: s.series_id == ^series_id)

  defp episodes_for(series_id) do
    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where: s.series_id == ^series_id and not is_nil(e.tmdb_episode_id)
    )
  end

  defp ensure_season(_series, existing, number) when is_map_key(existing, number),
    do: Map.fetch!(existing, number)

  defp ensure_season(series, _existing, number) do
    attrs = %{
      series_id: series.id,
      season_number: number,
      monitored: series.monitor_strategy != :none
    }

    case %Season{} |> Season.refresh_changeset(attrs) |> Repo.insert() do
      {:ok, season} ->
        season

      {:error, changeset} ->
        Logger.warning(
          "refresh skipped new season #{number} of series #{series.id}: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  # Finalize a parked row to its target slot (monitored/file_path/grab_id/counters omitted from the
  # cast → preserved). If the target slot is held by a row that vanished from TMDB — the one residual
  # the two-pass can't resolve without touching vanished rows — restore the row to its original
  # positive slot rather than leaving it at the -id park sentinel, which would otherwise leak a
  # negative episode_number into wanted_episodes → the TV poller's search/import.
  defp finalize_or_restore(parked_ep, original, season_id, fe) do
    changeset =
      Episode.refresh_changeset(parked_ep, %{
        season_id: season_id,
        episode_number: fe.episode_number,
        title: fe.title,
        # Merge-over (see Cinder.Catalog.merge_localizations/2): a failed non-canonical season
        # fetch yields %{} here, and replacing would erase the last-synced titles until the next
        # successful refresh.
        localizations:
          Cinder.Catalog.merge_localizations(parked_ep.localizations, fe.localizations),
        air_date: fe.air_date
      })

    case Repo.update(changeset) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.warning(
          "refresh: episode #{original.id} target slot occupied by a vanished row; " <>
            "restoring to its original number #{original.episode_number} instead"
        )

        parked_ep
        |> Episode.refresh_changeset(%{
          season_id: original.season_id,
          episode_number: original.episode_number
        })
        |> Repo.update()
        |> log_reconcile_error("restore episode #{original.id}")
    end
  end

  defp insert_episode(%Season{} = season, fe) do
    {classification, label} = Identity.classify_tmdb_episode(season.season_number, fe.title)

    %Episode{}
    |> Episode.refresh_changeset(%{
      season_id: season.id,
      tmdb_episode_id: fe.tmdb_episode_id,
      episode_number: fe.episode_number,
      title: fe.title,
      localizations: fe.localizations,
      air_date: fe.air_date,
      classification: classification,
      classification_source: "tmdb",
      classification_label: label,
      monitored: season.monitored and classification == :regular
    })
    |> Repo.insert()
    |> log_reconcile_error("insert episode tmdb_ep #{fe.tmdb_episode_id}")
  end

  defp log_reconcile_error({:ok, _} = ok, _context), do: ok

  defp log_reconcile_error({:error, changeset}, context) do
    # Residual reconcile conflict (e.g. a new/restored row whose target slot is still held by a row
    # that vanished from TMDB and is left untouched by design) — rare; log and continue so the rest
    # of the tree still reconciles rather than aborting the whole series.
    Logger.warning("refresh skipped #{context}: #{inspect(changeset.errors)}")
    :ok
  end

  # Resolve the impl at runtime — see `Cinder.Catalog.Discovery`'s copy for why not compile_env!.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
