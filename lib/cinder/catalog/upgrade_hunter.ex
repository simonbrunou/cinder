defmodule Cinder.Catalog.UpgradeHunter do
  @moduledoc """
  Periodically re-searches things already in the library, looking for a better release than the
  file on disk — the standing "keep improving" loop.

  Cinder has always known whether one file beats another (`Cinder.Library.Upgrade`), but only ever
  asked at *import* time: "is what just arrived better than what I have?" Nothing went looking. A
  title grabbed at 720p on request night stayed 720p forever unless an operator ran a manual
  search. This sweep asks the question on a timer.

  **Off by default.** It re-downloads and replaces library files, which is not something to start
  doing to someone's library because they upgraded Cinder — turn it on under "Library upgrades" in
  `/settings`, which overlays `enabled:` onto this module's config with no restart
  (`Cinder.Settings.load_into_env/0`). `config :cinder, #{inspect(__MODULE__)}, enabled: true`
  still sets the boot default an unset/cleared setting reverts to.

  ## How a candidate is chosen

  Each pass takes the `batch_size/0` least-recently-checked items (`upgrade_checked_at`, nulls
  first) and stamps them **before** searching, so a large library rotates steadily and a title
  that raises can't wedge the batch or re-run every tick.

  One gate before anything is downloaded: `Cinder.Library.Upgrade.candidate?/4` compares the
  *parsed* release against the imported file, so a sideways or worse release is dropped without
  being downloaded.

  For **movies** that gate is the only one: a movie upgrade grab imports by forced replace
  (`Library.stage_movie(replace: true)`), which bypasses the import's own keep-vs-replace check,
  so the sweep must never link a movie release it hasn't decided is an upgrade.

  For **episodes** there is a second gate. Every grab this sweep opens is marked
  `arbitrate_at_import` (#250), so `Library.stage_episodes/3` re-runs the comparison per *source
  file group* — a staged file is indivisible, so it replaces every episode it covers or none —
  against the files those episodes actually hold. A group that loses is not placed and its
  episodes keep what they had. That is what lets a season pack beating 8 of 10 episodes be taken
  at all: the other two simply keep their files. The manual path stays a forced replace, because
  there the operator chose the release, possibly for something the ranking can't see.

  An optional per-library resolution cutoff skips automatic movie searches once a file reaches
  that point (or an earlier resolution in the configured preference list). TV searches are season
  scoped, so they stop once every held episode in the season reaches it; until then the full held
  season stays claimable by a pack. Without a cutoff, language and source upgrades remain
  searchable even at the top resolution. Manual search is never gated by the cutoff.

  ## Scope

  Movies and series. Anime-profile series use the same per-title policy, stable-coordinate
  reservation, verification, and import arbitration as wanted Anime episodes.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`): stateless, self-rescheduling,
  crash-recoverable. Interval and batch size are module config
  (`config :cinder, #{inspect(__MODULE__)}, interval: <ms>, batch: <n>`).
  """
  import Ecto.Query

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{AnimePreferences, Language}
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.{Disk, Download, Repo, Settings}
  alias Cinder.HTTPPolicy
  alias Cinder.Library.Upgrade

  @default_interval :timer.hours(12)
  @default_batch 10

  use Cinder.Download.PollerSkeleton,
    log_prefix: "upgrade hunter",
    stateful: false,
    first_interval: :timer.minutes(10)

  @doc "Whether upgrade hunting runs (the `/settings` switch, over the `config.exs` default)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc "How many library items one pass examines."
  def batch_size, do: Keyword.get(config(), :batch, @default_batch)

  defp do_poll do
    if enabled?() do
      isolate("movie upgrades", fn -> hunt_movies() end)
      isolate("episode upgrades", fn -> hunt_episodes() end)
    end

    :ok
  end

  # --- movies ------------------------------------------------------------------------------------

  defp hunt_movies do
    movies =
      Repo.all(
        from m in Movie,
          where: m.status == :available and not is_nil(m.file_path),
          order_by: [asc_nulls_first: m.upgrade_checked_at],
          limit: ^batch_size()
      )

    stamp(Movie, Enum.map(movies, & &1.id))

    for movie <- movies do
      isolate("movie #{movie.id}", fn -> hunt_movie(movie) end)
    end
  end

  defp hunt_movie(movie) do
    unless Upgrade.cutoff_met?(movie, :movies) do
      # best_release_for/1 is start/1's search half WITHOUT its transition — the movie has to stay
      # :available (its file_path is the live library file) while we ask.
      case Download.best_release_for(movie) do
        {:ok, release} ->
          target = Language.target(movie.preferred_language, movie.original_language)
          maybe_grab_movie(movie, release, target)

        # :no_match / :no_language_match / a waiting-for-group hold / an indexer error: nothing to
        # upgrade to right now. Never park an :available movie over it — it already has its file.
        _other ->
          :ok
      end
    end
  end

  defp maybe_grab_movie(movie, release, target) do
    cond do
      not Upgrade.candidate?(movie, release, :movies, target) ->
        :ok

      not Disk.grab_space_available?(release.size) ->
        Logger.info("upgrade hunter: not enough space to upgrade movie #{movie.id}")

      true ->
        # An :available movie routes into :upgrading, which keeps file_path pointing at the live
        # file until the replacement is imported and swapped atomically.
        case Download.grab_movie(movie, release) do
          {:ok, _movie} ->
            Logger.info(
              "upgrade hunter: upgrading movie #{movie.id} to #{HTTPPolicy.sanitize_log(release.title)}"
            )

          {:error, reason} ->
            Logger.info(
              "upgrade hunter: movie #{movie.id} upgrade grab failed #{inspect(reason)}"
            )
        end
    end
  end

  # --- episodes ----------------------------------------------------------------------------------

  defp hunt_episodes do
    episodes =
      Repo.all(
        from e in holdings(),
          order_by: [asc_nulls_first: e.upgrade_checked_at],
          limit: ^batch_size(),
          preload: [season: :series]
      )

    stamp(Episode, Enum.map(episodes, & &1.id))

    episodes
    |> Enum.group_by(& &1.season.series.id)
    |> Enum.each(fn {_series_id, selected} -> hunt_selected_series(selected) end)
  end

  defp hunt_selected_series([episode | _] = selected) do
    series = episode.season.series

    case Catalog.media_profile_summary(series).effective do
      :anime -> isolate("series #{series.id}", fn -> hunt_anime_series(series.id) end)
      :standard -> hunt_selected_standard_seasons(series.id, selected)
    end
  end

  defp hunt_selected_standard_seasons(series_id, selected) do
    selected
    |> Enum.uniq_by(& &1.season_id)
    |> Enum.each(fn episode ->
      isolate(
        "series #{series_id} s#{episode.season.season_number}",
        fn -> hunt_standard_season(episode.season_id) end
      )
    end)
  end

  # Episodes this sweep can act on: monitored, a file to improve on, no grab already in flight.
  defp holdings do
    from e in Episode,
      where: e.monitored == true and not is_nil(e.file_path) and is_nil(e.grab_id)
  end

  # The batch is a slice of the whole LIBRARY, so a season almost always arrives partial. Widen it
  # back to every episode of the season we hold before searching: a season pack delivers the whole
  # season no matter how few episodes we asked about, and every delivered file no episode claims
  # becomes an operator residual hold (#247).
  defp hunt_standard_season(season_id) do
    episodes =
      Repo.all(
        from e in holdings(),
          where: e.season_id == ^season_id,
          order_by: e.episode_number,
          preload: [season: :series]
      )

    case episodes do
      [%Episode{season: %{series: series}} | _] ->
        stamp(Episode, Enum.map(episodes, & &1.id))
        maybe_search_standard_season(series, episodes)

      [] ->
        :ok
    end
  end

  defp maybe_search_standard_season(series, episodes) do
    unless Enum.all?(episodes, &Upgrade.cutoff_met?(&1, :tv)) do
      search_season(series, episodes)
    end
  end

  defp hunt_anime_series(series_id) do
    episodes =
      Repo.all(
        from e in holdings(),
          join: s in assoc(e, :season),
          where: s.series_id == ^series_id,
          order_by: [s.season_number, e.episode_number],
          preload: [season: :series]
      )

    case episodes do
      [%Episode{season: %{series: series}} | _] ->
        stamp(Episode, Enum.map(episodes, & &1.id))

        # Same Season-0 classification gate `wanted_episodes/0` / `episode_searchable?/3` apply:
        # an unclassified special or a pure `:extra` that somehow holds a file (adoption, manual
        # import) must not drive a search or be offered as an upgrade target (#356). Regular
        # (season > 0) episodes are untouched — the gate is Season-0-only.
        profile = Catalog.media_profile_summary(series)
        searchable = Enum.filter(episodes, &Catalog.episode_kind_wanted?(&1, &1.season, profile))

        eligible =
          searchable
          |> Enum.chunk_by(& &1.season_id)
          |> Enum.reject(&Enum.all?(&1, fn episode -> Upgrade.cutoff_met?(episode, :tv) end))
          |> List.flatten()

        if eligible != [] do
          search_anime_series(series, searchable, MapSet.new(eligible, & &1.id))
        end

      [] ->
        :ok
    end
  end

  defp search_season(series, episodes) do
    season_number = hd(episodes).season.season_number
    target = Language.target(series.preferred_language, series.original_language)
    season_size = max(Catalog.count_episodes(series.id, season_number), 1)

    opts =
      upgrade_search_opts(series) ++
        [
          # Every file we can't link to an episode we hold becomes an operator residual decision
          # at import (#247), so filter such releases before the set cover picks them.
          full_claim_only: true,
          pack_episode_count: season_size
        ]

    case Acquisition.best_releases(
           series,
           season_number,
           Enum.map(episodes, & &1.episode_number),
           opts
         ) do
      {:ok, assignments} ->
        Enum.each(assignments, &maybe_grab_episodes(&1, episodes, target))

      _no_match_or_error ->
        :ok
    end
  end

  defp search_anime_series(series, episodes, eligible_ids) do
    episode_ids = Enum.map(episodes, & &1.id)
    episodes_by_id = Map.new(episodes, &{&1.id, &1})
    context = Catalog.anime_series_acquisition_context(series)

    case AnimePreferences.resolve(series, Settings.anime_defaults()) do
      {:ok, policy} ->
        Catalog.set_anime_hold(series, nil)

        case Acquisition.best_anime_releases(
               context,
               episode_ids,
               upgrade_search_opts(series) ++
                 AnimePreferences.selection_opts(policy) ++
                 [
                   required_episode_ids: MapSet.to_list(eligible_ids),
                   candidate_filter: &anime_upgrade_candidate?(&1, episodes_by_id, eligible_ids)
                 ]
             ) do
          {:ok, %{assignments: assignments}} ->
            Enum.each(assignments, &maybe_grab_anime_episodes(&1, episodes, eligible_ids))

          _no_match_waiting_or_error ->
            :ok
        end

      {:error, reason} ->
        Catalog.set_anime_hold(series, reason)
    end
  end

  defp upgrade_search_opts(series) do
    [
      protocols: Download.available_protocols(),
      preferred_language: series.preferred_language,
      original_language: series.original_language,
      # The only consumer that includes `"no_upgrade"`: a release this sweep grabbed and the
      # import then arbitrated down to nothing placed would otherwise be re-offered every
      # rotation (#274). The wanted-episode sweep and the manual panel still see it.
      release_blocklist:
        Catalog.blocked_release_titles_for_series(series.id, include_reasons: [:no_upgrade])
    ] ++ Acquisition.band_opts(:tv)
  end

  # An assignment covers a set of episode NUMBERS — every one of them ours to claim, since
  # `full_claim_only` already dropped the releases carrying anything else. Take it if it improves
  # ANY covered episode: the import arbitrates per source-file group (`Library.stage_group/7`), so
  # the groups this release doesn't beat keep their files and the ones it does get the new one.
  # `Enum.all?` cost the whole pack whenever one episode of the season was already good enough —
  # #257.
  #
  # `any?` re-opens a re-download loop that `all?` incidentally suppressed, so it ships only
  # because all three of its routes are now closed or bounded:
  #
  #   * quality tokens — #277: `Library.new_quality/3` backfills a terse inner file's nil
  #     resolution/source/language from the release title, so a pack no longer out-ranks the very
  #     file it produced on a nil that sorts last;
  #   * size — #278/#283: `Upgrade.candidate?/4` weighs no size at all, so a multi-file container
  #     can't out-weigh the one file `lstat`ed out of it;
  #   * a worse-token file — still live, and deliberately: `new_quality/3` backfills only NIL
  #     fields, because a genuinely mixed pack must keep a member's worse token. So an episode
  #     holding `720p` inside a `1080p`-titled pack reads as improvable by that title forever while
  #     the import re-parses the file and declines. #274 BOUNDS it rather than removing it — a grab
  #     that commits having placed nothing writes a `no_upgrade` `BlockedRelease` row, which only
  #     this sweep's `release_blocklist` reads. One pack is downloaded and discarded, once; the
  #     rotation after that passes on it.
  defp maybe_grab_episodes({release, covered_numbers}, episodes, target) do
    covered = Enum.filter(episodes, &(&1.episode_number in covered_numbers))

    maybe_grab_episode_release(release, covered, target)
  end

  defp maybe_grab_anime_episodes(
         %{release: release, episode_ids: episode_ids},
         episodes,
         eligible_ids
       ) do
    covered = Enum.filter(episodes, &(&1.id in episode_ids))
    eligible = Enum.filter(covered, &MapSet.member?(eligible_ids, &1.id))

    # Anime policy already decided audio/subtitle suitability; the quality gate compares only the
    # ranked resolution/source fields here and the verified file again at import.
    maybe_grab_episode_release(release, covered, eligible, nil)
  end

  # `eligible_ids` already excludes cutoff-met episodes; membership alone is the classification
  # gate too, since `hunt_anime_series/1` never puts a story-special/recap-ineligible Season-0
  # episode into `eligible_ids` in the first place (#356).
  defp anime_upgrade_candidate?(release, episodes_by_id, eligible_ids) do
    Enum.any?(release.resolved_episode_ids || [], fn episode_id ->
      MapSet.member?(eligible_ids, episode_id) and
        Upgrade.candidate?(Map.fetch!(episodes_by_id, episode_id), release, :tv, nil)
    end)
  end

  defp maybe_grab_episode_release(release, covered, target) do
    maybe_grab_episode_release(release, covered, covered, target)
  end

  defp maybe_grab_episode_release(release, covered, candidates, target) do
    cond do
      candidates == [] or
          not Enum.any?(candidates, &Upgrade.candidate?(&1, release, :tv, target)) ->
        :ok

      not Disk.grab_space_available?(release.size) ->
        Logger.info(
          "upgrade hunter: not enough space for #{HTTPPolicy.sanitize_log(release.title)}"
        )

      true ->
        grab_episode_upgrade(release, Enum.map(covered, & &1.id))
    end
  end

  # operator_initiated: true is what lets the intent target episodes that already have a file —
  # the same flag the manual season search uses (`Cinder.Catalog.Grabs`). arbitrate_at_import is
  # what distinguishes the two: this sweep picks unattended, so the import re-checks each episode
  # against what it already holds and keeps the ones this release doesn't beat (#250).
  defp grab_episode_upgrade(release, episode_ids) do
    case Download.grab_episodes(release, episode_ids,
           operator_initiated: true,
           arbitrate_at_import: true
         ) do
      {:ok, _grab} ->
        Logger.info(
          "upgrade hunter: upgrading #{length(episode_ids)} episode(s) to #{HTTPPolicy.sanitize_log(release.title)}"
        )

      {:error, reason} ->
        Logger.info("upgrade hunter: episode upgrade grab failed #{inspect(reason)}")
    end
  end

  # --- shared ------------------------------------------------------------------------------------

  # Stamped BEFORE the search, so the rotation advances even for an item whose search raises —
  # otherwise one bad title would head the nulls-first ordering forever and the sweep would
  # re-examine it, and only it, every pass. Bookkeeping only: it touches no pipeline state, which
  # is why it is a sanctioned direct write rather than a Catalog transition.
  defp stamp(_schema, []), do: :ok

  defp stamp(schema, ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(from(r in schema, where: r.id in ^ids), set: [upgrade_checked_at: now])
    :ok
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
