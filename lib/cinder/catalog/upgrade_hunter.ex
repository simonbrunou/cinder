defmodule Cinder.Catalog.UpgradeHunter do
  @moduledoc """
  Periodically re-searches things already in the library, looking for a better release than the
  file on disk — the standing "keep improving" loop.

  Cinder has always known whether one file beats another (`Cinder.Library.Upgrade`), but only ever
  asked at *import* time: "is what just arrived better than what I have?" Nothing went looking. A
  title grabbed at 720p on request night stayed 720p forever unless an operator ran a manual
  search. This sweep asks the question on a timer.

  **Off by default.** It re-downloads and replaces library files, which is not something to start
  doing to someone's library because they upgraded Cinder — turn it on with
  `config :cinder, #{inspect(__MODULE__)}, enabled: true`.

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
  `arbitrate_at_import` (#250), so `Library.stage_episodes/3` re-runs the comparison per episode
  against the file that episode actually holds — a release that loses is not placed and the
  episode keeps what it had. That is what lets a season pack beating 8 of 10 episodes be taken at
  all: the other two simply keep their files. The manual path stays a forced replace, because
  there the operator chose the release, possibly for something the ranking can't see.

  ## ponytail: no resolution cutoff

  An earlier cut skipped the search entirely for items already at the top of the preferred-
  resolution list, to save an indexer call. That was wrong: language is decided **before** quality
  at all (`language_decides?/3`), and within quality `rank/4` orders resolution, then source — so a
  1080p file with the wrong audio language, or from the least-preferred source, would have been
  permanently unreachable. Exactly what a soft
  Original/Any grab or a later language change leaves behind. `candidate?/4` already returns false
  when nothing is better, so the cutoff bought one saved search per item per rotation and cost
  two of the three ranking keys. Deleted rather than taught about all three.

  ## Scope

  Movies and **standard** series. Anime-profile series are skipped: their release selection runs
  through per-title policy, holds and coordinate mapping built around *wanted* episodes, and
  re-offering upgrades through it needs its own design rather than a reused call.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`): stateless, self-rescheduling,
  crash-recoverable. Interval and batch size are module config
  (`config :cinder, #{inspect(__MODULE__)}, interval: <ms>, batch: <n>`).
  """
  import Ecto.Query

  alias Cinder.Acquisition
  alias Cinder.Acquisition.Language
  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.{Disk, Download, Repo}
  alias Cinder.HTTPPolicy
  alias Cinder.Library.Upgrade

  @default_interval :timer.hours(12)
  @default_batch 10

  use Cinder.Download.PollerSkeleton,
    log_prefix: "upgrade hunter",
    stateful: false,
    first_interval: :timer.minutes(10)

  @doc "Whether upgrade hunting runs (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
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
    |> Enum.uniq_by(& &1.season_id)
    |> Enum.each(fn episode ->
      isolate(
        "series #{episode.season.series.id} s#{episode.season.season_number}",
        fn -> hunt_season(episode.season_id) end
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
  defp hunt_season(season_id) do
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

        if Catalog.media_profile_summary(series).effective == :anime do
          # See "Scope" above — not a silent skip, so an operator wondering why their anime library
          # never upgrades finds the reason in the log.
          Logger.debug("upgrade hunter: skipping anime series #{series.id} (unsupported)")
        else
          search_season(series, episodes)
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
      [
        protocols: Download.available_protocols(),
        preferred_language: series.preferred_language,
        original_language: series.original_language,
        release_blocklist: Catalog.blocked_release_titles_for_series(series.id),
        # Every file we can't link to an episode we hold becomes an operator residual decision at
        # import (#247), so a release carrying one scores zero inside the cover and the releases
        # behind it are picked instead (`Scorer.claimable_coverage/5` — judging the winner after
        # the fact would throw away the whole season's upgrades).
        full_claim_only: true,
        pack_episode_count: season_size
      ] ++ Acquisition.band_opts(:tv)

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

  # An assignment covers a set of episode NUMBERS — every one of them ours to claim, since
  # `full_claim_only` already dropped the releases carrying anything else. Take it if it improves
  # ANY covered episode: a pack that beats 8 of a season's 10 is worth having, and demanding all 10
  # left such a season mixed forever (#257).
  #
  # Claiming the other two is safe: the grab is `arbitrate_at_import`, so the import re-runs the
  # comparison per episode against the real file and declines the ones this release doesn't beat
  # (#250) — a claimed episode can never have a good file swapped for a worse one.
  #
  # And `any?` cannot make a pack its own upgrade: size is out of the pre-download gate (#278) and
  # a terse inner file's nil tokens are backfilled from the release title at import (#277), so a
  # release that ties on language/resolution/source is no covered episode's candidate.
  defp maybe_grab_episodes({release, covered_numbers}, episodes, target) do
    covered = Enum.filter(episodes, &(&1.episode_number in covered_numbers))

    cond do
      covered == [] or not Enum.any?(covered, &Upgrade.candidate?(&1, release, :tv, target)) ->
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
