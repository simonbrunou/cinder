defmodule Cinder.Library.Adoption do
  @moduledoc """
  Discovers unmanaged files under the configured library roots and adopts
  operator-confirmed matches into the catalog.

  `scan/0` only reads the filesystem, TMDB, and catalog. All persisted movie and
  episode paths are written through the Catalog transition choke-points.
  """

  alias Cinder.Acquisition.Parser
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Profile, Series}
  alias Cinder.Library
  alias Cinder.Locales
  alias Cinder.Settings

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

  def preview_migration(source, opts \\ []), do: Library.MigrationAdoption.preview(source, opts)

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

  @doc """
  Filters filesystem-scan candidates down to the operator-confirmed ones.

  `params` is the adoption form's payload: `"selected"` lists auto-matched
  candidate ids to adopt, `"chosen"` maps ambiguous candidate ids to a picked
  TMDB id, and `"parts"` maps candidate ids to per-file part assignments.
  Auto-matched candidates are kept only when selected (with any part choices
  applied to their files); ambiguous candidates only when a TMDB result was
  chosen (recorded as `:chosen_tmdb_id`). Everything else is dropped.
  """
  def confirmed_candidates(candidates, params) do
    selected = params |> Map.get("selected", []) |> List.wrap() |> parse_ids()
    chosen = Map.get(params, "chosen", %{})
    parts = Map.get(params, "parts", %{})

    Enum.flat_map(candidates, &confirm_candidate(&1, selected, chosen, parts))
  end

  @doc """
  Builds migration adoption commands entirely from server-held
  selection/decision state (never a client-posted list), so a windowed-away
  row that never rendered a checkbox is still honoured.

  Selected ready candidates become `%{key: key, candidate: candidate}`;
  needs-decision candidates with a `"fold"`/`"part"` choice become
  `%{key: key, choice: choice, candidate: candidate}`. Undecided candidates
  produce no command.
  """
  def confirmed_migration_commands(buckets, selected_ready, decisions) do
    ready_commands =
      for candidate <- buckets.ready,
          MapSet.member?(selected_ready, candidate.id),
          do: %{key: candidate.key, candidate: candidate}

    decision_commands =
      for candidate <- buckets.needs_decision,
          choice = Map.get(decisions, candidate.id),
          choice in ["fold", "part", "preferred", "all_formats"],
          do: %{key: candidate.key, choice: choice, candidate: candidate}

    ready_commands ++ decision_commands
  end

  @doc "Counts needs-decision candidates that still have no fold/part choice."
  def undecided_count(needs_decision, decisions),
    do: Enum.count(needs_decision, &(not Map.has_key?(decisions, &1.id)))

  defp confirm_candidate(%{status: :auto_matched, id: id} = candidate, selected, _chosen, parts) do
    if MapSet.member?(selected, id) do
      [put_part_choices(candidate, candidate_choices(parts, id))]
    else
      []
    end
  end

  defp confirm_candidate(%{status: :ambiguous, id: id} = candidate, _selected, chosen, _parts)
       when is_map(chosen) do
    case parse_integer(Map.get(chosen, to_string(id))) do
      nil -> []
      tmdb_id -> [Map.put(candidate, :chosen_tmdb_id, tmdb_id)]
    end
  end

  defp confirm_candidate(_candidate, _selected, _chosen, _parts), do: []

  defp candidate_choices(parts, candidate_id) when is_map(parts) do
    case Map.get(parts, to_string(candidate_id), %{}) do
      choices when is_map(choices) -> choices
      _ -> %{}
    end
  end

  defp candidate_choices(_parts, _candidate_id), do: %{}

  defp put_part_choices(candidate, choices) do
    files =
      Enum.map(Map.get(candidate, :files, []), fn file ->
        target = parse_integer(Map.get(choices, to_string(Map.get(file, :id))))

        case Enum.find(Map.get(file, :part_candidates, []), &(&1.episode_number == target)) do
          nil ->
            file

          part_of ->
            %{file | status: :part, part_of: Map.take(part_of, [:season_number, :episode_number])}
        end
      end)

    Map.put(candidate, :files, files)
  end

  defp parse_ids(values) do
    values
    |> Enum.map(&parse_integer/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp scan_movies(managed) do
    scan_roots(:movies, :movie, managed, &movie_candidates/3)
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
    scan_roots(:tv, :series, managed, fn files, root, managed ->
      files
      |> Enum.filter(fn {path, _size} ->
        Library.video_file?(path) and not managed?(managed, path)
      end)
      |> Enum.group_by(&series_group(&1, root))
      |> Enum.map(&series_candidate/1)
    end)
  end

  # Scan the most-specific roots first so a nested Anime destination is grouped relative to its
  # own root, then discard paths already seen by a broader root.
  defp scan_roots(kind, candidate_kind, managed, build_candidates) do
    Settings.library_destinations()
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.sort_by(&byte_size(&1.path), :desc)
    |> Enum.reduce({[], MapSet.new()}, fn destination, {candidates, seen} ->
      %{path: root} = destination

      case filesystem().find_files(root) do
        {:ok, files} ->
          fresh = Enum.reject(files, &MapSet.member?(seen, normalize_path(elem(&1, 0))))
          seen = Enum.reduce(files, seen, &MapSet.put(&2, normalize_path(elem(&1, 0))))
          {fresh, identities} = snapshot_files(fresh)

          discovered =
            fresh
            |> build_candidates.(root, managed)
            |> Enum.map(&put_destination(&1, destination))
            |> Enum.map(&put_file_identities(&1, identities))

          {candidates ++ discovered, seen}

        {:error, reason} ->
          {candidates ++ [scan_error(candidate_kind, root, reason)], seen}
      end
    end)
    |> elem(0)
  end

  defp snapshot_files(files) do
    Enum.reduce(files, {[], %{}}, fn {path, walked_size}, {verified, identities} ->
      case filesystem().lstat(path) do
        {:ok, %File.Stat{type: :regular, size: ^walked_size} = stat} ->
          identity = file_identity(stat)
          {[{path, walked_size} | verified], Map.put(identities, normalize_path(path), identity)}

        _changed_or_unsafe ->
          {verified, identities}
      end
    end)
    |> then(fn {verified, identities} -> {Enum.reverse(verified), identities} end)
  end

  defp put_file_identities(candidate, identities) do
    candidate_identities =
      candidate
      |> candidate_paths()
      |> Map.new(fn path ->
        {normalize_path(path), Map.fetch!(identities, normalize_path(path))}
      end)

    Map.put(candidate, :file_identities, candidate_identities)
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

  defp put_destination(candidate, destination) do
    Map.merge(candidate, %{
      library_root: destination.path,
      media_profile: adoption_profile(destination),
      profile_id: Map.get(destination, :profile_id)
    })
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
         {:ok, profile, media_profile} <- validated_destination(candidate, :movies),
         {:ok, details} <- Catalog.get_movie(tmdb_id),
         {:ok, movie, created} <-
           Catalog.adopt_movie_at_available(
             movie_attrs(details, media_profile, profile),
             path,
             Map.get(candidate, :profile_id),
             adoption_profile(candidate),
             &revalidate_candidate(candidate, :movies, &1)
           ),
         :ok <- announce_movie_creation(movie, created == :created) do
      {:adopted, [path]}
    else
      _ -> :skipped
    end
  end

  defp movie_attrs(details, media_profile, profile) do
    details
    |> Map.take([
      :tmdb_id,
      :imdb_id,
      :title,
      :year,
      :poster_path,
      :original_language,
      :localizations
    ])
    |> Map.put(:media_profile, media_profile)
    |> Map.put(:profile_id, profile && profile.id)
  end

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
         tmdb_id when is_integer(tmdb_id) <- chosen_tmdb_id(candidate),
         {:ok, profile, media_profile} <- validated_destination(candidate, :tv) do
      do_adopt_series(files, tmdb_id, media_profile, profile, candidate)
    else
      _ -> :skipped
    end
  end

  defp do_adopt_series(files, tmdb_id, _media_profile, profile, candidate) do
    case Catalog.add_series(tmdb_id,
           monitor_strategy: :none,
           media_profile: :auto,
           profile_id: nil,
           before_write: fn -> revalidate_candidate(candidate, :tv, profile) end
         ) do
      {:ok, series} ->
        finish_series_adoption(files, series, candidate)

      {:error, _reason} ->
        :skipped
    end
  end

  defp finish_series_adoption(files, series, candidate) do
    case adopt_episode_files(files, Catalog.get_series_with_tree(series.id), candidate) do
      {:ok, []} ->
        :skipped

      {:ok, paths} ->
        {:adopted, paths}

      {:error, failures} ->
        {:failed, failures}
    end
  end

  defp adopt_episode_files(files, %Series{} = series, candidate) do
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

    case Catalog.adopt_series_files(
           series,
           actions,
           Map.get(candidate, :profile_id),
           adoption_profile(candidate),
           &revalidate_candidate(candidate, :tv, &1)
         ) do
      {:ok, applied} -> {:ok, applied |> Enum.map(& &1.path) |> Enum.uniq()}
      {:error, failures} -> {:error, failures}
    end
  end

  defp adopt_episode_files(_files, _missing_series, _candidate), do: {:ok, []}

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

  defp validated_destination(candidate, kind) do
    with {:ok, destination} <- current_destination(candidate, kind),
         true <- same_scanned_destination?(candidate, destination) do
      validated_destination_profile(destination, kind)
    else
      _changed_or_outside -> {:error, :stale_destination}
    end
  end

  defp revalidate_candidate(candidate, kind, profile) do
    with {:ok, destination} <- current_destination(candidate, kind),
         true <- same_scanned_destination?(candidate, destination),
         true <- same_current_profile?(destination, profile, kind),
         :ok <- validate_candidate_files(candidate, destination.path) do
      :ok
    else
      {:error, :inventory_changed} = error -> error
      _changed_or_outside -> {:error, :stale_destination}
    end
  end

  defp same_scanned_destination?(candidate, destination) do
    is_binary(Map.get(candidate, :library_root)) and
      Path.expand(candidate.library_root) == Path.expand(destination.path) and
      Map.get(candidate, :profile_id) == Map.get(destination, :profile_id) and
      adoption_profile(candidate) == adoption_profile(destination)
  end

  defp same_current_profile?(%{profile_id: nil}, nil, _kind), do: true

  defp same_current_profile?(%{profile_id: id}, %Profile{id: id, kind: kind}, kind)
       when is_integer(id),
       do: true

  defp same_current_profile?(_destination, _profile, _kind), do: false

  defp validate_candidate_files(candidate, root) do
    identities = Map.get(candidate, :file_identities, %{})

    case candidate_paths(candidate) do
      [] -> {:error, :inventory_changed}
      paths -> Enum.reduce_while(paths, :ok, &validate_candidate_path(&1, root, identities, &2))
    end
  end

  defp validate_candidate_path(path, root, identities, :ok) do
    expected = Map.get(identities, normalize_path(path))

    case validate_candidate_file(path, root, expected) do
      :ok -> {:cont, :ok}
      {:error, :inventory_changed} = error -> {:halt, error}
    end
  end

  defp validate_candidate_file(path, root, expected) when is_map(expected) do
    path_policy = Library.path_policy()

    with {:ok, expanded} <-
           path_policy.source_file(path, [root], Library.video_extensions(),
             filesystem: filesystem()
           ),
         true <- expanded == normalize_path(path),
         {:ok, %File.Stat{type: :regular} = stat} <- filesystem().lstat(expanded),
         true <- file_identity(stat) == expected do
      :ok
    else
      _changed_or_unsafe -> {:error, :inventory_changed}
    end
  end

  defp validate_candidate_file(_path, _root, _missing_identity),
    do: {:error, :inventory_changed}

  defp file_identity(stat) do
    Map.take(stat, [:size, :major_device, :inode, :mtime])
  end

  defp current_destination(candidate, kind) do
    destinations =
      Settings.library_destinations()
      |> Enum.filter(&(&1.kind == kind))
      |> Enum.sort_by(&byte_size(Path.expand(&1.path)), :desc)

    candidate
    |> candidate_paths()
    |> Enum.reduce_while(nil, fn path, found ->
      destination = Enum.find(destinations, &inside_destination?(path, &1))

      cond do
        is_nil(destination) -> {:halt, :mismatch}
        is_nil(found) -> {:cont, destination}
        same_destination?(found, destination) -> {:cont, found}
        true -> {:halt, :mismatch}
      end
    end)
    |> case do
      destination when is_map(destination) -> {:ok, destination}
      _empty_or_mismatch -> {:error, :outside_library}
    end
  end

  defp inside_destination?(path, destination) do
    root = Path.expand(destination.path)
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp same_destination?(left, right),
    do:
      Map.get(left, :profile_id) == Map.get(right, :profile_id) and
        adoption_profile(left) == adoption_profile(right) and
        Path.expand(left.path) == Path.expand(right.path)

  defp candidate_paths(%{paths: paths}) when is_list(paths) and paths != [], do: paths
  defp candidate_paths(%{path: path}) when is_binary(path), do: [path]

  defp candidate_paths(%{files: files}) when is_list(files),
    do: files |> Enum.map(&Map.get(&1, :path)) |> Enum.reject(&is_nil/1)

  defp candidate_paths(_candidate), do: []

  defp validated_destination_profile(%{profile_id: nil, profile: profile}, _kind),
    do: {:ok, nil, adoption_profile(profile)}

  defp validated_destination_profile(%{profile_id: id}, kind) when is_integer(id) do
    case Catalog.get_profile(id) do
      %Profile{kind: ^kind, handling: handling} = profile -> {:ok, profile, handling}
      _missing_or_wrong_kind -> {:error, :stale_destination}
    end
  end

  defp adoption_profile(%{profile_id: id, profile: profile}) when is_integer(id), do: profile
  defp adoption_profile(:anime), do: :anime
  defp adoption_profile(%{profile: :anime}), do: :anime

  defp adoption_profile(%{media_profile: profile}) when profile in [:auto, :standard, :anime],
    do: profile

  defp adoption_profile(_candidate_or_destination_profile), do: :auto

  defp managed_paths do
    movie_paths = Catalog.list_movies() |> Enum.flat_map(&Movie.file_paths/1)
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
