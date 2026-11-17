defmodule Cinder.Catalog.AnimeResolver do
  @moduledoc """
  Pure precedence-aware resolution of anime coordinates to stable episode IDs. Which mappings a
  search hands it for an unscoped code, after the bridge, shadowing and retirement, is
  `Cinder.Catalog.EpisodeNumbering`'s. The anime search hands it a scoped code's mappings in its
  provider namespace as they are, and the anime import a frozen grab's mappings.
  """

  @precedence %{inferred: 0, curated: 1, manual: 2}

  @doc """
  Resolves a search's matched mappings, each `%{identity, episode_ids, precedence, evidence}`, by
  precedence: `resolve/3` with each mapping's identity as its coordinate.
  """
  def resolve_mappings(matching) do
    resolve(
      Enum.map(matching, & &1.identity),
      Enum.map(matching, fn mapping ->
        %{
          coordinate: mapping.identity,
          episode_ids: mapping.episode_ids,
          precedence: mapping.precedence,
          evidence: mapping.evidence
        }
      end)
    )
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
