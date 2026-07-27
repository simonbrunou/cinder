defmodule Cinder.Catalog.SeriesDeletion do
  @moduledoc """
  Series/season/episode deletion machinery — whole-series cancel/delete and per-file unlink,
  carved out of `Cinder.Catalog.SeriesCatalog` as pure code motion (mirrors the
  `Cinder.Catalog.Grabs` / `Cinder.Catalog.MediaProfiles` split; see `Cinder.Catalog` for the
  facade that delegates the public functions here).

  The public entry points (`cancel_series/2`, `delete_series/3`, `delete_episode_file/3`,
  `delete_season_files/3`) are re-exposed through `Cinder.Catalog`. Transaction ordering, the
  post-commit client I/O, and the durable cleanup fences are unchanged from the original.
  """
  import Ecto.Query

  alias Cinder.Audit
  alias Cinder.Catalog.{Episode, Grab, Grabs, Season, Series}
  alias Cinder.Download
  alias Cinder.Repo
  alias Cinder.Requests

  @doc """
  Cancels an entire series WITHOUT deleting it: reaps every grab serving the series (any state,
  including `:downloaded` awaiting import — a surviving downloaded grab would re-import next tick),
  removing each tracked client download, then unmonitors every season and episode so the TV
  poller's `wanted_episodes` does not re-grab. Broadcasts `{:series_updated, id}`. Audited.

  Grab deletes, season+episode unmonitoring, the audit row, and durable cleanup fences are written
  in one transaction, so there is no poller-visible window where an episode is grab-less but still
  monitored. Client I/O runs only after commit; failures leave fences for reconciliation.
  """
  def cancel_series(%Series{} = series, actor) do
    result =
      Repo.transaction(fn ->
        episode_ids = episode_ids_for_series(series.id)
        unmonitor_series_tree(series.id)
        grabs = grabs_for_series(series.id)
        specs = Enum.map(grabs, &Grabs.grab_cleanup_spec(&1, Grabs.episode_ids_for_grab(&1.id)))

        # allow_stale: the TV poller may have finished/parked a grab between reads.
        for grab <- grabs, do: Repo.delete!(grab, allow_stale: true)
        intent_ids = Download.fence_episode_cleanup(episode_ids, specs)
        fresh = Repo.get!(Series, series.id)
        Audit.log_or_rollback(actor, :cancel_series, fresh, %{title: fresh.title})
        {fresh, intent_ids}
      end)

    with {:ok, {fresh, intent_ids}} <- result do
      Download.cleanup_intents(intent_ids)
      Cinder.Catalog.broadcast_series(fresh.id)
      {:ok, fresh}
    end
  end

  @doc """
  Deletes a series and its tree. Grab deletes and durable remote-cleanup fences commit in the same
  transaction as the series cascade, so the episode links cannot disappear before their remote IDs
  are recoverable. Client I/O runs after commit. Broadcasts
  `{:series_deleted, id}`. Audited. Pass `delete_files: true` to also unlink every episode
  `file_path` after the cascade (best-effort, non-blocking).
  """
  def delete_series(%Series{} = series, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)
    # Collect episode file paths BEFORE the cascade deletes the rows.
    paths = if delete_files?, do: episode_file_paths_for_series(series.id), else: []
    prepare = &prepare_series_cleanup/1

    with {:ok, {deleted, intent_ids}} <- Cinder.Catalog.delete_record(series, prepare) do
      Download.cleanup_intents(intent_ids)
      unlinked = Enum.map(paths, &{&1, Cinder.Catalog.best_effort_delete_file(&1)})
      Cinder.Catalog.audit_deletion(actor, :delete_series, deleted, delete_files?, unlinked)
      Cinder.Catalog.broadcast_series_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  defp episode_file_paths_for_series(series_id) do
    from(e in Episode,
      join: s in Season,
      on: s.id == e.season_id,
      where: s.series_id == ^series_id and not is_nil(e.file_path)
    )
    |> Repo.all()
    |> Enum.flat_map(&Episode.file_paths/1)
    |> Enum.uniq()
  end

  defp episode_ids_for_series(series_id) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id,
        select: e.id
    )
  end

  defp prepare_series_cleanup(series) do
    # Reap this title's approved series/season/episode requests in the same transaction (all carry
    # the series' tmdb_id in target_id) — same rationale as the movie path in
    # `Cinder.Catalog.delete_movie/3`.
    Requests.reap_approved_for_target(["series", "season", "episode"], series.tmdb_id)

    episode_ids = episode_ids_for_series(series.id)
    grabs = grabs_for_series(series.id)
    specs = Enum.map(grabs, &Grabs.grab_cleanup_spec(&1, Grabs.episode_ids_for_grab(&1.id)))
    intent_ids = Download.fence_episode_cleanup(episode_ids, specs)
    Enum.each(grabs, &Repo.delete!(&1, allow_stale: true))
    intent_ids
  end

  # Grabs whose episodes belong to this series (via the episode→season join), ALL states.
  defp grabs_for_series(series_id) do
    Repo.all(
      from g in Grab,
        join: e in Episode,
        on: e.grab_id == g.id,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id,
        distinct: true
    )
  end

  # Unmonitor every season + episode of the series in one write each so wanted_episodes is empty.
  defp unmonitor_series_tree(series_id) do
    ts = Cinder.Catalog.now()

    Repo.update_all(from(s in Series, where: s.id == ^series_id),
      set: [monitored: false, monitor_strategy: :none, updated_at: ts]
    )

    Repo.update_all(from(s in Season, where: s.series_id == ^series_id),
      set: [monitored: false, updated_at: ts]
    )

    Repo.update_all(
      from(e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id
      ),
      set: [monitored: false, updated_at: ts]
    )

    :ok
  end

  @doc """
  Deletes one episode's primary and part library files (Sonarr "delete episode file"). Every unlink
  is attempted. The following transaction removes only successfully unlinked paths from every
  affected episode row and records the actual results in the audit; failed paths remain recorded.
  When every path is gone, imported metadata is cleared and `opts[:unmonitor]` also flips
  `monitored` off. A partial or total unlink failure is logged and returned as `{:error, reason}`
  after the truthful DB/audit write. Broadcasts `{:series_updated, series_id}` after a DB change.
  """
  def delete_episode_file(episode, actor, opts \\ [])

  def delete_episode_file(%Episode{} = episode, actor, opts) do
    episode
    |> Episode.file_paths()
    |> delete_episode_paths(episode, actor, opts)
  end

  defp delete_episode_paths([], _episode, _actor, _opts), do: {:error, :no_file}

  defp delete_episode_paths(paths, episode, actor, opts) do
    results = unlink_paths(paths)

    with {:ok, {updated, changed?}} <-
           do_delete_episode_file_txn(
             episode,
             actor,
             Keyword.get(opts, :unmonitor, false),
             results
           ) do
      if changed?, do: Cinder.Catalog.broadcast_series(series_id_for_season(updated.season_id))
      episode_delete_result(updated, results)
    end
  end

  defp do_delete_episode_file_txn(episode, actor, unmonitor?, results) do
    Repo.transaction(fn ->
      fresh = Repo.get(Episode, episode.id) || Repo.rollback(:stale_entry)
      successful = successful_paths(results)

      outcomes =
        Repo.all(from e in Episode, where: e.season_id == ^fresh.season_id)
        |> Enum.filter(&shares_path?(&1, results))
        |> Enum.map(&reconcile_deleted_paths(&1, successful, unmonitor?))

      updated = Repo.get!(Episode, fresh.id)

      Audit.log_or_rollback(
        actor,
        :delete_episode_file,
        updated,
        unlink_audit_detail(results, %{
          unmonitored: unmonitor? and Episode.file_paths(updated) == []
        })
      )

      {updated, Enum.any?(outcomes, &(elem(&1, 1) != :unchanged))}
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  defp episode_delete_result(updated, results) do
    case Enum.find(results, fn {_path, result} -> result != :ok end) do
      nil -> {:ok, updated}
      {_path, {:error, reason}} -> {:error, reason}
    end
  end

  defp unlink_paths(paths) do
    paths
    |> Enum.uniq()
    |> Enum.map(&{&1, Cinder.Catalog.best_effort_delete_file(&1)})
  end

  defp successful_paths(results) do
    results
    |> Enum.flat_map(fn
      {path, :ok} -> [path]
      {_path, {:error, _reason}} -> []
    end)
    |> MapSet.new()
  end

  defp shares_path?(episode, results) do
    attempted = MapSet.new(results, &elem(&1, 0))
    Enum.any?(Episode.file_paths(episode), &MapSet.member?(attempted, &1))
  end

  defp reconcile_deleted_paths(episode, successful, unmonitor?) do
    primary = if MapSet.member?(successful, episode.file_path), do: nil, else: episode.file_path
    parts = Enum.reject(episode.part_file_paths || [], &MapSet.member?(successful, &1))

    cond do
      primary == episode.file_path and parts == (episode.part_file_paths || []) ->
        {episode, :unchanged}

      primary in [nil, ""] and parts == [] ->
        attrs = %{
          file_path: nil,
          part_file_paths: [],
          search_attempts: 0,
          imported_resolution: nil,
          imported_size: nil,
          imported_language: nil,
          imported_source: nil,
          imported_audio_languages: nil,
          imported_embedded_subtitles: nil,
          imported_sidecar_subtitles: nil
        }

        episode
        |> Episode.transition_changeset(attrs)
        |> maybe_unmonitor(unmonitor?)
        |> Repo.update!()
        |> then(&{&1, :cleared})

      true ->
        episode
        |> Episode.transition_changeset(%{file_path: primary, part_file_paths: parts})
        |> Repo.update!()
        |> then(&{&1, :partial})
    end
  end

  defp unlink_audit_detail(results, detail) do
    failed =
      for {path, {:error, reason}} <- results,
          do: "#{path}: #{inspect(reason)}"

    detail =
      Map.merge(detail, %{
        file_paths: Enum.map(results, &elem(&1, 0)),
        deleted_file_paths: for({path, :ok} <- results, do: path),
        files_deleted: failed == []
      })

    if failed == [], do: detail, else: Map.put(detail, :failed_unlinks, failed)
  end

  defp maybe_unmonitor(changeset, true),
    do: Ecto.Changeset.put_change(changeset, :monitored, false)

  defp maybe_unmonitor(changeset, false), do: changeset

  @doc """
  Deletes every library file in a season (Sonarr per-season "delete episode files"): every unique
  primary/part path is attempted once, then one transaction removes only successful paths from the
  affected episode rows and records the actual per-path outcome. Fully cleared episodes also drop
  imported metadata and are unmonitored when `opts[:unmonitor]` is true; partial and fully failed
  rows keep every path still known to exist. Returns `{:ok, cleared_count, failed_count}`, where
  `failed_count` counts episodes with at least one failed unlink.
  """
  def delete_season_files(%Season{} = season, actor, opts \\ []) do
    unmonitor? = Keyword.get(opts, :unmonitor, false)

    episodes =
      Repo.all(from e in Episode, where: e.season_id == ^season.id)
      |> Enum.reject(&(Episode.file_paths(&1) == []))

    results = episodes |> Enum.flat_map(&Episode.file_paths/1) |> unlink_paths()
    failed_count = Enum.count(episodes, &episode_unlink_failed?(&1, results))

    with {:ok, cleared_count} <-
           do_delete_season_files_txn(season, actor, results, unmonitor?) do
      Cinder.Catalog.broadcast_series(season.series_id)
      {:ok, cleared_count, failed_count}
    end
  end

  defp episode_unlink_failed?(episode, results) do
    result_by_path = Map.new(results)
    Enum.any?(Episode.file_paths(episode), &match?({:error, _}, result_by_path[&1]))
  end

  defp do_delete_season_files_txn(season, actor, results, unmonitor?) do
    Repo.transaction(fn ->
      successful = successful_paths(results)

      outcomes =
        Repo.all(from e in Episode, where: e.season_id == ^season.id)
        |> Enum.filter(&shares_path?(&1, results))
        |> Enum.map(&reconcile_deleted_paths(&1, successful, unmonitor?))

      cleared_count = Enum.count(outcomes, &(elem(&1, 1) == :cleared))

      Audit.log_or_rollback(
        actor,
        :delete_season_files,
        season,
        unlink_audit_detail(results, %{
          count: cleared_count,
          unmonitored: unmonitor?
        })
      )

      cleared_count
    end)
  end

  # Local one-liner copy (Cinder.Catalog keeps its own private copy too) — resolving a season's
  # series id for the post-commit broadcast.
  defp series_id_for_season(season_id),
    do: Repo.one(from s in Season, where: s.id == ^season_id, select: s.series_id)
end
