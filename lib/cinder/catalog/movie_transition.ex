defmodule Cinder.Catalog.MovieTransition do
  @moduledoc false
  # The `movies` adapter of `Cinder.GuardedWrite`. Only `Cinder.Catalog.MovieLifecycle` names it:
  # every movie status write is one of its verbs.
  @behaviour Cinder.GuardedWrite

  alias Cinder.Catalog.Events
  alias Cinder.Catalog.Movie

  @impl true
  def changeset(movie, attrs), do: Movie.transition_changeset(movie, attrs)

  # The transition changeset casts neither profile column, so `movies_profile_integrity` cannot
  # fire; a CHECK violation is a bug and re-raises.
  @impl true
  def refusal(_message, _attrs), do: nil

  # Per movie: `{:movie_updated, movie}` on the "movies" topic, then `[:cinder, :transition]`.
  @impl true
  def publish(movies) do
    Enum.each(movies, fn movie ->
      Events.movie_updated(movie)
      Events.transitioned(:movie, movie.status)
    end)
  end
end
