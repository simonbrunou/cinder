defmodule Cinder.Acquisition.Scorer do
  @moduledoc """
  Selects the best release from a list by explicit, configurable rules: an
  inclusive size band, a group blocklist, and an ordered resolution preference.

  Rules come from `config :cinder, #{inspect(__MODULE__)}` merged with per-call
  `opts`. Returns `{:ok, release}` or `:no_match` when none survive the filters.
  """
  alias Cinder.Acquisition.Release

  @default_preferred ["1080p", "720p"]

  @doc """
  Picks the best release from `releases`, or `:no_match` if none survive the
  size-band and blocklist filters.
  """
  def select(releases, opts \\ []) do
    rules = Keyword.merge(config(), opts)
    min_size = Keyword.get(rules, :min_size)
    max_size = Keyword.get(rules, :max_size)
    blocklist = rules |> Keyword.get(:blocklist, []) |> Enum.map(&String.downcase/1)
    preferred = Keyword.get(rules, :preferred_resolutions, @default_preferred)

    releases
    |> Enum.filter(&within_band?(&1, min_size, max_size))
    |> Enum.reject(&blocked?(&1, blocklist))
    |> pick_best(preferred)
  end

  @doc """
  Selects one or more releases that together cover `wanted_episodes` (a list of
  episode numbers) for a single `season`. Returns `{:ok, [release]}` or `:no_match`.

  Releases for other seasons (and movies, `season: nil`) are dropped; blocklisted
  groups and out-of-band releases are rejected. The size band is **per-episode**: a
  release covering `k` still-wanted episodes must satisfy `k*min_size ≤ size ≤
  k*max_size` (so a season pack is judged against the episodes it actually supplies).
  Selection is greedy set-cover — repeatedly take the release covering the most
  still-needed episodes (ties by resolution preference, then larger size) — which
  handles packs, ranges, and singles uniformly. Partial coverage is fine: the rest
  stay wanted for the next search tick.

  Rules come from `config :cinder, #{inspect(__MODULE__)}` merged with `opts`, exactly
  like `select/2`.

  `# ponytail:` greedy, not optimal set-cover. Optimal is NP-hard and pointless at
  household release-list sizes; upgrade only if release sets get pathological.
  """
  def select_for(releases, season, wanted_episodes, opts \\ []) do
    rules = Keyword.merge(config(), opts)
    blocklist = rules |> Keyword.get(:blocklist, []) |> Enum.map(&String.downcase/1)

    band = {
      Keyword.get(rules, :min_size),
      Keyword.get(rules, :max_size),
      Keyword.get(rules, :preferred_resolutions, @default_preferred)
    }

    releases
    |> Enum.filter(&(&1.season == season))
    |> Enum.reject(&blocked?(&1, blocklist))
    |> cover(MapSet.new(wanted_episodes), [], band)
  end

  defp cover(candidates, needed, chosen, band) do
    scored =
      if MapSet.size(needed) == 0 do
        []
      else
        candidates
        |> Enum.map(fn release -> {release, coverage(release, needed)} end)
        |> Enum.reject(fn {release, cov} ->
          MapSet.size(cov) == 0 or not tv_within_band?(release, MapSet.size(cov), band)
        end)
      end

    case scored do
      [] -> if chosen == [], do: :no_match, else: {:ok, Enum.reverse(chosen)}
      _ -> take_best(scored, candidates, needed, chosen, band)
    end
  end

  defp take_best(scored, candidates, needed, chosen, band) do
    {pick, cov} = Enum.max_by(scored, fn {release, cov} -> greedy_key(release, cov, band) end)
    cover(candidates -- [pick], MapSet.difference(needed, cov), [pick | chosen], band)
  end

  # A whole-season pack (no episode list) covers every still-needed episode; an
  # episode list covers its intersection with what's still needed.
  defp coverage(%Release{episodes: nil}, needed), do: needed
  defp coverage(%Release{episodes: eps}, needed), do: MapSet.intersection(MapSet.new(eps), needed)

  defp tv_within_band?(%Release{} = release, k, {min_size, max_size, _preferred}) do
    size = release.size || 0
    (is_nil(min_size) or size >= k * min_size) and (is_nil(max_size) or size <= k * max_size)
  end

  # max_by: more coverage wins; ties go to the more-preferred resolution, then larger size.
  defp greedy_key(%Release{} = release, cov, {_min, _max, preferred}) do
    rank = Enum.find_index(preferred, &(&1 == release.resolution)) || length(preferred)
    {MapSet.size(cov), -rank, release.size || 0}
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp within_band?(%Release{} = release, min_size, max_size) do
    size = release.size || 0
    (is_nil(min_size) or size >= min_size) and (is_nil(max_size) or size <= max_size)
  end

  defp blocked?(%Release{group: nil}, _blocklist), do: false
  defp blocked?(%Release{group: group}, blocklist), do: String.downcase(group) in blocklist

  defp pick_best([], _preferred), do: :no_match
  defp pick_best(releases, preferred), do: {:ok, Enum.min_by(releases, &sort_key(&1, preferred))}

  defp sort_key(%Release{} = release, preferred) do
    rank = Enum.find_index(preferred, &(&1 == release.resolution)) || length(preferred)
    {rank, -(release.size || 0)}
  end
end
