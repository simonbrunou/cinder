defmodule Cinder.Catalog.TMDB.HTTP do
  @moduledoc """
  Real `Cinder.Catalog.TMDB` impl, backed by `Req`.

  Reads `base_url`, `token` (v4 bearer) and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Returns normalized maps for both
  movies (`%{tmdb_id, title, year, poster_path, imdb_id, original_language}`; search results
  carry `imdb_id: nil`) and TV (see the `Cinder.Catalog.TMDB` callback docs).
  """
  @behaviour Cinder.Catalog.TMDB

  alias Cinder.HTTPPolicy

  @default_base_url "https://api.themoviedb.org"
  @max_response_bytes 4 * 1024 * 1024

  @impl true
  def search(query) do
    case request(url: "/3/search/movie", params: [query: query]) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  @impl true
  def get_movie(tmdb_id) do
    case request(url: "/3/movie/#{tmdb_id}") do
      {:ok, %{status: 200, body: %{"id" => _} = body}} -> {:ok, normalize(body)}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  @impl true
  def search_tv(query) do
    case request(url: "/3/search/tv", params: [query: query]) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize_tv/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  @impl true
  def get_series(tmdb_id) do
    # append_to_response folds external_ids (tvdb_id) into the one details call.
    case request(url: "/3/tv/#{tmdb_id}", params: [append_to_response: "external_ids"]) do
      {:ok, %{status: 200, body: %{"id" => _} = body}} -> {:ok, normalize_series(body)}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  @impl true
  def get_season(series_id, season_number) do
    case request(url: "/3/tv/#{series_id}/season/#{season_number}") do
      {:ok, %{status: 200, body: %{"episodes" => episodes} = body}} when is_list(episodes) ->
        {:ok, normalize_season(body)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  @impl true
  def get_movie_alternative_titles(tmdb_id) do
    alternative_titles("/3/movie/#{tmdb_id}/alternative_titles", "titles")
  end

  @impl true
  def get_series_alternative_titles(tmdb_id) do
    alternative_titles("/3/tv/#{tmdb_id}/alternative_titles", "results")
  end

  @impl true
  def get_episode_groups(series_id) do
    normalized_list("/3/tv/#{series_id}/episode_groups", "results", &normalize_group/1)
  end

  @impl true
  def get_episode_group(group_id) do
    case request(url: "/3/tv/episode_group/#{group_id}") do
      {:ok, %{status: 200, body: body}} -> normalize_group_detail(body)
      other -> error(other)
    end
  end

  @impl true
  def health do
    # /3/authentication validates the bearer token; short timeouts (receive AND
    # connect) so a down/slow TMDB can't hang the settings "Test connection".
    # Errors stay sanitized (no token/headers).
    case request(
           url: "/3/authentication",
           receive_timeout: 3_000,
           connect_options: [timeout: 3_000]
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:tmdb_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(opts) do
    config = Application.get_env(:cinder, __MODULE__, [])

    # retry: false — Req's default 3-retry backoff turns one hung/500ing TMDB call
    # into ~a minute; callers (search UI, poller, refresher) all prefer failing fast.
    [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false
    ]
    |> auth(Keyword.get(config, :token))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp auth(opts, nil), do: opts
  defp auth(opts, token), do: Keyword.put(opts, :auth, {:bearer, token})

  defp error({:ok, %{status: status}}), do: {:error, {:tmdb_status, status}}
  defp error({:error, reason}), do: {:error, reason}

  defp alternative_titles(path, container) do
    normalized_list(path, container, &normalize_alternative_title/1)
  end

  defp normalized_list(path, container, normalize) do
    case request(url: path) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        case Map.fetch(body, container) do
          {:ok, items} when is_list(items) -> normalize_items(items, normalize)
          _other -> {:error, :unexpected_response}
        end

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  defp normalize_items(items, normalize) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, normalized} ->
      case normalize.(item) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, :unexpected_response} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_alternative_title(%{"title" => title, "iso_3166_1" => country_code})
       when is_binary(title) and is_binary(country_code) do
    {:ok, %{title: title, country_code: country_code, kind: :alternative}}
  end

  defp normalize_alternative_title(_title), do: {:error, :unexpected_response}

  defp normalize_group(%{"id" => id, "type" => type, "name" => name})
       when is_binary(id) and is_integer(type) and is_binary(name) do
    {:ok, %{id: id, type: type, name: name}}
  end

  defp normalize_group(_group), do: {:error, :unexpected_response}

  defp normalize_group_detail(%{
         "id" => id,
         "type" => type,
         "name" => name,
         "groups" => groups
       })
       when is_binary(id) and is_integer(type) and is_binary(name) and is_list(groups) do
    with {:ok, nested_entries} <- normalize_items(groups, &normalize_group_entries/1) do
      entries =
        nested_entries
        |> List.flatten()
        |> Enum.sort_by(&{&1.group_order, &1.order})

      {:ok, %{id: id, type: type, name: name, entries: entries}}
    end
  end

  defp normalize_group_detail(_body), do: {:error, :unexpected_response}

  defp normalize_group_entries(%{"order" => group_order, "episodes" => episodes})
       when is_integer(group_order) and is_list(episodes) do
    normalize_items(episodes, &normalize_group_entry(&1, group_order))
  end

  defp normalize_group_entries(_group), do: {:error, :unexpected_response}

  defp normalize_group_entry(
         %{
           "id" => tmdb_episode_id,
           "order" => order,
           "season_number" => season_number,
           "episode_number" => episode_number
         },
         group_order
       )
       when is_integer(tmdb_episode_id) and is_integer(order) and is_integer(season_number) and
              is_integer(episode_number) do
    {:ok,
     %{
       tmdb_episode_id: tmdb_episode_id,
       group_order: group_order,
       order: order,
       season_number: season_number,
       episode_number: episode_number
     }}
  end

  defp normalize_group_entry(_episode, _group_order), do: {:error, :unexpected_response}

  defp normalize(movie) do
    %{
      tmdb_id: movie["id"],
      title: movie["title"],
      year: year_from(movie["release_date"]),
      poster_path: movie["poster_path"],
      imdb_id: movie["imdb_id"],
      original_language: movie["original_language"],
      # Descriptive metadata — only the details endpoint (get_movie) carries genres/runtime;
      # /search/movie omits them (genre_ids only), so a search map gets genres: [], runtime: nil.
      # Harmless: only get_movie feeds Movie.metadata_changeset.
      overview: movie["overview"],
      runtime: movie["runtime"],
      genres: genre_names(movie["genres"]),
      vote_average: movie["vote_average"],
      release_date: date_from(movie["release_date"])
    }
  end

  defp normalize_tv(series) do
    %{
      tmdb_id: series["id"],
      title: series["name"],
      year: year_from(series["first_air_date"]),
      poster_path: series["poster_path"],
      original_language: series["original_language"]
    }
  end

  defp normalize_series(body) do
    # external_ids only present with append_to_response; for TV the ids (tvdb_id)
    # live under it, unlike movies where imdb_id is top-level.
    external = body["external_ids"] || %{}

    %{
      tmdb_id: body["id"],
      tvdb_id: external["tvdb_id"],
      title: body["name"],
      year: year_from(body["first_air_date"]),
      poster_path: body["poster_path"],
      original_language: body["original_language"],
      overview: body["overview"],
      genres: genre_names(body["genres"]),
      vote_average: body["vote_average"],
      first_air_date: date_from(body["first_air_date"]),
      seasons: for(s <- body["seasons"] || [], do: %{season_number: s["season_number"]})
    }
  end

  # TMDB genres are `[%{"id" => _, "name" => _}]` on the details endpoints; keep the names only.
  # Search endpoints send `genre_ids` (no names) — so a search body yields `[]` here.
  defp genre_names(genres) when is_list(genres) do
    for %{"name" => name} <- genres, is_binary(name), do: name
  end

  defp genre_names(_), do: []

  defp normalize_season(body) do
    %{
      season_number: body["season_number"],
      episodes:
        for e <- body["episodes"] || [] do
          %{
            tmdb_episode_id: e["id"],
            episode_number: e["episode_number"],
            title: e["name"],
            air_date: date_from(e["air_date"])
          }
        end
    }
  end

  defp year_from(date) when is_binary(date) and date != "" do
    case Integer.parse(date) do
      {year, _rest} -> year
      :error -> nil
    end
  end

  defp year_from(_), do: nil

  # TMDB returns "" (or omits the key) for un-aired/TBA dates; map both to nil so the
  # :date cast and the monitor-strategy `>= today` comparison never see a bad string.
  defp date_from(date) when is_binary(date) and date != "" do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      {:error, _} -> nil
    end
  end

  defp date_from(_), do: nil
end
