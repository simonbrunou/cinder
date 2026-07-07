defmodule Cinder.CatalogFixtures do
  @moduledoc """
  Test helpers for building catalog entities (movies and the series/season/episode
  tree) via the `Cinder.Catalog` context and direct inserts.
  """

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season, Series}
  alias Cinder.Repo

  @movie_pipeline_keys [
    :status,
    :download_id,
    :file_path,
    :download_protocol,
    :release_title,
    :imported_resolution,
    :imported_size,
    :imported_language,
    :imported_source,
    :imported_audio_languages,
    :imported_embedded_subtitles,
    :imported_sidecar_subtitles
  ]

  @doc """
  Creates a watchlisted movie at `:requested`.

  Defaults `tmdb_id` to a fresh unique integer and `title` to "Inception"; any
  other key is passed through to `Catalog.add_to_watchlist/1`. Pipeline keys
  (`:status`, `:download_id`, `:file_path`, `:download_protocol`) are applied via
  a single `Catalog.transition/2` after creation, so a downloading/downloaded
  fixture is a one-liner.
  """
  def movie_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {pipeline, create_attrs} = Map.split(attrs, @movie_pipeline_keys)

    create_attrs =
      Map.merge(%{tmdb_id: System.unique_integer([:positive]), title: "Inception"}, create_attrs)

    {:ok, movie} = Catalog.add_to_watchlist(create_attrs)

    if map_size(pipeline) == 0 do
      movie
    else
      {:ok, movie} = Catalog.transition(movie, pipeline)
      movie
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
end
