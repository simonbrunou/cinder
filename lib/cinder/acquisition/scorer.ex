defmodule Cinder.Acquisition.Scorer do
  @moduledoc """
  Selects the best release from a list by explicit, configurable rules: an
  inclusive size band, a group blocklist, and a resolution allow-list that doubles
  as the ranking order.

  The resolution preference is a **strict allow-list**, not just a tiebreak: a
  release whose parsed resolution isn't in the list is rejected outright (a 480p is
  dropped, not merely out-ranked), and an untagged (nil) resolution is rejected too.
  So a user who wants 1080p never silently gets a 480p — if nothing in the allow-list
  survives, the result is `:no_match` and the item parks for the next search tick.

  An **empty** list disables the gate — but that's the no-rules programmatic default,
  not something a cleared `/settings` field produces: a blank field resolves to `nil`,
  which falls back to the configured default list (`["1080p", "720p"]`), so the gate
  stays active. To accept more resolutions, list them.

  Rules come from `config :cinder, #{inspect(__MODULE__)}` merged with per-call
  `opts`. Returns `{:ok, release}` or `:no_match` when none survive the filters.
  """
  alias Cinder.Acquisition.Release

  @default_preferred ["1080p", "720p"]

  @doc """
  Picks the best release from `releases`, or `:no_match` if none survive the
  size-band, blocklist, and resolution allow-list filters.
  """
  def select(releases, opts \\ []) do
    {min_size, max_size, preferred, blocklist} = rules(opts)

    releases
    |> Enum.filter(&within_band?(&1, min_size, max_size))
    |> Enum.reject(&blocked?(&1, blocklist))
    |> Enum.filter(&allowed_resolution?(&1, preferred))
    |> pick_best(preferred)
  end

  @doc """
  Selects one or more releases that together cover `wanted_episodes` (a list of
  episode numbers) for a single `season`. Returns `{:ok, [{release, covered_numbers}]}`
  (each release paired with the sorted episode numbers it is responsible for — the
  disjoint set the greedy assigned it) or `:no_match`. The pairing is the single source
  of truth for which episodes each release serves; callers map numbers → episode rows
  from it rather than re-deriving coverage.

  Releases for other seasons (and movies, `season: nil`) are dropped; blocklisted
  groups, out-of-band releases, and releases outside the resolution allow-list (see
  `select/2`) are rejected. The size band is **per-episode**: a
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
    {min_size, max_size, preferred, blocklist} = rules(opts)
    band = {min_size, max_size, preferred}

    releases
    |> Enum.filter(&(&1.season == season))
    |> Enum.reject(&blocked?(&1, blocklist))
    |> Enum.filter(&allowed_resolution?(&1, preferred))
    |> cover(MapSet.new(wanted_episodes), [], band)
  end

  # The normalized rule set, shared by both entry points: the size band, the
  # resolution preference (defaulted), and the downcased blocklist. Config block
  # overlaid by per-call opts.
  defp rules(opts) do
    rules = Keyword.merge(config(), opts)

    {
      Keyword.get(rules, :min_size),
      Keyword.get(rules, :max_size),
      Keyword.get(rules, :preferred_resolutions, @default_preferred),
      rules |> Keyword.get(:blocklist, []) |> Enum.map(&String.downcase/1)
    }
  end

  defp cover(candidates, needed, chosen, band) do
    {min_size, max_size, _preferred} = band

    scored =
      if MapSet.size(needed) == 0 do
        []
      else
        candidates
        |> Enum.map(fn release -> {release, coverage(release, needed)} end)
        |> Enum.reject(fn {release, cov} ->
          # Per-episode band: a release covering k still-wanted episodes is judged
          # against k×the band (a pack is allowed proportionally more size).
          k = MapSet.size(cov)
          k == 0 or not within_band?(release, scale(min_size, k), scale(max_size, k))
        end)
      end

    case scored do
      [] -> if chosen == [], do: :no_match, else: {:ok, Enum.reverse(chosen)}
      _ -> take_best(scored, candidates, needed, chosen, band)
    end
  end

  defp take_best(scored, candidates, needed, chosen, band) do
    {pick, cov} = Enum.max_by(scored, fn {release, cov} -> greedy_key(release, cov, band) end)
    covered = cov |> MapSet.to_list() |> Enum.sort()
    cover(candidates -- [pick], MapSet.difference(needed, cov), [{pick, covered} | chosen], band)
  end

  # A whole-season pack (no episode list) covers every still-needed episode; an
  # episode list covers its intersection with what's still needed.
  defp coverage(%Release{episodes: nil}, needed), do: needed
  defp coverage(%Release{episodes: eps}, needed), do: MapSet.intersection(MapSet.new(eps), needed)

  # max_by: more coverage wins; ties go to the more-preferred resolution, then larger size.
  defp greedy_key(%Release{} = release, cov, {_min, _max, preferred}) do
    {MapSet.size(cov), -resolution_rank(release, preferred), release.size || 0}
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  # A release whose indexer omits the size is unsizeable: accept it only when there's no band to
  # enforce. This closes the "0 ≤ max" hole — `size = release.size || 0` used to let an unknown
  # size sail past a configured max_size. With a min_size set it already failed (0 < min), so
  # behaviour there is unchanged; the live bug was max set, min unset.
  defp within_band?(%Release{size: nil}, min_size, max_size),
    do: is_nil(min_size) and is_nil(max_size)

  # One inclusive size-band check for both paths. The TV path pre-multiplies the
  # bounds by k (the episodes a release covers) at the call site; movies pass them as-is.
  defp within_band?(%Release{size: size}, min_size, max_size) do
    (is_nil(min_size) or size >= min_size) and (is_nil(max_size) or size <= max_size)
  end

  defp scale(nil, _k), do: nil
  defp scale(size, k), do: k * size

  @doc "Index of a resolution string in the preference list (lower = better); nil/unlisted sorts last."
  def resolution_rank(resolution, preferred) when is_binary(resolution) or is_nil(resolution),
    do: Enum.find_index(preferred, &(&1 == resolution)) || length(preferred)

  def resolution_rank(%Release{} = release, preferred),
    do: resolution_rank(release.resolution, preferred)

  defp blocked?(%Release{group: nil}, _blocklist), do: false
  defp blocked?(%Release{group: group}, blocklist), do: String.downcase(group) in blocklist

  # Strict allow-list: keep a release only if its resolution is one the user asked for.
  # nil (untagged) ∉ any list ⇒ rejected. An empty list = no preference configured ⇒ keep all
  # (a [] allow-list rejecting everything is never the intent; that would brick every grab).
  defp allowed_resolution?(_release, []), do: true

  defp allowed_resolution?(%Release{resolution: resolution}, preferred),
    do: resolution in preferred

  defp pick_best([], _preferred), do: :no_match
  defp pick_best(releases, preferred), do: {:ok, Enum.min_by(releases, &sort_key(&1, preferred))}

  defp sort_key(%Release{} = release, preferred) do
    {resolution_rank(release, preferred), -(release.size || 0)}
  end
end
