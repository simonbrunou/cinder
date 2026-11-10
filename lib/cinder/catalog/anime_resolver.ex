defmodule Cinder.Catalog.AnimeResolver do
  @moduledoc "Pure precedence-aware resolution of anime coordinates to stable episode IDs."

  alias Cinder.Catalog.Episode

  @precedence %{inferred: 0, curated: 1, manual: 2}

  @doc """
  Persisted coordinate schemes bridged onto an exact-value match for a parsed `scheme`, on top
  of the identical-scheme match every scheme already gets. Single source of truth for the A6
  alternate-season-numbering bridge rule: a parsed "standard" (SxxEyy) release/file value also
  matches a persisted "scene" coordinate (the alt-numbering TMDB group synced onto a series) by
  exact value, so a TVDB-numbered release resolves even when TMDB's own tree numbers the show
  differently. Consulted by `Cinder.Acquisition.Anime` (search/selection),
  `Cinder.Library.AnimePreflight` (import), and `Cinder.Download.Intent` (reservation) — each
  owns its own data-shape-specific match loop, but the scheme list itself lives only here.
  """
  def bridged_schemes("standard"), do: ["scene"]
  def bridged_schemes(_scheme), do: []

  @doc """
  Drops the auto native-standard canonical mapping from a value's matched set when a
  **vetted** (`:curated`/`:manual`) `"scene"` mapping for the same value points at a
  *different* episode (issue #156).

  Rationale: for a franchise carried as one TMDB series (e.g. Monogatari), an operator's alternate
  season numbering (`S04E05` = Second-Season ep 5) collides by exact string with the real native
  code of a different cour (`S04E05` = Hanamonogatari ep 5). Without this, the native canonical
  mapping (`:manual`) outranks the scene coordinate and the alt-numbered release resolves to the
  wrong episode and is dropped. Removing the coincidental native mapping lets the vetted scene
  coordinate win.

  Scoped for safety (never-guess): only a vetted scene coordinate triggers the drop — an
  auto-derived (`:inferred`) scene coordinate (e.g. an A6 TMDB-group sync) never silently overrides
  the native episode. A same-episode overlap (Frieren) is left untouched (the scene points at the
  same id, so no drop fires). Two vetted scene coordinates for one value pointing at
  different episodes are left intact so the resolver still reports `:ambiguous` (fail closed).

  Expects each mapping as `%{identity: %{source, scheme, namespace, ...}, precedence, episode_ids}`
  and returns the list unchanged when no vetted scene mapping collides, so ordinary
  standard resolution is unaffected.
  """
  def strip_shadowed_canonical(matches) do
    vetted_scene = Enum.filter(matches, &(&1.identity.scheme == "scene" and vetted?(&1)))

    if vetted_scene == [] do
      matches
    else
      Enum.reject(matches, fn m ->
        canonical_native?(m) and Enum.any?(vetted_scene, &(&1.episode_ids != m.episode_ids))
      end)
    end
  end

  @doc """
  Drops from a value's matched set each canonical mapping (`canonical_native?/1`) that a saved
  season offset retires (`retired_canonical?/2`), looked up across `mappings`, every mapping of
  the series (#987). When it drops one, it drops every `:inferred` match too, so a retired code
  resolves only through a vetted mapping (`vetted?/1`) that names it, or to no episode: an
  auto-derived mapping never takes the native episode's place. With nothing retired, the matches
  come back unchanged.

  Anime selection (`Cinder.Acquisition.Anime`) and the standard numbering bridge
  (`Cinder.Acquisition.judge_season/3`) run it after `strip_shadowed_canonical/1`.
  """
  def strip_retired_canonical(matches, mappings) do
    {retired, kept} =
      Enum.split_with(matches, &(canonical_native?(&1) and retired_canonical?(&1, mappings)))

    if retired == [], do: matches, else: Enum.reject(kept, &(&1.precedence == :inferred))
  end

  @doc """
  Whether a saved season offset retires `canonical`, a canonical mapping (`canonical_native?/1`),
  so its native code no longer names its episode (#987): one of `mappings` is a `:curated` scene
  mapping that gives the same episode a code in another season. Only the season offset panel
  writes `:curated` rows (`Cinder.Catalog.SceneNumbering.save_scene_offset_coordinates/3`), and it
  is saved when releases number the show's seasons with a fixed shift from TMDB, so a release
  naming the shifted episode's native code more likely names another episode. A `:manual` mapping
  records one file's name and says nothing about what the native code names, and an `:inferred`
  one never overrides a native episode, so neither retires it. Neither does a `:curated` code in
  the episode's own season. A vetted mapping (`vetted?/1`) naming the native code itself for the
  same episode, such as a fold of a file named by that code, keeps the code, as #924 keeps a
  vetted mapping naming only a code's native episode.
  """
  def retired_canonical?(%{identity: identity, episode_ids: episode_ids}, mappings) do
    value = identity.canonical_value
    native_season = Episode.season_from_code(value)
    ids = MapSet.new(episode_ids)
    names_episode? = fn mapping -> Enum.any?(mapping.episode_ids, &MapSet.member?(ids, &1)) end

    moved? =
      Enum.any?(mappings, fn %{identity: offset} = mapping ->
        mapping.precedence == :curated and Map.get(offset, :scheme) == "scene" and
          not canonical_native?(mapping) and
          other_season?(Map.get(offset, :canonical_value), native_season) and
          names_episode?.(mapping)
      end)

    moved? and
      not Enum.any?(mappings, fn mapping ->
        vetted?(mapping) and Map.get(mapping.identity, :canonical_value) == value and
          names_episode?.(mapping)
      end)
  end

  defp other_season?(value, native_season) when is_binary(value) do
    case Episode.season_from_code(value) do
      season when is_integer(season) -> season != native_season
      nil -> false
    end
  end

  defp other_season?(_value, _native_season), do: false

  @doc """
  Whether an operator vetted `mapping`: `:curated` (a saved season offset) or `:manual` (a file
  matched to an episode by hand). An `:inferred` mapping is auto-derived and never overrides a
  native episode. The canonical mapping (`canonical_native?/1`) carries `:manual` precedence but
  is the native code itself, not a vetted one.
  """
  def vetted?(%{precedence: precedence} = mapping),
    do: precedence in [:curated, :manual] and not canonical_native?(mapping)

  @doc """
  Whether `mapping` is the canonical standard mapping every episode carries
  (`Cinder.Catalog.MediaProfiles.acquisition_mappings/1`): its native SxxEyy code.
  """
  def canonical_native?(%{identity: identity}) do
    Map.get(identity, :source) == "cinder" and Map.get(identity, :namespace) == "canonical" and
      Map.get(identity, :scheme) == "standard"
  end

  def resolve(coordinates, mappings, opts \\ []) do
    matches =
      opts
      |> Keyword.get(:overrides, [])
      |> Kernel.++(mappings)
      |> Enum.filter(&(&1.coordinate in coordinates and &1.episode_ids != []))

    case matches do
      [] -> maybe_ignore(opts)
      _ -> resolve_at_highest_precedence(matches)
    end
  end

  defp resolve_at_highest_precedence(matches) do
    precedence =
      matches
      |> Enum.max_by(&Map.fetch!(@precedence, &1.precedence))
      |> Map.fetch!(:precedence)

    matches = Enum.filter(matches, &(&1.precedence == precedence))
    candidates = matches |> Enum.map(& &1.episode_ids) |> Enum.uniq() |> Enum.sort()
    evidence = %{precedence: precedence, matches: Enum.map(matches, &mapping_evidence/1)}

    case candidates do
      [episode_ids] -> {:ok, episode_ids, evidence}
      candidates -> {:ambiguous, candidates, evidence}
    end
  end

  defp mapping_evidence(mapping), do: Map.take(mapping, [:coordinate, :episode_ids, :evidence])

  defp maybe_ignore(opts) do
    case {opts[:role], opts[:extra_evidence]} do
      {:extra, evidence} when evidence not in [nil, false] ->
        {:ignore, :extra, %{role: :extra, evidence: evidence}}

      _ ->
        :unmatched
    end
  end
end
