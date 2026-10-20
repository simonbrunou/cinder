defmodule Cinder.CatalogFixtures do
  @moduledoc """
  Test helpers for building catalog entities (movies and the series/season/episode
  tree) via the `Cinder.Catalog` context and direct inserts.
  """

  alias Cinder.Catalog

  alias Cinder.Catalog.{
    Episode,
    EpisodeCoordinate,
    EpisodeCoordinateMembership,
    Events,
    Movie,
    Season,
    Series
  }

  alias Cinder.Library.ImportedQuality
  alias Cinder.Repo

  @movie_pipeline_keys [
    :status,
    :download_id,
    :file_path,
    :content_path,
    :download_protocol,
    :release_title
  ]

  @doc """
  Creates a movie at `:requested`.

  Defaults `tmdb_id` to a fresh unique integer and `title` to "Inception"; any
  other key is passed through to `Catalog.add_movie/1`. Pipeline keys
  (`:status`, `:download_id`, `:file_path`, `:download_protocol`, the `imported_*`
  columns) are applied via a single `seed_movie_state/2` after creation, so a
  downloading/downloaded fixture is a one-liner.
  """
  def movie_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {media_profile, attrs} = Map.pop(attrs, :media_profile)

    {pipeline, create_attrs} =
      Map.split(attrs, @movie_pipeline_keys ++ ImportedQuality.column_names(Movie))

    create_attrs =
      Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, create_attrs)

    {:ok, movie} = Catalog.add_movie(create_attrs)

    movie =
      if map_size(pipeline) == 0 do
        movie
      else
        {:ok, movie} = seed_movie_state(movie, pipeline)
        movie
      end

    if media_profile,
      do: Repo.update!(Movie.profile_changeset(movie, %{media_profile: media_profile})),
      else: movie
  end

  @doc """
  Test-only seeding path: writes `attrs` (pipeline fields, `:status` included) straight onto
  `movie` and broadcasts `{:movie_updated, movie}`, so an open LiveView sees the change.

  It skips the movie lifecycle on purpose: no transition matrix, no compare-and-swap and no
  `[:cinder, :transition]` telemetry. Use it to put a row where a test needs it, or to play a
  concurrent writer. To test a lifecycle edge, call the `Cinder.Catalog.MovieLifecycle` verb.
  Returns `{:ok, movie}`, or `{:error, changeset}` for an invalid status or counter.
  """
  def seed_movie_state(%Movie{} = movie, attrs) do
    with {:ok, seeded} <- movie |> Movie.transition_changeset(Map.new(attrs)) |> Repo.update() do
      Events.movie_updated(seeded)
      {:ok, seeded}
    end
  end

  @doc """
  Inserts a `Series` with sensible defaults (unique `tmdb_id`, title "Show",
  year 2008, monitored, `monitor_strategy: :future`). Override any field via `attrs`.
  """
  def series_fixture(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Series{
          tmdb_id: System.unique_integer([:positive]),
          title: "Show",
          year: 2008,
          monitored: true,
          monitor_strategy: :future
        },
        Map.new(attrs)
      )
    )
  end

  @doc """
  Inserts a `Season` under `series` (defaults: `season_number: 1`, monitored).
  """
  def season_fixture(series, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Season{series_id: series.id, season_number: 1, monitored: true},
        Map.new(attrs)
      )
    )
  end

  @doc """
  Inserts an `Episode` under `season` (defaults: `episode_number: 1`, monitored,
  `air_date: ~D[2001-01-01]`).
  """
  def episode_fixture(season, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Episode{
          season_id: season.id,
          episode_number: 1,
          monitored: true,
          air_date: ~D[2001-01-01]
        },
        Map.new(attrs)
      )
    )
  end

  @doc """
  Inserts an `EpisodeCoordinate` plus its ordered `EpisodeCoordinateMembership` rows for
  `episode_ids`, direct-Repo — mirrors what `Cinder.Catalog.Identity.put_coordinate_or_rollback/3`
  writes, minus the series-ownership validation and broadcast (a test seeding a coordinate needs
  neither). Returns the coordinate with `memberships: [:episode]` preloaded.
  """
  def episode_coordinate_fixture(%Series{id: series_id}, attrs, episode_ids) do
    coordinate =
      %EpisodeCoordinate{series_id: series_id}
      |> EpisodeCoordinate.changeset(Map.new(attrs))
      |> Repo.insert!()

    episode_ids
    |> Enum.with_index()
    |> Enum.each(fn {episode_id, position} ->
      %EpisodeCoordinateMembership{episode_coordinate_id: coordinate.id, episode_id: episode_id}
      |> EpisodeCoordinateMembership.changeset(%{position: position})
      |> Repo.insert!()
    end)

    Repo.preload(coordinate, memberships: [:episode])
  end

  @doc """
  A TMDB episode-group literal, list-shape (`group_count`/`episode_count`, no `entries`) and
  detail-shape (`entries`, no counts) alike — one builder shared by every test hand-rolling
  `get_episode_groups`/`get_episode_group` responses, instead of each file repeating the same
  `%{id:, type:, name:, entries: [...]}` map. Callers override whatever the test cares about.
  """
  def episode_group(attrs) do
    Map.merge(
      %{id: "group", type: 6, name: "Seasons", group_count: nil, episode_count: nil, entries: []},
      Map.new(attrs)
    )
  end
end
