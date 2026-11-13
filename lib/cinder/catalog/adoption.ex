defmodule Cinder.Catalog.Adoption do
  @moduledoc false

  alias Cinder.Catalog.{Episode, Episodes, Events, Identity, MediaProfiles, Profiles, Series}

  alias Cinder.{GuardedWrite, Repo}

  @doc """
  Atomically adopts a list of episode primary/part files. Every action succeeds or every episode
  write rolls back; failures retain their file and episode labels for the adoption UI.

  Each episode write is a guarded write (`Episodes.transition/3`), so broadcasts and transition
  telemetry fire only after commit, one `{:series_updated, id}` per series.
  """
  def adopt_episode_files(actions) when is_list(actions),
    do: adopt_episode_files(actions, [])

  def adopt_episode_files(actions, coordinate_batches)
      when is_list(actions) and is_list(coordinate_batches) do
    case GuardedWrite.transaction(
           fn ->
             {applied, _updated} = reduce_adoptions(actions)
             persist_coordinates(coordinate_batches)
             applied
           end,
           mode: :immediate
         ) do
      {:ok, applied} -> {:ok, Enum.reverse(applied)}
      {:error, failure} -> {:error, [failure]}
    end
  end

  # #455: `validator` (`revalidate_candidate/3`) lstat-walks every path component of each candidate,
  # filesystem I/O that can stall on a network-mounted library root. Run inside the `:immediate`
  # transaction it would hold SQLite's database-wide write lock for the whole stall, queuing every
  # other writer. So the profile is resolved and `validator` runs before any transaction, and
  # `do_adopt_series_files/4` re-resolves both the profile and the series fresh (indexed
  # `Repo.get`s, not filesystem I/O) inside a transaction scoped to only the DB writes.
  @doc false
  def adopt_series_files(
        %Series{id: series_id},
        actions,
        profile_id,
        legacy_handling,
        validator
      )
      when is_list(actions) and is_function(validator, 1) do
    with true <- actions != [],
         {:ok, profile, _handling} <-
           Profiles.resolve_assignment(profile_id, :tv, legacy_handling),
         :ok <- validator.(profile) do
      do_adopt_series_files(series_id, actions, profile_id, legacy_handling)
    else
      false -> {:error, [%{reason: :no_adoptable_files}]}
      {:error, reason} -> {:error, [%{reason: reason}]}
    end
  end

  defp do_adopt_series_files(series_id, actions, profile_id, legacy_handling) do
    result =
      GuardedWrite.transaction(
        fn ->
          with {:ok, profile, handling} <-
                 Profiles.resolve_assignment(profile_id, :tv, legacy_handling),
               %Series{} = series <- Repo.get(Series, series_id),
               {:ok, series} <- Profiles.assign_in_transaction(series, profile, handling) do
            {applied, updated} = reduce_adoptions(actions)
            {series, applied, updated}
          else
            nil -> Repo.rollback(%{reason: :series_not_found})
            {:error, reason} -> Repo.rollback(%{reason: reason})
          end
        end,
        mode: :immediate
      )

    # The adoption may have switched the series' profile, so its anime hold is decided again (#791).
    # The frame announced the series with the episodes it wrote; a profile switch that wrote none
    # is announced here.
    case result do
      {:ok, {series, applied, updated}} ->
        if updated == [], do: Events.series_updated(series.id)
        MediaProfiles.reresolve_anime_hold(series)
        {:ok, Enum.reverse(applied)}

      {:error, failure} ->
        {:error, [failure]}
    end
  end

  defp reduce_adoptions(actions),
    do: Enum.reduce_while(actions, {[], []}, &reduce_adoption/2)

  defp persist_coordinates(coordinate_batches) do
    Enum.each(coordinate_batches, fn batch ->
      case Identity.replace_provider_coordinates(
             batch.series,
             batch.source,
             batch.namespace,
             batch.scheme,
             batch.coordinates
           ) do
        {:ok, _coordinates} -> :ok
        {:error, reason} -> Repo.rollback(%{reason: {:coordinate_write_failed, reason}})
      end
    end)
  end

  defp reduce_adoption(action, {applied, updated}) do
    case adopt_file(action) do
      {:ok, nil} -> {:cont, {[action | applied], updated}}
      {:ok, episode} -> {:cont, {[action | applied], [episode | updated]}}
      {:error, reason} -> Repo.rollback(failure(action, reason))
    end
  end

  defp adopt_file(action), do: adopt_file(action, false)

  defp adopt_file(%{episode: %Episode{id: id}, type: :primary, path: path}, allow_active_grab?)
       when is_binary(path) and path != "" do
    case Repo.get(Episode, id) do
      nil ->
        {:error, :episode_not_found}

      %Episode{file_path: ^path} ->
        {:ok, nil}

      %Episode{grab_id: grab_id} when not is_nil(grab_id) and not allow_active_grab? ->
        {:error, :acquisition_in_progress}

      %Episode{file_path: nil} = episode ->
        update_episode(episode, %{file_path: path})

      %Episode{} ->
        {:error, :already_has_file}
    end
  end

  defp adopt_file(%{episode: %Episode{id: id}, type: :part, path: path}, allow_active_grab?)
       when is_binary(path) and path != "" do
    case Repo.get(Episode, id) do
      nil ->
        {:error, :episode_not_found}

      %Episode{} = episode ->
        parts = episode.part_file_paths || []

        cond do
          path in parts ->
            {:ok, nil}

          acquisition_in_progress?(episode, allow_active_grab?) ->
            {:error, :acquisition_in_progress}

          episode.file_path in [nil, ""] ->
            {:error, :primary_file_missing}

          true ->
            update_episode(episode, %{part_file_paths: parts ++ [path]})
        end
    end
  end

  defp adopt_file(_action, _allow_active_grab?), do: {:error, :invalid_action}

  defp acquisition_in_progress?(episode, allow_active_grab?),
    do: not allow_active_grab? and not is_nil(episode.grab_id)

  @doc false
  def adopt_episode_part(%Episode{} = episode, path),
    do: adopt_file(%{episode: episode, type: :part, path: path}, true)

  # A guarded write on the fields `adopt_file/2` just checked on its re-read. A row another writer
  # changed since is `:episode_not_found`, which the adoption UI renders as "The episode changed
  # while adoption was running."
  defp update_episode(episode, attrs) do
    expect = Map.take(episode, [:file_path, :part_file_paths, :grab_id])

    case Episodes.transition(episode, attrs, expect: expect) do
      {:error, :stale_status} -> {:error, :episode_not_found}
      result -> result
    end
  end

  defp failure(action, reason) when is_map(action),
    do: action |> Map.take([:episode_code, :path]) |> Map.put(:reason, reason)

  defp failure(_action, reason), do: %{reason: reason}
end
