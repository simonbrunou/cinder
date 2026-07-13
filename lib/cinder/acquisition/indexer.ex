defmodule Cinder.Acquisition.Indexer do
  @moduledoc """
  Behaviour for indexer release search (Torznab via Prowlarr).

  Prefer searching by IMDb id over free-text title. Fleshed out in Phase 2.
  """

  @callback search(imdb_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc "Searches movie releases by a bounded free-text query."
  @callback search_movie_query(query :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Searches TV releases by a bounded free-text query."
  @callback search_tv_query(query :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Searches for releases of one TV season. Prefer the `tvdb_id` when present; fall
  back to `title` + season otherwise. Returns the same normalized release maps as
  `search/1` (packs and individual episodes mixed — the parser/scorer sort them out).
  """
  @callback search_tv(tvdb_id :: integer() | nil, title :: String.t(), season :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Lightweight reachability check — `:ok` if the indexer answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}
end
