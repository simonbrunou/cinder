defmodule Cinder.Acquisition.Anime do
  @moduledoc "Bounded anime-aware query planning and release aggregation."

  alias Cinder.Acquisition.{AnimeParser, AnimePreferences, Language, Release, Scorer}
  alias Cinder.Catalog.{AnimeResolver, Episode, TitleAlias}
  alias Cinder.Download.Intent

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

    # No IMDb id (issue #195): the free-text queries carry the search alone, and every result then
    # faces the title guard `:id_scoped` results are exempt from.
    id_queries =
      if imdb_id, do: [{:id_scoped, fn -> indexer.search(imdb_id) end}], else: []

    run_queries(id_queries ++ free_text_queries, context)
  end

  def search_episodes(_indexer, _context, [], _opts), do: {:ok, [], false}

  def search_episodes(indexer, context, wanted_ids, _opts) do
    context
    |> episode_queries(indexer, wanted_ids)
    |> Enum.take(@max_queries)
    |> run_queries(context)
  end

  def best_episodes(indexer, context, wanted_ids, opts \\ []) do
    case search_episodes(indexer, context, wanted_ids, opts) do
      {:ok, releases, failed?} ->
        result = select_episodes(releases, context, wanted_ids, opts)
        required_ids = Keyword.get(opts, :required_episode_ids, wanted_ids)

        if failed? and not complete_result?(result, required_ids),
          do: {:error, :incomplete_search},
          else: result

      {:error, _reason} = error ->
        error
    end
  end

  def select_episodes(releases, context, wanted_ids, opts \\ []) do
    candidates =
      releases
      |> resolved_candidates(context, wanted_ids, opts)
      |> filter_policy(opts)
      |> filter_candidates(opts)

    hard_valid =
      Enum.filter(candidates, fn candidate ->
        match?({:ok, _selection}, Scorer.select_for_ids([candidate], wanted_ids, opts))
      end)

    case preferred_groups(opts) do
      [] -> select_immediately(hard_valid, context, wanted_ids, opts)
      groups -> select_with_waiting(hard_valid, context, wanted_ids, groups, opts)
    end
  end

  def select_movie(releases, opts \\ []) do
    hard_valid =
      releases
      |> Enum.map(&fill_movie_group/1)
      |> filter_policy(opts)
      |> Enum.filter(&(Scorer.verdict(&1, opts) == :ok))

    result =
      case preferred_groups(opts) do
        [] -> Scorer.select(hard_valid, opts)
        groups -> select_timed_movie(hard_valid, groups, opts)
      end

    cond do
      result == :no_match and Keyword.get(opts, :incomplete_search?, false) ->
        {:error, :incomplete_search}

      match?({:ok, %Release{}}, result) ->
        mark_policy(result, opts)

      true ->
        result
    end
  end

  @doc "Parses Anime movie traits for manual annotation without filtering operator choices."
  def manual_movie_candidates(releases, _opts), do: Enum.map(releases, &fill_movie_group/1)

  @doc "Resolves manual Anime candidates and freezes exact stable-ID mappings when safe."
  def manual_episode_candidates(releases, context, wanted_ids, _opts) do
    Enum.map(releases, fn release ->
      parsed = parse_anime_release(release, context)

      case resolve_release(parsed, context, wanted_ids) do
        [resolved] -> freeze_manual_candidate(parsed, resolved, context)
        [] -> parsed
      end
    end)
  end

  defp freeze_manual_candidate(parsed, resolved, context) do
    snapshot = build_mapping_snapshot(resolved, resolved.resolved_episode_ids, context)

    if is_map(snapshot) and
         Intent.valid_mapping_snapshot?(snapshot, :episode, resolved.resolved_episode_ids),
       do: %{resolved | mapping_snapshot: snapshot},
       else: parsed
  end

  def build_mapping_snapshot(%Release{} = release, reserved_ids, context) do
    case parser_snapshot_titles(context, parser_alias_titles(context)) do
      [] -> nil
      parser_titles -> do_build_mapping_snapshot(release, reserved_ids, context, parser_titles)
    end
  end

  defp do_build_mapping_snapshot(
         release,
         reserved_ids,
         context,
         [parser_title | parser_aliases]
       ) do
    reserved = MapSet.new(reserved_ids)

    mappings =
      context.mappings
      |> Enum.filter(fn mapping ->
        not MapSet.disjoint?(MapSet.new(mapping.episode_ids), reserved) and
          snapshot_mapping_safe?(mapping)
      end)
      |> Enum.map(&snapshot_mapping/1)

    parser_context =
      %{
        "title" => parser_title,
        "aliases" => parser_aliases,
        "blocked_titles" => parser_blocked_titles(context),
        "allow_unscoped_standard" => allow_unscoped_standard?(release, context),
        "year" => context.year
      }
      |> put_scene_titles(parser_scene_titles(context, reserved_ids))

    %{
      "version" => 3,
      "parser_context" => parser_context,
      "reserved_episode_ids" => reserved_ids,
      "release" => %{
        "title" => release.title,
        "coordinates" => Enum.map(release.coordinates || [], &snapshot_coordinate/1),
        "group" => release.group,
        "category_ids" => release.category_ids || [],
        "indexer_id" => release.indexer_id,
        "published_at" => iso8601(release.published_at)
      },
      "mappings" => mappings,
      "selected_resolution" => %{
        "episode_ids" => reserved_ids,
        "values" => Enum.map(release.resolution_evidence || [], &snapshot_resolution/1)
      }
    }
  end

  defp resolved_candidates(releases, context, wanted_ids, opts) do
    releases
    |> filter_protocols(Keyword.get(opts, :protocols))
    |> Enum.map(&parse_anime_release(&1, context))
    |> Enum.filter(&(&1.role == :story))
    |> language_pool(opts)
    |> Enum.flat_map(&resolve_release(&1, context, wanted_ids))
  end

  defp filter_protocols(releases, protocols) when is_list(protocols),
    do: Enum.filter(releases, &(&1.protocol in protocols))

  defp filter_protocols(releases, _protocols), do: releases

  defp parse_anime_release(release, context) do
    parser_context = %{
      kind: :series,
      titles: parser_snapshot_titles(context, parser_alias_titles(context)),
      blocked_titles: parser_blocked_titles(context),
      allow_unscoped_standard: allow_unscoped_standard?(release, context),
      year: context.year,
      scene_titles: parser_scene_titles(context)
    }

    parsed = AnimeParser.parse(release.title, parser_context)

    %{
      release
      | coordinates: parsed.coordinates,
        role: parsed.role,
        group: release.group || parsed.group,
        resolved_episode_ids: nil,
        resolution_evidence: nil,
        mapping_snapshot: nil
    }
  end

  defp parser_alias_titles(context) do
    retained_aliases = context |> eligible_alias_titles() |> Enum.take(@max_aliases)
    omitted_aliases = omitted_parser_alias_titles(context, retained_aliases)

    Enum.reject(retained_aliases, &title_blocked_by_omitted_alias?(&1, omitted_aliases))
  end

  defp parser_snapshot_titles(context, aliases) do
    [context.title | aliases]
    |> Enum.filter(&within_codepoint_limit?(&1, @max_title_codepoints))
    |> Enum.uniq_by(&normalize_title/1)
  end

  defp allow_unscoped_standard?(release, context) do
    within_codepoint_limit?(context.title, @max_title_codepoints) and
      :id_scoped in (release.query_origins || [])
  end

  defp eligible_alias_titles(context) do
    context
    |> known_alias_titles()
    |> Enum.filter(&within_codepoint_limit?(&1, @max_title_codepoints))
  end

  # Negative prefix evidence must include every persisted nonblank alias. The parser/search length
  # limit bounds positive use only; dropping an over-limit longer alias from the safety set would
  # let its retained prefix consume a numeric title continuation.
  defp known_alias_titles(context) do
    canonical_normalized = normalize_title(context.title)

    context.aliases
    |> Enum.filter(&known_alias?/1)
    |> Enum.sort_by(&alias_sort_key/1)
    |> Enum.uniq_by(&normalize_title(&1.title))
    |> Enum.reject(&(normalize_title(&1.title) == canonical_normalized))
    |> Enum.map(& &1.title)
  end

  defp omitted_parser_alias_titles(context, retained_aliases) do
    retained =
      context
      |> parser_snapshot_titles(retained_aliases)
      |> MapSet.new(&normalize_title/1)

    [context.title | known_alias_titles(context)]
    |> Enum.reject(&MapSet.member?(retained, normalize_title(&1)))
  end

  defp parser_scene_titles(context, reserved_ids \\ nil) do
    retained_aliases = parser_alias_titles(context)

    scene_titles_by_normalized_title =
      context
      |> Map.get(:scene_titles, [])
      |> Map.new(fn scene_title ->
        title = Map.get(scene_title, :title) || Map.get(scene_title, "title")
        {normalize_title(title), scene_title}
      end)

    if within_codepoint_limit?(context.title, @max_title_codepoints) do
      retained_aliases
      |> Enum.map(&Map.get(scene_titles_by_normalized_title, normalize_title(&1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn scene_title ->
        normalized = scene_title |> scene_title_field(:title) |> normalize_title()

        scene_title_applies?(scene_title, context, reserved_ids) and
          within_codepoint_limit?(normalized, @max_title_codepoints)
      end)
      |> Enum.take(@max_aliases)
    else
      []
    end
  end

  # The parser snapshot is intentionally bounded. Neither the canonical title nor a retained alias
  # may outlive a longer known alias omitted from positive parsing by either the count or codepoint
  # bound. Persist every rejected retained title as negative evidence so frozen replay cannot infer
  # through the exact title the live parser removed.
  defp parser_blocked_titles(context) do
    retained_aliases = context |> eligible_alias_titles() |> Enum.take(@max_aliases)
    omitted_aliases = omitted_parser_alias_titles(context, retained_aliases)

    [context.title | retained_aliases]
    |> Enum.filter(fn title ->
      title_blocked_by_omitted_alias?(title, omitted_aliases) and
        within_codepoint_limit?(title, @max_title_codepoints)
    end)
    |> Enum.uniq_by(&normalize_title/1)
  end

  defp title_blocked_by_omitted_alias?(title, omitted_aliases) do
    title = normalize_title(title)

    Enum.any?(omitted_aliases, fn omitted_alias ->
      omitted_alias = normalize_title(omitted_alias)
      longer_title_extension?(title, omitted_alias)
    end)
  end

  defp longer_title_extension?(shorter, longer) do
    if String.length(longer) > String.length(shorter) and String.starts_with?(longer, shorter) do
      {_prefix, remainder} = String.split_at(longer, String.length(shorter))
      Regex.match?(~r/^[\s._\-–—(]/u, remainder)
    else
      false
    end
  end

  defp scene_title_applies?(_scene_title, _context, nil), do: true

  defp scene_title_applies?(scene_title, context, reserved_ids) do
    scope = %{
      title: scene_title_field(scene_title, :title),
      season: scene_title_field(scene_title, :season),
      source: scene_title_field(scene_title, :source),
      namespace: scene_title_field(scene_title, :namespace)
    }

    reserved = MapSet.new(reserved_ids)
    Enum.any?(context.mappings, &scene_mapping_applies?(&1, scope, reserved))
  end

  defp scene_title_field(scene_title, key),
    do: Map.get(scene_title, key) || Map.get(scene_title, Atom.to_string(key))

  defp scene_mapping_applies?(mapping, scope, reserved) do
    identity = mapping.identity

    identity.source == scope.source and identity.scheme == "scene" and
      identity.namespace == scope.namespace and
      scene_value_in_season?(identity.canonical_value, scope.season) and
      matching_scope_title?(Map.get(mapping, :scope_title), scope.title) and
      not MapSet.disjoint?(MapSet.new(mapping.episode_ids), reserved)
  end

  defp matching_scope_title?(mapping_title, title)
       when is_binary(mapping_title) and is_binary(title),
       do: normalize_title(mapping_title) == normalize_title(title)

  defp matching_scope_title?(_mapping_title, _title), do: false

  defp scene_value_in_season?(value, season) when is_binary(value) and is_integer(season) do
    case Regex.run(~r/^S(\d{2,3})E\d{2,4}$/u, value, capture: :all_but_first) do
      [value_season] -> String.to_integer(value_season) == season
      _invalid -> false
    end
  end

  defp scene_value_in_season?(_value, _season), do: false

  defp put_scene_titles(parser_context, []), do: parser_context

  defp put_scene_titles(parser_context, scene_titles) do
    serialized =
      Enum.map(scene_titles, fn scene_title ->
        %{
          "title" =>
            normalize_title(Map.get(scene_title, :title) || Map.get(scene_title, "title")),
          "season" => Map.get(scene_title, :season) || Map.get(scene_title, "season"),
          "source" => Map.get(scene_title, :source) || Map.get(scene_title, "source"),
          "namespace" => Map.get(scene_title, :namespace) || Map.get(scene_title, "namespace")
        }
      end)

    Map.put(parser_context, "scene_titles", serialized)
  end

  defp fill_movie_group(%Release{group: nil} = release) do
    parsed = AnimeParser.parse(release.title, %{kind: :movie})
    %{release | group: parsed.group}
  end

  defp fill_movie_group(release), do: release

  defp language_pool(candidates, opts) do
    case Keyword.get(opts, :anime_policy) do
      nil -> legacy_language_pool(candidates, opts)
      _policy -> candidates
    end
  end

  defp legacy_language_pool(candidates, opts) do
    preferred = Keyword.get(opts, :preferred_language)
    original = Keyword.get(opts, :original_language)

    case Language.filter(candidates, preferred, original) do
      [] when candidates != [] -> if Language.strict?(preferred), do: [], else: candidates
      filtered -> filtered
    end
  end

  defp filter_policy(candidates, opts) do
    case Keyword.get(opts, :anime_policy) do
      nil -> candidates
      policy -> Enum.filter(candidates, &AnimePreferences.release_allowed?(&1, policy))
    end
  end

  defp filter_candidates(candidates, opts) do
    case Keyword.get(opts, :candidate_filter) do
      nil -> candidates
      filter when is_function(filter, 1) -> Enum.filter(candidates, filter)
    end
  end

  defp resolve_release(%Release{coordinates: coordinates} = release, context, wanted_ids)
       when coordinates != [] do
    values =
      for coordinate <- coordinates, value <- coordinate.values do
        %{
          scheme: coordinate.scheme,
          canonical_value: value,
          source: Map.get(coordinate, :source),
          namespace: Map.get(coordinate, :namespace),
          scope_title: Map.get(coordinate, :scope_title)
        }
      end

    case resolve_values(values, context.mappings, []) do
      {:ok, evidence} ->
        episode_ids = evidence |> Enum.flat_map(& &1.episode_ids) |> Enum.uniq()

        if MapSet.subset?(MapSet.new(episode_ids), MapSet.new(wanted_ids)) do
          [
            %{
              release
              | resolved_episode_ids: episode_ids,
                resolution_evidence: evidence
            }
          ]
        else
          []
        end

      :error ->
        []
    end
  end

  defp resolve_release(_release, _context, _wanted_ids), do: []

  @doc """
  Resolves one parsed episode coordinate through the same persisted-coordinate bridge used by
  Anime selection. Standard TV uses this when a series has alternate-season scene coordinates.
  """
  def resolve_episode_coordinate(scheme, value, mappings) do
    matching = mappings_for_value(mappings, scheme, value)
    resolver_mappings = Enum.map(matching, &resolver_mapping/1)
    identities = Enum.map(matching, & &1.identity)

    AnimeResolver.resolve(identities, resolver_mappings)
  end

  defp resolve_values([], _mappings, evidence), do: {:ok, Enum.reverse(evidence)}

  defp resolve_values([coordinate | rest], mappings, evidence) do
    case resolve_coordinate(coordinate, mappings) do
      {:ok, episode_ids, resolver_evidence} ->
        value_evidence =
          %{
            scheme: coordinate.scheme,
            canonical_value: coordinate.canonical_value,
            episode_ids: episode_ids,
            precedence: resolver_evidence.precedence,
            mapping_identities: Enum.map(resolver_evidence.matches, & &1.coordinate)
          }
          |> put_coordinate_scope(coordinate)

        resolve_values(rest, mappings, [value_evidence | evidence])

      _unresolved ->
        :error
    end
  end

  defp resolve_coordinate(
         %{source: source, namespace: namespace, scope_title: scope_title} = coordinate,
         mappings
       )
       when is_binary(source) and is_binary(namespace) and is_binary(scope_title) do
    matching =
      Enum.filter(mappings, fn mapping ->
        identity = mapping.identity

        identity.source == source and identity.scheme == coordinate.scheme and
          identity.namespace == namespace and
          identity.canonical_value == coordinate.canonical_value and
          matching_scope_title?(Map.get(mapping, :scope_title), scope_title)
      end)

    resolve_matching_mappings(matching)
  end

  defp resolve_coordinate(%{source: source, namespace: namespace}, _mappings)
       when is_binary(source) or is_binary(namespace),
       do: :error

  defp resolve_coordinate(coordinate, mappings) do
    resolve_episode_coordinate(coordinate.scheme, coordinate.canonical_value, mappings)
  end

  defp resolve_matching_mappings(matching) do
    resolver_mappings = Enum.map(matching, &resolver_mapping/1)
    identities = Enum.map(matching, & &1.identity)
    AnimeResolver.resolve(identities, resolver_mappings)
  end

  defp put_coordinate_scope(value, %{
         source: source,
         namespace: namespace,
         scope_title: scope_title
       })
       when is_binary(source) and is_binary(namespace) and is_binary(scope_title) do
    Map.merge(value, %{source: source, namespace: namespace, scope_title: scope_title})
  end

  defp put_coordinate_scope(value, _coordinate), do: value

  # The scheme-bridging rule (which persisted schemes a parsed value also matches) lives once in
  # `AnimeResolver.bridged_schemes/1`. `strip_shadowed_canonical/1` then lets an operator-reviewed
  # scene coordinate win over the coincidental native code of a *different* episode that shares the
  # same SxxEyy string (issue #156); an auto-derived `:inferred` scene coordinate leaves the native
  # canonical in place, so ordinary resolution is unchanged.
  defp mappings_for_value(mappings, scheme, value) do
    schemes = [scheme | AnimeResolver.bridged_schemes(scheme)]

    mappings
    |> Enum.filter(
      &(Map.get(&1.identity, :scheme) in schemes and
          Map.get(&1.identity, :canonical_value) == value)
    )
    |> AnimeResolver.strip_shadowed_canonical()
  end

  defp resolver_mapping(mapping) do
    %{
      coordinate: mapping.identity,
      episode_ids: mapping.episode_ids,
      precedence: mapping.precedence,
      evidence: mapping.evidence
    }
  end

  defp select_immediately([], _context, _wanted_ids, _opts), do: :no_match

  defp select_immediately(candidates, context, wanted_ids, opts) do
    candidates
    |> validated_assignments(wanted_ids, context, opts)
    |> selection_result(nil)
  end

  defp preferred_groups(opts) do
    opts
    |> Keyword.get(:preferred_groups, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_group/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_group(group), do: group |> String.trim() |> String.downcase()

  defp select_timed_movie(candidates, groups, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    delay = Keyword.get(opts, :fallback_delay, 0)
    entries = Enum.flat_map(candidates, &timed_entry(&1, groups, now, delay))
    eligible = for %{status: :eligible, release: release} <- entries, do: release

    case Scorer.select(eligible, opts) do
      {:ok, _release} = selected ->
        selected

      :no_match ->
        delayed = Enum.filter(entries, &(&1.status == :delayed))
        movie_waiting_result(delayed)
    end
  end

  defp movie_waiting_result([]), do: :no_match

  defp movie_waiting_result(delayed) do
    retry_at = delayed |> Enum.map(& &1.retry_at) |> Enum.min(DateTime)
    {:waiting_for_preferred_group, %{retry_at: retry_at}}
  end

  defp select_with_waiting(candidates, context, wanted_ids, groups, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    delay = Keyword.get(opts, :fallback_delay, 0)

    entries =
      Enum.flat_map(candidates, &timed_entry(&1, groups, now, delay))
      |> Enum.filter(&valid_timed_entry_snapshot?(&1, context))

    outcomes =
      entries
      |> coverage_components()
      |> Enum.map(&select_component(&1, context, wanted_ids, opts))

    assignments = Enum.flat_map(outcomes, & &1.assignments)
    waiting_outcomes = Enum.filter(outcomes, & &1.waiting)

    waiting =
      case waiting_outcomes do
        [] ->
          nil

        waiting_outcomes ->
          waiting_ids =
            Enum.reduce(waiting_outcomes, MapSet.new(), &MapSet.union(&1.ids, &2))

          %{
            episode_ids: Enum.filter(wanted_ids, &MapSet.member?(waiting_ids, &1)),
            retry_at: waiting_outcomes |> Enum.map(& &1.retry_at) |> Enum.min(DateTime)
          }
      end

    selection_result(assignments, waiting)
  end

  defp timed_entry(release, groups, now, delay) do
    ids = MapSet.new(release.resolved_episode_ids || [])

    if normalize_group(release.group || "") in groups do
      [%{release: release, ids: ids, status: :eligible, retry_at: nil}]
    else
      fallback_entry(release, ids, now, delay)
    end
  end

  defp fallback_entry(
         %Release{published_at: %DateTime{} = published_at} = release,
         ids,
         now,
         delay
       ) do
    retry_at = DateTime.add(published_at, delay, :second)
    status = if DateTime.compare(retry_at, now) == :gt, do: :delayed, else: :eligible
    [%{release: release, ids: ids, status: status, retry_at: retry_at}]
  end

  defp fallback_entry(_release, _ids, _now, _delay), do: []

  defp valid_timed_entry_snapshot?(entry, context) do
    episode_ids =
      entry.release.resolved_episode_ids
      |> List.wrap()
      |> Enum.filter(&MapSet.member?(entry.ids, &1))

    snapshot = build_mapping_snapshot(entry.release, episode_ids, context)

    is_map(snapshot) and Intent.valid_mapping_snapshot?(snapshot, :episode, episode_ids)
  end

  defp coverage_components(entries), do: build_components(entries, [])

  defp build_components([], components), do: Enum.reverse(components)

  defp build_components([entry | rest], components) do
    {component, remaining} = grow_component([entry], entry.ids, rest)

    build_components(remaining, [
      %{entries: component, ids: component_ids(component)} | components
    ])
  end

  defp grow_component(component, ids, remaining) do
    {overlapping, separate} =
      Enum.split_with(remaining, &(not MapSet.disjoint?(&1.ids, ids)))

    case overlapping do
      [] ->
        {component, separate}

      overlapping ->
        expanded_ids = Enum.reduce(overlapping, ids, &MapSet.union(&1.ids, &2))
        grow_component(component ++ overlapping, expanded_ids, separate)
    end
  end

  defp component_ids(entries),
    do: Enum.reduce(entries, MapSet.new(), &MapSet.union(&1.ids, &2))

  defp select_component(component, context, wanted_ids, opts) do
    eligible = for %{status: :eligible, release: release} <- component.entries, do: release
    delayed = Enum.filter(component.entries, &(&1.status == :delayed))
    component_wanted = Enum.filter(wanted_ids, &MapSet.member?(component.ids, &1))
    selected_assignments = validated_assignments(eligible, component_wanted, context, opts)
    covered = selected_assignments |> Enum.flat_map(& &1.episode_ids) |> MapSet.new()

    if MapSet.equal?(covered, component.ids) do
      %{assignments: selected_assignments, waiting: false}
    else
      uncovered = MapSet.difference(component.ids, covered)
      relevant_delayed = Enum.filter(delayed, &(not MapSet.disjoint?(&1.ids, uncovered)))

      case relevant_delayed do
        [] ->
          %{assignments: selected_assignments, waiting: false}

        relevant_delayed ->
          %{
            assignments: selected_assignments,
            waiting: true,
            ids: uncovered,
            retry_at: relevant_delayed |> Enum.map(& &1.retry_at) |> Enum.min(DateTime)
          }
      end
    end
  end

  defp validated_assignments([], _wanted_ids, _context, _opts), do: []

  defp validated_assignments(candidates, wanted_ids, context, opts) do
    case Scorer.select_for_ids(candidates, wanted_ids, opts) do
      {:ok, selections} ->
        {accepted, rejected} = assignments_with_rejections(selections, context, opts)

        case rejected do
          [] ->
            accepted

          rejected ->
            candidates
            |> reject_candidates(rejected)
            |> validated_assignments(wanted_ids, context, opts)
        end

      :no_match ->
        []
    end
  end

  defp reject_candidates(candidates, rejected) do
    Enum.reject(candidates, fn candidate -> Enum.any?(rejected, &(&1 == candidate)) end)
  end

  defp assignments_with_rejections(selections, context, opts) do
    Enum.reduce(selections, {[], []}, fn {release, episode_ids}, {accepted, rejected} ->
      snapshot = build_mapping_snapshot(release, episode_ids, context)

      if is_map(snapshot) and Intent.valid_mapping_snapshot?(snapshot, :episode, episode_ids) do
        marked = release |> Map.put(:mapping_snapshot, snapshot) |> mark_policy(opts)
        assignment = %{release: marked, episode_ids: episode_ids, mapping_snapshot: snapshot}
        {[assignment | accepted], rejected}
      else
        {accepted, [release | rejected]}
      end
    end)
    |> then(fn {accepted, rejected} -> {Enum.reverse(accepted), rejected} end)
  end

  defp mark_policy({:ok, release}, opts), do: {:ok, mark_policy(release, opts)}

  defp mark_policy(%Release{} = release, opts) do
    case Keyword.get(opts, :anime_policy) do
      nil -> release
      policy -> %{release | release_policy_snapshot: AnimePreferences.snapshot(policy, release)}
    end
  end

  defp selection_result([], nil), do: :no_match
  defp selection_result([], waiting), do: {:waiting_for_preferred_group, waiting}

  defp selection_result(assignments, waiting),
    do: {:ok, %{assignments: assignments, waiting: waiting}}

  defp complete_result?(result, wanted_ids) do
    covered = result_episode_ids(result)
    MapSet.subset?(MapSet.new(wanted_ids), covered)
  end

  defp result_episode_ids({:ok, %{assignments: assignments, waiting: waiting}}) do
    assignment_ids = Enum.flat_map(assignments, & &1.episode_ids)
    MapSet.new(assignment_ids ++ waiting_ids(waiting))
  end

  defp result_episode_ids({:waiting_for_preferred_group, waiting}),
    do: MapSet.new(waiting.episode_ids)

  defp result_episode_ids(_result), do: MapSet.new()

  defp waiting_ids(nil), do: []
  defp waiting_ids(waiting), do: waiting.episode_ids

  defp snapshot_mapping(mapping) do
    %{
      "identity" => snapshot_identity(mapping.identity),
      "precedence" => Atom.to_string(mapping.precedence),
      "episode_ids" => mapping.episode_ids,
      "evidence" => json_safe(mapping.evidence)
    }
    |> put_snapshot_scope_title(Map.get(mapping, :scope_title))
  end

  defp snapshot_mapping_safe?(mapping) do
    case Map.get(mapping, :scope_title) do
      nil ->
        true

      title when is_binary(title) ->
        normalized = normalize_title(title)

        mapping.identity.scheme == "scene" and
          within_codepoint_limit?(normalized, @max_title_codepoints)

      _invalid ->
        false
    end
  end

  defp snapshot_coordinate(coordinate) do
    %{"scheme" => coordinate.scheme, "values" => coordinate.values}
    |> put_snapshot_scope(coordinate)
  end

  defp snapshot_resolution(resolution) do
    %{
      "scheme" => resolution.scheme,
      "canonical_value" => resolution.canonical_value,
      "episode_ids" => resolution.episode_ids,
      "precedence" => Atom.to_string(resolution.precedence),
      "mapping_identities" => Enum.map(resolution.mapping_identities, &snapshot_identity/1)
    }
    |> put_snapshot_scope(resolution)
  end

  defp put_snapshot_scope(snapshot, %{
         source: source,
         namespace: namespace,
         scope_title: scope_title
       })
       when is_binary(source) and is_binary(namespace) and is_binary(scope_title) do
    Map.merge(snapshot, %{
      "source" => source,
      "namespace" => namespace,
      "scope_title" => normalize_title(scope_title)
    })
  end

  defp put_snapshot_scope(snapshot, _value), do: snapshot

  defp put_snapshot_scope_title(snapshot, title) when is_binary(title) and title != "",
    do: Map.put(snapshot, "scope_title", normalize_title(title))

  defp put_snapshot_scope_title(snapshot, _title), do: snapshot

  defp snapshot_identity(identity) do
    %{
      "source" => identity.source,
      "scheme" => identity.scheme,
      "namespace" => identity.namespace,
      "canonical_value" => identity.canonical_value
    }
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_datetime), do: nil

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp episode_queries(context, indexer, wanted_ids) do
    seasons = wanted_seasons(context, wanted_ids)
    alt_seasons = scene_seasons(context, wanted_ids) -- seasons

    id_queries =
      Enum.map(seasons ++ alt_seasons, fn season ->
        origin = if is_nil(context.tvdb_id), do: :free_text, else: :id_scoped

        {origin, fn -> indexer.search_tv(context.tvdb_id, context.title, season) end}
      end)

    title_queries =
      Enum.map(search_titles(context), fn title ->
        {:free_text, fn -> indexer.search_tv_query(title, categories: [@anime_category]) end}
      end)

    id_queries ++ title_queries ++ coordinate_queries(context, indexer, wanted_ids, seasons)
  end

  # A6: the distinct season numbers a persisted scene coordinate (A6 alternate-season
  # numbering) claims for a still-wanted episode — e.g. Frieren's TMDB season 1 covers a
  # TVDB-shaped season 2 for episodes 29-38. Added to the id-scoped `search_tv` queries
  # (deduped against the TMDB-season list above) so a TVDB-indexed indexer's `{Season:2}`
  # token search actually gets issued; the free-text coordinate query itself needs no change
  # (`coordinate_queries/4` already iterates "scene" — it's `@queryable_schemes` — over the
  # TMDB season list, which already covers these same episodes).
  @doc "Returns the bounded scene-coordinate seasons covering the wanted episode IDs."
  def scene_seasons(context, wanted_ids) do
    wanted = MapSet.new(wanted_ids)
    bridged = AnimeResolver.bridged_schemes("standard")

    context.mappings
    |> Enum.filter(fn mapping ->
      mapping.identity.scheme in bridged and
        not MapSet.disjoint?(MapSet.new(mapping.episode_ids), wanted)
    end)
    |> Enum.map(&Episode.season_from_code(&1.identity.canonical_value))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_seasons)
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
    [context.title | parser_alias_titles(context)]
    |> Enum.filter(&within_codepoint_limit?(&1, @max_title_codepoints))
  end

  defp known_alias?(%{title: title}),
    do: is_binary(title) and String.trim(title) != ""

  defp known_alias?(_alias), do: false

  defp alias_sort_key(alias_record) do
    {
      Map.get(@precedence_rank, Map.get(alias_record, :precedence), map_size(@precedence_rank)),
      Map.get(@kind_rank, Map.get(alias_record, :kind), map_size(@kind_rank)),
      Map.get(alias_record, :normalized_title) || normalize_title(alias_record.title),
      alias_record.title
    }
  end

  defp within_codepoint_limit?(value, limit) when is_binary(value),
    do: length(String.codepoints(value)) <= limit

  defp within_codepoint_limit?(_value, _limit), do: false

  # Nothing left to ask (no IMDb id and every title over the codepoint limit). Return an empty
  # pool rather than raising on `hd(failures)` — a raise here only gets logged by the poller's
  # isolate, so it would re-run every tick with nothing parked.
  defp run_queries([], _context), do: {:ok, [], false}

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
    [%{release | query_origins: Map.get(result, :query_origins) || [origin]}]
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

  defp normalize_title(title), do: TitleAlias.normalize(title)
end
