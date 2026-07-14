defmodule Cinder.Catalog.ReleaseVerification do
  @moduledoc """
  Release verification holds, mapping-hold retries, and confirmed-release rejection for both
  movies and TV grabs — the post-download/pre-import safety net `Cinder.Library.PolicyVerifier`
  writes into.
  """

  import Ecto.Query

  alias Cinder.Audit
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Grab, Movie, Season}
  alias Cinder.Download
  alias Cinder.Repo

  @doc false
  def hold_movie_verification(%Movie{status: :downloaded} = movie, :download, attempts),
    do: do_hold_movie_verification(movie, :download, attempts)

  def hold_movie_verification(%Movie{status: :upgrading} = movie, :upgrade, attempts),
    do: do_hold_movie_verification(movie, :upgrade, attempts)

  def hold_movie_verification(%Movie{}, _origin, _attempts), do: {:error, :stale_status}

  defp do_hold_movie_verification(movie, origin, attempts) do
    attrs = %{
      status: :import_failed,
      import_attempts: attempts,
      verification_hold_origin: origin
    }

    changes = Movie.transition_changeset(movie, attrs).changes

    result =
      Repo.transaction(fn ->
        case Repo.update_all(
               from(m in Movie,
                 where:
                   m.id == ^movie.id and m.status == ^movie.status and
                     m.release_title == ^movie.release_title
               ),
               set: Map.to_list(changes) ++ [updated_at: Catalog.now()]
             ) do
          {1, _} -> Repo.get!(Movie, movie.id)
          {0, _} -> Repo.rollback(:stale_status)
        end
      end)

    Catalog.publish_guarded_movie_transition(result)
  end

  @doc false
  def transition_verification_hold(movie, attrs) do
    changes = Movie.transition_changeset(movie, attrs).changes

    result =
      Repo.transaction(fn ->
        case Repo.update_all(
               from(m in Movie,
                 where:
                   m.id == ^movie.id and m.status == :import_failed and
                     m.verification_hold_origin == ^movie.verification_hold_origin and
                     m.release_title == ^movie.release_title
               ),
               set: Map.to_list(changes) ++ [updated_at: Catalog.now()]
             ) do
          {1, _} -> Repo.get!(Movie, movie.id)
          {0, _} -> Repo.rollback(:stale_status)
        end
      end)

    Catalog.publish_guarded_movie_transition(result)
  end

  @doc false
  def clear_verification_hold(movie, actor, target_status, action) do
    result =
      Repo.transaction(fn ->
        fresh = claim_verification_hold!(movie)
        intent_ids = Download.fence_movie_cleanup(fresh)

        attrs = %{
          status: target_status,
          download_id: nil,
          download_protocol: nil,
          release_title: nil,
          release_policy_snapshot: nil,
          verification_hold_origin: nil
        }

        attrs =
          if movie.verification_hold_origin == :download,
            do: Map.put(attrs, :file_path, nil),
            else: attrs

        updated = fresh |> Movie.transition_changeset(attrs) |> Repo.update!()
        Audit.log_or_rollback(actor, action, updated, %{from: :import_failed})
        {Repo.get!(Movie, updated.id), intent_ids}
      end)

    with {:ok, {updated, intent_ids}} <- result do
      Download.cleanup_intents(intent_ids)
      Catalog.broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  defp claim_verification_hold!(movie) do
    case Repo.update_all(
           from(m in Movie,
             where:
               m.id == ^movie.id and m.status == :import_failed and
                 m.verification_hold_origin == ^movie.verification_hold_origin and
                 m.release_title == ^movie.release_title
           ),
           set: [updated_at: Catalog.now()]
         ) do
      {1, _} -> Repo.get!(Movie, movie.id)
      {0, _} -> Repo.rollback(:stale_status)
    end
  end

  @doc false
  def hold_grab_verification(%Grab{} = grab) do
    observed_attempts = grab.download_attempts || 0

    case Repo.update_all(
           from(g in Grab,
             where:
               g.id == ^grab.id and g.mapping_status == :resolved and
                 g.download_attempts == ^observed_attempts and not is_nil(g.content_path),
             select: g
           ),
           set: [
             mapping_status: :verification_blocked,
             download_attempts: observed_attempts + 1,
             updated_at: Catalog.now()
           ]
         ) do
      {1, [held]} -> broadcast_grab_and_ok(held)
      {0, _} -> {:error, :stale_grab}
    end
  end

  @doc false
  def retry_grab_verification(%Grab{} = grab),
    do: retry_grab(grab, :verification_blocked, :verification_not_held)

  @doc false
  def retry_grab_mapping(%Grab{} = grab), do: retry_grab(grab, :needs_mapping, :mapping_not_held)

  defp retry_grab(grab, from_status, error_atom) do
    case Repo.update_all(
           from(g in Grab,
             where: g.id == ^grab.id and g.mapping_status == ^from_status,
             select: g
           ),
           set: [mapping_status: :resolved, download_attempts: 0, updated_at: Catalog.now()]
         ) do
      {1, [retried]} -> broadcast_grab_and_ok(retried)
      {0, _} -> {:error, error_atom}
    end
  end

  defp broadcast_grab_and_ok(grab) do
    Catalog.broadcast_series(Catalog.series_id_for_grab(grab.id))
    {:ok, grab}
  end

  @doc false
  def reject_movie_release(%Movie{} = expected, evidence) do
    result =
      Repo.transaction(fn ->
        {claimed, _} =
          Repo.update_all(
            from(m in Movie,
              where:
                m.id == ^expected.id and m.status == ^expected.status and
                  m.status in [:downloaded, :upgrading] and
                  m.release_title == ^expected.release_title and
                  m.release_policy_snapshot == ^expected.release_policy_snapshot
            ),
            set: [updated_at: Catalog.now()]
          )

        if claimed != 1, do: Repo.rollback(:stale_release)
        fresh = Repo.get!(Movie, expected.id)

        insert_blocked_release!(%{
          movie_id: fresh.id,
          release_title: fresh.release_title,
          reason: policy_reason(evidence)
        })

        intent_ids = Download.fence_movie_cleanup(fresh)
        target_status = if fresh.status == :upgrading, do: :available, else: :requested

        attrs = %{
          status: target_status,
          download_id: nil,
          download_protocol: nil,
          release_title: nil,
          release_policy_snapshot: nil
        }

        attrs = if fresh.status == :upgrading, do: attrs, else: Map.put(attrs, :file_path, nil)

        updated =
          fresh
          |> Movie.transition_changeset(attrs)
          |> Repo.update!()

        {updated, intent_ids}
      end)

    with {:ok, {updated, intent_ids}} <- result do
      Download.cleanup_intents(intent_ids)
      Catalog.broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  @doc false
  def reject_grab_release(%Grab{} = expected, evidence) do
    expected_episode_ids = expected_grab_episode_ids(expected)

    result =
      Repo.transaction(fn ->
        {claimed, _} =
          Repo.update_all(
            reject_grab_query(expected),
            set: [updated_at: Catalog.now()]
          )

        if claimed != 1, do: Repo.rollback(:stale_release)
        fresh = Repo.get!(Grab, expected.id)
        episode_ids = Catalog.episode_ids_for_grab(fresh.id) |> Enum.sort()
        series_ids = series_ids_for_episode_ids(episode_ids)

        if stale_grab_ownership?(episode_ids, expected_episode_ids, series_ids),
          do: Repo.rollback(:stale_release)

        [series_id] = series_ids

        insert_blocked_release!(%{
          series_id: series_id,
          release_title: fresh.release_title,
          reason: policy_reason(evidence)
        })

        intent_ids =
          Download.fence_episode_cleanup(episode_ids, [
            Catalog.grab_cleanup_spec(fresh, episode_ids)
          ])

        deleted = Repo.delete!(fresh)
        {deleted, intent_ids, series_id}
      end)

    with {:ok, {deleted, intent_ids, series_id}} <- result do
      Download.cleanup_intents(intent_ids)
      Catalog.broadcast_series(series_id)
      {:ok, deleted}
    end
  end

  defp reject_grab_query(expected) do
    from g in Grab,
      where:
        g.id == ^expected.id and g.mapping_status == :resolved and
          g.release_title == ^expected.release_title and
          g.release_policy_snapshot == ^expected.release_policy_snapshot
  end

  defp stale_grab_ownership?(episode_ids, expected_episode_ids, series_ids),
    do: episode_ids == [] or episode_ids != expected_episode_ids or length(series_ids) != 1

  defp series_ids_for_episode_ids(episode_ids) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.id in ^episode_ids,
        select: s.series_id,
        distinct: true
    )
  end

  defp expected_grab_episode_ids(%Grab{episodes: episodes}) when is_list(episodes),
    do: episodes |> Enum.map(& &1.id) |> Enum.sort()

  defp expected_grab_episode_ids(%Grab{
         mapping_snapshot: %{"reserved_episode_ids" => episode_ids}
       })
       when is_list(episode_ids),
       do: Enum.sort(episode_ids)

  defp expected_grab_episode_ids(%Grab{}), do: :unknown

  defp policy_reason(evidence), do: inspect({:release_policy_mismatch, evidence})

  defp insert_blocked_release!(attrs) do
    %BlockedRelease{}
    |> BlockedRelease.changeset(attrs)
    |> Repo.insert!()
  end
end
