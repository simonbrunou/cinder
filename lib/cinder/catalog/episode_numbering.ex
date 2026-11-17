defmodule Cinder.Catalog.EpisodeNumbering do
  @moduledoc """
  Which episode an episode code names, for the standard and anime searches: the one reading of a
  series' coordinate mappings (`Cinder.Catalog.MediaProfiles.acquisition_mappings/1`).

  A search reads an unscoped code through `resolve/4`: the series' kind sets the schemes it
  matches (`bridged_schemes/1`), a vetted scene mapping shadows the native code of another
  episode (#156), a saved season offset retires the native code of each episode it moves (#987),
  and `Cinder.Catalog.AnimeResolver.resolve/3` then picks the highest precedence. The anime search
  matches a code scoped to a provider namespace and a scene title against that namespace's
  mappings alone, with no bridge, shadowing or retirement. The standard search also marks a
  native release whose code a vetted mapping or an offset takes from its native episode
  (`contested_native_codes/2`), and the anime query planner skips a retired code
  (`queryable_code?/2`).

  The imports and the reservation apply no shadowing and no retirement (ADR 0002, #987's
  out-of-scope list). The anime import and the reservation read an unscoped code as the anime
  grab's mapping snapshot froze it, through `grab_schemes/2`, and match a scoped code against its
  provider namespace exactly. The standard import (`Cinder.Library`) matches a file against the
  current codes of its grab's episodes, through `bridged_schemes/1`.

  Each mapping is `%{identity: %{source, scheme, namespace, canonical_value}, precedence,
  episode_ids, evidence}`. A **vetted mapping** is a `:curated` or `:manual` one other than the
  native code itself (`GLOSSARY.md`).
  """

  alias Cinder.Catalog.{AnimeResolver, Episode}

  @doc """
  The persisted schemes a parsed SxxEyy code also matches, besides `"standard"` itself, for a
  series of `kind`: `:standard` bridges scene and TVDB-aired codes (#924), in that order of
  preference, and `:anime` bridges scene codes only (A6). The search planners and the standard
  import (`Cinder.Library`) read it.
  """
  def bridged_schemes(:standard), do: ~w(scene aired)
  def bridged_schemes(:anime), do: ~w(scene)

  @doc """
  The persisted schemes an anime grab's frozen code of `scheme` matches, for the anime import
  (`Cinder.Library.AnimePreflight`) and the reservation (`Cinder.Download.Intent`): `scheme`
  itself, plus `bridged_schemes/1` for a `"standard"` code. They read an unscoped code as the
  grab's mapping snapshot froze it, with no shadowing and no retirement (ADR 0002), so they call
  this, never `resolve/4`.
  """
  def grab_schemes(kind, scheme), do: [scheme | bridge(kind, scheme)]

  defp bridge(kind, "standard"), do: bridged_schemes(kind)
  defp bridge(_kind, _scheme), do: []

  @doc """
  Which episode `value`, parsed under `scheme`, names in a search of a series of `kind`. It reads
  the mappings of `grab_schemes/2`'s schemes carrying `value`, then:

  1. Drops the native code when a vetted scene mapping for the same value names another episode
     (#156). Only a scene mapping does; two vetted scene mappings naming different episodes stay,
     so the code resolves two ways.
  2. Drops the native code when a saved season offset retires it (#987), and with it every
     `:inferred` match, so a retired code reads only through a vetted mapping naming it.
  3. Resolves the rest by precedence (`Cinder.Catalog.AnimeResolver.resolve/3`) and returns its
     result unchanged: `{:ok, episode_ids, evidence}`, `{:ambiguous, candidates, evidence}` or
     `:unmatched`.

  `mappings` is every mapping the search reads, and also the list the retirement looks up.
  """
  def resolve(kind, scheme, value, mappings) do
    schemes = grab_schemes(kind, scheme)

    matching =
      mappings
      |> Enum.filter(
        &(Map.get(&1.identity, :scheme) in schemes and
            Map.get(&1.identity, :canonical_value) == value)
      )
      |> strip_shadowed_canonical()
      |> strip_retired_canonical(mappings)

    AnimeResolver.resolve_mappings(matching)
  end

  @doc """
  The native codes of `season_number` that the standard search must not read as their native
  episode, looked up across `mappings`, every mapping of the series. The standard search marks a
  native release naming one, or a whole-season pack of the season, `:conflicting_standard_numbering`
  (`Cinder.Acquisition.judge_season/3`).

  - A vetted scene or TVDB-aired mapping assigns the code to an episode other than its native one,
    in another season (#924) or the same one (#986). A code's native episode is the one whose
    native code carries it, so a code no episode carries counts as elsewhere. This counts aired
    mappings too, where `resolve/4`'s shadowing counts scene mappings only.
  - A saved season offset retires the code (#987).

  An `:inferred` mapping, or a vetted one naming only the code's native episode, contests nothing.
  """
  def contested_native_codes(mappings, season_number) do
    native_ids_by_value = native_ids_by_value(mappings)

    assigned_elsewhere =
      for %{identity: %{canonical_value: value} = identity, episode_ids: episode_ids} = mapping <-
            mappings,
          identity.scheme in bridged_schemes(:standard),
          vetted?(mapping),
          Episode.season_from_code(value) == season_number,
          native_ids = Map.get(native_ids_by_value, value, MapSet.new()),
          Enum.any?(episode_ids, &(not MapSet.member?(native_ids, &1))),
          into: MapSet.new(),
          do: value

    for %{identity: %{canonical_value: value}} = mapping <- mappings,
        Episode.season_from_code(value) == season_number,
        retired_canonical?(mapping, mappings),
        into: assigned_elsewhere,
        do: value
  end

  defp native_ids_by_value(mappings) do
    mappings
    |> Enum.filter(&canonical_native?/1)
    |> Enum.group_by(& &1.identity.canonical_value, & &1.episode_ids)
    |> Map.new(fn {value, ids} -> {value, ids |> List.flatten() |> MapSet.new()} end)
  end

  @doc """
  Whether a search may query `mapping`'s code, judged against `mappings`, every mapping of the
  series: false only for a native code a saved season offset retired (#987), which names no
  episode. The anime query planner reads it (#1257).
  """
  def queryable_code?(mapping, mappings), do: not retired_canonical?(mapping, mappings)

  # #156: for a franchise carried as one TMDB series (Monogatari), an operator's alternate season
  # numbering (`S04E05` = Second-Season ep 5) collides by exact string with the native code of
  # another cour (`S04E05` = Hanamonogatari ep 5). The native mapping (`:manual`) would outrank
  # the scene one, so the vetted scene mapping drops it. An `:inferred` scene mapping (a TMDB
  # group sync) never does, and a scene mapping naming the same episode (Frieren) leaves it.
  defp strip_shadowed_canonical(matches) do
    vetted_scene = Enum.filter(matches, &(&1.identity.scheme == "scene" and vetted?(&1)))

    if vetted_scene == [] do
      matches
    else
      Enum.reject(matches, fn m ->
        canonical_native?(m) and Enum.any?(vetted_scene, &(&1.episode_ids != m.episode_ids))
      end)
    end
  end

  # #987: drops each native code a saved season offset retires, and with it every `:inferred`
  # match, so an auto-derived mapping never takes the native episode's place.
  defp strip_retired_canonical(matches, mappings) do
    {retired, kept} = Enum.split_with(matches, &retired_canonical?(&1, mappings))

    if retired == [], do: matches, else: Enum.reject(kept, &(&1.precedence == :inferred))
  end

  # Whether a saved season offset retires `mapping`, a native code, so it no longer names its
  # episode (#987): one of `mappings` is a `:curated` scene mapping giving the same episode a
  # code in another season. Only the season offset panel writes `:curated` rows
  # (`Cinder.Catalog.SceneNumbering.save_scene_offset_coordinates/3`), saved when releases number
  # the show's seasons with a fixed shift from TMDB, so a release naming the shifted episode's
  # native code more likely names another episode. A `:manual` mapping records one file's name
  # and an `:inferred` one never overrides a native episode, so neither retires it; nor does a
  # `:curated` code in the episode's own season. A vetted mapping naming the native code itself
  # for the same episode, such as a fold of a file named by that code, keeps it, as #924 keeps a
  # vetted mapping naming only a code's native episode. Any mapping but a native code is false.
  defp retired_canonical?(%{identity: identity, episode_ids: episode_ids} = mapping, mappings) do
    canonical_native?(mapping) and moved_by_offset?(identity, episode_ids, mappings)
  end

  defp moved_by_offset?(identity, episode_ids, mappings) do
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

  # Whether an operator vetted `mapping`: `:curated` (a saved season offset) or `:manual` (a file
  # matched to an episode by hand). The native code carries `:manual` precedence but is not one.
  defp vetted?(%{precedence: precedence} = mapping),
    do: precedence in [:curated, :manual] and not canonical_native?(mapping)

  @doc """
  Whether `mapping` is the native code every episode carries
  (`Cinder.Catalog.MediaProfiles.acquisition_mappings/1`): its own SxxEyy.
  """
  def canonical_native?(%{identity: identity}) do
    Map.get(identity, :source) == "cinder" and Map.get(identity, :namespace) == "canonical" and
      Map.get(identity, :scheme) == "standard"
  end
end
