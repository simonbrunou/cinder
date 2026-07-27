defmodule Cinder.Library.MigrationAdoption do
  @moduledoc false

  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.Adoption, as: CatalogAdoption
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Library.MigrationReconciler
  alias Cinder.Repo

  @statuses [:ready, :needs_decision, :blocked, :already_managed]

  def preview(source) when source in [:radarr, :sonarr] do
    with {:ok, module} <- source_module(source),
         {:ok, snapshot} <- module.snapshot() do
      lookups = lookups(snapshot)
      reconciled = MigrationReconciler.reconcile(snapshot, lookups)
      managed = managed_state()

      candidates =
        source
        |> plan(snapshot, reconciled, lookups, managed)
        |> Kernel.++(diagnostic_candidates(snapshot, source))
        |> Enum.sort_by(& &1.key)
        |> Enum.with_index(1)
        |> Enum.map(fn {candidate, id} -> Map.put(candidate, :id, id) end)

      {:ok,
       %{
         source: source,
         candidates: candidates,
         counts: counts(candidates),
         series_counts: series_counts(candidates)
       }}
    end
  end

  def preview(_source), do: {:error, :unknown_migration_source}

  def adopt(source, commands) when source in [:radarr, :sonarr] and is_list(commands) do
    case adoption_candidates(source, commands) do
      {:ok, by_key} ->
        {selected, unavailable} = selected_candidates(commands, by_key)
        {selected, stale} = revalidate_selected(source, selected)

        %{
          adopted: 0,
          skipped: length(unavailable) + length(stale),
          failures: [],
          adopted_keys: [],
          stale_keys: stale
        }
        |> adopt_selected(source, selected)

      {:error, reason} ->
        %{
          adopted: 0,
          skipped: length(commands),
          failures: [%{reason: reason}],
          adopted_keys: [],
          stale_keys: []
        }
    end
  end

  def adopt(_source, _commands),
    do: %{adopted: 0, skipped: 0, failures: [], adopted_keys: [], stale_keys: []}

  defp adoption_candidates(source, commands) do
    case candidates_from_commands(commands) do
      {:ok, candidates} ->
        {:ok, Map.new(candidates, &{&1.key, &1})}

      :legacy ->
        case preview(source) do
          {:ok, preview} -> {:ok, Map.new(preview.candidates, &{&1.key, &1})}
          {:error, _reason} = error -> error
        end
    end
  end

  defp candidates_from_commands(commands) do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, candidates} ->
      key = command_value(command, :key)
      candidate = command_value(command, :candidate)

      if is_map(candidate) and Map.get(candidate, :key) == key,
        do: {:cont, {:ok, [candidate | candidates]}},
        else: {:halt, :legacy}
    end)
  end

  defp command_value(command, key) when is_map(command),
    do: Map.get(command, key) || Map.get(command, Atom.to_string(key))

  defp command_value(_command, _key), do: nil

  defp source_module(source) do
    case Application.fetch_env!(:cinder, :migration_sources) do
      %{^source => module} -> {:ok, module}
      _sources -> {:error, :not_configured}
    end
  end

  defp lookups(snapshot) do
    movie_keys =
      for %{tmdb_id: nil, imdb_id: imdb_id} <- snapshot.movies,
          is_binary(imdb_id) and imdb_id != "",
          do: {:imdb_id, imdb_id}

    tvdb_keys =
      for record <- snapshot.series ++ snapshot.episodes,
          is_integer(record.tvdb_id) and record.tvdb_id > 0,
          do: {:tvdb_id, record.tvdb_id}

    (movie_keys ++ tvdb_keys)
    |> Enum.uniq()
    |> Map.new(fn {source, id} = key ->
      {key, tmdb().find_by_external_id(id, source)}
    end)
  end

  defp plan(:radarr, snapshot, reconciled, _lookups, managed),
    do: plan_movies(snapshot, reconciled, managed)

  defp plan(:sonarr, snapshot, reconciled, lookups, managed),
    do: plan_episodes(snapshot, reconciled, lookups, managed)

  defp plan_movies(snapshot, reconciled, managed) do
    files = files_by_id(snapshot.files, :movie)
    resolved = Map.new(reconciled.movies, &{&1.provider_id, &1})
    unresolved = unresolved_by_id(reconciled.unresolved, :movie)

    candidates =
      Enum.map(snapshot.movies, fn movie ->
        file = Map.get(files, movie.file_id)
        identity = Map.get(resolved, movie.provider_id)
        reason = Map.get(unresolved, movie.provider_id)
        movie_candidate(movie, identity, file, reason, managed)
      end)

    referenced = MapSet.new(snapshot.movies, & &1.file_id)

    candidates ++
      for file <- Map.values(files), not MapSet.member?(referenced, file.provider_id) do
        %{
          key: "movie-file:#{file.provider_id}",
          kind: :movie,
          provider_id: file.provider_id,
          source: :radarr,
          title: Path.basename(file.path),
          path: file.path,
          size: file.size,
          status: :blocked,
          reason: :unlinked_file
        }
      end
  end

  defp movie_candidate(movie, nil, file, reason, _managed) do
    %{
      key: "movie:#{movie.provider_id}",
      kind: :movie,
      provider_id: movie.provider_id,
      source: :radarr,
      title: "Movie #{movie.provider_id}",
      path: file && file.path,
      size: file && file.size,
      status: :blocked,
      reason: reason || :identity_unresolved
    }
  end

  defp movie_candidate(movie, identity, nil, _reason, _managed) do
    %{
      key: "movie:#{movie.provider_id}",
      kind: :movie,
      provider_id: movie.provider_id,
      source: :radarr,
      tmdb_id: identity.tmdb_id,
      title: "Movie #{movie.provider_id}",
      path: nil,
      size: nil,
      status: :blocked,
      reason: :file_missing
    }
  end

  defp movie_candidate(movie, identity, file, _reason, managed) do
    case Catalog.get_movie(identity.tmdb_id) do
      {:ok, details} ->
        status_reason =
          movie_path_status(Catalog.get_movie_by_tmdb_id(identity.tmdb_id), file.path, managed)

        %{
          key: "movie:#{movie.provider_id}",
          kind: :movie,
          provider_id: movie.provider_id,
          source: :radarr,
          tmdb_id: identity.tmdb_id,
          title: details.title,
          year: details.year,
          path: file.path,
          size: file.size,
          details: details,
          status: elem(status_reason, 0),
          reason: elem(status_reason, 1)
        }

      {:error, reason} ->
        %{
          key: "movie:#{movie.provider_id}",
          kind: :movie,
          provider_id: movie.provider_id,
          source: :radarr,
          tmdb_id: identity.tmdb_id,
          title: "Movie #{movie.provider_id}",
          path: file.path,
          size: file.size,
          status: :blocked,
          reason: {:tmdb_details_failed, reason}
        }
    end
  end

  defp movie_path_status(%Movie{file_path: path}, path, _managed),
    do: {:already_managed, nil}

  defp movie_path_status(%Movie{file_path: existing}, _path, _managed)
       when is_binary(existing) and existing != "",
       do: {:blocked, :identity_conflict}

  defp movie_path_status(_movie, path, managed) do
    if Map.has_key?(managed.paths, normalize_path(path)),
      do: {:blocked, :path_conflict},
      else: {:ready, nil}
  end

  # Sonarr may return one row per episode for a shared multi-episode file. Collapse by
  # episodeFileId before any conflict analysis so one physical file always plans one action set.
  defp plan_episodes(snapshot, reconciled, lookups, managed) do
    files = files_by_id(snapshot.files, :episode)
    resolved = Map.new(reconciled.episodes, &{&1.provider_id, &1})
    resolved_by_series = Enum.group_by(reconciled.episodes, & &1.series_id)
    unresolved = unresolved_by_id(reconciled.unresolved, :episode)
    series = series_metadata(snapshot, reconciled, lookups)
    cinder_series = cinder_series_index(series)
    episode_indexes = %{resolved_by_series: resolved_by_series, cinder_series: cinder_series}

    grouped =
      snapshot.episodes
      |> Enum.group_by(fn episode ->
        if is_integer(episode.file_id),
          do: {:file, episode.file_id},
          else: {:episode, episode.provider_id}
      end)
      |> Enum.map(fn {group_key, episodes} ->
        episode_group_candidate(
          group_key,
          episodes,
          files,
          resolved,
          unresolved,
          series,
          episode_indexes,
          managed
        )
      end)

    referenced =
      snapshot.episodes
      |> Enum.map(& &1.file_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    unlinked =
      for file <- Map.values(files), not MapSet.member?(referenced, file.provider_id) do
        %{
          key: "episode-file:#{file.provider_id}",
          kind: :episode,
          provider_id: file.provider_id,
          source: :sonarr,
          title: Path.basename(file.path),
          path: file.path,
          size: file.size,
          status: :blocked,
          reason: :unlinked_file
        }
      end

    merge_n_to_one(grouped, lookups, managed, cinder_series) ++ unlinked
  end

  defp episode_group_candidate(
         group_key,
         episodes,
         files,
         resolved,
         unresolved,
         series,
         episode_indexes,
         managed
       ) do
    series_ids = episodes |> Enum.map(& &1.series_id) |> Enum.uniq()
    identities = Enum.map(episodes, &Map.get(resolved, &1.provider_id))
    reasons = episodes |> Enum.map(&Map.get(unresolved, &1.provider_id)) |> Enum.reject(&is_nil/1)

    file_id =
      case group_key do
        {:file, id} -> id
        _group -> nil
      end

    file = Map.get(files, file_id)
    series_info = if length(series_ids) == 1, do: Map.get(series, hd(series_ids))

    base = %{
      key: group_key(group_key),
      kind: :episode,
      provider_id: file_id || hd(episodes).provider_id,
      source: :sonarr,
      series_provider_id: List.first(series_ids),
      series: series_info,
      title: series_title(series_info),
      path: file && file.path,
      size: file && file.size,
      file: file,
      source_episodes: episodes,
      episodes: Enum.reject(identities, &is_nil/1),
      series_episodes: Map.get(episode_indexes.resolved_by_series, List.first(series_ids), [])
    }

    put_episode_group_status(
      base,
      series_ids,
      series_info,
      reasons,
      identities,
      file,
      episode_indexes.cinder_series,
      managed
    )
  end

  defp put_episode_group_status(
         base,
         series_ids,
         series_info,
         reasons,
         identities,
         file,
         cinder_series,
         managed
       ) do
    {status, reason} =
      cond do
        length(series_ids) != 1 -> {:blocked, :mixed_series_file}
        is_nil(series_info) -> {:blocked, :series_unresolved}
        reasons != [] -> {:blocked, List.first(reasons)}
        Enum.any?(identities, &is_nil/1) -> {:blocked, :identity_unresolved}
        is_nil(file) -> {:blocked, :file_missing}
        true -> episode_file_status(base, managed, cinder_series)
      end

    Map.merge(base, %{status: status, reason: reason})
  end

  defp group_key({:file, id}), do: "episode-file:#{id}"
  defp group_key({:episode, id}), do: "episode:#{id}"

  defp series_metadata(snapshot, reconciled, lookups) do
    resolved = Map.new(reconciled.series, &{&1.provider_id, &1})

    Map.new(snapshot.series, fn source_series ->
      identity = Map.get(resolved, source_series.provider_id)
      match = unique_lookup(lookups, {:tvdb_id, source_series.tvdb_id}, :tv)

      info =
        if identity do
          %{
            provider_id: source_series.provider_id,
            tvdb_id: source_series.tvdb_id,
            tmdb_id: identity.tmdb_id,
            title: match && Map.get(match, :title),
            year: match && Map.get(match, :year)
          }
        end

      {source_series.provider_id, info}
    end)
  end

  defp series_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp series_title(%{tvdb_id: tvdb_id}), do: "TVDB #{tvdb_id}"
  defp series_title(_series), do: "Unknown series"

  defp diagnostic_candidates(snapshot, source) do
    snapshot
    |> Map.get(:diagnostics, [])
    |> Enum.with_index(1)
    |> Enum.map(fn {diagnostic, index} ->
      provider_id = Map.get(diagnostic, :provider_id)

      %{
        key: "series-snapshot:#{provider_id || index}",
        kind: :series,
        provider_id: provider_id,
        series_provider_id: provider_id,
        source: source,
        title: Map.get(diagnostic, :title, "Unknown series"),
        path: nil,
        size: nil,
        status: :blocked,
        reason: Map.get(diagnostic, :reason, :series_snapshot_failed)
      }
    end)
  end

  defp cinder_series_index(series) do
    existing = Map.new(Catalog.list_series(), &{&1.tmdb_id, &1})

    Map.new(series, fn
      {provider_id, %{tmdb_id: tmdb_id}} ->
        {provider_id, load_cinder_series(Map.get(existing, tmdb_id))}

      {provider_id, _info} ->
        {provider_id, nil}
    end)
  end

  defp load_cinder_series(%Series{} = series) do
    tree = Catalog.get_series_with_tree(series.id)

    %{
      series: tree,
      targets:
        tree
        |> episode_tree()
        |> Map.new(fn {tmdb_id, episode, season} -> {tmdb_id, {episode, season}} end)
    }
  end

  defp load_cinder_series(nil), do: nil

  defp episode_file_status(candidate, managed, cinder_series) do
    with %{targets: targets_by_tmdb} <- Map.get(cinder_series, candidate.series_provider_id),
         {:ok, targets} <- episode_targets(targets_by_tmdb, candidate.episodes) do
      path = candidate.file.path

      cond do
        Enum.all?(targets, &(&1.file_path == path)) ->
          {:already_managed, nil}

        Enum.any?(targets, &(is_binary(&1.file_path) and &1.file_path != "")) ->
          {:blocked, :identity_conflict}

        path_owned_elsewhere?(managed, path, targets) ->
          {:blocked, :path_conflict}

        true ->
          {:ready, nil}
      end
    else
      nil ->
        if Map.has_key?(managed.paths, normalize_path(candidate.file.path)),
          do: {:blocked, :path_conflict},
          else: {:ready, nil}

      {:error, reason} ->
        {:blocked, reason}
    end
  end

  defp episode_targets(targets_by_tmdb, identities) do
    targets =
      identities
      |> Enum.map(&Map.get(targets_by_tmdb, &1.tmdb_episode_id))
      |> Enum.map(fn
        {%Episode{} = episode, _season} -> episode
        nil -> nil
      end)

    if Enum.any?(targets, &is_nil/1),
      do: {:error, :catalog_episode_missing},
      else: {:ok, Enum.uniq_by(targets, & &1.id)}
  end

  defp merge_n_to_one(candidates, lookups, managed, cinder_series) do
    actionable = Enum.filter(candidates, &(&1.status in [:ready, :already_managed]))

    collisions =
      actionable
      |> Enum.flat_map(fn candidate ->
        Enum.map(candidate.episodes, &{&1.tmdb_episode_id, candidate.key})
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_tmdb_id, keys} -> keys |> Enum.uniq() |> length() > 1 end)
      |> Map.new(fn {tmdb_id, keys} -> {tmdb_id, Enum.uniq(keys)} end)

    involved = collisions |> Map.values() |> List.flatten() |> MapSet.new()
    by_key = Map.new(candidates, &{&1.key, &1})

    merged =
      Enum.map(collisions, fn {tmdb_id, keys} ->
        members = Enum.map(keys, &Map.fetch!(by_key, &1))
        n_to_one_candidate(tmdb_id, members, lookups, managed, cinder_series)
      end)

    untouched = Enum.reject(candidates, &MapSet.member?(involved, &1.key))

    overlap_keys =
      collisions
      |> Map.values()
      |> List.flatten()
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> MapSet.new(fn {key, _count} -> key end)

    if MapSet.size(overlap_keys) == 0 do
      untouched ++ merged
    else
      untouched ++
        Enum.map(
          Enum.filter(candidates, &MapSet.member?(involved, &1.key)),
          &%{&1 | status: :blocked, reason: :complex_n_to_one}
        )
    end
  end

  defp n_to_one_candidate(tmdb_id, members, lookups, managed, cinder_series) do
    all_only_target? =
      Enum.all?(members, fn member ->
        Enum.all?(member.episodes, &(&1.tmdb_episode_id == tmdb_id))
      end)

    primary_members =
      Enum.filter(members, fn member ->
        Enum.any?(member.episodes, &canonical_episode?(&1, lookups))
      end)

    base = %{
      key: "episode-n-to-one:#{tmdb_id}:#{Enum.map_join(members, "-", & &1.provider_id)}",
      kind: :episode,
      provider_id: hd(members).provider_id,
      source: :sonarr,
      series_provider_id: hd(members).series_provider_id,
      series: hd(members).series,
      title: hd(members).title,
      tmdb_episode_id: tmdb_id,
      members: members,
      episodes: Enum.flat_map(members, & &1.episodes),
      source_episodes: Enum.flat_map(members, & &1.source_episodes),
      series_episodes: hd(members).series_episodes
    }

    cond do
      not all_only_target? ->
        Map.merge(base, %{status: :blocked, reason: :complex_n_to_one})

      length(primary_members) != 1 ->
        Map.merge(base, %{status: :blocked, reason: :authoritative_primary_unresolved})

      true ->
        primary = hd(primary_members)
        extras = Enum.reject(members, &(&1.key == primary.key))
        {status, reason} = n_to_one_status(primary, extras, managed, cinder_series)

        Map.merge(base, %{
          status: status,
          reason: reason,
          primary_file: primary.file,
          extra_files: Enum.map(extras, & &1.file)
        })
    end
  end

  defp canonical_episode?(episode, lookups) do
    case unique_lookup(lookups, {:tvdb_id, episode.tvdb_id}, :episode) do
      %{
        season_number: season_number,
        episode_number: episode_number
      } ->
        episode.season_number == season_number and episode.episode_number == episode_number

      _match ->
        false
    end
  end

  defp n_to_one_status(primary, extras, managed, cinder_series) do
    case Map.get(cinder_series, primary.series_provider_id) do
      %{targets: targets_by_tmdb} ->
        case episode_targets(targets_by_tmdb, primary.episodes) do
          {:ok, [target]} -> existing_n_to_one_status(primary, extras, target, managed)
          {:error, reason} -> {:blocked, reason}
        end

      nil ->
        paths = [primary.file.path | Enum.map(extras, & &1.file.path)]

        if Enum.any?(paths, &Map.has_key?(managed.paths, normalize_path(&1))),
          do: {:blocked, :path_conflict},
          else: {:needs_decision, nil}
    end
  end

  defp existing_n_to_one_status(primary, extras, target, managed) do
    paths = [primary.file.path | Enum.map(extras, & &1.file.path)]

    cond do
      Enum.all?(paths, &(&1 in Episode.file_paths(target))) ->
        {:already_managed, nil}

      target.file_path not in [nil, "", primary.file.path] ->
        {:blocked, :identity_conflict}

      Enum.any?(paths, &path_owned_elsewhere?(managed, &1, [target])) ->
        {:blocked, :path_conflict}

      true ->
        {:needs_decision, nil}
    end
  end

  defp path_owned_elsewhere?(managed, path, targets) do
    case Map.get(managed.paths, normalize_path(path)) do
      {:episode, episode_id} -> Enum.all?(targets, &(&1.id != episode_id))
      nil -> false
      _other_owner -> true
    end
  end

  defp revalidate_selected(source, selected) do
    {present, missing} = Enum.split_with(selected, &candidate_files_exist?/1)

    case Repo.transaction(fn -> revalidate_catalog(source, present) end) do
      {:ok, {valid, stale}} ->
        {valid, candidate_keys(missing ++ stale)}

      {:error, _reason} ->
        {[], candidate_keys(selected)}
    end
  end

  defp candidate_files_exist?({candidate, _choice}) do
    candidate
    |> candidate_paths()
    |> Enum.all?(fn path ->
      is_binary(path) and path != "" and match?({:ok, %File.Stat{}}, filesystem().lstat(path))
    end)
  end

  defp candidate_paths(%{primary_file: %{path: path}} = candidate),
    do: [path | Enum.map(Map.get(candidate, :extra_files, []), & &1.path)]

  defp candidate_paths(%{file: %{path: path}}), do: [path]
  defp candidate_paths(%{path: path}), do: [path]
  defp candidate_paths(_candidate), do: []

  defp candidate_keys(items), do: Enum.map(items, fn {candidate, _choice} -> candidate.key end)

  defp revalidate_catalog(:radarr, selected) do
    managed = managed_state(Enum.flat_map(selected, &candidate_paths(elem(&1, 0))))

    Enum.split_with(selected, fn {candidate, _choice} ->
      Map.get(candidate.details, :tmdb_id) == candidate.tmdb_id and
        movie_path_status(
          Catalog.get_movie_by_tmdb_id(candidate.tmdb_id),
          candidate.path,
          managed
        ) == {:ready, nil}
    end)
  end

  defp revalidate_catalog(:sonarr, selected) do
    managed = managed_state(Enum.flat_map(selected, &candidate_paths(elem(&1, 0))))
    cinder_series = targeted_cinder_series_index(selected)

    Enum.split_with(selected, fn {candidate, _choice} ->
      episode_candidate_current?(candidate, managed, cinder_series)
    end)
  end

  defp targeted_cinder_series_index(selected) do
    selected
    |> Enum.map(fn {candidate, _choice} ->
      {candidate.series_provider_id, candidate.series}
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Map.new(fn
      {provider_id, %{tmdb_id: tmdb_id}} ->
        {provider_id, load_cinder_series(Catalog.get_series_by_tmdb_id(tmdb_id))}

      {provider_id, _series} ->
        {provider_id, nil}
    end)
  end

  defp episode_candidate_current?(%{status: :ready} = candidate, managed, cinder_series),
    do: episode_file_status(candidate, managed, cinder_series) == {:ready, nil}

  defp episode_candidate_current?(
         %{status: :needs_decision} = candidate,
         managed,
         cinder_series
       ) do
    primary =
      Enum.find(candidate.members, fn member ->
        member.file.provider_id == candidate.primary_file.provider_id
      end)

    if primary do
      extras = Enum.reject(candidate.members, &(&1.key == primary.key))
      n_to_one_status(primary, extras, managed, cinder_series) == {:needs_decision, nil}
    else
      false
    end
  end

  defp episode_candidate_current?(_candidate, _managed, _cinder_series), do: false

  defp selected_candidates(commands, by_key) do
    Enum.reduce(commands, {[], []}, fn command, {selected, unavailable} ->
      key = command_value(command, :key)
      choice = command_value(command, :choice)

      case Map.get(by_key, key) do
        %{status: :ready} = candidate ->
          {[{candidate, nil} | selected], unavailable}

        %{status: :needs_decision} = candidate when choice in [:fold, "fold", :part, "part"] ->
          {[{candidate, normalize_choice(choice)} | selected], unavailable}

        _unavailable ->
          {selected, [key | unavailable]}
      end
    end)
    |> then(fn {selected, unavailable} ->
      {Enum.reverse(selected), Enum.reverse(unavailable)}
    end)
  end

  defp normalize_choice(choice) when choice in [:fold, "fold"], do: :fold
  defp normalize_choice(_choice), do: :part

  defp adopt_selected(summary, :radarr, selected) do
    Enum.reduce(selected, summary, fn {candidate, _choice}, acc ->
      adopt_movie_candidate(acc, candidate)
    end)
  end

  defp adopt_selected(summary, :sonarr, selected) do
    selected
    |> Enum.group_by(fn {candidate, _choice} -> candidate.series_provider_id end)
    |> Enum.reduce(summary, fn {_series_provider_id, items}, acc ->
      adopt_series_items(acc, items)
    end)
  end

  defp adopt_movie_candidate(summary, candidate) do
    case Catalog.find_or_create_at_available(movie_attrs(candidate.details), candidate.path) do
      {:ok, movie, marker} ->
        announce_movie(movie, marker)

        summary
        |> Map.update!(:adopted, &(&1 + 1))
        |> add_adopted_keys([candidate.key])

      {:error, reason} ->
        add_failure(summary, %{path: candidate.path, reason: reason})
    end
  end

  defp announce_movie(movie, :created), do: Catalog.broadcast_movie_created(movie)
  defp announce_movie(_movie, :existing), do: :ok

  defp adopt_series_items(summary, [{first, _choice} | _rest] = items) do
    existing? = match?(%Series{}, Catalog.get_series_by_tmdb_id(first.series.tmdb_id))

    case Catalog.add_series(first.series.tmdb_id, monitor_strategy: :none) do
      {:ok, series} ->
        persist_series_items(summary, items, series, existing?)

      {:error, reason} ->
        Enum.reduce(items, summary, fn {candidate, _choice}, acc ->
          add_failure(acc, %{path: candidate_path(candidate), reason: reason})
        end)
    end
  end

  defp persist_series_items(summary, items, series, existing?) do
    tree = Catalog.get_series_with_tree(series.id)
    episode_tree = episode_tree(tree)

    episode_ids =
      Map.new(episode_tree, fn {tmdb_id, episode, _season} -> {tmdb_id, episode.id} end)

    episode_targets =
      Map.new(episode_tree, fn {tmdb_id, episode, season} -> {tmdb_id, {episode, season}} end)

    coordinate_episodes =
      items
      |> Enum.flat_map(fn {candidate, _choice} -> candidate.series_episodes end)
      |> Enum.uniq_by(& &1.provider_id)

    with {:ok, actions} <- series_actions(items, episode_targets),
         {:ok, batches} <-
           MigrationReconciler.coordinate_batches(
             %{episodes: coordinate_episodes},
             episode_ids
           ),
         {:ok, _applied} <-
           CatalogAdoption.adopt_episode_files(
             actions,
             Enum.map(batches, &Map.put(&1, :series, series))
           ) do
      if not existing?, do: Catalog.broadcast_series(series.id)

      summary
      |> Map.update!(:adopted, &(&1 + length(items)))
      |> add_adopted_keys(Enum.map(items, fn {candidate, _choice} -> candidate.key end))
    else
      {:error, failures} when is_list(failures) ->
        %{summary | failures: summary.failures ++ failures}

      {:error, reason} ->
        Enum.reduce(items, summary, fn {candidate, _choice}, acc ->
          add_failure(acc, %{path: candidate_path(candidate), reason: reason})
        end)
    end
  end

  defp series_actions(items, targets) do
    Enum.reduce_while(items, {:ok, []}, fn
      {%{status: :ready} = candidate, _choice}, {:ok, actions} ->
        case primary_actions(candidate.file, candidate.episodes, targets) do
          {:ok, planned} -> {:cont, {:ok, Enum.reverse(planned, actions)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {%{status: :needs_decision} = candidate, choice}, {:ok, actions} ->
        case n_to_one_actions(candidate, choice, targets) do
          {:ok, planned} -> {:cont, {:ok, Enum.reverse(planned, actions)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, actions} -> {:ok, Enum.reverse(actions)}
      error -> error
    end
  end

  defp primary_actions(file, identities, targets) do
    identities
    |> Enum.uniq_by(& &1.tmdb_episode_id)
    |> Enum.reduce_while({:ok, []}, fn identity, {:ok, actions} ->
      case Map.get(targets, identity.tmdb_episode_id) do
        {%Episode{} = episode, season_number} ->
          action = episode_action(episode, season_number, file.path, :primary)
          {:cont, {:ok, [action | actions]}}

        nil ->
          {:halt, {:error, {:cinder_episode_not_found, identity.tmdb_episode_id}}}
      end
    end)
  end

  defp n_to_one_actions(candidate, choice, targets) do
    case Map.get(targets, candidate.tmdb_episode_id) do
      {%Episode{} = episode, season_number} ->
        primary = episode_action(episode, season_number, candidate.primary_file.path, :primary)

        parts =
          if choice == :part do
            Enum.map(
              candidate.extra_files,
              &episode_action(episode, season_number, &1.path, :part)
            )
          else
            []
          end

        {:ok, [primary | parts]}

      nil ->
        {:error, {:cinder_episode_not_found, candidate.tmdb_episode_id}}
    end
  end

  defp episode_action(episode, season_number, path, type) do
    %{
      episode: episode,
      episode_code: Episode.code(season_number, episode.episode_number),
      path: path,
      type: type
    }
  end

  defp episode_tree(%Series{} = series) do
    for season <- series.seasons,
        episode <- season.episodes,
        not is_nil(episode.tmdb_episode_id),
        do: {episode.tmdb_episode_id, episode, season.season_number}
  end

  defp movie_attrs(details) do
    Map.take(details, [
      :tmdb_id,
      :imdb_id,
      :title,
      :year,
      :poster_path,
      :original_language,
      :localizations
    ])
  end

  defp add_failure(summary, failure),
    do: Map.update!(summary, :failures, &(&1 ++ [failure]))

  defp add_adopted_keys(summary, keys),
    do: Map.update!(summary, :adopted_keys, &(&1 ++ keys))

  defp candidate_path(%{path: path}), do: path
  defp candidate_path(%{primary_file: %{path: path}}), do: path
  defp candidate_path(_candidate), do: nil

  defp counts(candidates) do
    Map.new(@statuses, fn status ->
      {status, Enum.count(candidates, &(&1.status == status))}
    end)
  end

  defp series_counts(candidates) do
    candidates
    |> Enum.filter(&is_integer(Map.get(&1, :series_provider_id)))
    |> Enum.group_by(& &1.series_provider_id)
    |> Enum.map(fn {provider_id, grouped} ->
      %{
        provider_id: provider_id,
        title: grouped |> hd() |> Map.get(:title),
        counts: counts(grouped)
      }
    end)
    |> Enum.sort_by(&{&1.title, &1.provider_id})
  end

  defp files_by_id(files, kind) do
    for %{kind: ^kind} = file <- files, into: %{}, do: {file.provider_id, file}
  end

  defp unresolved_by_id(unresolved, kind) do
    for %{kind: ^kind} = item <- unresolved, into: %{}, do: {item.provider_id, item.reason}
  end

  defp unique_lookup(lookups, key, type) do
    case Map.get(lookups, key) do
      {:ok, results} when is_list(results) ->
        case Enum.filter(results, &(&1.type == type)) do
          [match] -> match
          _results -> nil
        end

      _result ->
        nil
    end
  end

  defp managed_state do
    movies =
      for %Movie{file_path: path, id: id} <- Catalog.list_movies(),
          is_binary(path) and path != "",
          do: {normalize_path(path), {:movie, id}}

    episodes =
      for episode <- Catalog.list_episodes_with_file(),
          path <- Episode.file_paths(episode),
          do: {normalize_path(path), {:episode, episode.id}}

    %{paths: Map.new(movies ++ episodes)}
  end

  defp managed_state(paths) do
    query_paths =
      paths
      |> Enum.flat_map(&[&1, normalize_path(&1)])
      |> Enum.uniq()

    normalized = MapSet.new(query_paths, &normalize_path/1)

    movies =
      Repo.all(from movie in Movie, where: movie.file_path in ^query_paths)
      |> Enum.flat_map(fn movie ->
        for path <- [movie.file_path],
            MapSet.member?(normalized, normalize_path(path)),
            do: {normalize_path(path), {:movie, movie.id}}
      end)

    encoded_paths = Jason.encode!(query_paths)

    episodes =
      Repo.all(
        from episode in Episode,
          where:
            episode.file_path in ^query_paths or
              fragment(
                "EXISTS (SELECT 1 FROM json_each(?) owned JOIN json_each(?) wanted ON owned.value = wanted.value)",
                episode.part_file_paths,
                ^encoded_paths
              )
      )
      |> Enum.flat_map(fn episode ->
        for path <- Episode.file_paths(episode),
            MapSet.member?(normalized, normalize_path(path)),
            do: {normalize_path(path), {:episode, episode.id}}
      end)

    %{paths: Map.new(movies ++ episodes)}
  end

  defp normalize_path(path), do: Path.expand(path)
  defp filesystem, do: Application.fetch_env!(:cinder, :filesystem)
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)
end
