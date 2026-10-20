defmodule Cinder.Catalog.EpisodeTransition do
  @moduledoc false
  # The `episodes` adapter of `Cinder.GuardedWrite`: an episode's pipeline fields, from which its
  # state is derived. Only `Cinder.Catalog.transition_episode/3` names it.
  @behaviour Cinder.GuardedWrite

  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season}
  alias Cinder.Repo

  @impl true
  def changeset(episode, attrs), do: Episode.transition_changeset(episode, attrs)

  # No trigger guards an episode's pipeline fields; a CHECK violation is a bug and re-raises.
  @impl true
  def refusal(_message, _attrs), do: nil

  # One `{:series_updated, id}` per series, then `[:cinder, :transition]` per episode.
  @impl true
  def publish(episodes) do
    season_ids = episodes |> Enum.map(& &1.season_id) |> Enum.uniq()

    series =
      Repo.all(from s in Season, where: s.id in ^season_ids, select: {s.id, s.series_id})
      |> Map.new()

    episodes
    |> Enum.group_by(&Map.get(series, &1.season_id))
    |> Enum.each(fn {series_id, written} ->
      Catalog.publish_episode_transition_batch(written, series_id)
    end)
  end
end
