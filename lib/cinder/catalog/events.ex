defmodule Cinder.Catalog.Events do
  @moduledoc """
  What the catalog announces once a change has committed. The only module that spells the
  `"movies"` and `"series"` topics, and the only one that emits `[:cinder, :transition]`.

  A movie event carries the full struct, a flat row a LiveView patches in place. A series event
  carries only the id, because a series is a tree the detail view re-derives on receipt. A new
  media type picks the shape that matches it (flat row → struct, tree → id).

  Call an announcement after commit, never inside the transaction that wrote the change: a
  subscriber that re-reads on receipt would otherwise see the old row. Each one returns what
  `Phoenix.PubSub.broadcast/3` does (`:ok`).
  """
  alias Cinder.Catalog.Movie

  @movies "movies"
  @series "series"

  @doc """
  Subscribes the caller to `{:movie_created | :movie_updated, movie}` and `{:movie_deleted, id}`.
  """
  def subscribe_movies, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @movies)

  @doc """
  Subscribes the caller to `{:series_updated, id}`, `{:series_deleted, id}` and
  `:media_server_seasons_updated`.
  """
  def subscribe_series, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @series)

  @doc "Announces a movie row that a creation transaction just committed."
  def movie_created(%Movie{} = movie), do: broadcast(@movies, {:movie_created, movie})

  @doc "Announces a movie row's committed change, carrying the fresh row."
  def movie_updated(%Movie{} = movie), do: broadcast(@movies, {:movie_updated, movie})

  @doc "Announces a deleted movie so open views drop the row."
  def movie_deleted(id), do: broadcast(@movies, {:movie_deleted, id})

  @doc """
  Announces a committed change anywhere in a series' tree. A nil id (a grab whose episodes were
  all unlinked, say) announces nothing, so callers need not guard it.
  """
  def series_updated(nil), do: :ok
  def series_updated(series_id), do: broadcast(@series, {:series_updated, series_id})

  @doc "Announces a deleted series so open views drop the row."
  def series_deleted(id), do: broadcast(@series, {:series_deleted, id})

  @doc "Announces a fresh media-server season inventory (`Cinder.Catalog.MediaServerSeasons`)."
  def media_server_seasons_updated, do: broadcast(@series, :media_server_seasons_updated)

  @doc """
  Emits one `[:cinder, :transition]` for a committed pipeline write: `kind` is `:movie` or
  `:episode`, `to` the status (or derived episode state) it reached.
  """
  def transitioned(kind, to) when kind in [:movie, :episode] do
    :telemetry.execute([:cinder, :transition], %{count: 1}, %{kind: kind, to: to})
  end

  defp broadcast(topic, message), do: Phoenix.PubSub.broadcast(Cinder.PubSub, topic, message)
end
