defmodule Cinder.Library.Adoption do
  @moduledoc """
  Discovers unmanaged files under the configured library roots and adopts
  operator-confirmed matches into the catalog.

  `scan/0` only reads the filesystem, TMDB, and catalog. All persisted movie and
  episode paths are written through the Catalog transition choke-points.
  """

  alias Cinder.Acquisition.Parser
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Series}
  alias Cinder.Library
  alias Cinder.Locales

  @candidate_limit 5
  @provider_tag ~r/^(.*?)\s*\{((?:tmdb|tvdb)-\d+|imdb-tt\d+)\}\s*$/iu
  @title_year ~r/^(.*?)\s*\((\d{4})\)\s*$/u

  @doc "Returns adoption candidates for every unmanaged video in both library roots."
  def scan do
    managed = managed_paths()

    (scan_movies(managed) ++ scan_series(managed))
    |> Enum.sort_by(&{&1.kind, &1.directory})
    |> Enum.with_index(1)
    |> Enum.map(fn {candidate, id} -> Map.put(candidate, :id, id) end)
  end

  defdelegate preview_migration(source), to: Cinder.Library.MigrationAdoption, as: :preview
  defdelegate adopt_migration(source, commands), to: Cinder.Library.MigrationAdoption, as: :adopt

  @doc """
  Adopts confirmed candidates and returns
  `%{adopted: count, skipped: count, failures: [failure]}`.

  Ambiguous candidates must carry `:chosen_tmdb_id`. Already-managed paths and
  candidates without an actionable file are skipped. Catalog write failures are
  reported separately with their episode and path.
  """
  def adopt(candidates) when is_list(candidates) do
    {summary, _managed} =
      Enum.reduce(
        candidates,
        {%{adopted: 0, skipped: 0, failures: []}, managed_paths()},
        fn candidate, {summary, managed} ->
          case adopt_candidate(candidate, managed) do
            {:adopted, paths} ->
              {
                Map.update!(summary, :adopted, &(&1 + 1)),
                Enum.reduce(paths, managed, &MapSet.put(&2, normalize_path(&1)))
              }

            {:failed, failures} ->
              {Map.update!(summary, :failures, &(&1 ++ failures)), managed}

            :skipped ->
              {Map.update!(summary, :skipped, &(&1 + 1)), managed}
          end
        end
      )

    summary
  end

  def adopt(_candidates), do: %{adopted: 0, skipped: 0, failures: []}

  defp scan_movies(managed) do
    case root_files(:movies) do
      {:ok, root, files} ->
        movie_candidates(files, root, managed)

      {:error, root, reason} ->
        [scan_error(:movie, root, reason)]

      :unconfigured ->
        []
    end
  end

  defp movie_candidates(files, root, managed) do
    files
    |> Enum.filter(fn {path, _size} -> Library.video_file?(path) end)
    |> Enum.group_by(&movie_group(&1, root))
    |> Enum.reject(&managed_movie_group?(&1, managed))
    |> Enum.map(&movie_candidate/1)
  end

  defp managed_movie_group?({_group, entries}, managed),
    do: Enum.any?(entries, fn {path, _size} -> managed?(managed, path) end)

  defp scan_series(managed) do
    case root_files(:tv) do
      {:ok, root, files} ->
        files
        |> Enum.filter(fn {path, _size} ->
          Library.video_file?(path) and not managed?(managed, path)
        end)
        |> Enum.group_by(&series_group(&1, root))
        |> Enum.map(&series_candidate/1)

      {:error, root, reason} ->
        [scan_error(:series, root, reason)]

      :unconfigured ->
        []
    end
  end

  defp root_files(kind) do
    case Application.get_env(:cinder, :"#{kind}_library_path") do
      root when is_binary(root) and root != "" ->
        case filesystem().find_files(root) do
          {:ok, files} -> {:ok, root, files}
          {:error, reason} -> {:error, root, reason}
        end

      _ ->
        :unconfigured
    end
  end

  defp movie_group({path, _size}, root) do
    case Path.split(Path.relative_to(path, root)) do
      [filename] -> {path, Path.rootname(filename)}
      [directory | _rest] -> {Path.join(root, directory), directory}
    end
  end

  defp series_group({path, _size}, root) do
    case Path.split(Path.relative_to(path, root)) do
      [filename] -> {path, Path.rootname(filename)}
      [directory | _rest] -> {Path.join(root, directory), directory}
    end
  end

  defp movie_candidate({{directory, directory_name}, entries}) do
    paths = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    {path, _size} = Enum.min_by(entries, fn {entry_path, size} -> {-size, entry_path} end)
    parsed = parse_directory(directory_name)

    parsed
    |> candidate_base(:movie, directory, paths)
    |> Map.put(:path, path)
    |> identify_movie()
  end

  defp series_candidate({{directory, directory_name}, entries}) do
    paths = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    parsed = parse_directory(directory_name)

    files =
      paths
      |> Enum.map(&parse_episode_file/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {file, id} -> Map.put(file, :id, id) end)

    parsed
    |> candidate_base(:series, directory, paths)
    |> Map.put(:files, files)
    |> identify_series()
  end

  defp candidate_base(parsed, kind, directory, paths) do
    %{
      kind: kind,
      directory: directory,
      paths: paths,
      title: parsed.title,
      year: parsed.year,
      tagged_tmdb_id: parsed.tmdb_id,
      provider_tag: parsed.provider_tag,
      status: :unmatched,
      match: nil,
      candidates: [],
      reason: nil
    }
  end

  defp identify_movie(%{provider_tag: {:tmdb_id, tmdb_id}} = candidate) do
    match = %{
      tmdb_id: tmdb_id,
      title: candidate.title,
      year: candidate.year,
      poster_path: nil
    }

    %{candidate | status: :auto_matched, match: match}
  end

  defp identify_movie(%{provider_tag: {source, _id} = tag} = candidate)
       when source in [:imdb_id, :tvdb_id] do
    case external_match(tag, :movie) do
      {:ok, match} -> %{candidate | status: :auto_matched, match: match}
      :unresolved -> identify_movie_by_title(candidate)
    end
  end

  defp identify_movie(candidate), do: identify_movie_by_title(candidate)

  defp identify_movie_by_title(candidate) do
    case Catalog.search_movies(candidate.title) do
      {:ok, results} -> put_search_match(candidate, results)
      {:error, reason} -> %{candidate | status: :unmatched, reason: {:tmdb_search_failed, reason}}
    end
  end

  defp identify_series(%{provider_tag: {:tmdb_id, tmdb_id}} = candidate),
    do: identify_tagged_series(candidate, tmdb_id)

  defp identify_series(%{provider_tag: {source, _id} = tag} = candidate)
       when source in [:imdb_id, :tvdb_id] do
    case external_match(tag, :tv) do
      {:ok, %{tmdb_id: tmdb_id}} -> identify_tagged_series(candidate, tmdb_id)
      :unresolved -> identify_series_by_title(candidate)
    end
  end

  defp identify_series(candidate), do: identify_series_by_title(candidate)

  defp identify_tagged_series(candidate, tmdb_id) do
    case fetch_series_tree(tmdb_id) do
      {:ok, info, episode_options} ->
        candidate
        |> Map.put(:match, info)
        |> put_episode_matches(episode_options)

      {:error, reason} ->
        %{candidate | status: :unmatched, reason: {:tmdb_details_failed, reason}}
    end
  end

  defp identify_series_by_title(candidate) do
    case Catalog.search_tv(candidate.title) do
      {:ok, results} ->
        identify_series(candidate, results)

      {:error, reason} ->
        %{candidate | status: :unmatched, reason: {:tmdb_search_failed, reason}}
    end
  end

  defp external_match({source, external_id}, kind) do
    case tmdb().find_by_external_id(external_id, source) do
      {:ok, results} when is_list(results) ->
        case Enum.filter(
               results,
               &match?(%{type: ^kind, tmdb_id: tmdb_id} when is_integer(tmdb_id), &1)
             ) do
          [match] -> {:ok, match}
          _zero_or_many -> :unresolved
        end

      _error ->
        :unresolved
    end
  end

  defp identify_series(candidate, results) do
    case exact_match(results, candidate.title, candidate.year) do
      {:ok, match} -> put_series_match(candidate, match, results)
      :ambiguous -> put_ambiguous_series(candidate, results)
    end
  end

  defp put_series_match(candidate, match, results) do
    case fetch_series_tree(match.tmdb_id) do
      {:ok, _info, episode_options} ->
        candidate
        |> Map.put(:match, match)
        |> Map.put(:candidates, top_candidates(results))
        |> put_episode_matches(episode_options)

      {:error, reason} ->
        %{
          candidate
          | status: :unmatched,
            candidates: top_candidates(results),
            reason: {:tmdb_details_failed, reason}
        }
    end
  end

  defp put_ambiguous_series(candidate, results) do
    %{
      candidate
      | status: :ambiguous,
        candidates: top_candidates(results),
        files: mark_pending(candidate.files)
    }
  end

  defp put_search_match(candidate, results) do
    case exact_match(results, candidate.title, candidate.year) do
      {:ok, match} ->
        %{
          candidate
          | status: :auto_matched,
            match: match,
            candidates: top_candidates(results)
        }

      :ambiguous ->
        %{candidate | status: :ambiguous, candidates: top_candidates(results)}
    end
  end

  defp exact_match(results, title, year) do
    case Enum.filter(results, &(same_title?(&1.title, title) and &1.year == year)) do
      [match] -> {:ok, match}
      _zero_or_many -> :ambiguous
    end
  end

  defp same_title?(left, right), do: normalize_title(left) == normalize_title(right)

  defp normalize_title(title) do
    title
    |> String.normalize(:nfd)
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
  end

  defp top_candidates(results), do: Enum.take(results, @candidate_limit)

  defp parse_directory(name) do
    {base, provider_tag} = parse_provider_tag(name)

    case Regex.run(@title_year, base, capture: :all_but_first) do
      [title, year] ->
        %{
          title: String.trim(title),
          year: parse_integer(year),
          tmdb_id: tagged_tmdb_id(provider_tag),
          provider_tag: provider_tag
        }

      _ ->
        %{
          title: base,
          year: nil,
          tmdb_id: tagged_tmdb_id(provider_tag),
          provider_tag: provider_tag
        }
    end
  end

  defp parse_provider_tag(name) do
    case Regex.run(@provider_tag, name, capture: :all_but_first) do
      [base, tag] ->
        [source, external_id] = tag |> String.downcase() |> String.split("-", parts: 2)
        {String.trim(base), provider_tag(source, external_id)}

      _ ->
        {String.trim(name), nil}
    end
  end

  defp provider_tag("tmdb", id), do: {:tmdb_id, parse_integer(id)}
  defp provider_tag("tvdb", id), do: {:tvdb_id, parse_integer(id)}
  defp provider_tag("imdb", id), do: {:imdb_id, id}

  defp tagged_tmdb_id({:tmdb_id, id}), do: id
  defp tagged_tmdb_id(_tag), do: nil

  defp parse_episode_file(path) do
    parsed = Parser.parse(Path.basename(path))

    if is_integer(parsed.season) and is_list(parsed.episodes) and parsed.episodes != [] do
      %{
        path: path,
        season_number: parsed.season,
        episode_numbers: parsed.episodes,
        status: :pending,
        mappings: [],
        part_candidates: [],
        part_of: nil,
        reason: nil
      }
    else
      %{
        path: path,
        season_number: nil,
        episode_numbers: [],
        status: :unmatched,
        mappings: [],
        part_candidates: [],
        part_of: nil,
        reason: :episode_number_not_found
      }
    end
  end

  defp mark_pending(files) do
    Enum.map(files, fn
      %{status: :unmatched} = file -> file
      file -> %{file | status: :pending}
    end)
  end

  defp put_episode_matches(candidate, episode_options) do
    files = resolve_episode_files(candidate.files, episode_options)

    cond do
      Enum.any?(files, &(&1.status == :matched)) ->
        %{candidate | status: :auto_matched, files: files}

      Enum.any?(files, &(Map.get(&1, :part_candidates, []) != [])) ->
        %{candidate | status: :auto_matched, files: files}

      true ->
        %{candidate | status: :unmatched, files: files, reason: :no_matched_episodes}
    end
  end

  defp resolve_episode_files(files, episode_options) do
    episode_keys =
      MapSet.new(episode_options, &{&1.season_number, &1.episode_number})

    options_by_season = Enum.group_by(episode_options, & &1.season_number)

    Enum.map(files, fn
      %{status: :unmatched} = file ->
        file

      file ->
        mappings =
          Enum.map(file.episode_numbers, fn episode_number ->
            %{season_number: file.season_number, episode_number: episode_number}
          end)

        missing =
          Enum.reject(mappings, fn mapping ->
            MapSet.member?(episode_keys, {mapping.season_number, mapping.episode_number})
          end)

        if missing == [] do
          %{file | status: :matched, mappings: mappings, reason: nil}
        else
          %{
            file
            | status: :unmatched,
              mappings: [],
              part_candidates: part_candidates(file, options_by_season),
              reason: {:episode_not_found, missing}
          }
        end
    end)
    |> demote_duplicate_claims()
  end

  defp part_candidates(%{episode_numbers: [_], season_number: season}, options_by_season),
    do: Map.get(options_by_season, season, [])

  defp part_candidates(_file, _options_by_season), do: []

  # Two files claiming the same episode is exactly the ambiguity adoption must never
  # resolve by guessing (last-write-wins would silently pick one) — hold every claimant
  # for the operator instead, mirroring the import pipeline's never-guess rule.
  defp demote_duplicate_claims(files) do
    duplicates =
      files
      |> Enum.filter(&(&1.status == :matched))
      |> Enum.flat_map(fn file ->
        Enum.map(file.mappings, &{&1.season_number, &1.episode_number})
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, claims} -> claims > 1 end)
      |> MapSet.new(fn {key, _claims} -> key end)

    if MapSet.size(duplicates) == 0 do
      files
    else
      Enum.map(files, &demote_duplicate_file(&1, duplicates))
    end
  end

  defp demote_duplicate_file(%{status: :matched} = file, duplicates) do
    dupes =
      file.mappings
      |> Enum.map(&{&1.season_number, &1.episode_number})
      |> Enum.filter(&MapSet.member?(duplicates, &1))

    if dupes == [] do
      file
    else
      %{file | status: :unmatched, mappings: [], reason: {:duplicate_episode_claim, dupes}}
    end
  end

  defp demote_duplicate_file(file, _duplicates), do: file

  defp fetch_series_tree(tmdb_id) do
    with {:ok, info} <- tmdb().get_series(tmdb_id),
         {:ok, seasons} <- fetch_seasons(tmdb_id, info.seasons) do
      episode_options =
        for season <- seasons,
            episode <- season.episodes do
          %{
            season_number: season.season_number,
            episode_number: episode.episode_number,
            title: episode.title
          }
        end

      {:ok, info, episode_options}
    end
  end

  defp fetch_seasons(tmdb_id, seasons) do
    Enum.reduce_while(seasons, {:ok, []}, fn %{season_number: season_number}, {:ok, acc} ->
      case tmdb().get_season(tmdb_id, season_number, Locales.canonical()) do
        {:ok, season} -> {:cont, {:ok, [season | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp adopt_candidate(%{kind: :movie} = candidate, managed),
    do: adopt_movie(candidate, managed)

  defp adopt_candidate(%{kind: :series} = candidate, managed),
    do: adopt_series(candidate, managed)

  defp adopt_candidate(_candidate, _managed), do: :skipped

  defp adopt_movie(candidate, managed) do
    with true <- candidate.status in [:auto_matched, :ambiguous],
         tmdb_id when is_integer(tmdb_id) <- chosen_tmdb_id(candidate),
         path when is_binary(path) <- Map.get(candidate, :path),
         false <- managed?(managed, path),
         {:ok, details} <- Catalog.get_movie(tmdb_id),
         {:ok, movie, created} <-
           Catalog.find_or_create_at_available(movie_attrs(details), path),
         :ok <- announce_movie_creation(movie, created == :created) do
      {:adopted, [path]}
    else
      _ -> :skipped
    end
  end

  defp movie_attrs(details),
    do:
      Map.take(details, [
        :tmdb_id,
        :imdb_id,
        :title,
        :year,
        :poster_path,
        :original_language,
        :localizations
      ])

  defp announce_movie_creation(movie, true), do: Catalog.broadcast_movie_created(movie)
  defp announce_movie_creation(_movie, false), do: :ok

  defp adopt_series(candidate, managed) do
    files =
      candidate
      |> Map.get(:files, [])
      |> Enum.filter(&(&1.status in [:matched, :pending, :part]))
      |> Enum.reject(&managed?(managed, &1.path))

    with true <- candidate.status in [:auto_matched, :ambiguous],
         true <- files != [],
         tmdb_id when is_integer(tmdb_id) <- chosen_tmdb_id(candidate) do
      do_adopt_series(files, tmdb_id)
    else
      _ -> :skipped
    end
  end

  defp do_adopt_series(files, tmdb_id) do
    existing? = match?(%Series{}, Catalog.get_series_by_tmdb_id(tmdb_id))

    case Catalog.add_series(tmdb_id, monitor_strategy: :none) do
      {:ok, series} -> finish_series_adoption(files, series, existing?)
      {:error, _reason} -> :skipped
    end
  end

  defp finish_series_adoption(files, series, existing?) do
    case adopt_episode_files(files, Catalog.get_series_with_tree(series.id)) do
      {:ok, []} ->
        :skipped

      {:ok, paths} ->
        announce_series_creation(series, existing?)
        {:adopted, paths}

      {:error, failures} ->
        {:failed, failures}
    end
  end

  defp announce_series_creation(_series, true), do: :ok
  defp announce_series_creation(series, false), do: Catalog.broadcast_series(series.id)

  defp adopt_episode_files(files, %Series{} = series) do
    episodes =
      for season <- series.seasons,
          episode <- season.episodes,
          into: %{},
          do: {{season.season_number, episode.episode_number}, episode}

    {normal_files, part_files} = Enum.split_with(files, &(&1.status != :part))

    {primary_actions, _written} =
      Enum.reduce(normal_files, {[], MapSet.new()}, &plan_episode_file(&1, episodes, &2))

    part_actions = Enum.reduce(part_files, [], &plan_episode_part(&1, episodes, &2))
    actions = Enum.reverse(primary_actions) ++ Enum.reverse(part_actions)

    case Catalog.adopt_episode_files(actions) do
      {:ok, applied} -> {:ok, applied |> Enum.map(& &1.path) |> Enum.uniq()}
      {:error, failures} -> {:error, failures}
    end
  end

  defp adopt_episode_files(_files, _missing_series), do: {:ok, []}

  defp plan_episode_part(
         %{
           status: :part,
           part_of: %{season_number: season_number, episode_number: episode_number}
         } = file,
         episodes,
         actions
       ) do
    case Map.get(episodes, {season_number, episode_number}) do
      %Episode{} = episode ->
        [episode_action(episode, file.path, season_number, episode_number, :part) | actions]

      _ ->
        actions
    end
  end

  defp plan_episode_part(%{status: :part}, _episodes, actions), do: actions

  defp plan_episode_file(file, episodes, {actions, written}) do
    keys = Enum.map(file.episode_numbers, &{file.season_number, &1})
    mapped = Enum.map(keys, &Map.get(episodes, &1))

    # `written` re-guards within this run what demote_duplicate_claims/1 already holds at
    # scan time: a key another file just claimed can never be silently overwritten.
    if Enum.any?(keys, &MapSet.member?(written, &1)) or
         not adoptable_episode_file?(mapped, file.path) do
      {actions, written}
    else
      actions =
        mapped
        |> Enum.zip(keys)
        |> Enum.reduce(actions, fn
          {%Episode{file_path: nil} = episode, {season_number, episode_number}}, acc ->
            [
              episode_action(
                episode,
                file.path,
                season_number,
                episode_number,
                :primary
              )
              | acc
            ]

          {_already_adopted, _key}, acc ->
            acc
        end)

      {actions, MapSet.union(written, MapSet.new(keys))}
    end
  end

  defp adoptable_episode_file?(episodes, path) do
    Enum.all?(episodes, fn
      %Episode{file_path: nil} -> true
      %Episode{file_path: ^path} -> true
      _ -> false
    end)
  end

  defp episode_action(episode, path, season_number, episode_number, type) do
    %{
      episode: episode,
      episode_code: Episode.code(season_number, episode_number),
      path: path,
      type: type
    }
  end

  defp chosen_tmdb_id(%{chosen_tmdb_id: id}), do: parse_integer(id)
  defp chosen_tmdb_id(%{match: %{tmdb_id: id}}), do: parse_integer(id)
  defp chosen_tmdb_id(_candidate), do: nil

  defp managed_paths do
    movie_paths = Catalog.list_movies() |> Enum.map(& &1.file_path)
    episode_paths = Catalog.list_episodes_with_file() |> Enum.flat_map(&Episode.file_paths/1)

    (movie_paths ++ episode_paths)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> MapSet.new(&normalize_path/1)
  end

  defp managed?(managed, path), do: MapSet.member?(managed, normalize_path(path))
  defp normalize_path(path), do: Path.expand(path)

  defp scan_error(kind, root, reason) do
    %{
      kind: kind,
      directory: root,
      paths: [],
      path: nil,
      files: [],
      title: Path.basename(root),
      year: nil,
      tagged_tmdb_id: nil,
      provider_tag: nil,
      status: :unmatched,
      match: nil,
      candidates: [],
      reason: {:scan_failed, reason}
    }
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp filesystem, do: Application.fetch_env!(:cinder, :filesystem)
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
