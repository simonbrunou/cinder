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

  alias Cinder.Repo

  @doc """
  Creates a movie at `:requested`.

  Defaults `tmdb_id` to a fresh unique integer and `title` to "Inception". Each key lands in
  one place: `:media_profile` in `Movie.profile_changeset/2`, a `Movie.creation_fields/0` key in
  `Catalog.add_movie/1`, and any other `Movie.transition_fields/0` key (`:status`,
  `:download_id`, the attempt counters, the `imported_*` columns...) in `seed_movie_state/2`
  after creation, so a downloading/downloaded fixture is a one-liner.

  No passed value is dropped silently. It raises `ArgumentError` on a key none of them takes, on
  a blank value `cast/3` empties (a blank string becomes the field's default, a blank list entry
  is removed), and on a value `Movie.transition_changeset/2` clears at the movie's status. A
  value that changeset clears only on the status change itself gets a second
  `seed_movie_state/2` write, which broadcasts `{:movie_updated, movie}` again.
  """
  def movie_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {profile_attrs, rest} = Map.split(attrs, [:media_profile])
    {create_attrs, rest} = Map.split(rest, Movie.creation_fields())
    {pipeline, unknown} = Map.split(rest, Movie.transition_fields())

    reject!(
      Map.keys(unknown),
      "it takes :media_profile and the atom keys Movie.creation_fields/0 or " <>
        "Movie.transition_fields/0 lists"
    )

    reject!(emptied(attrs), "cast/3 reads their blank value as empty")

    create_attrs =
      Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, create_attrs)

    {:ok, movie} = Catalog.add_movie(create_attrs)
    movie = if map_size(pipeline) == 0, do: movie, else: seed_pipeline(movie, pipeline)

    if map_size(profile_attrs) == 0,
      do: movie,
      else: Repo.update!(Movie.profile_changeset(movie, profile_attrs))
  end

  # `Movie.transition_changeset/2` can clear a passed value on the status change it writes, so a
  # value the first write cleared gets a second write with the status already in place. A value
  # still cleared after that is one the movie's status never keeps.
  defp seed_pipeline(movie, pipeline) do
    {:ok, movie} = seed_movie_state(movie, pipeline)
    movie = reseed(movie, pipeline, unseeded(movie, pipeline))

    reject!(
      unseeded(movie, pipeline),
      "Movie.transition_changeset/2 clears them at status #{inspect(movie.status)}"
    )

    movie
  end

  defp reseed(movie, _pipeline, []), do: movie

  defp reseed(movie, pipeline, keys) do
    {:ok, movie} = seed_movie_state(movie, Map.take(pipeline, keys))
    movie
  end

  # The passed keys whose value differs from the movie's: `cast/3` records only those as changes.
  defp unseeded(movie, pipeline) do
    movie
    |> Ecto.Changeset.cast(pipeline, Map.keys(pipeline))
    |> Map.fetch!(:changes)
    |> Map.keys()
  end

  # The passed keys whose value `cast/3` empties (`""`, `"  "`, a blank list entry), found by
  # casting once as usual and once with no empty values.
  defp emptied(attrs) do
    as_cast = cast_results(attrs, [])
    as_given = cast_results(attrs, empty_values: [])
    for key <- Map.keys(attrs), as_cast[key] != as_given[key], do: key
  end

  # Each key's cast value as `{:ok, value}`, or `:error` when its cast fails.
  defp cast_results(attrs, opts) do
    changeset = Ecto.Changeset.cast(%Movie{}, attrs, Map.keys(attrs), opts)

    Map.new(attrs, fn {key, _value} ->
      if Keyword.has_key?(changeset.errors, key),
        do: {key, :error},
        else: {key, {:ok, Ecto.Changeset.get_field(changeset, key)}}
    end)
  end

  defp reject!([], _reason), do: :ok

  defp reject!(keys, reason),
    do: raise(ArgumentError, "movie_fixture/1 cannot take #{inspect(keys)}: #{reason}")

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
  Puts a movie or series on an anime hold for `reason` through its one writer,
  `Catalog.set_anime_hold/2`, as a sweep would, and returns the held title.
  """
  def anime_hold_fixture(title, reason) do
    {:ok, held} = Catalog.set_anime_hold(title, reason)
    held
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
