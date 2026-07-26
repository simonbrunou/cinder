defmodule Cinder.Library.Adoption do
  @moduledoc """
  Discovers unmanaged files under the configured library roots and adopts
  operator-confirmed matches into the catalog.

  `scan/0` only reads the filesystem, TMDB, and catalog. All persisted movie and
  episode paths are written through the Catalog transition choke-points.
  """

  alias Cinder.Acquisition.Parser
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Library
  alias Cinder.Locales

  @candidate_limit 5
  @tmdb_tag ~r/^(.*?)\s*\{tmdb-(\d+)\}\s*$/iu
  @title_year ~r/^(.*?)\s*\((\d{4})\)\s*$/u

  @doc "Returns adoption candidates for every unmanaged video in both library roots."
  def scan do
    managed = managed_paths()

    (scan_movies(managed) ++ scan_series(managed))
    |> Enum.sort_by(&{&1.kind, &1.directory})
    |> Enum.with_index(1)
    |> Enum.map(fn {candidate, id} -> Map.put(candidate, :id, id) end)
  end

  @doc """
  Adopts confirmed candidates and returns `%{adopted: count, skipped: count}`.

  Ambiguous candidates must carry `:chosen_tmdb_id`. Already-managed paths and
  candidates without an actionable file are skipped.
  """
  def adopt(candidates) when is_list(candidates) do
    {summary, _managed} =
      Enum.reduce(candidates, {%{adopted: 0, skipped: 0}, managed_paths()}, fn candidate,
                                                                               {summary, managed} ->
        case adopt_candidate(candidate, managed) do
          {:adopted, paths} ->
            {
              Map.update!(summary, :adopted, &(&1 + 1)),
              Enum.reduce(paths, managed, &MapSet.put(&2, normalize_path(&1)))
            }

          :skipped ->
            {Map.update!(summary, :skipped, &(&1 + 1)), managed}
        end
      end)

    summary
  end

  def adopt(_candidates), do: %{adopted: 0, skipped: 0}

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
    files = Enum.map(paths, &parse_episode_file/1)

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
      status: :unmatched,
      match: nil,
      candidates: [],
      reason: nil
    }
  end

  defp identify_movie(%{tagged_tmdb_id: tmdb_id} = candidate) when is_integer(tmdb_id) do
    match = %{
      tmdb_id: tmdb_id,
      title: candidate.title,
      year: candidate.year,
      poster_path: nil
    }

    %{candidate | status: :auto_matched, match: match}
  end

  defp identify_movie(candidate) do
    case Catalog.search_movies(candidate.title) do
      {:ok, results} -> put_search_match(candidate, results)
      {:error, reason} -> %{candidate | status: :unmatched, reason: {:tmdb_search_failed, reason}}
    end
  end

  defp identify_series(%{tagged_tmdb_id: tmdb_id} = candidate) when is_integer(tmdb_id) do
    case fetch_series_tree(tmdb_id) do
      {:ok, info, episode_keys} ->
        candidate
        |> Map.put(:match, info)
        |> put_episode_matches(episode_keys)

      {:error, reason} ->
        %{candidate | status: :unmatched, reason: {:tmdb_details_failed, reason}}
    end
  end

  defp identify_series(candidate) do
    case Catalog.search_tv(candidate.title) do
      {:ok, results} ->
        identify_series(candidate, results)

      {:error, reason} ->
        %{candidate | status: :unmatched, reason: {:tmdb_search_failed, reason}}
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
      {:ok, _info, episode_keys} ->
        candidate
        |> Map.put(:match, match)
        |> Map.put(:candidates, top_candidates(results))
        |> put_episode_matches(episode_keys)

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
    {base, tmdb_id} =
      case Regex.run(@tmdb_tag, name, capture: :all_but_first) do
        [base, id] -> {String.trim(base), parse_integer(id)}
        _ -> {String.trim(name), nil}
      end

    case Regex.run(@title_year, base, capture: :all_but_first) do
      [title, year] ->
        %{title: String.trim(title), year: parse_integer(year), tmdb_id: tmdb_id}

      _ ->
        %{title: base, year: nil, tmdb_id: tmdb_id}
    end
  end

  defp parse_episode_file(path) do
    parsed = Parser.parse(Path.basename(path))

    if is_integer(parsed.season) and is_list(parsed.episodes) and parsed.episodes != [] do
      %{
        path: path,
        season_number: parsed.season,
        episode_numbers: parsed.episodes,
        status: :pending,
        mappings: [],
        reason: nil
      }
    else
      %{
        path: path,
        season_number: nil,
        episode_numbers: [],
        status: :unmatched,
        mappings: [],
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

  defp put_episode_matches(candidate, episode_keys) do
    files = resolve_episode_files(candidate.files, episode_keys)

    if Enum.any?(files, &(&1.status == :matched)) do
      %{candidate | status: :auto_matched, files: files}
    else
      %{candidate | status: :unmatched, files: files, reason: :no_matched_episodes}
    end
  end

  defp resolve_episode_files(files, episode_keys) do
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
          %{file | status: :unmatched, mappings: [], reason: {:episode_not_found, missing}}
        end
    end)
    |> demote_duplicate_claims()
  end

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
      keys =
        for season <- seasons,
            episode <- season.episodes,
            into: MapSet.new(),
            do: {season.season_number, episode.episode_number}

      {:ok, info, keys}
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
         {:ok, movie, created?} <- movie_for_adoption(details),
         :ok <- announce_movie_creation(movie, created?),
         {:ok, _movie} <- Catalog.transition(movie, %{status: :available, file_path: path}) do
      {:adopted, [path]}
    else
      _ -> :skipped
    end
  end

  defp movie_for_adoption(details) do
    case Catalog.get_movie_by_tmdb_id(details.tmdb_id) do
      %Movie{file_path: path} when path not in [nil, ""] ->
        {:error, :already_has_file}

      %Movie{} = movie ->
        {:ok, movie, false}

      nil ->
        attrs =
          Map.take(details, [
            :tmdb_id,
            :imdb_id,
            :title,
            :year,
            :poster_path,
            :original_language,
            :localizations
          ])

        case Catalog.add_movie(attrs) do
          {:ok, movie} -> {:ok, movie, true}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp announce_movie_creation(movie, true), do: Catalog.broadcast_movie_created(movie)
  defp announce_movie_creation(_movie, false), do: :ok

  defp adopt_series(candidate, managed) do
    files =
      candidate
      |> Map.get(:files, [])
      |> Enum.filter(&(&1.status in [:matched, :pending]))
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

    with {:ok, series} <- Catalog.add_series(tmdb_id, monitor_strategy: :none),
         {:ok, strategy_changed?} <- ensure_unmonitored(series) do
      announce_series_creation(series, existing?)
      {count, paths} = adopt_episode_files(files, Catalog.get_series_with_tree(series.id))
      finish_series_adoption(existing?, strategy_changed?, count, paths)
    else
      {:error, _reason} -> :skipped
    end
  end

  defp announce_series_creation(_series, true), do: :ok
  defp announce_series_creation(series, false), do: Catalog.broadcast_series(series.id)

  defp finish_series_adoption(false, _strategy_changed?, _count, paths), do: {:adopted, paths}
  defp finish_series_adoption(true, true, _count, paths), do: {:adopted, paths}
  defp finish_series_adoption(true, false, count, paths) when count > 0, do: {:adopted, paths}
  defp finish_series_adoption(true, false, 0, _paths), do: :skipped

  defp ensure_unmonitored(%Series{monitor_strategy: :none, monitored: false}), do: {:ok, false}

  defp ensure_unmonitored(series) do
    case Catalog.set_series_monitor_strategy(series, :none) do
      {:ok, _series} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adopt_episode_files(files, %Series{} = series) do
    episodes =
      for season <- series.seasons,
          episode <- season.episodes,
          into: %{},
          do: {{season.season_number, episode.episode_number}, episode}

    {count, paths, _written} =
      Enum.reduce(files, {0, [], MapSet.new()}, &adopt_episode_file(&1, episodes, &2))

    {count, paths}
  end

  defp adopt_episode_files(_files, _missing_series), do: {0, []}

  defp adopt_episode_file(file, episodes, {count, paths, written}) do
    keys = Enum.map(file.episode_numbers, &{file.season_number, &1})
    mapped = Enum.map(keys, &Map.get(episodes, &1))

    # `written` re-guards within this run what demote_duplicate_claims/1 already holds at
    # scan time: a key another file just claimed can never be silently overwritten.
    if Enum.any?(keys, &MapSet.member?(written, &1)) or
         not adoptable_episode_file?(mapped, file.path) do
      {count, paths, written}
    else
      updates = Enum.reduce(mapped, 0, &write_episode_path(&1, file.path, &2))

      {count + updates, maybe_add_path(paths, file.path, updates),
       MapSet.union(written, MapSet.new(keys))}
    end
  end

  defp adoptable_episode_file?(episodes, path) do
    Enum.all?(episodes, fn
      %Episode{file_path: nil} -> true
      %Episode{file_path: ^path} -> true
      _ -> false
    end)
  end

  defp write_episode_path(%Episode{file_path: nil} = episode, path, count) do
    case Catalog.transition_episode(episode, %{file_path: path}) do
      {:ok, _episode} -> count + 1
      {:error, _reason} -> count
    end
  end

  defp write_episode_path(_episode, _path, count), do: count

  defp maybe_add_path(paths, path, updates) when updates > 0, do: [path | paths]
  defp maybe_add_path(paths, _path, _updates), do: paths

  defp chosen_tmdb_id(%{chosen_tmdb_id: id}), do: parse_integer(id)
  defp chosen_tmdb_id(%{match: %{tmdb_id: id}}), do: parse_integer(id)
  defp chosen_tmdb_id(_candidate), do: nil

  defp managed_paths do
    movie_paths = Catalog.list_movies() |> Enum.map(& &1.file_path)
    episode_paths = Catalog.list_episodes_with_file() |> Enum.map(& &1.file_path)

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
