defmodule Cinder.Library.AnimePreflight do
  @moduledoc "Pure, exhaustive anime file-to-episode preflight."

  alias Cinder.Acquisition.AnimeParser
  alias Cinder.Catalog.AnimeResolver

  def run(%{"version" => 2} = snapshot, inventory, episodes) do
    context = snapshot["parser_context"]

    parser_context = %{
      kind: :series,
      titles: [context["title"] | context["aliases"]],
      year: context["year"]
    }

    inventory
    |> build_state({parser_context, snapshot["mappings"]})
    |> validate(authoritative_ids(episodes))
    |> result()
  end

  defp authoritative_ids(episodes), do: MapSet.new(Enum.map(episodes, & &1.id))

  defp build_state(inventory, parser) do
    %{files: Enum.map(inventory, &automatic_decision(&1, parser))}
  end

  defp automatic_decision(entry, {context, mappings}) do
    parsed = AnimeParser.parse(Path.basename(entry.relative_path), context)

    case resolve(parsed, mappings) do
      {:ok, episode_ids, evidence} ->
        decision(entry, parsed, episode_ids, :automatic, false, evidence)

      {:ignore, evidence} ->
        decision(entry, parsed, [], :automatic, true, evidence)

      {:unresolved, evidence} ->
        decision(entry, parsed, [], :automatic, false, evidence)
    end
  end

  defp decision(entry, parsed, episode_ids, source, ignored, evidence) do
    %{
      relative_path: entry.relative_path,
      identity: entry.identity,
      parsed: parsed,
      episode_ids: episode_ids,
      source: source,
      ignored: ignored,
      evidence: evidence
    }
  end

  defp resolve(%{coordinates: []} = parsed, mappings) do
    case resolve_value(nil, nil, parsed, mappings) do
      {:ignore, :extra, evidence} -> {:ignore, evidence}
      _unresolved -> {:unresolved, %{resolution: :unmatched}}
    end
  end

  defp resolve(parsed, mappings) do
    parsed.coordinates
    |> Enum.flat_map(fn coordinate ->
      Enum.map(coordinate.values, &{coordinate.scheme, &1})
    end)
    |> Enum.reduce_while({[], []}, fn {scheme, value}, {ids, resolutions} ->
      case resolve_value(scheme, value, parsed, mappings) do
        {:ok, episode_ids, resolver} ->
          resolution = %{
            scheme: scheme,
            canonical_value: value,
            episode_ids: episode_ids,
            resolver: resolver
          }

          {:cont, {ids ++ episode_ids, resolutions ++ [resolution]}}

        {:ambiguous, candidates, resolver} ->
          resolution = %{
            scheme: scheme,
            canonical_value: value,
            candidates: candidates,
            resolver: resolver
          }

          {:halt,
           {:unresolved, %{resolution: :ambiguous, resolutions: resolutions ++ [resolution]}}}

        _unresolved ->
          {:halt, {:unresolved, %{resolution: :unmatched}}}
      end
    end)
    |> case do
      {:unresolved, evidence} -> {:unresolved, evidence}
      {episode_ids, resolutions} -> {:ok, Enum.uniq(episode_ids), %{resolutions: resolutions}}
    end
  end

  defp resolve_value(scheme, value, parsed, mappings) do
    matching =
      Enum.filter(mappings, fn mapping ->
        identity = mapping["identity"]
        identity["scheme"] == scheme and identity["canonical_value"] == value
      end)

    resolver_mappings =
      Enum.map(matching, fn mapping ->
        %{
          coordinate: atom_identity(mapping["identity"]),
          episode_ids: mapping["episode_ids"],
          precedence: String.to_existing_atom(mapping["precedence"]),
          evidence: mapping["evidence"]
        }
      end)

    AnimeResolver.resolve(Enum.map(resolver_mappings, & &1.coordinate), resolver_mappings,
      role: parsed.role,
      extra_evidence: parsed.role == :extra and %{parser: "anime_v1"}
    )
  end

  defp atom_identity(identity) do
    %{
      source: identity["source"],
      scheme: identity["scheme"],
      namespace: identity["namespace"],
      canonical_value: identity["canonical_value"]
    }
  end

  defp validate(state, authoritative) do
    unresolved = Enum.filter(state.files, &(&1.episode_ids == [] and not &1.ignored))

    cond do
      unresolved != [] ->
        paths = Enum.map(unresolved, & &1.relative_path) |> Enum.sort()
        candidates = unresolved |> Enum.flat_map(&candidate_ids/1) |> Enum.uniq() |> Enum.sort()
        {:error, state, issue("unresolved_file", paths, candidates)}

      outside = outside_ids(state.files, authoritative) ->
        paths = paths_assigning(state.files, outside)
        {:error, state, issue("outside_authoritative_set", paths, outside)}

      duplicates = duplicate_ids(state.files) ->
        paths = paths_assigning(state.files, duplicates)
        {:error, state, issue("duplicate_episode_assignment", paths, duplicates)}

      missing = missing_ids(state.files, authoritative) ->
        {:error, state, issue("missing_episode_assignment", [], missing)}

      true ->
        {:ok, state}
    end
  end

  defp outside_ids(files, authoritative) do
    outside =
      files
      |> assigned_ids()
      |> MapSet.difference(authoritative)
      |> MapSet.to_list()
      |> Enum.sort()

    if outside == [], do: nil, else: outside
  end

  defp duplicate_ids(files) do
    duplicates =
      files
      |> Enum.reject(& &1.ignored)
      |> Enum.flat_map(fn file -> Enum.uniq(file.episode_ids) end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [], do: nil, else: duplicates
  end

  defp missing_ids(files, authoritative) do
    missing =
      authoritative
      |> MapSet.difference(assigned_ids(files))
      |> MapSet.to_list()
      |> Enum.sort()

    if missing == [], do: nil, else: missing
  end

  defp assigned_ids(files) do
    files
    |> Enum.reject(& &1.ignored)
    |> Enum.flat_map(& &1.episode_ids)
    |> MapSet.new()
  end

  defp paths_assigning(files, episode_ids) do
    ids = MapSet.new(episode_ids)

    files
    |> Enum.filter(fn file ->
      not MapSet.disjoint?(MapSet.new(file.episode_ids), ids)
    end)
    |> Enum.map(& &1.relative_path)
    |> Enum.sort()
  end

  defp candidate_ids(%{evidence: %{resolution: :ambiguous, resolutions: resolutions}}) do
    resolutions
    |> Enum.flat_map(&Map.get(&1, :candidates, []))
    |> List.flatten()
  end

  defp candidate_ids(_file), do: []

  defp issue(reason, paths, candidate_ids) do
    %{
      "version" => 1,
      "reason" => reason,
      "relative_paths" => paths,
      "candidate_episode_ids" => candidate_ids
    }
  end

  defp result({:ok, state}) do
    files = Enum.sort_by(state.files, & &1.relative_path)

    assignments =
      files
      |> Enum.reject(& &1.ignored)
      |> Enum.map(&Map.take(&1, [:relative_path, :episode_ids]))

    {:ok, %{decisions: decisions(files), assignments: assignments}}
  end

  defp result({:error, state, issue}) do
    files = Enum.sort_by(state.files, & &1.relative_path)
    {:needs_mapping, %{decisions: decisions(files), issue: issue}}
  end

  defp decisions(files) do
    %{
      "version" => 1,
      "files" => Enum.map(files, &json_decision/1)
    }
  end

  defp json_decision(file) do
    %{
      "relative_path" => file.relative_path,
      "size" => file.identity.size,
      "major_device" => file.identity.major_device,
      "inode" => file.identity.inode,
      "mtime" => file.identity.mtime,
      "parsed" => json_safe(file.parsed),
      "episode_ids" => file.episode_ids,
      "source" => Atom.to_string(file.source),
      "ignored" => file.ignored,
      "evidence" => json_safe(file.evidence)
    }
  end

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value
end
