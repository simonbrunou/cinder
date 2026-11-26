defmodule Cinder.Indexers.ProwlarrApi do
  @moduledoc """
  Reads Prowlarr's own API outside search: the one way Cinder reads `/api/v1/*` besides
  `Cinder.Acquisition.IndexerSource.Prowlarr`'s search and health calls. The Prowlarr import
  (`Cinder.Indexers.ProwlarrImport`) reads the indexers, the indexer proxies and the host config
  through it (#1673).

  `connection/0` reads the Prowlarr URL and API key Cinder stores, the `base_url` and `api_key`
  of `config :cinder, Cinder.Acquisition.IndexerSource.Prowlarr` that the `prowlarr_url` and
  `prowlarr_api_key` settings overlay. With either unset or blank it answers
  `{:error, :not_configured}`; it never falls back to the search's `http://localhost:9696`.

  `get/3` sends one GET to a path under that URL, with its query, through the adapter the
  `:prowlarr_api` key names (`Cinder.Indexers.ProwlarrApi.HTTP`), read with
  `Application.fetch_env!/2` on each call. It answers the decoded JSON body of a 200, or a closed
  error tag that never holds a URL, a header or a body: `{:http_status, status}` for any other
  status, a redirect included, `:timeout`, `:too_large`, `:transport` and `:invalid_json`.
  """

  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.Indexers.ProwlarrApi.Connection

  @type error ::
          {:http_status, non_neg_integer()}
          | :timeout
          | :too_large
          | :transport
          | :invalid_json

  @doc "Sends a GET to `path` with `query` under the connection's URL."
  @callback get(Connection.t(), path :: String.t(), query :: keyword()) ::
              {:ok, term()} | {:error, error()}

  @doc "The stored Prowlarr URL and API key, or `{:error, :not_configured}` when either is unset or blank."
  @spec connection() :: {:ok, Connection.t()} | {:error, :not_configured}
  def connection do
    key = :cinder |> Application.get_env(Prowlarr, []) |> Keyword.get(:api_key)

    case {Prowlarr.saved_base_url(), key} do
      {url, key} when is_binary(url) and is_binary(key) ->
        if String.trim(key) == "",
          do: {:error, :not_configured},
          else: {:ok, %Connection{url: url, api_key: key}}

      _unset ->
        {:error, :not_configured}
    end
  end

  @doc "Sends a GET to `path` with `query` through the configured adapter."
  @spec get(Connection.t(), String.t(), keyword()) :: {:ok, term()} | {:error, error()}
  def get(%Connection{} = connection, path, query \\ []),
    do: Application.fetch_env!(:cinder, :prowlarr_api).get(connection, path, query)
end
