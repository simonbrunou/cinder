defmodule Cinder.Catalog.EpisodeTransition do
  @moduledoc false

  import Ecto.Query

  alias Cinder.Catalog.Episode
  alias Cinder.Repo

  def guarded(%Episode{} = episode, attrs, expected) do
    case Episode.transition_changeset(episode, attrs) do
      %{valid?: true} = changeset ->
        guarded_update(episode.id, changeset.changes, expected)

      %{valid?: false} = changeset ->
        {:error, changeset}
    end
  end

  defp guarded_update(id, changes, expected) do
    query =
      Enum.reduce(expected, from(e in Episode, where: e.id == ^id), fn
        {field, nil}, query ->
          from e in query, where: is_nil(field(e, ^field))

        {field, value}, query ->
          from e in query, where: field(e, ^field) == ^value
      end)

    case Repo.update_all(query |> select([e], e),
           set: Map.to_list(changes) ++ [updated_at: Cinder.Catalog.now()]
         ) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, :stale_episode}
    end
  end
end
