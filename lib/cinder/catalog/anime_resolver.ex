defmodule Cinder.Catalog.AnimeResolver do
  @moduledoc "Pure precedence-aware resolution of anime coordinates to stable episode IDs."

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
  Drops the auto native-standard canonical mapping from a value's matched set when an
  **operator-reviewed** (`:curated`/`:manual`) `"scene"` mapping for the same value points at a
  *different* episode (issue #156).

  Rationale: for a franchise carried as one TMDB series (e.g. Monogatari), an operator's alternate
  season numbering (`S04E05` = Second-Season ep 5) collides by exact string with the real native
  code of a different cour (`S04E05` = Hanamonogatari ep 5). Without this, the native canonical
  mapping (`:manual`) outranks the scene coordinate and the alt-numbered release resolves to the
  wrong episode and is dropped. Removing the coincidental native mapping lets the operator-reviewed
  scene coordinate win.

  Scoped for safety (never-guess): only an operator-reviewed scene coordinate triggers the drop — an
  auto-derived (`:inferred`) scene coordinate (e.g. an A6 TMDB-group sync) never silently overrides
  the native episode. A same-episode overlap (Frieren) is left untouched (the scene points at the
  same id, so no drop fires). Two operator-reviewed scene coordinates for one value pointing at
  different episodes are left intact so the resolver still reports `:ambiguous` (fail closed).

  Expects each mapping as `%{identity: %{source, scheme, namespace, ...}, precedence, episode_ids}`
  and returns the list unchanged when no operator-reviewed scene mapping collides, so ordinary
  standard resolution is unaffected.
  """
  def strip_shadowed_canonical(matches) do
    vetted_scene =
      Enum.filter(matches, fn m ->
        m.identity.scheme == "scene" and m.precedence in [:curated, :manual]
      end)

    if vetted_scene == [] do
      matches
    else
      Enum.reject(matches, fn m ->
        canonical_native?(m) and Enum.any?(vetted_scene, &(&1.episode_ids != m.episode_ids))
      end)
    end
  end

  defp canonical_native?(%{identity: identity}) do
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
