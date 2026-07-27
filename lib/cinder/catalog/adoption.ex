defmodule Cinder.Catalog.Adoption do
  @moduledoc false

  import Ecto.Query

  alias Cinder.Catalog.{Episode, Identity, Season, SeriesCatalog}
  alias Cinder.Repo

  @doc """
  Atomically adopts a list of episode primary/part files. Every action succeeds or every episode
  write rolls back; failures retain their file and episode labels for the adoption UI.

  Broadcasts and transition telemetry fire only after commit.
  """
  def adopt_episode_files(actions) when is_list(actions),
    do: adopt_episode_files(actions, [])

  def adopt_episode_files(actions, coordinate_batches)
      when is_list(actions) and is_list(coordinate_batches) do
    case Repo.transaction(fn ->
           {applied, updated} = reduce_adoptions(actions)
           persist_coordinates(coordinate_batches)
           {applied, updated}
         end) do
      {:ok, {applied, updated}} ->
        publish(updated)
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

  defp adopt_file(%{episode: %Episode{id: id}, type: :primary, path: path})
       when is_binary(path) and path != "" do
    case Repo.get(Episode, id) do
      nil -> {:error, :episode_not_found}
      %Episode{file_path: nil} = episode -> update_episode(episode, %{file_path: path})
      %Episode{file_path: ^path} -> {:ok, nil}
      %Episode{} -> {:error, :already_has_file}
    end
  end

  defp adopt_file(%{episode: %Episode{id: id}, type: :part, path: path})
       when is_binary(path) and path != "" do
    case Repo.get(Episode, id) do
      nil ->
        {:error, :episode_not_found}

      %Episode{file_path: primary} when primary in [nil, ""] ->
        {:error, :primary_file_missing}

      %Episode{} = episode ->
        parts = episode.part_file_paths || []

        if path in parts,
          do: {:ok, nil},
          else: update_episode(episode, %{part_file_paths: parts ++ [path]})
    end
  end

  defp adopt_file(_action), do: {:error, :invalid_action}

  defp update_episode(episode, attrs) do
    episode
    |> Episode.transition_changeset(attrs)
    |> Repo.update(stale_error_field: :id)
  end

  defp failure(action, reason) when is_map(action),
    do: action |> Map.take([:episode_code, :path]) |> Map.put(:reason, reason)

  defp failure(_action, reason), do: %{reason: reason}

  defp publish(updated) do
    season_ids = Enum.map(updated, & &1.season_id)

    Repo.all(from s in Season, where: s.id in ^season_ids, select: s.series_id, distinct: true)
    |> Enum.each(&Cinder.Catalog.broadcast_series/1)

    Enum.each(updated, fn episode ->
      :telemetry.execute(
        [:cinder, :transition],
        %{count: 1},
        %{kind: :episode, to: SeriesCatalog.episode_state(episode)}
      )
    end)
  end
end
