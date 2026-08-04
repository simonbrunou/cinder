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

  `search_tv/3` is the TV sibling: `type=tvsearch`, unioning a `{TvdbId:...}{Season:...}`
  token query with a free-text title + `{Season:...}` query (see `search_tv/3` for why
  the id query alone is not enough), reusing the same normalization.
  """
  @behaviour Cinder.Acquisition.Indexer

  alias Cinder.HTTPPolicy
  alias Cinder.Util

  @default_base_url "http://localhost:9696"
  @max_response_bytes 4 * 1024 * 1024

  @impl true
  def search(imdb_id) do
    search_query("{ImdbId:#{imdb_id}}", "movie", [])
  end

  @impl true
  def search_tv(nil, title, season) do
    case search_query(tv_query(nil, title, season), "tvsearch", []) do
      {:ok, releases} -> {:ok, tag_query_origin(releases, :free_text)}
      {:error, _reason} = error -> error
    end
  end

  # Text-scraper indexers (1337x & co.) return nothing for a {TvdbId:...} token —
  # Prowlarr does no id→title resolution for them — so the id query alone hides every
  # release they carry. Union both shapes (id results first, deduped by download_url);
  # one side failing degrades to the other so a flaky scraper can't sink the search.
  # Keep per-result provenance so callers can title-guard the free-text half without
  # rejecting AKA-titled releases that genuinely came from the TVDB-scoped query.
  def search_tv(tvdb_id, title, season) do
    case {search_query(tv_query(tvdb_id, title, season), "tvsearch", []),
          search_query(tv_query(nil, title, season), "tvsearch", [])} do
      {{:ok, by_id}, {:ok, by_title}} ->
        releases =
          tag_query_origin(by_id, :id_scoped) ++ tag_query_origin(by_title, :free_text)

        {:ok, merge_query_origins(releases)}

      {{:ok, by_id}, _error} ->
        {:ok, tag_query_origin(by_id, :id_scoped)}

      {_error, {:ok, by_title}} ->
        {:ok, tag_query_origin(by_title, :free_text)}

      {error, _error} ->
        error
    end
  end

  defp tag_query_origin(releases, origin),
    do: Enum.map(releases, &Map.put(&1, :query_origins, [origin]))

  defp merge_query_origins(releases) do
    releases
    |> Enum.reduce({[], %{}}, fn release, {keys, by_url} ->
      key = release.download_url

      case Map.fetch(by_url, key) do
        {:ok, existing} ->
          origins = Enum.uniq(existing.query_origins ++ release.query_origins)
          {keys, Map.put(by_url, key, %{existing | query_origins: origins})}

        :error ->
          {[key | keys], Map.put(by_url, key, release)}
      end
    end)
    |> then(fn {keys, by_url} ->
      keys |> Enum.reverse() |> Enum.map(&Map.fetch!(by_url, &1))
    end)
  end

  @impl true
  def search_movie_query(query, opts), do: search_query(query, "moviesearch", opts)

  @impl true
  def search_tv_query(query, opts), do: search_query(query, "tvsearch", opts)

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
    # 90s receive_timeout: a search fanning out to a scraper indexer behind FlareSolverr
    # takes 20-60s (a Cloudflare solve alone budgets 60s), and 15s silently starved the
    # title-query half of search_tv/3's union down to usenet-only results.
    [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      receive_timeout: 90_000,
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

  defp search_query(query, type, opts) do
    params =
      [query: query, type: type]
      |> add_categories(Keyword.get(opts, :categories, []))

    case request(url: "/api/v1/search", params: params) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        {:ok, Enum.flat_map(results, &normalize/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  defp add_categories(params, []), do: params

  defp add_categories(params, categories),
    do: Keyword.put(params, :categories, Enum.join(categories, ","))

  defp normalize(result) when is_map(result) do
    with title when is_binary(title) <- Util.blank_to_nil(result["title"]),
         download_url when is_binary(download_url) <-
           Util.blank_to_nil(result["downloadUrl"]) || Util.blank_to_nil(result["magnetUrl"]) do
      [
        %{
          title: title,
          size: integer_or_nil(result["size"]),
          download_url: download_url,
          download_url_origin: download_url_origin(download_url),
          protocol: protocol(result["protocol"]),
          category_ids: category_ids(result["categories"]),
          indexer_id: integer_or_nil(result["indexerId"]),
          published_at: published_at(result["publishDate"])
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize(_result), do: []

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp category_ids(categories) when is_list(categories) do
    categories
    |> Enum.flat_map(fn
      %{"id" => id} when is_integer(id) -> [id]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp category_ids(_categories), do: []

  defp published_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp published_at(_value), do: nil

  defp download_url_origin(download_url) when is_binary(download_url) do
    origin = Keyword.get(config(), :base_url, @default_base_url)
    if HTTPPolicy.same_origin?(download_url, origin), do: origin
  end

  # Prowlarr's unified search tags each result "torrent" or "usenet"; anything
  # absent/unexpected defaults to :torrent (the conservative routing choice).
  defp protocol("usenet"), do: :usenet
  defp protocol(_), do: :torrent
end
