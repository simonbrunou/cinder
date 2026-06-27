defmodule Cinder.Acquisition.Indexer.Prowlarr do
  @moduledoc """
  Real `Cinder.Acquisition.Indexer` impl, backed by `Req`, against Prowlarr's
  unified JSON search (`GET /api/v1/search`).

  Reads `base_url`, `api_key` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Searches by IMDb id with
  Prowlarr's `{ImdbId:...}` query token (`type=movie`) and returns normalized
  release maps (`%{title, size, download_url, protocol}`). `download_url`
  falls back to a magnet link when no torrent-file URL is present; `protocol` is
  `:usenet` for Usenet results, `:torrent` otherwise.

  `search_tv/3` is the TV sibling: `type=tvsearch` with a `{TvdbId:...}{Season:...}`
  token (or a free-text title + `{Season:...}` when no TVDB id), reusing the same
  normalization.
  """
  @behaviour Cinder.Acquisition.Indexer

  @default_base_url "http://localhost:9696"

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
    case request(url: "/api/v1/health", receive_timeout: 3_000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  defp request(opts) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [base_url: Keyword.get(config, :base_url, @default_base_url), receive_timeout: 15_000]
    |> auth(Keyword.get(config, :api_key))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
    |> Req.request()
  end

  defp auth(opts, nil), do: opts
  defp auth(opts, api_key), do: Keyword.put(opts, :headers, [{"x-api-key", api_key}])

  defp error({:ok, %{status: status}}), do: {:error, {:prowlarr_status, status}}
  defp error({:error, reason}), do: {:error, reason}

  defp normalize(result) do
    %{
      title: result["title"],
      size: result["size"],
      download_url: result["downloadUrl"] || result["magnetUrl"],
      protocol: protocol(result["protocol"])
    }
  end

  # Prowlarr's unified search tags each result "torrent" or "usenet"; anything
  # absent/unexpected defaults to :torrent (the conservative routing choice).
  defp protocol("usenet"), do: :usenet
  defp protocol(_), do: :torrent
end
