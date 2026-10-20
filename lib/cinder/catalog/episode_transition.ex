defmodule Cinder.Catalog.EpisodeTransition do
  @moduledoc false
  # The `episodes` adapter of `Cinder.GuardedWrite`: an episode's pipeline fields, from which its
  # state is derived. Only `Cinder.Catalog.Episodes.transition/3` names it.
  @behaviour Cinder.GuardedWrite

  alias Cinder.Catalog.{Episode, Episodes}

  @impl true
  def changeset(episode, attrs), do: Episode.transition_changeset(episode, attrs)

  # No trigger guards an episode's pipeline fields; a CHECK violation is a bug and re-raises.
  @impl true
  def refusal(_message, _attrs), do: nil

  # One `{:series_updated, id}` per series, then `[:cinder, :transition]` per episode.
  @impl true
  def publish(episodes), do: Episodes.announce(episodes)
end
