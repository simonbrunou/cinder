defmodule Cinder.Acquisition.Indexer do
  @moduledoc """
  Behaviour for indexer release search (Torznab via Prowlarr).

  Prefer searching by IMDb id over free-text title. Fleshed out in Phase 2.
  """

  @callback search(imdb_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc "Lightweight reachability check — `:ok` if the indexer answers, else `{:error, reason}`."
  @callback health() :: :ok | {:error, term()}
end
