defmodule Cinder.Acquisition.Scorer do
  @moduledoc """
  Selects the best release from a list by explicit, configurable rules: an
  inclusive size band, release-title exclusions, resolution and source allow-lists, and
  preferred title terms.

  The resolution preference is a **strict allow-list**, not just a tiebreak: a
  release whose parsed resolution isn't in the list is rejected outright (a 480p is
  dropped, not merely out-ranked), and an untagged (nil) resolution is rejected too.
  So a user who wants 1080p never silently gets a 480p — if nothing in the allow-list
  survives, the result is `:no_match` and the item parks for the next search tick.

  The source preference (`preferred_sources`) is a **lenient allow-list**: an empty
  list (the default) accepts every source; a non-empty list rejects a recognized-but-
  unlisted source. Crucially, a `nil` source (untagged release) always passes — a
  parser miss must never strand a grab. Ranking order is resolution → source → preferred term →
  size.

  An **empty** resolution list disables the resolution gate — but that's the no-rules
  programmatic default, not something a cleared `/settings` field produces: a blank
  field resolves to `nil`, which falls back to the configured default list
  (`["1080p", "720p"]`), so the gate stays active. To accept more resolutions, list
  them.

  Rules come from per-call `opts` — the pollers and the manual-search panel pass the
  household policy (`Cinder.Acquisition.HouseholdPolicy.for_target/2`), which carries the
  settings-store band. Returns `{:ok, release}` or `:no_match` when none survive the filters.
  """
  alias Cinder.Acquisition.{AnimePreferences, Language, Release}

  @default_preferred ["1080p", "720p"]

  @doc "The default resolution allow-list, used when none is configured."
  def default_preferred, do: @default_preferred

  @doc """
  Picks the best release from `releases`, or `:no_match` if none survive the
  size-band, release-blocklist, and resolution allow-list filters.
  """
  def select(releases, opts \\ []) do
    {min_size, max_size, preferred, sources, release_blocklist, _preferred_terms, blocked_terms} =
      rules(opts)

    releases
    |> Enum.filter(&within_band?(&1, min_size, max_size))
    |> Enum.reject(&excluded_title?(&1, release_blocklist, blocked_terms))
    |> Enum.filter(&(allowed_resolution?(&1, preferred) and allowed_source?(&1, sources)))
    |> pick_best(opts)
  end

  @doc """
  Selects one or more releases that together cover `wanted_episodes` (a list of
  episode numbers) for a single `season`. Returns `{:ok, [{release, covered_numbers}]}`
  (each release paired with the sorted episode numbers it is responsible for — the
  disjoint set the greedy assigned it) or `:no_match`. The pairing is the single source
  of truth for which episodes each release serves; callers map numbers → episode rows
  from it rather than re-deriving coverage.

  Releases for other seasons (and movies, `season: nil`) are dropped; blocklisted
  titles, out-of-band releases, and releases outside the resolution allow-list (see
  `select/2`) are rejected. The size band is **per-episode**: a
  release covering `k` still-wanted episodes must satisfy `k*min_size ≤ size ≤
  k*max_size` (so a season pack is judged against the episodes it actually supplies).

  Selection is greedy set-cover, which handles packs, ranges, and singles uniformly. Its order is
  decided here (ADR 0003 records why); callers pass facts, never a band rule or a retry:

  1. **Two passes.** The cover first bands every release by the still-wanted episodes it covers.
     Only when that selects nothing does it run again with each whole-season pack banded by
     `max(k, opts[:pack_episode_count])`, the episodes the season holds: the season band (#268).
     With 4 of 22 episodes wanted, a 19.7 GB pack is ~0.9 GB per episode, not 4.9. A pack that
     only fits the season band never competes with an in-band release, so four 1 GB singles
     don't collapse into one 19.7 GB pack, and it waits while in-band releases cover any of the
     want.
  2. **Each greedy step** takes, of what fits the pass's band, a release whose language tag
     satisfies the audio target before an untagged one (#191: untagged covers only what nothing
     tagged in that band can), then the one covering the most still-needed episodes, then the
     best `rank_key/2`. Ties keep input order.

  Partial coverage is fine: the rest stay wanted for the next search tick. `verdict_for_season/4`
  is this rule for one release, which the manual-search panel shows.

  `opts[:pack_episode_count]` is the season's real episode count. Under `full_claim_only` it is
  also what a whole-season pack must claim, in both passes.

  Rules come from per-call `opts`, exactly like `select/2`.
  `opts[:alternate_numbering]` may map alternate season/episode coordinates onto
  canonical wanted episode numbers; only those mapped coordinates are eligible.

  `# ponytail:` greedy, not optimal set-cover. Optimal is NP-hard and pointless at
  household release-list sizes; upgrade only if release sets get pathological.
  """
  def select_for(releases, season, wanted_episodes, opts \\ []) do
    {min_size, max_size, preferred, sources, release_blocklist, _preferred_terms, blocked_terms} =
      rules(opts)

    alternate_numbering = Keyword.get(opts, :alternate_numbering, %{})

    candidates =
      releases
      |> Enum.filter(&coverable_season?(&1, season, alternate_numbering))
      |> Enum.reject(&excluded_title?(&1, release_blocklist, blocked_terms))
      |> Enum.filter(&(allowed_resolution?(&1, preferred) and allowed_source?(&1, sources)))

    coverage_fun = &claimable_coverage(&1, &2, season, alternate_numbering, opts)

    Enum.find_value(pack_episodes_per_pass(opts), :no_match, fn pack_episodes ->
      band = {min_size, max_size, pack_episodes}

      case cover(candidates, MapSet.new(wanted_episodes), [], band, coverage_fun, opts) do
        :no_match -> nil
        selections -> selections
      end
    end)
  end

  # The episodes a whole-season pack is banded by in each pass of `select_for/4`: the still-wanted
  # ones it covers (0 adds nothing to its coverage), then the season band.
  defp pack_episodes_per_pass(opts), do: [0 | List.wrap(Keyword.get(opts, :pack_episode_count))]

  defp pack_episodes(opts), do: Keyword.get(opts, :pack_episode_count) || 0

  @doc """
  Selects releases by resolved stable episode IDs.

  A release is eligible only while every ID it claims is still needed, so the
  greedy cover never truncates one release's durable meaning. Returned IDs keep
  the resolver's membership order rather than database-ID sort order.

  Each greedy step follows `select_for/4`'s order. There is one pass: a whole-season pack is
  banded by `max(k, opts[:pack_episode_count])` at once, as `verdict_for_ids/2` bands it.
  """
  def select_for_ids(releases, wanted_ids, opts \\ []) do
    {min_size, max_size, preferred, sources, release_blocklist, _preferred_terms, blocked_terms} =
      rules(opts)

    band = {min_size, max_size, pack_episodes(opts)}

    result =
      releases
      |> Enum.reject(&excluded_title?(&1, release_blocklist, blocked_terms))
      |> Enum.filter(&(allowed_resolution?(&1, preferred) and allowed_source?(&1, sources)))
      |> cover(MapSet.new(wanted_ids), [], band, &id_coverage/2, opts)

    restore_id_order(result)
  end

  @doc """
  Classifies a single `release` against the same rules `select/2` applies, returning `:ok` or
  `{:rejected, reason}` with `reason` in `[:out_of_band, :blocklisted, :blocked_term,
  :wrong_resolution, :wrong_source]`. Used by the interactive manual-search panel to show WHY the
  auto-pick would skip a release while still letting the user grab it. Shares the private
  predicates with `select/2`, so the panel verdict and the auto-pick can never drift.

  A TV release is banded per episode by what it carries: the episodes it names, its stable ids,
  or `opts[:pack_episode_count]` for a whole-season pack. A season row the cover could take uses
  `verdict_for_season/4` instead.
  """
  def verdict(%Release{} = release, opts \\ []),
    do: classify(release, [episodes_multiplier(release, opts)], opts)

  @doc """
  `verdict/2` for a release the standard season cover takes alone: its size band is
  `select_for/4`'s, both passes included. A release covering `k` still-wanted episodes fits when
  it is in band at `k` episodes, or, for a whole-season pack, at the season band `max(k,
  opts[:pack_episode_count])`. `season`, `wanted_episodes` and `opts` are what `select_for/4`
  takes.

  For a release covering at least one still-wanted episode this is `:ok` exactly when
  `select_for([release], season, wanted_episodes, opts)` matches. So a multi-episode release that
  also names imported episodes is banded by the wanted ones alone, as the cover bands it, though a
  manual grab links every episode it names.

  A release covering none (an upgrade in an imported season, another season's release) is one the
  cover never takes. It keeps `verdict/2`'s band by what it carries: the episodes it names or
  resolves to, else for a whole-season pack the season's episode count, the band the upgrade
  sweep's season pass uses. So the panel still tells the operator whether an upgrade fits.
  """
  def verdict_for_season(%Release{} = release, season, wanted_episodes, opts \\ []) do
    case MapSet.size(season_coverage(release, season, wanted_episodes, opts)) do
      0 ->
        verdict(release, opts)

      k ->
        multipliers = Enum.map(pack_episodes_per_pass(opts), &banded_episodes(release, k, &1))
        classify(release, multipliers, opts)
    end
  end

  # The still-wanted episodes `select_for/4` would assign `release` if it were the only candidate.
  defp season_coverage(release, season, wanted_episodes, opts) do
    numbering = Keyword.get(opts, :alternate_numbering, %{})

    if coverable_season?(release, season, numbering),
      do: claimable_coverage(release, MapSet.new(wanted_episodes), season, numbering, opts),
      else: MapSet.new()
  end

  @doc """
  `verdict/2` for a release the stable-id cover takes alone: its size band is scaled by the stable
  episode ids it resolves to, exactly as `select_for_ids/3` scales it, not by the episodes its name
  lists. For a release whose ids are non-empty, unique and all still wanted (every release the
  anime release judge freezes a mapping for), this is `:ok` exactly when
  `select_for_ids([release], wanted_ids, opts)` matches.
  """
  def verdict_for_ids(%Release{} = release, opts \\ []) do
    ids = release.resolved_episode_ids || []
    classify(release, [banded_episodes(release, length(ids), pack_episodes(opts))], opts)
  end

  # The release is in band when it fits the size band scaled by any of `multipliers`.
  defp classify(release, multipliers, opts) do
    {min_size, max_size, preferred, sources, release_blocklist, _preferred_terms, blocked_terms} =
      rules(opts)

    in_band? =
      Enum.any?(multipliers, &within_band?(release, scale(min_size, &1), scale(max_size, &1)))

    cond do
      not in_band? ->
        {:rejected, :out_of_band}

      title_blocked?(release, release_blocklist) ->
        {:rejected, :blocklisted}

      contains_blocked_term?(release, blocked_terms) ->
        {:rejected, :blocked_term}

      not allowed_resolution?(release, preferred) ->
        {:rejected, :wrong_resolution}

      not allowed_source?(release, sources) ->
        {:rejected, :wrong_source}

      true ->
        :ok
    end
  end

  # `full_claim_only: true` scores a release only while it can claim EVERY episode it carries — the
  # same non-truncating rule `id_coverage/2` applies to stable ids. Only
  # `Cinder.Catalog.UpgradeHunter` passes it: a delivered file it can't link to an episode it holds
  # arrives at import as an operator residual decision (#247), whereas the normal sweep is happy to
  # take a pack for a subset of a season and let the extras be residuals.
  #
  # It belongs HERE, inside the coverage function, for two separate reasons. Rejecting the winner
  # after the fact is useless: `cover/6` is greedy and destructive, so an unclaimable season pack
  # takes the whole wanted set and the singles behind it are never scored — declining it afterwards
  # discards that season's upgrades every pass. And filtering candidates once against the INITIAL
  # want is not enough either: `needed` shrinks with each pick, so a release that overlaps an
  # earlier pick (or that only fits the band at the smaller k) would still be handed a truncated
  # assignment, and its unclaimed files land back in an operator hold. Zero coverage drops it from
  # the round without consuming anything.
  #
  # A whole-season pack carries the season (`pack_episode_count`, the same opt `verdict/2` bands
  # packs with); anything else carries the episodes it names.
  defp claimable_coverage(release, needed, season, alternate_numbering, opts) do
    if unclaimable?(release, needed, opts),
      do: MapSet.new(),
      else: alternate_coverage(release, needed, season, alternate_numbering)
  end

  defp unclaimable?(release, wanted, opts) do
    Keyword.get(opts, :full_claim_only, false) and not claims_all?(release, wanted, opts)
  end

  defp claims_all?(%Release{episodes: eps}, wanted, _opts) when is_list(eps) and eps != [],
    do: MapSet.subset?(MapSet.new(eps), wanted)

  defp claims_all?(%Release{}, wanted, opts),
    do: MapSet.size(wanted) == Keyword.get(opts, :pack_episode_count)

  defp episodes_multiplier(%Release{episodes: eps}, _opts) when is_list(eps) and eps != [],
    do: length(eps)

  defp episodes_multiplier(%Release{resolved_episode_ids: ids}, _opts)
       when is_list(ids) and ids != [],
       do: length(ids)

  defp episodes_multiplier(%Release{season: season}, opts) when not is_nil(season),
    do: Keyword.get(opts, :pack_episode_count) || 1

  defp episodes_multiplier(_movie_release, _opts), do: 1

  @doc """
  The ascending sort key `select/2` ranks by (language → resolution → source → preferred title
  term → larger size). Best sorts first.

  The language rank exists for the untagged releases `Cinder.Acquisition.Language.filter/4` keeps
  under `keep_untagged: true`: a release whose tag actually satisfies the target outranks one that
  merely wasn't ruled out, so untagged only wins when nothing tagged survived the band. It is a
  no-op whenever the language filter is off or every candidate satisfies the target.

  That "only wins when nothing tagged survived" guarantee holds for `select/2`, where this IS the
  sort key, and within each pass of the set-covers, whose greedy step ranks the language term
  ahead of coverage (`select_for/4`, ADR 0003). Across `select_for/4`'s passes the band decides
  first: an untagged single in the still-wanted band is taken before a tagged pack that fits only
  the season band.

  It is skipped entirely under an `:anime_policy`. The anime pools deliberately never run
  `Language.filter/3` (the release judge turns its language stage off under an anime policy)
  while still carrying `:preferred_language`/`:original_language` in `opts`,
  so ranking on the parsed name here would demote the untagged releases that make up most of an
  anime pool — letting a crude `MULTI`/`JAPANESE` token outrank resolution and override the
  evidence-based `AnimePreferences` policy that replaced exactly that heuristic.
  """
  def rank_key(%Release{} = release, opts \\ []) do
    {_min, _max, preferred, sources, _rbl, preferred_terms, _blocked_terms} = rules(opts)

    {anime_rank_key(release, opts), language_rank(release, opts),
     sort_key(release, preferred, sources, preferred_terms)}
  end

  defp language_rank(release, opts) do
    if is_nil(Keyword.get(opts, :anime_policy)),
      do: standard_language_rank(release, opts),
      else: 0
  end

  defp standard_language_rank(release, opts) do
    target =
      Language.target(
        Keyword.get(opts, :preferred_language),
        Keyword.get(opts, :original_language)
      )

    if Language.satisfies_lang?(release.language, target), do: 0, else: 1
  end

  defp anime_rank_key(release, opts) do
    case Keyword.get(opts, :anime_policy) do
      nil -> {0, 0, 0}
      policy -> AnimePreferences.rank_key(release, policy)
    end
  end

  # The normalized rule set, shared by both entry points: the size band, the
  # resolution preference (defaulted), and the downcased release blocklist. Per-call opts
  # only — the old `config :cinder, Scorer` env seam was never set anywhere and is
  # unreachable in the shipped image (operators configure bands via /settings).
  defp rules(rules) do
    {
      Keyword.get(rules, :min_size),
      Keyword.get(rules, :max_size),
      Keyword.get(rules, :preferred_resolutions, @default_preferred),
      Keyword.get(rules, :preferred_sources, []),
      rules |> Keyword.get(:release_blocklist, []) |> Enum.map(&String.downcase/1),
      rules |> Keyword.get(:preferred_terms, []) |> Enum.map(&String.downcase/1),
      rules |> Keyword.get(:blocked_terms, []) |> Enum.map(&String.downcase/1)
    }
  end

  # `band` is one pass's per-episode size bounds plus the episodes a whole-season pack is banded by
  # in that pass.
  defp cover(candidates, needed, chosen, band, coverage_fun, opts) do
    {min_size, max_size, pack_episodes} = band

    scored =
      if MapSet.size(needed) == 0 do
        []
      else
        candidates
        |> Enum.map(fn release -> {release, coverage_fun.(release, needed)} end)
        |> Enum.reject(fn {release, cov} ->
          # Per-episode band: a release covering k still-wanted episodes is judged
          # against k×the band (a pack is allowed proportionally more size), but never
          # against less than the episodes a whole-season pack CARRIES in this pass.
          k = MapSet.size(cov)
          banded = banded_episodes(release, k, pack_episodes)
          k == 0 or not within_band?(release, scale(min_size, banded), scale(max_size, banded))
        end)
      end

    case scored do
      [] -> if chosen == [], do: :no_match, else: {:ok, Enum.reverse(chosen)}
      _ -> take_best(scored, candidates, needed, chosen, band, coverage_fun, opts)
    end
  end

  defp take_best(scored, candidates, needed, chosen, band, coverage_fun, opts) do
    {pick, cov} =
      Enum.min_by(scored, fn {release, coverage} -> pick_key(release, coverage, opts) end)

    covered = cov |> MapSet.to_list() |> Enum.sort()

    cover(
      candidates -- [pick],
      MapSet.difference(needed, cov),
      [{pick, covered} | chosen],
      band,
      coverage_fun,
      opts
    )
  end

  # One greedy step's order (ADR 0003): a release whose tag satisfies the audio target, then the
  # one covering more still-needed episodes, then `rank_key/2`. Ties keep input order.
  defp pick_key(release, coverage, opts),
    do: {language_rank(release, opts), -MapSet.size(coverage), rank_key(release, opts)}

  # A whole-season pack (no episode list) covers every still-needed episode; an
  # episode list covers its intersection with what's still needed.
  defp coverage(%Release{episodes: nil}, needed), do: needed
  defp coverage(%Release{episodes: eps}, needed), do: MapSet.intersection(MapSet.new(eps), needed)

  defp alternate_coverage(
         %Release{season: release_season} = release,
         needed,
         native_season,
         _numbering
       )
       when release_season == native_season,
       do: coverage(release, needed)

  defp alternate_coverage(%Release{season: season} = release, needed, _native, numbering) do
    season_numbering = Map.fetch!(numbering, season)
    episodes = release.episodes || Map.keys(season_numbering)

    covered =
      episodes
      |> Enum.flat_map(&Map.get(season_numbering, &1, []))
      |> MapSet.new()

    MapSet.intersection(covered, needed)
  end

  defp id_coverage(%Release{resolved_episode_ids: resolved_episode_ids}, needed) do
    ids = MapSet.new(resolved_episode_ids || [])
    if MapSet.size(ids) > 0 and MapSet.subset?(ids, needed), do: ids, else: MapSet.new()
  end

  defp restore_id_order({:ok, selections}) do
    {:ok, Enum.map(selections, fn {release, _ids} -> {release, release.resolved_episode_ids} end)}
  end

  defp restore_id_order(:no_match), do: :no_match

  # A release whose indexer omits the size is unsizeable: accept it only when there's no band to
  # enforce. This closes the "0 ≤ max" hole — `size = release.size || 0` used to let an unknown
  # size sail past a configured max_size. With a min_size set it already failed (0 < min), so
  # behaviour there is unchanged; the live bug was max set, min unset.
  defp within_band?(%Release{size: nil}, min_size, max_size),
    do: is_nil(min_size) and is_nil(max_size)

  # One inclusive size-band check for every path. The covers and the verdicts pre-multiply the
  # bounds by the episodes a release is banded by at the call site; `select/2` passes them as-is.
  defp within_band?(%Release{size: size}, min_size, max_size) do
    (is_nil(min_size) or size >= min_size) and (is_nil(max_size) or size <= max_size)
  end

  defp scale(nil, _k), do: nil
  defp scale(size, k), do: k * size

  # The episodes a release CARRIES in a cover pass that bands whole-season packs by `pack_episodes`:
  # a bare-season pack carries the whole season, everything else is banded by its coverage alone.
  # 0 (not 1, unlike `episodes_multiplier/2`) leaves the multiplier at the coverage, which is
  # `select_for/4`'s first pass; running that pass first means the season band can only gain
  # matches, never lose a small pack to a newly-scaled `min_size` (#268). The count is a proxy: an
  # ongoing season's unaired rows inflate it, and a half-season pack ("S05A") parses as a pack of
  # that season.
  defp carried(%Release{episodes: nil, season: season}, pack_episodes) when not is_nil(season),
    do: pack_episodes

  defp carried(_release, _pack_episodes), do: 0

  # The episodes a release covering `k` still-needed ones is banded by in a cover pass that bands
  # whole-season packs by `pack_episodes`. The covers and their verdicts share it.
  defp banded_episodes(release, k, pack_episodes), do: max(k, carried(release, pack_episodes))

  # The cover's season filter: a release of the native season, or of an alternate season the
  # numbering maps.
  defp coverable_season?(%Release{season: release_season}, season, alternate_numbering),
    do: release_season == season or Map.has_key?(alternate_numbering, release_season)

  @doc "Index of a resolution string in the preference list (lower = better); nil/unlisted sorts last."
  def resolution_rank(resolution, preferred) when is_binary(resolution) or is_nil(resolution),
    do: rank_in(resolution, preferred)

  def resolution_rank(%Release{} = release, preferred),
    do: resolution_rank(release.resolution, preferred)

  @doc "Index of a source string in the preference list (lower = better); nil/unlisted sorts last."
  def source_rank(source, preferred) when is_binary(source) or is_nil(source),
    do: rank_in(source, preferred)

  def source_rank(%Release{} = release, preferred),
    do: source_rank(release.source, preferred)

  # Index of value in the preference list (lower = better); nil/unlisted sorts last.
  defp rank_in(value, preferred),
    do: Enum.find_index(preferred, &(&1 == value)) || length(preferred)

  # Exact (downcased) release-name exclusion. The per-item blocklist
  # passes the failed release titles as `release_blocklist`; an untitled release can't match.
  defp title_blocked?(%Release{title: nil}, _list), do: false
  defp title_blocked?(%Release{title: title}, list), do: String.downcase(title) in list

  defp contains_blocked_term?(%Release{title: nil}, _terms), do: false

  defp contains_blocked_term?(%Release{title: title}, terms) do
    title = String.downcase(title)
    Enum.any?(terms, &String.contains?(title, &1))
  end

  defp excluded_title?(release, release_blocklist, blocked_terms),
    do:
      title_blocked?(release, release_blocklist) or contains_blocked_term?(release, blocked_terms)

  # Strict allow-list: keep a release only if its resolution is one the user asked for.
  # nil (untagged) ∉ any list ⇒ rejected. An empty list = no preference configured ⇒ keep all
  # (a [] allow-list rejecting everything is never the intent; that would brick every grab).
  defp allowed_resolution?(_release, []), do: true

  defp allowed_resolution?(%Release{resolution: resolution}, preferred),
    do: resolution in preferred

  # Source allow-list, but LENIENT on untagged (unlike resolution): empty list keeps all;
  # a nil source passes (a parser miss must not strand a grab); only a recognized but unlisted
  # source is rejected.
  defp allowed_source?(_release, []), do: true
  defp allowed_source?(%Release{source: nil}, _preferred), do: true
  defp allowed_source?(%Release{source: source}, preferred), do: source in preferred

  defp pick_best([], _opts), do: :no_match

  defp pick_best(releases, opts), do: {:ok, Enum.min_by(releases, &rank_key(&1, opts))}

  defp sort_key(%Release{} = release, preferred, sources, terms) do
    {resolution_rank(release, preferred), source_rank(release, sources),
     preferred_term_rank(release, terms), -(release.size || 0)}
  end

  defp preferred_term_rank(%Release{title: nil}, terms), do: length(terms)

  defp preferred_term_rank(%Release{title: title}, terms) do
    title = String.downcase(title)
    Enum.find_index(terms, &String.contains?(title, &1)) || length(terms)
  end
end
