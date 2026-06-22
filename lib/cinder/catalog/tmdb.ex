defmodule Cinder.Catalog.TMDB do
  @moduledoc """
  Behaviour for TMDB discovery: search and fetch details for movies and TV.

  The concrete impl is resolved from config; tests use a Mox mock. Movie and TV
  callbacks are kept distinct (no overloaded `search/1`).
  """

  @callback search(query :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_movie(tmdb_id :: integer()) :: {:ok, map()} | {:error, term()}

  @doc "TV search. Returns normalized series maps (`%{tmdb_id, title, year, poster_path}`)."
  @callback search_tv(query :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Series details + the list of season numbers. Returns
  `%{tmdb_id, tvdb_id, title, year, poster_path, seasons: [%{season_number}]}`.
  `tvdb_id` is `nil` when TMDB has no `external_ids` block.
  """
  @callback get_series(tmdb_id :: integer()) :: {:ok, map()} | {:error, term()}

  @doc """
  One season's episodes. Returns
  `%{season_number, episodes: [%{tmdb_episode_id, episode_number, title, air_date}]}`
  (`air_date` is a `Date` or `nil`).
  """
  @callback get_season(series_id :: integer(), season_number :: integer()) ::
              {:ok, map()} | {:error, term()}

  @doc "Lightweight reachability/token check — `:ok` if TMDB answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}
end
