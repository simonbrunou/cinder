defmodule Cinder.Catalog.TMDB do
  @moduledoc """
  Behaviour for TMDB discovery: search and fetch details for movies and TV.

  The concrete impl is resolved from config; tests use a Mox mock. Movie and TV
  callbacks are kept distinct (no overloaded `search/2`).
  """

  @doc "Movie search. Returns `%{tmdb_id, title, year, poster_path, imdb_id, original_language, overview, runtime, genres, vote_average, release_date}` per result (`imdb_id`/`runtime` are `nil` and `genres` is `[]` on search results — only `get_movie` details carry them; `original_language`/`overview`/`vote_average`/`release_date` are populated by `/search/movie`)."
  @callback search(query :: String.t(), locale :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Single movie details. Returns `%{tmdb_id, title, year, poster_path, imdb_id, original_language, overview, runtime, genres, vote_average, release_date}` (`genres` is a list of names, `release_date` a `Date` or `nil`)."
  @callback get_movie(tmdb_id :: integer()) :: {:ok, map()} | {:error, term()}

  @doc "TV search. Returns normalized series maps (`%{tmdb_id, title, year, poster_path, original_language}`)."
  @callback search_tv(query :: String.t(), locale :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Series details + the list of season numbers. Returns
  `%{tmdb_id, tvdb_id, title, year, poster_path, original_language, overview, genres,
  vote_average, first_air_date, seasons: [%{season_number}]}`. `tvdb_id` is `nil` when TMDB
  has no `external_ids` block; `genres` is a list of names, `first_air_date` a `Date` or `nil`.
  """
  @callback get_series(tmdb_id :: integer()) :: {:ok, map()} | {:error, term()}

  @doc """
  One season's episodes. Returns
  `%{season_number, episodes: [%{tmdb_episode_id, episode_number, title, air_date}]}`
  (`air_date` is a `Date` or `nil`).
  """
  @callback get_season(
              series_id :: integer(),
              season_number :: integer(),
              locale :: String.t()
            ) ::
              {:ok, map()} | {:error, term()}

  @doc "Alternative movie titles normalized as title, country code, and `:alternative` kind."
  @callback get_movie_alternative_titles(tmdb_id :: integer()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Alternative series titles normalized as title, country code, and `:alternative` kind."
  @callback get_series_alternative_titles(tmdb_id :: integer()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Lists a series' TMDB episode groups, with their group/episode counts for the alternate-numbering picker."
  @callback get_episode_groups(series_id :: integer()) ::
              {:ok,
               [
                 %{
                   id: String.t(),
                   type: integer(),
                   name: String.t(),
                   group_count: integer() | nil,
                   episode_count: integer() | nil
                 }
               ]}
              | {:error, term()}

  @doc "Fetches an episode group with its flattened, ordered episode coordinates."
  @callback get_episode_group(group_id :: String.t()) ::
              {:ok,
               %{
                 id: String.t(),
                 type: integer(),
                 name: String.t(),
                 entries: [map()]
               }}
              | {:error, term()}

  @doc "Lightweight reachability/token check — `:ok` if TMDB answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}
end
