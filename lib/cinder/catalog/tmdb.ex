defmodule Cinder.Catalog.TMDB do
  @moduledoc """
  Behaviour for TMDB discovery: search movies and fetch details.

  The concrete impl is resolved from config; tests use a Mox mock.
  Callbacks are fleshed out in Phase 1.
  """

  @callback search(query :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_movie(tmdb_id :: integer()) :: {:ok, map()} | {:error, term()}

  @doc "Lightweight reachability/token check — `:ok` if TMDB answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}
end
