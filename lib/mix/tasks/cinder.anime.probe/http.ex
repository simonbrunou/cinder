defmodule Mix.Tasks.Cinder.Anime.Probe.HTTP do
  @moduledoc false

  alias Cinder.HTTPPolicy

  @tmdb_base_url "https://api.themoviedb.org"
  @prowlarr_base_url "http://localhost:9696"
  @max_response_bytes 4 * 1024 * 1024

  @spec fetch_title(map(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_title(title, tmdb_config, prowlarr_config) do
    with {:ok, searches} <- tmdb_searches(title, tmdb_config),
         {:ok, alternatives} <- tmdb_alternatives(title, tmdb_config),
         {:ok, details} <- tmdb_details(title, tmdb_config),
         {:ok, groups} <- tmdb_groups(title, tmdb_config),
         {:ok, prowlarr} <- prowlarr_searches(title, prowlarr_config) do
      {:ok,
       %{
         slug: title.slug,
         kind: title.kind,
         tmdb_id: title.tmdb_id,
         searches: searches,
         alternatives: alternatives,
         details: details,
         groups: groups,
         prowlarr: prowlarr
       }}
    end
  end

  defp tmdb_searches(title, config) do
    map_ok(title.discovery_queries, fn query ->
      case tmdb_request(config, url: "/3/search/#{tmdb_kind(title.kind)}", params: [query: query]) do
        {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
          {:ok,
           %{
             query: query,
             results: Enum.map(results, &normalize_search_result(&1, title.kind))
           }}

        other ->
          provider_error(:tmdb, other)
      end
    end)
  end

  defp tmdb_alternatives(title, config) do
    path = "/3/#{tmdb_kind(title.kind)}/#{title.tmdb_id}/alternative_titles"

    case tmdb_request(config, url: path) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        alternatives =
          case title.kind do
            :tv -> body["results"]
            :movie -> body["titles"]
          end

        if is_list(alternatives) do
          {:ok, Enum.map(alternatives, &%{title: &1["title"]})}
        else
          {:error, :unexpected_response}
        end

      other ->
        provider_error(:tmdb, other)
    end
  end

  defp tmdb_details(title, config) do
    path = "/3/#{tmdb_kind(title.kind)}/#{title.tmdb_id}"

    case tmdb_request(config, url: path) do
      {:ok, %{status: 200, body: %{"id" => _id} = body}} ->
        {:ok,
         %{
           id: body["id"],
           title: body[tmdb_title_key(title.kind)],
           seasons:
             for(
               %{"season_number" => number} <- body["seasons"] || [],
               do: %{season_number: number}
             )
         }}

      other ->
        provider_error(:tmdb, other)
    end
  end

  defp tmdb_groups(%{kind: :movie}, _config), do: {:ok, []}

  defp tmdb_groups(title, config) do
    case tmdb_request(config, url: "/3/tv/#{title.tmdb_id}/episode_groups") do
      {:ok, %{status: 200, body: %{"results" => groups}}} when is_list(groups) ->
        required_types = MapSet.new([2 | title.expect.required_group_types])

        groups
        |> Enum.filter(&MapSet.member?(required_types, &1["type"]))
        |> map_ok(&tmdb_group(&1, config))

      other ->
        provider_error(:tmdb, other)
    end
  end

  defp tmdb_group(group, config) do
    case tmdb_request(config, url: "/3/tv/episode_group/#{group["id"]}") do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok,
         %{
           id: body["id"] || group["id"],
           type: body["type"] || group["type"],
           name: body["name"] || group["name"],
           entries: normalize_group_entries(body["groups"])
         }}

      other ->
        provider_error(:tmdb, other)
    end
  end

  defp normalize_group_entries(groups) do
    for %{"order" => group_order, "episodes" => episodes} <- groups || [],
        is_list(episodes),
        episode <- episodes do
      %{
        episode_id: episode["id"],
        group_order: group_order,
        order: episode["order"],
        season_number: episode["season_number"],
        episode_number: episode["episode_number"]
      }
    end
  end

  defp prowlarr_searches(title, config) do
    searches = for query <- title.prowlarr_queries, mode <- [:all, :anime], do: {query, mode}

    map_ok(searches, fn {query, mode} ->
      params =
        [query: query, type: prowlarr_type(title.kind)]
        |> maybe_add_category(mode)

      case prowlarr_request(config, url: "/api/v1/search", params: params) do
        {:ok, %{status: 200, body: results}} when is_list(results) ->
          {:ok,
           %{
             query: query,
             mode: mode,
             results: results |> Enum.take(50) |> Enum.map(&normalize_release/1)
           }}

        other ->
          provider_error(:prowlarr, other)
      end
    end)
  end

  defp maybe_add_category(params, :all), do: params
  defp maybe_add_category(params, :anime), do: Keyword.put(params, :categories, 5070)

  defp normalize_release(result) do
    %{
      title: result["title"],
      size: result["size"],
      protocol: result["protocol"],
      categories:
        for(
          %{"id" => id, "name" => name} <- result["categories"] || [],
          do: %{id: id, name: name}
        ),
      published_at: result["publishDate"]
    }
  end

  defp normalize_search_result(result, kind) do
    %{id: result["id"], title: result[tmdb_title_key(kind)]}
  end

  defp tmdb_request(config, opts) do
    config
    |> request_options(@tmdb_base_url)
    |> add_bearer(Keyword.get(config, :token))
    |> Keyword.merge(opts)
    |> bounded_request(config)
  end

  defp prowlarr_request(config, opts) do
    config
    |> request_options(@prowlarr_base_url)
    |> add_api_key(Keyword.get(config, :api_key))
    |> Keyword.merge(opts)
    |> bounded_request(config)
  end

  defp request_options(config, default_base_url) do
    [
      base_url: Keyword.get(config, :base_url, default_base_url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false
    ]
  end

  defp bounded_request(opts, config) do
    opts
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp add_bearer(opts, nil), do: opts
  defp add_bearer(opts, token), do: Keyword.put(opts, :auth, {:bearer, token})
  defp add_api_key(opts, nil), do: opts
  defp add_api_key(opts, api_key), do: Keyword.put(opts, :headers, [{"x-api-key", api_key}])

  defp provider_error(_provider, {:error, reason}) when is_atom(reason), do: {:error, reason}

  defp provider_error(_provider, {:error, %{reason: reason}}) when is_atom(reason),
    do: {:error, reason}

  defp provider_error(_provider, {:error, _reason}), do: {:error, :request_failed}
  defp provider_error(_provider, {:ok, %{status: 200}}), do: {:error, :unexpected_response}

  defp provider_error(provider, {:ok, %{status: status}}),
    do: {:error, {status_tag(provider), status}}

  defp provider_error(_provider, _result), do: {:error, :request_failed}

  defp status_tag(:tmdb), do: :tmdb_status
  defp status_tag(:prowlarr), do: :prowlarr_status
  defp tmdb_kind(:tv), do: "tv"
  defp tmdb_kind(:movie), do: "movie"
  defp tmdb_title_key(:tv), do: "name"
  defp tmdb_title_key(:movie), do: "title"
  defp prowlarr_type(:tv), do: "tvsearch"
  defp prowlarr_type(:movie), do: "moviesearch"

  defp map_ok(enumerable, function) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, values} ->
      case function.(item) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error
end
