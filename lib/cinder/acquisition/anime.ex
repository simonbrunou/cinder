defmodule Cinder.Acquisition.Anime do
  @moduledoc "Bounded anime-aware query planning and release aggregation."

  alias Cinder.Acquisition.Release

  @anime_category 5070
  @max_aliases 7
  @max_seasons 4
  @max_queries 24
  @queryable_schemes ~w(standard absolute scene)
  @max_title_codepoints 200
  @max_coordinate_codepoints 32

  @precedence_rank %{manual: 0, curated: 1, inferred: 2}
  @kind_rank %{scene: 0, licensed: 1, romaji: 2, native: 3, alternative: 4}

  def search_movie(indexer, imdb_id, context, _opts) do
    free_text_queries =
      Enum.map(search_titles(context), fn title ->
        query = "#{title} #{context.year}"

        {:free_text, fn -> indexer.search_movie_query(query, categories: [@anime_category]) end}
      end)

    run_queries([{:id_scoped, fn -> indexer.search(imdb_id) end} | free_text_queries], context)
  end

  def search_episodes(indexer, context, wanted_ids, _opts) do
    context
    |> episode_queries(indexer, wanted_ids)
    |> Enum.take(@max_queries)
    |> run_queries(context)
  end

  defp episode_queries(context, indexer, wanted_ids) do
    seasons = wanted_seasons(context, wanted_ids)

    id_queries =
      Enum.map(seasons, fn season ->
        origin = if is_nil(context.tvdb_id), do: :free_text, else: :id_scoped

        {origin, fn -> indexer.search_tv(context.tvdb_id, context.title, season) end}
      end)

    title_queries =
      Enum.map(search_titles(context), fn title ->
        {:free_text, fn -> indexer.search_tv_query(title, categories: [@anime_category]) end}
      end)

    id_queries ++ title_queries ++ coordinate_queries(context, indexer, wanted_ids, seasons)
  end

  defp coordinate_queries(context, indexer, wanted_ids, seasons) do
    if within_codepoint_limit?(context.title, @max_title_codepoints) do
      for season <- seasons,
          scheme <- @queryable_schemes,
          coordinate = earliest_coordinate(context, wanted_ids, season, scheme),
          not is_nil(coordinate) do
        query = "#{context.title} #{coordinate}"

        {:free_text, fn -> indexer.search_tv_query(query, categories: [@anime_category]) end}
      end
    else
      []
    end
  end

  defp earliest_coordinate(context, wanted_ids, season_number, scheme) do
    episode_positions =
      context.episodes
      |> Enum.filter(&(&1.id in wanted_ids and &1.season_number == season_number))
      |> Map.new(&{&1.id, &1.episode_number})

    context.mappings
    |> Enum.filter(fn mapping ->
      mapping.identity.scheme == scheme and
        within_codepoint_limit?(
          mapping.identity.canonical_value,
          @max_coordinate_codepoints
        ) and
        Enum.any?(mapping.episode_ids, &Map.has_key?(episode_positions, &1))
    end)
    |> Enum.min_by(
      fn mapping ->
        first_episode =
          mapping.episode_ids
          |> Enum.filter(&Map.has_key?(episode_positions, &1))
          |> Enum.map(&Map.fetch!(episode_positions, &1))
          |> Enum.min()

        identity = mapping.identity

        {first_episode, identity.canonical_value, identity.source, identity.namespace}
      end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      mapping -> mapping.identity.canonical_value
    end
  end

  defp wanted_seasons(context, wanted_ids) do
    context.episodes
    |> Enum.filter(&(&1.id in wanted_ids))
    |> Enum.map(& &1.season_number)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_seasons)
  end

  defp search_titles(context) do
    canonical_normalized = normalize_title(context.title)

    aliases =
      context.aliases
      |> Enum.filter(&valid_alias?/1)
      |> Enum.sort_by(&alias_sort_key/1)
      |> Enum.uniq_by(&normalize_title(&1.title))
      |> Enum.reject(&(normalize_title(&1.title) == canonical_normalized))
      |> Enum.take(@max_aliases)
      |> Enum.map(& &1.title)

    [context.title | aliases]
    |> Enum.filter(&within_codepoint_limit?(&1, @max_title_codepoints))
  end

  defp valid_alias?(%{title: title}) do
    is_binary(title) and String.trim(title) != "" and
      within_codepoint_limit?(title, @max_title_codepoints)
  end

  defp valid_alias?(_alias), do: false

  defp alias_sort_key(alias_record) do
    {
      Map.get(@precedence_rank, alias_record.precedence, map_size(@precedence_rank)),
      Map.get(@kind_rank, alias_record.kind, map_size(@kind_rank)),
      alias_record.normalized_title,
      alias_record.title
    }
  end

  defp within_codepoint_limit?(value, limit) when is_binary(value),
    do: length(String.codepoints(value)) <= limit

  defp within_codepoint_limit?(_value, _limit), do: false

  defp run_queries(queries, context) do
    outcomes = Enum.map(queries, &run_query/1)
    successes = for {:ok, releases} <- outcomes, do: releases
    failures = for {:error, reason} <- outcomes, do: reason

    case successes do
      [] ->
        {:error, hd(failures)}

      _ ->
        releases = successes |> List.flatten() |> deduplicate() |> apply_title_guard(context)
        {:ok, releases, failures != []}
    end
  end

  defp run_query({origin, query}) do
    case query.() do
      {:ok, results} when is_list(results) ->
        {:ok, Enum.flat_map(results, &build_release(&1, origin))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_release(%{title: title} = result, origin) when is_binary(title) do
    release = Release.new(result)
    [%{release | query_origins: [origin]}]
  end

  defp build_release(_result, _origin), do: []

  defp deduplicate(releases) do
    releases
    |> Enum.reduce({[], %{}}, fn release, {keys, by_key} ->
      key = release_key(release)

      if Map.has_key?(by_key, key) do
        {keys, Map.update!(by_key, key, &merge_release(&1, release))}
      else
        {keys ++ [key], Map.put(by_key, key, release)}
      end
    end)
    |> then(fn {keys, by_key} -> Enum.map(keys, &Map.fetch!(by_key, &1)) end)
  end

  defp release_key(%Release{download_url: url, protocol: protocol})
       when is_binary(url) and url != "",
       do: {protocol, url}

  defp release_key(%Release{} = release) do
    {release.protocol, normalize_title(release.title), release.size}
  end

  defp merge_release(first, later) do
    %{
      first
      | size: first.size || later.size,
        download_url_origin: first.download_url_origin || later.download_url_origin,
        category_ids: union(first.category_ids, later.category_ids),
        indexer_id: first.indexer_id || later.indexer_id,
        published_at: first.published_at || later.published_at,
        query_origins: union(first.query_origins, later.query_origins)
    }
  end

  defp union(first, second), do: Enum.uniq((first || []) ++ (second || []))

  defp apply_title_guard(releases, context) do
    Enum.filter(releases, fn release ->
      :id_scoped in release.query_origins or free_text_match?(release.title, context)
    end)
  end

  defp free_text_match?(release_title, %{kind: :movie} = context) do
    known_title_match?(release_title, context) and exact_movie_year?(release_title, context.year)
  end

  defp free_text_match?(release_title, context), do: known_title_match?(release_title, context)

  defp known_title_match?(release_title, context) do
    normalized_release = release_title |> strip_group() |> normalize_title()

    context
    |> guard_titles()
    |> Enum.any?(fn title ->
      normalized_title = normalize_title(title)

      if String.starts_with?(normalized_release, normalized_title) do
        remainder =
          binary_part(
            normalized_release,
            byte_size(normalized_title),
            byte_size(normalized_release) - byte_size(normalized_title)
          )

        legal_title_remainder?(remainder)
      else
        false
      end
    end)
  end

  defp guard_titles(context) do
    [context.title | Enum.map(context.aliases, & &1.title)]
    |> Enum.filter(&within_codepoint_limit?(&1, @max_title_codepoints))
    |> Enum.uniq_by(&normalize_title/1)
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp legal_title_remainder?(""), do: true

  defp legal_title_remainder?(remainder) do
    Regex.match?(
      ~r/^[\s._\-–—]+(?:\(?\d{4}\)?\b|S\d{1,3}(?:E\d+)?\b|E\d+\b|\d{1,6}(?:\s*-\s*\d{1,6})?(?:v\d+)?\b|\[|\(?(?:\d{3,4}p|WEB|BLURAY|BD|HDTV)\b)/iu,
      remainder
    )
  end

  defp exact_movie_year?(title, year) when is_integer(year) do
    years = Regex.scan(~r/(?<!\d)(?:19|20)\d{2}(?!\d)/u, title, capture: :first) |> List.flatten()
    years == [Integer.to_string(year)]
  end

  defp exact_movie_year?(_title, _year), do: false

  defp strip_group(title), do: Regex.replace(~r/^\s*\[[^\]\r\n]+\]\s*/u, title, "")

  defp normalize_title(title) do
    title
    |> String.normalize(:nfkc)
    |> String.trim()
    |> String.downcase()
  end
end
