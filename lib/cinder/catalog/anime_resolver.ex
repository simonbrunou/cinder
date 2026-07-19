defmodule Cinder.Catalog.AnimeResolver do
  @moduledoc "Pure precedence-aware resolution of anime coordinates to stable episode IDs."

  @precedence %{inferred: 0, curated: 1, manual: 2}

  @doc """
  Persisted coordinate schemes bridged onto an exact-value match for a parsed `scheme`, on top
  of the identical-scheme match every scheme already gets. Single source of truth for the A6
  alternate-season-numbering bridge rule: a parsed "standard" (SxxEyy) release/file value also
  matches a persisted "scene" coordinate (the alt-numbering TMDB group synced onto a series) by
  exact value, so a TVDB-numbered release resolves even when TMDB's own tree numbers the show
  differently. Consulted by both `Cinder.Acquisition.Anime` (search/selection) and
  `Cinder.Library.AnimePreflight` (import) — each owns its own data-shape-specific match loop,
  but the scheme list itself lives only here.
  """
  def bridged_schemes("standard"), do: ["scene"]
  def bridged_schemes(_scheme), do: []

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
