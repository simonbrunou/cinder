defmodule Cinder.Acquisition do
  @moduledoc """
  Release acquisition: search an indexer for a movie and pick the best release.

  The indexer is reached only through the `Cinder.Acquisition.Indexer` behaviour,
  resolved from config (`config :cinder, :indexer`) so tests use a Mox mock and
  never hit the network.
  """
  require Logger

  alias Cinder.Acquisition.{Anime, AnimePreferences}
  alias Cinder.Acquisition.Language
  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.Scorer
  alias Cinder.Catalog.{AnimeResolver, Episode}

  @max_alternate_seasons 4
  @standard_tv_bridged_schemes ~w(scene aired)

  @doc """
  Size-band scorer opts for a library `kind` (`:movies`/`:tv`), read from the settings-overlaid
  `:cinder` env (`:movies_min_size`, `:tv_max_size`, …). Only non-nil keys are returned: a nil
  `:preferred_resolutions` or `:preferred_sources` would override the scorer's default, and an
  unset band ⇒ omitted ⇒ `Scorer` keeps its defaults (unbounded / default resolutions / any source).
  Both pollers pass these through to `Scorer`, so the movie and TV bands are configured the same way.
  """
  def band_opts(kind) do
    [
      min_size: Application.get_env(:cinder, :"#{kind}_min_size"),
      max_size: Application.get_env(:cinder, :"#{kind}_max_size"),
      preferred_resolutions: Application.get_env(:cinder, :"#{kind}_preferred_resolutions"),
      preferred_sources: Application.get_env(:cinder, :"#{kind}_preferred_sources")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Searches the configured indexer for `imdb_id`, parses each result, and returns
  the best release per `Scorer` rules. `opts` are forwarded to `Scorer.select/2`.

  When `opts[:protocols]` is given (a list of `:torrent`/`:usenet`), releases on
  any other protocol are dropped before scoring — this is the graceful-degradation
  guard, so a release with no configured download client is never chosen.
  Omitting the option keeps every protocol.

  Returns `{:ok, %Release{}}`, `:no_match` (no results, or none survive the rules),
  `:no_language_match` (a non-empty candidate set was fully removed by an active per-item
  language preference), or `{:error, term}` (indexer failure, passed through).
  """
  def best_release(imdb_id, opts \\ []) do
    case indexer().search(imdb_id) do
      {:ok, raw_results} ->
        case movie_pool(Enum.map(raw_results, &Release.new/1), opts) do
          :no_language_match -> :no_language_match
          pool -> Scorer.select(pool, opts)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Free-text fallback for a movie TMDB publishes no IMDb id for (issue #195): a `"Title Year"`
  `moviesearch` instead of the `{ImdbId:...}` token, then the same title guard the free-text TV
  path uses plus a year-token check, re-establishing the identity the id token would have pinned.
  Returns the same values as `best_release/2`.
  """
  def best_release_by_title(title, year, opts \\ []) do
    with {:ok, releases} <- title_search(title, year) do
      case releases |> filter_movie_title(title, year) |> movie_pool(opts) do
        :no_language_match -> :no_language_match
        pool -> Scorer.select(pool, opts)
      end
    end
  end

  @doc "Searches additive anime movie queries and selects through the standard hard rules."
  def best_anime_movie(imdb_id, context, opts \\ []) do
    with {:ok, releases, failed?} <- Anime.search_movie(indexer(), imdb_id, context, opts) do
      case anime_movie_pool(releases, opts) do
        :no_language_match ->
          :no_language_match

        pool ->
          Anime.select_movie(pool, Keyword.put(opts, :incomplete_search?, failed?))
      end
    end
  end

  @doc """
  Searches the configured indexer for one TV `season` of `series`, parses each
  result, on the free-text path keeps only releases whose name plausibly matches
  the series title, and returns the chosen releases — each paired with the episode
  numbers it covers — per `Scorer.select_for/4`. `wanted_numbers` is the
  still-wanted episode-number set for that season.

  `opts[:protocols]` drops releases on any other protocol before scoring (same
  graceful-degradation guard as `best_release/2`); `opts` is otherwise forwarded
  to the scorer.

  Returns `{:ok, [{%Release{}, [number]}]}`, `:no_match`, or `{:error, term}`.

  The title guard rejects an obviously-wrong series from a free-text (title-only)
  indexer search — it applies ONLY when `series.tvdb_id` is nil; a TvdbId-token
  search is already scoped to the right show. `select_for` matches only on
  season number, so without this a same-season release of another show could be
  grabbed. It is a boundary-anchored token-run match (see `title_matches?/2`); it
  cannot disambiguate same-named variants (a US vs UK edition) or spinoffs that
  share the title as a prefix ("9-1-1" vs "9-1-1: Lone Star"), and it fails closed
  for titles that fold to nothing (non-Latin scripts) — all of those rely on the
  `tvdb_id`-based search (M6 reconciliation).

  When `opts[:alternate_numbering]` is present, the mapped scene seasons are searched
  additively and the same map is forwarded to `Scorer.select_for/4`.
  """
  def best_releases(series, season_number, wanted_numbers, opts \\ []) do
    alternate_seasons =
      opts
      |> Keyword.get(:alternate_numbering, %{})
      |> Map.keys()
      |> Enum.reject(&(&1 == season_number))
      |> Enum.sort()

    case search_tv_seasons(indexer(), series, [season_number | alternate_seasons]) do
      {:ok, raw_results} ->
        preferred = Keyword.get(opts, :preferred_language)
        original = Keyword.get(opts, :original_language)

        candidates =
          raw_results
          |> Enum.map(&Release.new/1)
          |> filter_protocols(Keyword.get(opts, :protocols))
          |> filter_title(series)

        # A strict total-wipe collapses to [] → select_for → :no_match → the tv_poller bump path.
        cover_set =
          case language_pool(candidates, preferred, original) do
            :no_language_match -> []
            pool -> pool
          end

        Scorer.select_for(cover_set, season_number, wanted_numbers, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp search_tv_seasons(indexer, series, [season_number]) do
    indexer.search_tv(series.tvdb_id, series.title, season_number)
  end

  defp search_tv_seasons(indexer, series, season_numbers) do
    Enum.reduce_while(season_numbers, {:ok, []}, fn season_number, {:ok, batches} ->
      case indexer.search_tv(series.tvdb_id, series.title, season_number) do
        {:ok, raw_results} -> {:cont, {:ok, [raw_results | batches]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, batches} -> {:ok, batches |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  @doc "Selects anime episodic releases by stable Catalog episode IDs."
  def best_anime_releases(context, wanted_episode_ids, opts \\ []) do
    Anime.best_episodes(indexer(), context, wanted_episode_ids, opts)
  end

  @doc """
  Lists EVERY parsed release for `imdb_id`, each paired with the scorer's verdict (`:ok` or
  `{:rejected, reason}`), sorted acceptable-first then best-ranked. Unlike `best_release/2` it
  does not drop or collapse — the interactive manual-search panel shows them all and lets the
  user grab any (overriding the band/blocklist). `opts[:protocols]` adds a `:wrong_protocol`
  verdict for releases with no configured client (still listed, but the panel disables grab).
  """
  def list_releases(imdb_id, opts \\ []) do
    case indexer().search(imdb_id) do
      {:ok, raw} -> {:ok, annotate(Enum.map(raw, &Release.new/1), opts)}
      {:error, _} = error -> error
    end
  end

  @doc "Manual-search variant of `best_release_by_title/3`, listing every guarded candidate."
  def list_releases_by_title(title, year, opts \\ []) do
    with {:ok, releases} <- title_search(title, year), do: {:ok, annotate(releases, opts)}
  end

  @doc """
  The releases automatic selection's title guard would keep for `target` — all of them when no
  guard applies, an id-scoped search being identity-scoped already. The manual panel lists
  guarded-away rows on purpose, so it needs this to tell a candidate-pool survivor from a row the
  sweep never sees; re-deriving the guard there would drift from these clauses.
  """
  def title_guard(releases, :movie, %{imdb_id: imdb_id, title: title, year: year})
      when imdb_id in [nil, ""],
      do: filter_movie_title(releases, title, year)

  def title_guard(releases, :tv, series), do: filter_title(releases, series)
  def title_guard(releases, _mode, _target), do: releases

  @doc """
  TV variant of `list_releases/2`. A `:standard_numbering` result from
  `standard_tv_numbering/3` adds the same bounded alternate-season queries used by automatic
  acquisition and freezes each bridged release's resolved Catalog episode ids.
  """
  def list_releases_tv(series, season_number, opts \\ []) do
    numbering = Keyword.get(opts, :standard_numbering)

    alternate_seasons =
      case numbering do
        %{search_seasons: seasons} -> seasons
        _none -> []
      end

    seasons = [season_number | Enum.reject(alternate_seasons, &(&1 == season_number))]

    case search_tv_seasons(indexer(), series, seasons) do
      {:ok, raw} ->
        releases =
          raw
          |> Enum.map(&Release.new/1)
          |> deduplicate_tv_releases()
          |> Enum.map(&resolve_standard_manual_release(&1, season_number, numbering))

        {:ok, annotate(releases, Keyword.delete(opts, :standard_numbering))}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Derives the bounded scene/TVDB-aired bridge used by Standard TV acquisition.

  `scorer` is the canonical-number map consumed by automatic selection. Manual search also uses
  `search_seasons`, stable `episode_ids`, and `conflicts` so its later grab cannot reinterpret an
  alternate-numbered release through native episode numbers.
  """
  def standard_tv_numbering(context, episodes, native_seasons) do
    wanted_by_id = Map.new(episodes, &{&1.id, &1.episode_number})
    wanted_ids = MapSet.new(Map.keys(wanted_by_id))
    mappings = prefer_scene_mappings(context.mappings, wanted_ids)

    relevant =
      Enum.filter(mappings, fn mapping ->
        mapping.identity.scheme in @standard_tv_bridged_schemes and
          not MapSet.disjoint?(MapSet.new(mapping.episode_ids), wanted_ids)
      end)

    alternate_seasons =
      relevant
      |> Enum.map(&Episode.season_from_code(&1.identity.canonical_value))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@max_alternate_seasons)

    initial = %{
      scorer: %{},
      search_seasons: alternate_seasons,
      episode_ids: %{},
      conflicts: MapSet.new()
    }

    relevant
    |> Enum.map(& &1.identity.canonical_value)
    |> Enum.uniq()
    |> Enum.reduce(initial, fn value, numbering ->
      with {alternate_season, alternate_episode} <-
             Episode.season_and_episode_from_code(value),
           false <- MapSet.member?(native_seasons, alternate_season),
           true <- alternate_season in alternate_seasons do
        put_standard_resolution(
          numbering,
          value,
          alternate_season,
          alternate_episode,
          resolve_standard_coordinate(value, mappings),
          wanted_by_id,
          wanted_ids
        )
      else
        _unusable -> numbering
      end
    end)
  end

  @doc "Lists Anime movie releases with manual, overridable policy verdicts."
  def list_anime_movie_releases(imdb_id, context, opts) do
    with {:ok, releases, _failed?} <- Anime.search_movie(indexer(), imdb_id, context, opts) do
      {:ok, releases |> Anime.manual_movie_candidates(opts) |> annotate(opts)}
    end
  end

  @doc "Lists Anime episode releases with frozen stable-ID mappings when resolvable."
  def list_anime_episode_releases(context, wanted_ids, opts) do
    with {:ok, releases, _failed?} <- Anime.search_episodes(indexer(), context, wanted_ids, opts) do
      manual_opts = Keyword.put(opts, :manual_anime_tv, true)

      {:ok,
       releases
       |> Anime.manual_episode_candidates(context, wanted_ids, opts)
       |> annotate(manual_opts)}
    end
  end

  defp annotate(releases, opts) do
    protocols = Keyword.get(opts, :protocols)

    releases
    |> Enum.map(fn release -> {release, release_verdict(release, protocols, opts)} end)
    |> Enum.sort_by(fn {release, verdict} -> {verdict != :ok, Scorer.rank_key(release, opts)} end)
  end

  defp release_verdict(%Release{} = release, protocols, opts) do
    cond do
      is_list(protocols) and not is_nil(release.protocol) and release.protocol not in protocols ->
        {:rejected, :wrong_protocol}

      release.resolution_evidence == :conflicting_standard_numbering ->
        {:rejected, :conflicting_standard_numbering}

      Keyword.get(opts, :manual_anime_tv, false) and not safe_anime_mapping?(release) ->
        {:rejected, :unsafe_anime_mapping}

      policy = Keyword.get(opts, :anime_policy) ->
        anime_manual_verdict(release, policy, opts)

      true ->
        Scorer.verdict(release, opts)
    end
  end

  defp anime_manual_verdict(release, policy, opts) do
    case AnimePreferences.verdict(release, policy) do
      :ok -> anime_timing_verdict(release, policy, opts)
      rejection -> rejection
    end
  end

  defp anime_timing_verdict(release, %{preferred_groups: []}, opts),
    do: Scorer.verdict(release, opts)

  defp anime_timing_verdict(release, policy, opts) do
    if AnimePreferences.normalize_group(release.group) in policy.preferred_groups do
      Scorer.verdict(release, opts)
    else
      fallback_timing_verdict(release, policy, opts)
    end
  end

  defp fallback_timing_verdict(
         %Release{published_at: %DateTime{} = published_at} = release,
         policy,
         opts
       ) do
    retry_at = DateTime.add(published_at, policy.group_fallback_delay, :second)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    if DateTime.compare(retry_at, now) == :gt,
      do: {:rejected, :awaiting_preferred_group},
      else: Scorer.verdict(release, opts)
  end

  defp fallback_timing_verdict(_release, _policy, _opts),
    do: {:rejected, :publication_time_required}

  defp safe_anime_mapping?(%Release{
         resolved_episode_ids: ids,
         mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => reserved}
       })
       when is_list(ids) and ids != [],
       do: ids == reserved

  defp safe_anime_mapping?(_release), do: false

  defp put_standard_resolution(
         numbering,
         value,
         alternate_season,
         alternate_episode,
         {:ok, episode_ids, _evidence},
         wanted_by_id,
         wanted_ids
       ) do
    if MapSet.subset?(MapSet.new(episode_ids), wanted_ids) do
      canonical_numbers = Enum.map(episode_ids, &Map.fetch!(wanted_by_id, &1))

      numbering
      |> put_in([:episode_ids, value], episode_ids)
      |> update_in([:scorer], fn scorer ->
        Map.update(
          scorer,
          alternate_season,
          %{alternate_episode => canonical_numbers},
          &Map.put(&1, alternate_episode, canonical_numbers)
        )
      end)
    else
      update_in(numbering.conflicts, &MapSet.put(&1, value))
    end
  end

  defp put_standard_resolution(
         numbering,
         value,
         _season,
         _episode,
         _unresolved,
         _wanted_by_id,
         _wanted_ids
       ),
       do: update_in(numbering.conflicts, &MapSet.put(&1, value))

  defp prefer_scene_mappings(mappings, wanted_ids) do
    scene_ids =
      mappings
      |> Enum.filter(&(&1.identity.scheme == "scene"))
      |> Enum.flat_map(& &1.episode_ids)
      |> MapSet.new()
      |> MapSet.intersection(wanted_ids)

    {mappings, dropped_ids} =
      Enum.map_reduce(mappings, MapSet.new(), fn
        %{identity: %{scheme: "aired"}} = mapping, dropped_ids ->
          shadowed = MapSet.intersection(MapSet.new(mapping.episode_ids), scene_ids)

          mapping = %{
            mapping
            | episode_ids: Enum.reject(mapping.episode_ids, &MapSet.member?(shadowed, &1))
          }

          {mapping, MapSet.union(dropped_ids, shadowed)}

        mapping, dropped_ids ->
          {mapping, dropped_ids}
      end)

    if MapSet.size(dropped_ids) > 0 do
      Logger.warning(
        "standard TV numbering: ignored TVDB aired coordinates for " <>
          "#{MapSet.size(dropped_ids)} episode(s) because scene coordinates take precedence"
      )
    end

    Enum.reject(mappings, &(&1.episode_ids == []))
  end

  defp resolve_standard_coordinate(value, mappings) do
    matching =
      mappings
      |> Enum.filter(
        &(Map.get(&1.identity, :scheme) in ["standard" | @standard_tv_bridged_schemes] and
            Map.get(&1.identity, :canonical_value) == value)
      )
      |> AnimeResolver.strip_shadowed_canonical()

    resolver_mappings =
      Enum.map(matching, fn mapping ->
        %{
          coordinate: mapping.identity,
          episode_ids: mapping.episode_ids,
          precedence: mapping.precedence,
          evidence: mapping.evidence
        }
      end)

    AnimeResolver.resolve(Enum.map(matching, & &1.identity), resolver_mappings)
  end

  defp resolve_standard_manual_release(release, native_season, numbering)

  defp resolve_standard_manual_release(
         %Release{season: native_season} = release,
         native_season,
         _
       ),
       do: release

  defp resolve_standard_manual_release(%Release{} = release, _native_season, %{
         episode_ids: episode_ids,
         conflicts: conflicts
       }) do
    values = standard_release_values(release, Map.keys(episode_ids) ++ MapSet.to_list(conflicts))

    cond do
      Enum.any?(values, &MapSet.member?(conflicts, &1)) ->
        %{release | resolution_evidence: :conflicting_standard_numbering}

      ids = values |> Enum.flat_map(&Map.get(episode_ids, &1, [])) |> Enum.uniq() ->
        if ids == [], do: release, else: %{release | resolved_episode_ids: ids}
    end
  end

  defp resolve_standard_manual_release(%Release{} = release, _native_season, _none), do: release

  defp standard_release_values(%Release{season: season, episodes: nil}, known_values)
       when is_integer(season) do
    Enum.filter(known_values, &(Episode.season_from_code(&1) == season))
  end

  defp standard_release_values(%Release{season: season, episodes: episodes}, _known_values)
       when is_integer(season) and is_list(episodes) do
    Enum.map(episodes, &Episode.code(season, &1))
  end

  defp standard_release_values(_release, _known_values), do: []

  defp deduplicate_tv_releases(releases) do
    Enum.uniq_by(releases, fn
      %Release{download_url: url, protocol: protocol} when is_binary(url) and url != "" ->
        {protocol, url}

      %Release{} = release ->
        {release.protocol, release.title, release.size}
    end)
  end

  # Resolve the candidate pool a language preference scores against. An explicit-language pick
  # (french) with nothing satisfying it returns :no_language_match so the caller parks visibly;
  # a soft Original/Any pick falls back to the unfiltered candidates. The parser tags `language`
  # from the whole release name, so a title-word collision (e.g. "The Italian Job" → ITALIAN)
  # must not strand a title under the default — hence Original/Any is soft, an explicit pick strict.
  defp language_pool(candidates, preferred, original, filter_opts \\ []) do
    case Language.filter(candidates, preferred, original, filter_opts) do
      [] when candidates != [] ->
        if Language.strict?(preferred), do: :no_language_match, else: candidates

      filtered ->
        filtered
    end
  end

  # `keep_untagged: true` is movie-only on purpose: this pool feeds `Scorer.select/2`, where
  # `rank_key/2` IS the sort key, so an untagged release can only win when nothing tagged survives
  # the band. The TV/anime pools feed the set-cover selectors, which sort by coverage first and
  # would let an untagged pack beat confirmed-original singles — see `Language.keep?/3`.
  defp movie_pool(releases, opts) do
    candidates = filter_protocols(releases, Keyword.get(opts, :protocols))
    preferred = Keyword.get(opts, :preferred_language)
    original = Keyword.get(opts, :original_language)
    language_pool(candidates, preferred, original, keep_untagged: true)
  end

  defp anime_movie_pool(releases, opts) do
    case Keyword.get(opts, :anime_policy) do
      nil -> movie_pool(releases, opts)
      _policy -> filter_protocols(releases, Keyword.get(opts, :protocols))
    end
  end

  # The title guard protects only the free-text (title-only) fallback search. A
  # TvdbId-token search is already scoped to the right series by the indexer, and
  # normalization cannot equate AKA titles ("Money Heist" vs "La.Casa.de.Papel"),
  # so filtering there would strand whole seasons at :no_match.
  #
  # Token-run matching: the folded series title must equal the concatenation of a contiguous
  # run of WHOLE release-name tokens — boundary-anchored at both ends. So series "24" matches
  # "24.S01E05" and the tag-prefixed "[TGx] 24.S01E05" but not "Other.Show.2024..." (no "24"
  # token), and "Dark" no longer substring-matches "Darkwing.Duck...". Concatenating the run
  # keeps acronym/possessive/fused variants working ("S.W.A.T." ⇔ "SWAT", "Grey's" ⇔ "Greys",
  # "The Office" ⇔ "TheOffice"). Documented ceilings (need the tvdb_id-scoped path): a spinoff
  # sharing the title as a leading run ("9-1-1" accepts "9-1-1.Lone.Star..."), a different
  # show carrying the title as one of its own tokens ("Reno.911" for series "9-1-1"), and
  # same-named variants.
  defp filter_title(candidates, %{tvdb_id: nil, title: title} = series),
    do: candidates |> filter_by_title(title) |> reject_year_conflicts(series)

  defp filter_title(candidates, series), do: reject_year_conflicts(candidates, series)

  # The tvdb_id-scoped query used to guarantee same-show results, but search_tv/3 now
  # unions in a free-text title query (so scraper indexers contribute — see
  # Indexer.Prowlarr), which can surface a same-named different show: "Charmed (2018)"
  # packs for the year-1998 series. An explicit year token is the one discriminator
  # scene names reliably carry, so a candidate is dropped only when every year in its
  # title is more than a year off the series year (±1 absorbs premiere-date wobble
  # between TMDB and scene naming). Yearless titles pass — same loose-on-purpose
  # trade-off as filter_by_title/2, and the manual panel still lists what this drops.
  defp reject_year_conflicts(candidates, %{year: year}) when is_integer(year),
    do: Enum.reject(candidates, &year_conflict?(&1.title, year))

  defp reject_year_conflicts(candidates, _series), do: candidates

  defp year_conflict?(release_title, year) do
    case Regex.scan(~r/\b(?:19|20)\d{2}\b/, release_title) do
      [] -> false
      matches -> Enum.all?(matches, fn [y] -> abs(String.to_integer(y) - year) > 1 end)
    end
  end

  defp filter_by_title(candidates, title) do
    case title_needle(title) do
      "" -> []
      needle -> Enum.filter(candidates, &token_run_match?(tokens(&1.title), needle))
    end
  end

  # The free-text movie search an absent IMDb id degrades to. Unguarded on purpose: automatic
  # selection filters below, but the manual panel must keep listing everything (see
  # `list_releases/2`) — the guard is deliberately strict, so a title convention it fails closed on
  # is exactly when the operator needs to see and override the rows.
  defp title_search(title, year) do
    query = [title, year] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    case indexer().search_movie_query(query, []) do
      {:ok, raw} -> {:ok, Enum.map(raw, &Release.new/1)}
      {:error, _reason} = error -> error
    end
  end

  # Scene movie names are `Title.Year.rest`, so with a known year BOTH ends of the title are
  # pinnable and the guard demands exactly that: everything before the year token concatenates to
  # the title, nothing more. The run-anywhere match `filter_title/2` uses is far too loose here —
  # it accepts "Dune.Drifter.2021" AND "Sand.Dune.2021" for "Dune (2021)", and the scorer would
  # then pick whichever is bigger. With no IMDb id to fall back on, over-strictness costs an honest
  # :no_match while looseness imports the wrong film — and the manual panel still lists what this
  # drops. A movie with no year of its own gets the same shape, anchored per `anchor_indexes/2`.
  defp filter_movie_title(candidates, title, year) do
    case title_needle(title) do
      "" -> []
      needle -> Enum.filter(candidates, &movie_title_match?(&1.title, needle, year))
    end
  end

  defp movie_title_match?(release_title, needle, year) do
    tokens = untagged_tokens(release_title)

    tokens
    |> anchor_indexes(year)
    |> Enum.any?(&(tokens |> Enum.take(&1) |> Enum.join() == needle))
  end

  # Where the release year may sit. With a known year every occurrence is a candidate —
  # "Blade.Runner.2049.2017" is the 2017 film whose title also ends in a year. With no year to
  # match, only the LAST year-like token can be it: trying them all would take that same release
  # for plain "Blade Runner" (anchoring on the 2049 in its title).
  defp anchor_indexes(tokens, nil) do
    case tokens |> Enum.reverse() |> Enum.find_index(&Regex.match?(~r/^(?:19|20)\d{2}$/, &1)) do
      nil -> []
      from_end -> [length(tokens) - from_end - 1]
    end
  end

  defp anchor_indexes(tokens, year) do
    target = Integer.to_string(year)
    for {^target, index} <- Enum.with_index(tokens), do: index
  end

  # Tag-prefixed names ("[TGx] Dune.2021...") are common and would otherwise fail the start anchor.
  defp untagged_tokens(release_title),
    do: release_title |> String.replace(~r/^\s*\[[^\]\r\n]+\]\s*/u, "") |> tokens()

  # Fail closed when tokenization ate most of the title: a non-Latin title ("Дом") folds to
  # nothing, "Дом 2" to a bare "2" — a remnant that would match almost anything and import the
  # wrong show. Both sides of the ratio start from the same fold/1 so an "&"→"and" expansion
  # can't inflate the needle past the check. Those series can't be safely matched by name; the
  # tvdb_id-scoped search (which skips this guard entirely) is the escape hatch.
  @doc """
  Whether `name` — a release name or a file name — **leads with** `target`'s title: the folded
  title has to be spelled by `name`'s tokens starting at the first one, and the token after it has
  to open a release tag (a season/episode marker, or a year consistent with `target.year`) rather
  than continue a show's name.

  Stricter than `title_guard/3`'s `token_run_match?/2`, which is boundary-anchored but free-floating
  and accepts a leading run without caring what follows. The import calls this to decide whether a
  file it is about to **discard** really belongs to the series (`Cinder.Library`'s residual drop,
  #262), and a discard is unrecoverable, so it must not be a guess. The extra anchoring closes two
  of `filter_title/2`'s documented ceilings: a spinoff extending the title ("9-1-1: Lone Star"
  under "9-1-1", "Law & Order: SVU" under "Law & Order") is rejected here, and a title appearing as
  some other show's inner token was never reachable from index 0.

  Shares the same fold, so everything `filter_title/2` is built to accept still matches:
  "S.W.A.T." ⇔ "SWAT", "Grey's" ⇔ "Greys", "Law & Order" ⇔ "Law.and.Order", "Pokémon" ⇔ "Pokemon".
  A title that folds to too little to be safe (`title_needle/1` returning "") matches nothing —
  fail-closed, same escape hatch as the search guard.
  """
  @spec names_title?(String.t() | nil, %{title: String.t() | nil, year: integer() | nil}) ::
          boolean()
  def names_title?(name, %{title: title} = target) do
    case title_needle(title) do
      "" -> false
      needle -> name |> tokens() |> consume_leading(needle) |> release_tag_next?(target)
    end
  end

  # {:ok, tokens_after_the_title} once the needle is exactly spelled, :error otherwise.
  defp consume_leading(_tokens, ""), do: :error
  defp consume_leading([], _needle), do: :error

  defp consume_leading([token | rest], needle) do
    case String.replace_prefix(needle, token, "") do
      ^needle -> :error
      "" -> {:ok, rest}
      remaining -> consume_leading(rest, remaining)
    end
  end

  # The episode-marker spellings `Parser.parse/1` itself claims, so a file the import matched is
  # always confirmable here: `S01`, `S01E05`, the GLUED multi-episode `S01E05E06` (its hyphenated
  # twin `S01E05-E06` already splits into two tokens), a bare `E05`, and the `1x05` cross form.
  # Anything narrower re-opens the operator hold #251 removed for exactly the combined-episode
  # files `fully_held?/3` exists to count.
  @episode_marker ~r/^(?:s\d{1,3}(?:e\d+)*|(?:e\d+)+|\d{1,2}x\d{1,2})$/
  @year_marker ~r/^(?:19|20)\d{2}$/

  defp release_tag_next?(:error, _target), do: false
  defp release_tag_next?({:ok, []}, _target), do: false

  defp release_tag_next?({:ok, [next | _]}, target) do
    cond do
      Regex.match?(@episode_marker, next) ->
        true

      # A year token is a release tag only if it is OUR year — the same discriminator, and the
      # same ±1 tolerance, `reject_year_conflicts/2` uses for "Charmed (2018)" against the 1998
      # series; without it `The.Office.2005.S01E05` is discarded under a different The Office.
      #
      # An unknown series year rejects rather than accepting, which is where this DIVERGES from
      # `reject_year_conflicts/2`. That clause fails open because filtering a search too hard
      # strands a season at :no_match — annoying, recoverable. Here the same "no opinion" would
      # authorise deleting a file we cannot place. Same missing datum, opposite safe direction.
      Regex.match?(@year_marker, next) ->
        is_integer(Map.get(target, :year)) and not year_conflict?(next, target.year)

      true ->
        false
    end
  end

  defp title_needle(series_title) do
    needle = series_title |> tokens() |> Enum.join()

    significant =
      (series_title || "")
      |> fold()
      |> String.replace(~r/[^\p{L}\p{N}]/u, "")
      |> String.length()

    if String.length(needle) * 2 >= significant, do: needle, else: ""
  end

  # Letters NFD can't decompose to ASCII (the strip below would otherwise eat them mid-token:
  # "Æon Flux" ⇒ ["on", "flux"], unmatchable against "Aeon.Flux..."). ASCII-ized forms are how
  # release names spell them.
  @transliterations %{
    "æ" => "ae",
    "œ" => "oe",
    "ø" => "o",
    "ß" => "ss",
    "ð" => "d",
    "đ" => "d",
    "ł" => "l",
    "þ" => "th"
  }

  # Downcase, spell out "&" (scene names always write "and", TMDB keeps the ampersand), drop
  # possessive apostrophes ("Grey's" ⇒ "greys"), transliterate the non-decomposable letters.
  defp fold(title) do
    title
    |> String.downcase()
    |> String.replace("&", "and")
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[æœøßðđłþ]/u, &Map.fetch!(@transliterations, &1))
  end

  # fold/1 → NFD-decompose (so ASCII-ized "Pokemon" still matches "Pokémon") → strip non-ASCII
  # (the combining marks NFD exposed, plus non-Latin scripts) → split on separator runs.
  # "Grey's Anatomy" ⇒ ["greys", "anatomy"], "9-1-1" ⇒ ["9", "1", "1"].
  defp tokens(nil), do: []

  defp tokens(title) do
    title
    |> fold()
    |> nfd()
    |> String.replace(~r/[^\x00-\x7f]/u, "")
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  # Does any contiguous run of whole tokens concatenate to exactly `needle`?
  defp token_run_match?([], _needle), do: false

  defp token_run_match?([_ | rest] = hay, needle),
    do: run_consumes?(hay, needle) or token_run_match?(rest, needle)

  defp run_consumes?(_tokens, ""), do: true
  defp run_consumes?([], _needle), do: false

  defp run_consumes?([token | rest], needle) do
    # Tokens are never "" (split with trim: true), so an unchanged needle means "not a prefix".
    case String.replace_prefix(needle, token, "") do
      ^needle -> false
      remaining -> run_consumes?(rest, remaining)
    end
  end

  # :unicode.characters_to_nfd_binary returns {:error, _, _} on malformed UTF-8; fall back to the
  # raw (downcased) string so a garbled indexer title can't raise and permanently stall a season's
  # search pass (the raise would be caught per-group by the poller, but that group never progresses).
  defp nfd(string) do
    case :unicode.characters_to_nfd_binary(string) do
      binary when is_binary(binary) -> binary
      _ -> string
    end
  end

  defp filter_protocols(releases, nil), do: releases

  defp filter_protocols(releases, allowed),
    do: Enum.filter(releases, &(&1.protocol in allowed))

  # Resolve the impl at runtime (not compile_env!) so the test Mox module — defined
  # at runtime — doesn't warn under --warnings-as-errors. fetch_env! fails fast if unset.
  defp indexer, do: Application.fetch_env!(:cinder, :indexer)
end
