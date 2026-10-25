defmodule Cinder.Acquisition do
  @moduledoc """
  Release acquisition: search an indexer for a movie and pick the best release.

  The indexer is reached only through the `Cinder.Acquisition.Indexer` behaviour,
  resolved from config (`config :cinder, :indexer`) so tests use a Mox mock and
  never hit the network.
  """
  require Logger

  alias Cinder.Acquisition.{Anime, AnimeParser}
  alias Cinder.Acquisition.Release
  alias Cinder.Acquisition.ReleaseJudge
  alias Cinder.Acquisition.Scorer
  alias Cinder.Catalog.{AnimeResolver, Episode}

  @max_alternate_seasons 4
  @standard_tv_bridged_schemes ~w(scene aired)

  @doc """
  The release the movie sweep grabs for the movie `context` describes
  (`Cinder.Catalog.movie_acquisition_context/1`): `judge_movie/3`'s pick
  (`Cinder.Acquisition.ReleaseJudge.pick/1`). `opts` is the household policy
  (`Cinder.Acquisition.HouseholdPolicy.for_target/2`).

  Returns `{:ok, %Release{}}`, `:no_match` (no results, or none survive the rules),
  `:no_language_match` (a strict audio pick removed every candidate), or `{:error, term}`
  (indexer failure, passed through).
  """
  def best_release(imdb_id, context, opts \\ []) do
    with {:ok, judged} <- judge_movie(imdb_id, context, opts), do: ReleaseJudge.pick(judged)
  end

  @doc """
  Searches the indexer for a movie and judges every result (`Cinder.Acquisition.ReleaseJudge`).
  The sweep picks from it (`best_release/3`) and the manual-search panel lists it.

  With an IMDb id the search is `{ImdbId:...}`-scoped. That scope is not identity proof, so a
  release must still spell one of the movie's known titles (`{:imdb, context}`). With a nil or
  blank id (TMDB publishes none for some titles, #195) it is a free-text `"Title Year"` search,
  and the stricter Title.Year guard re-establishes the identity the id would have pinned
  (`{:title_year, title, year}`). The guard follows the id that was searched, not
  `context.imdb_id`: the sweep can fetch an id the context doesn't carry yet.
  """
  def judge_movie(imdb_id, context, opts \\ [])

  def judge_movie(imdb_id, context, opts) when imdb_id in [nil, ""] do
    with {:ok, releases} <- title_search(context.title, context.year),
         do: {:ok, ReleaseJudge.judge(releases, {:title_year, context.title, context.year}, opts)}
  end

  def judge_movie(imdb_id, context, opts) do
    case indexer().search(imdb_id) do
      {:ok, raw} ->
        {:ok, ReleaseJudge.judge(Enum.map(raw, &Release.new/1), {:imdb, context}, opts)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  The release the anime movie sweep grabs: `judge_anime_movie/3`'s pick
  (`Cinder.Acquisition.ReleaseJudge.pick/1`). `opts` is the household policy plus `anime_policy:`.

  Returns what the pick returns (`{:ok, %Release{}}`, `:no_match`, `:no_language_match`,
  `{:waiting_for_preferred_group, %{retry_at: retry_at}}`), `{:error, :incomplete_search}` when
  nothing matched and some query failed (the release it needed may be behind the failure), or
  `{:error, term}` when every query failed.
  """
  def best_anime_movie(imdb_id, context, opts \\ []) do
    with {:ok, judged, incomplete?} <- judge_anime_movie(imdb_id, context, opts) do
      case ReleaseJudge.pick(judged) do
        :no_match when incomplete? -> {:error, :incomplete_search}
        result -> result
      end
    end
  end

  @doc """
  Runs the anime movie queries and judges every result (`Cinder.Acquisition.ReleaseJudge`, guard
  `{:anime_movie, context}`), for the manual-search panel. The sweep picks from the same record
  (`best_anime_movie/3`).

  Returns `{:ok, judged, incomplete?}` or `{:error, term}`
  (`Cinder.Acquisition.Anime.judge_movie/4`).
  """
  def judge_anime_movie(imdb_id, context, opts \\ []),
    do: Anime.judge_movie(indexer(), imdb_id, context, opts)

  @doc """
  Searches the configured indexer for one TV `season` of `series` and returns the chosen
  releases, each paired with the episode numbers it covers, per `Scorer.select_for/4`.
  `wanted_numbers` is the still-wanted episode-number set for that season.

  The set-cover runs over what the release judge keeps (`Cinder.Acquisition.ReleaseJudge`,
  guard `{:series, series, season_number, wanted_numbers}`): releases with a download client,
  whose name is the series' (see `title_guard/2`), that satisfy the audio pick. A strict pick
  that removes every candidate leaves nothing to cover, so the season is `:no_match`. `opts` is
  the household policy (`Cinder.Acquisition.HouseholdPolicy.for_target/2`) plus the facts the
  set-cover reads, such as `opts[:pack_episode_count]`, the season's real episode count
  (`Scorer.select_for/4`).

  Returns `{:ok, [{%Release{}, [number]}]}`, `:no_match`, or `{:error, term}`.

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
        %ReleaseJudge{kept: cover_set} =
          raw_results
          |> Enum.map(&Release.new/1)
          |> ReleaseJudge.judge({:series, series, season_number, wanted_numbers}, opts)

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

  @doc """
  The releases the anime episode sweep grabs for `wanted_episode_ids`, by stable Catalog episode
  ids: `judge_anime_episodes/3`'s pick (`Cinder.Acquisition.Anime.best_episodes/4`).
  """
  def best_anime_releases(context, wanted_episode_ids, opts \\ []) do
    Anime.best_episodes(indexer(), context, wanted_episode_ids, opts)
  end

  @doc """
  Runs the anime episode queries for `wanted_ids` and judges every result
  (`Cinder.Acquisition.ReleaseJudge`, guard `{:anime_episodes, context, wanted_ids}`), for the
  manual-search panel. The sweep picks from the same record (`best_anime_releases/3`).

  Returns `{:ok, judged, incomplete?}` or `{:error, term}`
  (`Cinder.Acquisition.Anime.judge_episodes/4`).
  """
  def judge_anime_episodes(context, wanted_ids, opts \\ []),
    do: Anime.judge_episodes(indexer(), context, wanted_ids, opts)

  @doc """
  The release judge's title guard: the releases automatic selection keeps as the target's own.

  - `{:imdb, context}`: an `{ImdbId:...}`-scoped movie search. The release has to spell one of the
    movie's known titles (`context` is `Cinder.Catalog.movie_acquisition_context/1`'s map).
  - `{:title_year, title, year}`: a free-text movie search. Everything before the year token has
    to be the title.
  - `{:series, series, season_number, wanted_numbers}`: a season search. An explicit TVDB id
    match is proof; otherwise the title run has to open a release tag, and a known year has to
    agree.
  - `{:anime_movie, context}`: the anime movie queries. The anime guard
    (`Cinder.Acquisition.Anime.names_movie?/2`), and for an IMDb-scoped result the `{:imdb,
    context}` spelling as well.

  Only `Cinder.Acquisition.ReleaseJudge` calls this.
  """
  def title_guard(releases, {:imdb, context}), do: filter_id_scoped_movie(releases, context)

  def title_guard(releases, {:title_year, title, year}),
    do: filter_movie_title(releases, title, year)

  def title_guard(releases, {:series, series, _season_number, _wanted_numbers}),
    do: filter_title(releases, series)

  def title_guard(releases, {:anime_movie, context}) do
    Enum.filter(releases, fn release ->
      Anime.names_movie?(release, context) or
        (:id_scoped in (release.query_origins || []) and
           filter_id_scoped_movie([release], context) != [])
    end)
  end

  @doc """
  Searches the indexer for one TV `season` of `series` and judges every result
  (`Cinder.Acquisition.ReleaseJudge`, guard `{:series, series, season_number, wanted_numbers}`),
  for the manual-search panel. `wanted_numbers` and `opts` are the facts `best_releases/4` takes,
  so a row's verdict is the set-cover's for that release alone.

  `numbering` is `standard_tv_numbering/3`'s result, or nil. It adds the bounded alternate-season
  queries and freezes each bridged release's resolved Catalog episode ids, so a later grab can't
  reinterpret an alternate-numbered release through native episode numbers; a coordinate that
  resolves two ways is marked instead. Its `scorer` map becomes `opts[:alternate_numbering]`, as
  the sweep passes it to `best_releases/4`. Unlike `best_releases/4` it also drops duplicate
  results. The judging is the sweep's; these inputs differ on purpose (#775).
  """
  def judge_season(series, season_number, wanted_numbers, numbering, opts \\ []) do
    {alternate_seasons, opts} =
      case numbering do
        %{search_seasons: seasons, scorer: scorer} ->
          {seasons, Keyword.put(opts, :alternate_numbering, scorer)}

        nil ->
          {[], opts}
      end

    seasons = [season_number | Enum.reject(alternate_seasons, &(&1 == season_number))]

    case search_tv_seasons(indexer(), series, seasons) do
      {:ok, raw} ->
        releases =
          raw
          |> Enum.map(&Release.new/1)
          |> deduplicate_tv_releases()
          |> Enum.map(&resolve_standard_manual_release(&1, season_number, numbering))

        {:ok,
         ReleaseJudge.judge(releases, {:series, series, season_number, wanted_numbers}, opts)}

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

  # `Indexer.Prowlarr.search_tv/3` unions a TVDB-scoped query with a free-text query. Query origin
  # is not identity proof: a provider can ignore the id, and dedup can give one wrong result both
  # origins (#315). An explicit matching result TVDB id is proof and preserves AKA titles. Without
  # one, a known-year series requires both its title and matching year evidence; that deliberately
  # rejects ambiguous yearless packs rather than unattendedly importing a same-named reboot.
  defp filter_title(candidates, %{tvdb_id: nil} = series),
    do: candidates |> filter_by_title(series) |> reject_year_conflicts(series)

  defp filter_title(candidates, series) do
    candidates
    |> Enum.filter(&tv_title_match?(&1, series))
    |> reject_year_conflicts(series)
  end

  defp tv_title_match?(%Release{tvdb_id: tvdb_id}, %{tvdb_id: tvdb_id})
       when is_integer(tvdb_id),
       do: true

  defp tv_title_match?(%Release{tvdb_id: result_id}, %{tvdb_id: target_id})
       when is_integer(result_id) and is_integer(target_id),
       do: false

  defp tv_title_match?(
         %Release{title: title, query_origins: origins},
         %{year: year} = series
       )
       when is_integer(year) and is_list(origins),
       do: search_title_match?(series, title) and year_verified?(title, series)

  # A series with no year cannot use year evidence. Preserve the legacy provenance behavior there:
  # free-text results need the title guard; id-only results remain the best evidence available.
  defp tv_title_match?(%Release{title: title, query_origins: origins}, series)
       when is_list(origins) do
    :free_text not in origins or :id_scoped in origins or search_title_match?(series, title)
  end

  # Other indexer implementations predate provenance. Preserve their legacy TVDB-scoped contract;
  # the configured Prowlarr implementation always tags its TV results above.
  defp tv_title_match?(_release, _series), do: true

  # The tvdb_id-scoped query used to guarantee same-show results, but search_tv/3 now
  # unions in a free-text title query (so scraper indexers contribute — see
  # Indexer.Prowlarr), which can surface a same-named different show: "Charmed (2018)"
  # packs for the year-1998 series. An explicit year token is the one discriminator
  # scene names reliably carry, so a candidate is dropped only when every year in its
  # title is more than a year off the series year (±1 absorbs premiere-date wobble
  # between TMDB and scene naming). A year-shaped token that spells the series' OWN title
  # (a series literally named "1923") is stripped before this scan — it is the title, not
  # year evidence — so `release_years/2` excludes it on both sides of the check.
  # `tv_title_match?/2` applies the stricter identity rule for unverified known-year results;
  # this final pass also catches conflicts on explicitly identified AKA results.
  defp reject_year_conflicts(candidates, %{year: year} = series) when is_integer(year),
    do: Enum.reject(candidates, &year_conflict?(&1.title, series))

  defp reject_year_conflicts(candidates, _series), do: candidates

  defp year_conflict?(release_title, %{year: year} = series) do
    case release_years(release_title, series) do
      [] -> false
      years -> Enum.all?(years, &(abs(&1 - year) > 1))
    end
  end

  defp year_verified?(release_title, %{year: year} = series),
    do: Enum.any?(release_years(release_title, series), &(abs(&1 - year) <= 1))

  # A year-shaped token that is part of the series' own matched title run ("1923", "1883", "1899")
  # is the TITLE, not year evidence: it must count neither as a conflict nor as verification.
  # Stripped once via `title_needle/1` + `consume_leading/2` — the same leading-run matcher
  # `leads_with_title?/2` uses — so a genuine year elsewhere in the name (a real premiere year, or
  # an actual reboot year) still counts.
  defp release_years(release_title, series) do
    release_title
    |> tokens()
    |> drop_title_run(series)
    |> Enum.filter(&Regex.match?(~r/^(?:19|20)\d{2}$/, &1))
    |> Enum.map(&String.to_integer/1)
  end

  defp drop_title_run(tokens, target) do
    case title_needle(Map.get(target, :title)) do
      "" -> tokens
      needle -> strip_run(tokens, needle)
    end
  end

  defp strip_run([], _needle), do: []

  defp strip_run([token | rest] = tokens, needle) do
    case consume_leading(tokens, needle) do
      {:ok, remaining} -> strip_run(remaining, needle)
      :error -> [token | strip_run(rest, needle)]
    end
  end

  defp filter_by_title(candidates, series),
    do: Enum.filter(candidates, &search_title_match?(series, &1.title))

  defp search_title_match?(series, release_title),
    do: release_title |> tokens() |> title_run_before_tag?(series)

  defp title_run_before_tag?([], _series), do: false

  defp title_run_before_tag?([_ | rest] = tokens, series),
    do: leads_with_title?(tokens, series) or title_run_before_tag?(rest, series)

  # The free-text movie search an absent IMDb id degrades to. Unguarded on purpose: the release
  # judge drops what the Title.Year guard rejects from the sweep's pool, but the manual panel must
  # keep listing everything — the guard is deliberately strict, so a title convention it fails
  # closed on is exactly when the operator needs to see and override the rows.
  defp title_search(title, year) do
    query = [title, year] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    case indexer().search_movie_query(query, []) do
      {:ok, raw} -> {:ok, Enum.map(raw, &Release.new/1)}
      {:error, _reason} = error -> error
    end
  end

  # An IMDb-scoped search is scope, not identity proof — the TV lesson of #315. An indexer can
  # ignore the `{ImdbId:...}` token and answer with keyword matches or its latest feed, and an
  # uploader can link a release to the wrong IMDb page; the scorer then takes the biggest file,
  # which is how "Spider-Island" was grabbed for "Spider-Man: Brand New Day". So a release must
  # spell one of the movie's known titles (canonical, TMDB-localized, alias) as a whole-token run.
  #
  # Deliberately looser than `filter_movie_title/3`'s Title.Year anchoring: the id scope already
  # did most of the work, and this is the main movie path, so it must keep the conventions that
  # guard fails closed on — language before the year ("Dune.German.2021"), an edition tag, a site
  # prefix, no year at all. A movie with no usable needle (a non-Latin title and no Latin alias)
  # has nothing to compare names against, so the id scope stays the only evidence.
  defp filter_id_scoped_movie(candidates, context) do
    needles =
      [context.title | context.localized_titles ++ Enum.map(context.aliases, & &1.title)]
      |> Enum.map(&title_needle/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case needles do
      [] -> candidates
      needles -> Enum.filter(candidates, &(&1.title |> untagged_tokens() |> spells_any?(needles)))
    end
  end

  defp spells_any?(tokens, needles), do: Enum.any?(needles, &spells?(tokens, &1))

  # An all-digit title ("2012", "1917", "300") has to lead the name. Anywhere else the same tokens
  # are another release's year or decoration: "Avatar.2012.1080p" is not the movie "2012".
  defp spells?(tokens, needle) do
    if Regex.match?(~r/^\d+$/, needle),
      do: consume_leading(tokens, needle) != :error,
      else: spells_run?(tokens, needle)
  end

  defp spells_run?([], _needle), do: false

  defp spells_run?([_ | rest] = tokens, needle),
    do: consume_leading(tokens, needle) != :error or spells_run?(rest, needle)

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
  defp untagged_tokens(release_title), do: release_title |> untag() |> tokens()

  # `sanitize/1` first, here and in `tokens/1`: these `/u` regexes raise on malformed UTF-8, and one
  # garbled indexer title must not stall a whole search pass (#451).
  defp untag(nil), do: nil

  defp untag(release_title),
    do: String.replace(AnimeParser.sanitize(release_title), ~r/^\s*\[[^\]\r\n]+\]\s*/u, "")

  # Fail closed when tokenization ate most of the title: a non-Latin title ("Дом") folds to
  # nothing, "Дом 2" to a bare "2" — a remnant that would match almost anything and import the
  # wrong show. Both sides of the ratio start from the same fold/1 so an "&"→"and" expansion
  # can't inflate the needle past the check. Those series can't be safely matched by name; the
  # id-scoped result (which skips this guard) is the escape hatch.
  @doc """
  Whether `name` — a release name or a file name — **leads with** `target`'s title: the folded
  title has to be spelled by `name`'s tokens starting at the first one, and the token after it has
  to open a release tag (a season/episode marker, or a year consistent with `target.year`) rather
  than continue a show's name.

  The import calls this to decide whether a file it is about to **discard** really belongs to the
  series (`Cinder.Library`'s residual drop, #262), and a discard is unrecoverable, so it must not be
  a guess. Search-side free-text filtering uses a compatibility-oriented variant: it may find the
  same title run after a franchise prefix, but still requires the release-tag boundary. That keeps
  `Yellowstone.1883.S01...` while rejecting a run continued by `Side.Story` (#310).

  Shares the same fold, so everything `filter_title/2` is built to accept still matches:
  "S.W.A.T." ⇔ "SWAT", "Grey's" ⇔ "Greys", "Law & Order" ⇔ "Law.and.Order", "Pokémon" ⇔ "Pokemon".
  A title that folds to too little to be safe (`title_needle/1` returning "") matches nothing —
  fail-closed, same escape hatch as the search guard.
  """
  @spec names_title?(String.t() | nil, %{title: String.t() | nil, year: integer() | nil}) ::
          boolean()
  def names_title?(name, target), do: name |> tokens() |> leads_with_title?(target)

  @doc """
  Whether `name` — a file inside the pack `release_title` names — **leads with a prefix of that
  pack's own name**, followed by the same release tag `names_title?/2` demands.

  Every legitimate sibling file in a pack repeats the pack's leading token run; the foreign file
  #262 is about repeats none of it. Anchoring on the pack instead of on the series title is what
  lets an already-held file drop when it spells a qualifier the TMDB title lacks
  ("Shameless.US.S01E05.mkv" under series "Shameless"), carries a site prefix the pack carries too
  ("www.tracker.org - Show.S01E05.mkv"), or names no title at all ("S01E05.mkv" — the empty
  prefix, where the episode marker itself has to lead). All three are #265.

  Prefix, not equality, because the pack name keeps going after the title ("Show.S01.1080p...")
  and the file stops at its own release tag. The tag check is what keeps that honest: a token run
  the pack merely continues ("Show.US..." under a pack named "Show.S01...") is not followed by a
  tag and is rejected, exactly as it is today.

  `nil` — a grab with no recorded release title — matches nothing; the caller falls back to
  `names_title?/2`, which it also ORs with, so a pack named by an AKA its files don't share stays
  confirmable by the series title.
  """
  @spec names_release?(String.t() | nil, String.t() | nil, %{
          title: String.t() | nil,
          year: integer() | nil
        }) :: boolean()
  def names_release?(_name, nil, _target), do: false

  def names_release?(name, release_title, target) do
    untagged = untag(name)
    file = tokens(untagged)
    packed = release_title |> untagged_tokens() |> Enum.scan(&(&2 <> &1))
    prefixes = if titleless?(untagged, file), do: ["" | packed], else: packed

    Enum.any?(prefixes, &(file |> consume_prefix(&1) |> release_tag_next?(target)))
  end

  # Whether the name spells no title before its first token — checked on the string rather than on
  # the tokens because `tokens/1` strips non-Latin scripts, so "Дом.S01E05.mkv" tokenizes exactly
  # like a title-less "S01E05.mkv". Those series are the ones `title_needle/1` refuses to match by
  # name at all, and the empty prefix must not be the back door into discarding their files.
  defp titleless?(_untagged, []), do: false

  defp titleless?(untagged, [first | _]),
    do: untagged |> String.trim_leading() |> String.downcase() |> String.starts_with?(first)

  defp leads_with_title?(tokens, %{title: title} = target) do
    case title_needle(title) do
      "" -> false
      needle -> tokens |> consume_leading(needle) |> release_tag_next?(target)
    end
  end

  # The empty prefix is the title-less file: there is nothing to spell, so the first token has to
  # BE the release tag.
  defp consume_prefix(tokens, ""), do: {:ok, tokens}
  defp consume_prefix(tokens, needle), do: consume_leading(tokens, needle)

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
      #
      # Compared directly rather than through `year_conflict?/2`: `next` is a candidate TAG, so
      # the title-run stripping that guard applies must not run here (a series titled "1923"
      # would otherwise treat a second "1923" token as its own year).
      Regex.match?(@year_marker, next) ->
        case Map.get(target, :year) do
          year when is_integer(year) -> abs(String.to_integer(next) - year) <= 1
          _ -> false
        end

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
    |> AnimeParser.sanitize()
    |> fold()
    |> nfd()
    |> String.replace(~r/[^\x00-\x7f]/u, "")
    |> String.split(~r/[^a-z0-9]+/, trim: true)
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

  # Resolve the impl at runtime (not compile_env!) so the test Mox module — defined
  # at runtime — doesn't warn under --warnings-as-errors. fetch_env! fails fast if unset.
  defp indexer, do: Application.fetch_env!(:cinder, :indexer)
end
