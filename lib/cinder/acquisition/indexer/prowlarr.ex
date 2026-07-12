defmodule Cinder.Acquisition.Indexer.Prowlarr do
  @moduledoc """
  Real `Cinder.Acquisition.Indexer` impl, backed by `Req`, against Prowlarr's
  unified JSON search (`GET /api/v1/search`).

  Reads `base_url`, `api_key` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Searches by IMDb id with
  Prowlarr's `{ImdbId:...}` query token (`type=movie`) and returns normalized
  release maps (`%{title, size, download_url, download_url_origin, protocol}`). `download_url`
  falls back to a magnet link when no torrent-file URL is present; `protocol` is
  `:usenet` for Usenet results, `:torrent` otherwise.

  `search_tv/3` is the TV sibling: `type=tvsearch` with a `{TvdbId:...}{Season:...}`
  token (or a free-text title + `{Season:...}` when no TVDB id), reusing the same
  normalization.
  """
  @behaviour Cinder.Acquisition.Indexer

  alias Cinder.HTTPPolicy

  @default_base_url "http://localhost:9696"
  @max_response_bytes 4 * 1024 * 1024

  @impl true
  def search(imdb_id) do
    params = [query: "{ImdbId:#{imdb_id}}", type: "movie"]

    case request(url: "/api/v1/search", params: params) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  @impl true
  def search_tv(tvdb_id, title, season) do
    params = [query: tv_query(tvdb_id, title, season), type: "tvsearch"]

    case request(url: "/api/v1/search", params: params) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  # Prowlarr parses brace tokens out of the query (same syntax as the movie
  # `{ImdbId:...}` path). Prefer the TVDB id; fall back to a free-text title scoped
  # by season. (See the Servarr "Prowlarr Search" wiki.)
  defp tv_query(nil, title, season), do: "#{title} {Season:#{season}}"
  defp tv_query(tvdb_id, _title, season), do: "{TvdbId:#{tvdb_id}}{Season:#{season}}"

  @impl true
  def health do
    # Short receive AND connect bounds — a blackholed host would otherwise sit on
    # Mint's default 30s connect timeout despite the 3s receive_timeout.
    case request(
           url: "/api/v1/health",
           receive_timeout: 3_000,
           connect_options: [timeout: 3_000]
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  defp request(opts) do
    config = config()

    # retry: false — the pollers carry their own bounded-retry budget; Req's default
    # 3-retry backoff on top of it only stretches a tick against a failing indexer.
    [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false
    ]
    |> auth(Keyword.get(config, :api_key))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp auth(opts, nil), do: opts
  defp auth(opts, api_key), do: Keyword.put(opts, :headers, [{"x-api-key", api_key}])

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp error({:ok, %{status: status}}), do: {:error, {:prowlarr_status, status}}
  defp error({:error, reason}), do: {:error, reason}

  defp normalize(result) do
    download_url = result["downloadUrl"] || result["magnetUrl"]

    %{
      title: result["title"],
      size: result["size"],
      download_url: download_url,
      download_url_origin: download_url_origin(download_url),
      protocol: protocol(result["protocol"])
    }
  end

  defp download_url_origin(download_url) when is_binary(download_url) do
    origin = Keyword.get(config(), :base_url, @default_base_url)
    if HTTPPolicy.same_origin?(download_url, origin), do: origin
  end

  defp download_url_origin(_download_url), do: nil

  # Prowlarr's unified search tags each result "torrent" or "usenet"; anything
  # absent/unexpected defaults to :torrent (the conservative routing choice).
  defp protocol("usenet"), do: :usenet
  defp protocol(_), do: :torrent
end
