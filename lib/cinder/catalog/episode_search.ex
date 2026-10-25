defmodule Cinder.Catalog.EpisodeSearch do
  @moduledoc """
  What the TV sweep and the manual season panel search for, and how a fruitless search backs off:
  the wanted set (`wanted_episodes/0`) and its eligibility rules, the operator's manual set, the
  re-queues (`search_episode_now/1`, `search_season_now/1`, the Rehunter's
  `rehunt_parked_episodes/1`), and the `search_attempts` bump with its exhaustion notice. The
  budget itself is `Cinder.Catalog.Episodes.max_search_attempts/0`.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{
    BlockedReleases,
    Episode,
    Episodes,
    Events,
    MediaProfiles,
    Season,
    Series,
    SeriesCatalog
  }

  alias Cinder.{Notifier, Repo, Settings}

  @doc """
  The SQL-expressible wanted set: monitored episodes with no file and no active grab whose
  `air_date` has passed (set and `<= today`). Preloads `season: :series` for the poller's
  search + season-grouping. Backoff/bound filtering (search_attempts, retry window) is applied
  by the TV poller, matching the movie poller's split. Gated on the leaf `episode.monitored`
  flag (the cascade/add keep it the single source of truth).

  Regular episodes keep the existing positive season/episode-number gate. Explicitly monitored,
  classified Anime story specials and recaps share the common missing/air-date predicates; an
  unclassified Anime special or a pure `:extra` stays excluded. A Standard (non-Anime) Season 00
  row shares the same common predicates with no classification gate — an operator who explicitly
  monitors a Standard special wants it searched exactly like a regular episode.
  """
  def wanted_episodes do
    Repo.all(from e in wanted_episodes_query(), preload: [season: :series])
  end

  @doc """
  Episodes a season-level manual search may replace or fill: ungrabbed available episodes
  (monitored or not) plus the normal wanted set. Unlike `wanted_episodes/0`, it is never the set
  the automatic sweep grabs for. The sweep reads it only through `season_acquisition_context/2`,
  to build the season's numbering bridge from the same episodes the panel does.

  Deliberately does NOT apply the Anime Season-0 story-special/recap classification restriction
  (`episode_kind_wanted?/3`) that gates automatic search and the upgrade hunter — an operator
  working a season panel can still target an unclassified special or a pure `:extra` explicitly.
  The restriction is a policy default for unattended sweeps, not an operator-facing lock (#356).

  `today` is the household date an episode must have aired by.
  """
  def manual_search_episodes(series_id, season_number, today \\ Settings.household_date()) do
    episodes =
      Repo.all(
        from e in Episode,
          join: s in assoc(e, :season),
          where:
            s.series_id == ^series_id and s.season_number == ^season_number and is_nil(e.grab_id),
          preload: [season: :series]
      )

    case episodes do
      [%{season: %{series: series}} | _] ->
        profile = MediaProfiles.media_profile_summary(series)
        Enum.filter(episodes, &manual_searchable?(&1, profile, today))

      [] ->
        []
    end
  end

  @doc """
  The facts a standard season's release list is built from (`Cinder.Acquisition.judge_season/3`),
  read in one transaction, so the TV sweep and the manual season panel search the season from the
  same inputs:

  - `series`, as given, and `season_number`;
  - `episode_count`: every episode of the season, the set-cover's `pack_episode_count`;
  - `episodes`: the searched episodes (`manual_search_episodes/2`), each `%{id, episode_number,
    state}` in `Episodes.state/2`'s terms: `:wanted` or `:search_parked` for one still wanted (the
    sweep searches a `:search_parked` one again once it's re-queued), `:available` for an imported
    one;
  - `native_seasons`: the season and every other season of the series with a wanted episode
    (`wanted_episodes/0`, backing off or parked included). The sweep searches each of those as a
    native season, on this tick or a later one, so the numbering bridge never reads one as an
    alternate season;
  - `mappings`: the series' episode coordinate mappings (`MediaProfiles.acquisition_mappings/1`).
  """
  def season_acquisition_context(%Series{id: series_id} = series, season_number) do
    {:ok, context} =
      Repo.transaction(fn ->
        today = Settings.household_date()

        %{
          series: series,
          season_number: season_number,
          episode_count: SeriesCatalog.count_episodes(series_id, season_number),
          # One `today` for the filter and the state, so no row reads as `:upcoming`.
          episodes:
            for episode <- manual_search_episodes(series_id, season_number, today) do
              %{
                id: episode.id,
                episode_number: episode.episode_number,
                state: Episodes.state(episode, today)
              }
            end,
          native_seasons: MapSet.put(wanted_season_numbers(series_id), season_number),
          mappings: MediaProfiles.acquisition_mappings(series)
        }
      end)

    context
  end

  defp wanted_season_numbers(series_id) do
    Repo.all(
      from([e, s] in wanted_episodes_query(),
        where: s.series_id == ^series_id,
        distinct: true,
        select: s.season_number
      )
    )
    |> MapSet.new()
  end

  @doc """
  Whether a season offers a manual search: it has an episode `manual_search_episodes/2` would act
  on. `season.episodes` must be loaded; each episode gets `season` attached in memory. The season
  panel's "Find a better match" renders from this, so it never opens on nothing to search.
  """
  def season_manual_searchable?(%Season{episodes: episodes} = season, profile) do
    today = Settings.household_date()
    Enum.any?(episodes, &manual_searchable?(%{&1 | season: season}, profile, today))
  end

  # An episode a manual search may act on: not owned by another grab, and either already
  # downloaded (an upgrade candidate) or one the sweep would search. Monitoring gates only the
  # automatic sweep.
  defp manual_searchable?(%Episode{} = episode, profile, today),
    do:
      is_nil(episode.grab_id) and
        (episode.file_path not in [nil, ""] or episode_searchable?(episode, profile, today))

  @doc "Count of wanted episodes (see `wanted_episodes/0`)."
  def count_wanted_episodes, do: Repo.aggregate(wanted_episodes_query(), :count)

  @doc "Count of still-wanted episodes in one season of `series_id` (see `wanted_episodes/0`)."
  def count_wanted_episodes(series_id, season_number) do
    Repo.aggregate(
      from([e, s] in wanted_episodes_query(),
        where: s.series_id == ^series_id and s.season_number == ^season_number
      ),
      :count
    )
  end

  @doc """
  Re-queues every search-parked episode whose row has been untouched since `cutoff`, by zeroing
  its `search_attempts` — the automatic counterpart to `search_episode_now/1`, driven by
  `Cinder.Catalog.Rehunter`. Eligibility reuses `wanted_episodes_query/0` verbatim, so the set can
  never drift from what the TV sweep actually searches.

  One `update_all` (no join — the ids are selected first, since SQLite can't UPDATE ... FROM), then
  one `{:series_updated, id}` broadcast per affected series so open views re-render the state
  change from `:search_parked` back to `:wanted`. `updated_at` is deliberately left alone, matching
  `MediaProfiles.set_series_language/2`'s reset: the sweep's own attempt bump is what
  re-establishes the backoff clock. Returns the number of episodes re-queued.
  """
  def rehunt_parked_episodes(%DateTime{} = cutoff) do
    parked =
      Repo.all(
        from([e, s] in wanted_episodes_query(),
          where: e.search_attempts >= ^Episodes.max_search_attempts() and e.updated_at < ^cutoff,
          select: {e.id, s.series_id}
        )
      )

    case Enum.unzip(parked) do
      {[], _} ->
        0

      {ids, series_ids} ->
        {count, _} =
          Repo.update_all(from(e in Episode, where: e.id in ^ids), set: [search_attempts: 0])

        series_ids |> Enum.uniq() |> Enum.each(&Events.series_updated/1)
        count
    end
  end

  @doc """
  Re-queues a single searchable `episode` for the TV sweep by zeroing its `search_attempts`
  (clearing any backoff/attempt-cap park). The episode is re-read with its series profile before
  writing so a stale LiveView click cannot requeue an episode that is no longer eligible. Already
  imported or grabbed episodes preserve the existing no-op contract.
  """
  def search_episode_now(%Episode{id: id}) do
    case Repo.one(from e in Episode, where: e.id == ^id, preload: [season: :series]) do
      %Episode{} = episode ->
        cond do
          not is_nil(episode.file_path) or not is_nil(episode.grab_id) ->
            :ok

          episode_searchable?(
            episode,
            MediaProfiles.media_profile_summary(episode.season.series)
          ) ->
            # Manual re-search: give any :stalled-reaped release for this series a fresh chance.
            BlockedReleases.clear_stalled_blocklist(series: episode.season.series.id)
            Episodes.transition(episode, %{search_attempts: 0})

          true ->
            {:error, :not_searchable}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Re-queues every still-wanted episode of one `season` (zeroes their `search_attempts`)."
  def search_season_now(%Season{id: season_id}) do
    episodes = wanted_episodes() |> Enum.filter(&(&1.season_id == season_id))

    # Manual re-search: give any :stalled-reaped release for this series a fresh chance.
    case episodes do
      [%{season: %{series: %{id: series_id}}} | _] ->
        BlockedReleases.clear_stalled_blocklist(series: series_id)

      _ ->
        :ok
    end

    Enum.each(episodes, &Episodes.transition(&1, %{search_attempts: 0}))
  end

  defp wanted_episodes_query do
    today = Settings.household_date()

    from e in Episode,
      join: s in assoc(e, :season),
      join: series in assoc(s, :series),
      where:
        e.monitored == true and is_nil(e.file_path) and is_nil(e.grab_id) and
          not is_nil(e.air_date) and e.air_date <= ^today,
      where: ^wanted_kind_dynamic()
  end

  # The season/classification half of `wanted_episodes_query/0`'s eligibility, split out as a
  # `dynamic` so the caller's own complexity stays flat — shared verbatim by `upcoming_episodes/0`
  # so the two can't drift.
  defp wanted_kind_dynamic do
    dynamic(
      [e, s, series],
      (s.season_number > 0 and e.episode_number > 0) or
        (series.media_profile == :anime and e.classification in [:story_special, :recap]) or
        (series.media_profile != :anime and s.season_number == 0 and e.episode_number > 0)
    )
  end

  @doc "Whether one preloaded episode shares the wanted query's current eligibility semantics."
  def episode_searchable?(
        %Episode{season: %Season{} = season} = episode,
        profile,
        today \\ Settings.household_date()
      ) do
    common? =
      episode.monitored and is_nil(episode.file_path) and is_nil(episode.grab_id) and
        not is_nil(episode.air_date) and Date.compare(episode.air_date, today) != :gt

    common? and episode_kind_wanted?(episode, season, profile)
  end

  @doc """
  The season/classification half of automatic eligibility, shared by every non-manual path:
  a regular episode (`season > 0`, `episode > 0`) is always in; a Season 0 row needs its media
  profile's own extra gate — Anime restricts to classified `:story_special` / `:recap` (an
  unclassified special or a pure `:extra` never auto-searches, #356), Standard admits any
  numbered S00 row an operator explicitly monitored. Mirrors `wanted_kind_dynamic/0`'s SQL
  predicate exactly, and is reused by `Cinder.Catalog.UpgradeHunter`'s anime candidate
  selection so the upgrade sweep can't re-open a door `wanted_episodes/0` keeps shut. Manual
  search (`manual_search_episodes/2`) deliberately does NOT call this — an operator working a
  season panel may want to search/replace an episode the automatic sweeps would skip.
  """
  def episode_kind_wanted?(episode, season, profile) do
    regular? = season.season_number > 0 and episode.episode_number > 0
    special? = profile.effective == :anime and episode.classification in [:story_special, :recap]

    standard_special? =
      profile.effective != :anime and season.season_number == 0 and episode.episode_number > 0

    regular? or special? or standard_special?
  end

  @doc """
  Monitored, dated episodes in a calendar window (`today - 7 .. today + 90`), ordered by air date,
  with `season: :series` preloaded for the calendar view. A season 0 row is included only when
  it's actually search-eligible — a Standard-profile explicit S00 monitor, or an Anime-classified
  story special/recap — mirroring `wanted_episodes_query/0`, so the view's derived "wanted" badge
  stays honest for every row, not just regular episodes.
  """
  def upcoming_episodes do
    today = Settings.household_date()
    from_date = Date.add(today, -7)
    to_date = Date.add(today, 90)

    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        join: series in assoc(s, :series),
        where:
          e.monitored and not is_nil(e.air_date) and e.air_date >= ^from_date and
            e.air_date <= ^to_date,
        where: ^wanted_kind_dynamic(),
        order_by: [asc: e.air_date],
        preload: [season: :series]
    )
  end

  @doc """
  Bumps `search_attempts` (and `updated_at`, for the poller's search backoff) on the given
  episodes in one write, then broadcasts each affected series. Used by the search pass on
  no-match / client-add failure / indexer error (no grab exists yet on that path).
  """
  def increment_search_attempts([]), do: :ok

  def increment_search_attempts(episode_ids) when is_list(episode_ids) do
    Repo.update_all(from(e in Episode, where: e.id in ^episode_ids),
      inc: [search_attempts: 1],
      set: [updated_at: DateTime.utc_now(:second)]
    )

    for series_id <- Episodes.series_ids(episode_ids),
        do: Events.series_updated(series_id)

    announce_search_exhausted(episode_ids)
    :ok
  end

  @doc """
  Announces the episodes among `episode_ids` that a `search_attempts` bump just took past the
  search budget: they leave the sweep for good, and that moment must never be silent (the movie
  analogue parks visibly at `:search_failed`). Called after commit by both bump paths, the sweep's
  `increment_search_attempts/1` and `Cinder.Catalog.Grabs`' non-imported bump on a finished or
  parked grab. Re-selecting fresh rows makes the check immune to stale in-memory counters.
  Monitored-only: a parked grab of a just-cancelled series bumps unmonitored episodes the sweep
  doesn't own. Single-series by construction (both callers pass one grab/season group); the
  notifier payload's episodes carry `season: :series` for the transports' summary line.
  Best-effort: never raises, always `:ok`.
  """
  def announce_search_exhausted([]), do: :ok

  # Best-effort like `Grabs.create_grab/5`'s post-commit broadcast (and guarded the same way): it
  # runs AFTER the bump/finalize committed, so a re-select raise here (pool-checkout timeout,
  # SQLITE_BUSY) must not escape — in finish_grab's caller that would skip the client-download
  # removal and the availability notification for a grab row that is already gone.
  #
  # >= rather than ==: crossings normally land exactly at the cap (new grabs reset or start
  # below it), but pre-existing data can sit at the cap inside an in-flight grab and get
  # bumped past it. A capped episode can't re-announce — the sweep skips it and every grab
  # path resets — so >= adds no duplicates, only catches the above-cap stragglers.
  def announce_search_exhausted(episode_ids) do
    exhausted =
      Repo.all(
        from e in Episode,
          where:
            e.id in ^episode_ids and e.search_attempts >= ^Episodes.max_search_attempts() and
              is_nil(e.file_path) and is_nil(e.grab_id) and e.monitored == true,
          preload: [season: :series]
      )

    case exhausted do
      [] ->
        :ok

      [%{season: %{series: series, season_number: season}} | _] = episodes ->
        numbers = Enum.map(episodes, & &1.episode_number)

        Logger.warning(
          "tv search exhausted for #{series.title} season #{season} episode(s) " <>
            "#{inspect(numbers)}; the sweep will skip them until a manual Search"
        )

        Notifier.notify({:episodes_search_exhausted, episodes})
    end
  rescue
    e -> Logger.warning("search-exhaustion announce failed: #{inspect(e)}")
  catch
    kind, value -> Logger.warning("search-exhaustion announce #{kind}: #{inspect(value)}")
  end
end
