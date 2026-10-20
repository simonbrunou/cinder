defmodule Cinder.Catalog.TitleDeletion do
  @moduledoc """
  Deleting or cancelling a title (a movie or a series) and the files it holds: whole-movie and
  whole-series delete, whole-series cancel, and per-episode and per-season file unlink. Each
  writes its audit row, and announces through `Cinder.Catalog.Events`, only after its transaction
  commits.

  A delete's durable cleanup fences commit in the same transaction as the row delete; client I/O
  runs after commit, and a failure leaves the fence for reconciliation. A file unlink is
  best-effort: a failed one is logged and recorded in the audit detail, never propagated.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Audit
  alias Cinder.Catalog.{Attention, Episode, Episodes, Events, Grab, Grabs, Movie, Season, Series}
  alias Cinder.Download
  alias Cinder.Library
  alias Cinder.Library.ImportedQuality
  alias Cinder.Repo
  alias Cinder.Requests

  @doc """
  Deletes a movie's DB row. An active row's tracked download is captured in a durable cleanup
  fence in the same transaction, then removed after commit. Broadcasts `{:movie_deleted, id}`.

  Pass `delete_files: true` in `opts` to also unlink the on-disk library file after the row is
  deleted (best-effort: a failed unlink is logged, not propagated). Default leaves files on disk.
  The audit row is written last, after the unlink is attempted, so `files_deleted` records what
  actually happened rather than the caller's intent.
  """
  def delete_movie(%Movie{} = movie, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)

    prepare = fn fresh ->
      # Reap this title's approved request(s) in the same transaction — a movie gone but its
      # :approved request left behind strands the requester on a stale "Approved" badge with the
      # Add button suppressed. Pending/denied are deliberately left (see reap_approved_for_target/2).
      Requests.reap_approved_for_target(["movie"], fresh.tmdb_id)

      # Still owns a client download: it can be cancelled or have its upgrade aborted.
      include_remote? =
        Attention.offers?(fresh, :cancel) or Attention.offers?(fresh, :cancel_upgrade) or
          fresh.verification_hold_origin in [:download, :upgrade]

      Download.fence_movie_cleanup(fresh, include_remote: include_remote?)
    end

    with {:ok, {deleted, intent_ids}} <- delete_record(movie, prepare) do
      Download.cleanup_intents(intent_ids)

      unlinked =
        if delete_files?,
          do: Enum.map(Movie.file_paths(deleted), &{&1, best_effort_delete_file(&1)}),
          else: []

      audit_deletion(actor, :delete_movie, deleted, delete_files?, unlinked)
      Events.movie_deleted(deleted.id)
      {:ok, deleted}
    end
  end

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
      Events.series_updated(fresh.id)
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

    with {:ok, {deleted, intent_ids}} <- delete_record(series, prepare) do
      Download.cleanup_intents(intent_ids)
      unlinked = Enum.map(paths, &{&1, best_effort_delete_file(&1)})
      audit_deletion(actor, :delete_series, deleted, delete_files?, unlinked)
      Events.series_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  defp episode_file_paths_for_series(series_id) do
    from(e in Episode,
      join: s in Season,
      on: s.id == e.season_id,
      where:
        s.series_id == ^series_id and
          (not is_nil(e.file_path) or fragment("json_array_length(?) > 0", e.part_file_paths))
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
    # the series' tmdb_id in target_id) — same rationale as the movie path in `delete_movie/3`.
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
  # No sweep visits the series again to re-evaluate an anime hold, so the hold goes too: it would
  # otherwise need attention forever.
  defp unmonitor_series_tree(series_id) do
    ts = DateTime.utc_now(:second)

    Repo.update_all(from(s in Series, where: s.id == ^series_id),
      set: [monitored: false, monitor_strategy: :none, anime_hold_reason: nil, updated_at: ts]
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
      if changed?, do: Events.series_updated(Episodes.series_id(updated))
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
    |> Enum.map(&{&1, best_effort_delete_file(&1)})
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
        attrs =
          Map.merge(
            %{file_path: nil, part_file_paths: [], search_attempts: 0},
            ImportedQuality.columns(nil, Episode)
          )

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
      Events.series_updated(season.series_id)
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

  # Deletes a movie or series row (no audit write here — the caller writes it post-commit, after
  # any file unlink it performs, via audit_deletion/5, so the audit can record the true outcome
  # rather than the caller's intent). A concurrent delete (Repo.delete/1 raises) becomes a clean
  # {:error, :stale_entry}.
  defp delete_record(record, prepare) do
    Repo.transaction(fn ->
      module = record.__struct__

      case Repo.update_all(from(r in module, where: r.id == ^record.id),
             set: [updated_at: DateTime.utc_now(:second)]
           ) do
        {1, _} -> :ok
        {0, _} -> Repo.rollback(:stale_entry)
      end

      fresh = Repo.get!(module, record.id)
      prepared = prepare.(fresh)

      case Repo.delete(fresh) do
        {:ok, deleted} -> {deleted, prepared}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # Best-effort library-file unlink shared by every delete path: a failed unlink is logged, never
  # propagated, so it can't strand the row delete — but the real :ok/{:error, reason} outcome is
  # returned so the audit can record it truthfully instead of echoing the caller's intent.
  # ponytail: no nil clause here — Library.delete_file/1 already guards nil/"" and returns :ok.
  defp best_effort_delete_file(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("library file delete failed for #{inspect(path)}: #{inspect(reason)}")
        error
    end
  end

  # Writes the post-commit deletion audit row with the ACTUAL per-file unlink outcome: when
  # delete_files? is false nothing was attempted, so `files_deleted` is trivially false; when true,
  # it's true only if every attempted unlink succeeded. A partial/total failure is recorded with
  # the leftover paths+reasons and logged loudly — there is no outbox/retry here (household scale),
  # so this log line + the audit detail are the only trace. The delete already committed, so a
  # refused audit row can only be logged (`Audit.log_or_warn/4`).
  defp audit_deletion(actor, action, deleted, delete_files?, unlink_results) do
    detail = deletion_audit_detail(deleted, delete_files?, unlink_results)
    Audit.log_or_warn(actor, action, deleted, detail)
  end

  defp deletion_audit_detail(deleted, false, _unlink_results) do
    %{title: deleted.title, files_deleted: false}
  end

  defp deletion_audit_detail(deleted, true, unlink_results) do
    failed = for {path, {:error, reason}} <- unlink_results, do: "#{path}: #{inspect(reason)}"
    file_paths = Enum.map(unlink_results, &elem(&1, 0))

    if failed == [] do
      %{title: deleted.title, files_deleted: true, file_paths: file_paths}
    else
      Logger.warning(
        "#{inspect(deleted.__struct__)} #{deleted.id} delete: #{length(failed)} file(s) left on disk: #{inspect(failed)}"
      )

      %{
        title: deleted.title,
        files_deleted: false,
        file_paths: file_paths,
        failed_unlinks: failed
      }
    end
  end
end
