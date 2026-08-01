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

  Two gates before anything is downloaded:

  1. **The cutoff.** An item already at the top of the household's preferred-resolution list has
     nothing better to find, so it doesn't cost an indexer call. That reuses
     `Cinder.Library.preferred_resolutions/1` — there is deliberately no separate "cutoff"
     setting to keep in sync with the list that already expresses the same preference.
  2. **The promise.** `Cinder.Library.upgrade_candidate?/4` compares the *parsed* release against
     the imported file, so a sideways or worse release is dropped without downloading it.

  Both are advisory, and that is fine: the **import stays the arbiter**. It re-runs the same
  comparison against the real file and keeps the existing one if the promise didn't hold, so a
  mis-parsed release name can never leave the library worse off than it started.

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

    for movie <- movies, not at_cutoff?(movie, :movies) do
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
            Logger.info("upgrade hunter: upgrading movie #{movie.id} to #{release.title}")

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
        from e in Episode,
          where: e.monitored == true and not is_nil(e.file_path) and is_nil(e.grab_id),
          order_by: [asc_nulls_first: e.upgrade_checked_at],
          limit: ^batch_size(),
          preload: [season: :series]
      )

    stamp(Episode, Enum.map(episodes, & &1.id))

    episodes
    |> Enum.reject(&at_cutoff?(&1, :tv))
    |> Enum.group_by(&{&1.season.series.id, &1.season.season_number})
    |> Enum.each(fn {{series_id, season_number}, group} ->
      isolate("series #{series_id} s#{season_number}", fn -> hunt_season(group) end)
    end)
  end

  defp hunt_season([%Episode{season: %{series: series}} | _] = episodes) do
    if Catalog.media_profile_summary(series).effective == :anime do
      # See "Scope" above — not a silent skip, so an operator wondering why their anime library
      # never upgrades finds the reason in the log.
      Logger.debug("upgrade hunter: skipping anime series #{series.id} (unsupported)")
    else
      search_season(series, episodes)
    end
  end

  defp search_season(series, episodes) do
    season_number = hd(episodes).season.season_number
    target = Language.target(series.preferred_language, series.original_language)

    opts =
      [
        protocols: Download.available_protocols(),
        preferred_language: series.preferred_language,
        original_language: series.original_language,
        release_blocklist: Catalog.blocked_release_titles_for_series(series.id)
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

  # An assignment covers a set of episode NUMBERS; only upgrade the ones this release actually
  # improves, so a season pack that beats two of five episodes doesn't drag the other three
  # through a pointless replace.
  defp maybe_grab_episodes({release, covered_numbers}, episodes, target) do
    upgradable =
      Enum.filter(
        episodes,
        &(&1.episode_number in covered_numbers and
            Upgrade.candidate?(&1, release, :tv, target))
      )

    cond do
      upgradable == [] ->
        :ok

      not Disk.grab_space_available?(release.size) ->
        Logger.info("upgrade hunter: not enough space for #{release.title}")

      true ->
        grab_episode_upgrade(release, Enum.map(upgradable, & &1.id))
    end
  end

  # operator_initiated: true is what lets the intent target episodes that already have a file —
  # the same flag the manual season search uses (`Cinder.Catalog.Grabs`).
  defp grab_episode_upgrade(release, episode_ids) do
    case Download.grab_episodes(release, episode_ids, operator_initiated: true) do
      {:ok, _grab} ->
        Logger.info(
          "upgrade hunter: upgrading #{length(episode_ids)} episode(s) to #{release.title}"
        )

      {:error, reason} ->
        Logger.info("upgrade hunter: episode upgrade grab failed #{inspect(reason)}")
    end
  end

  # --- shared ------------------------------------------------------------------------------------

  # At the top of the preferred list there is nothing better to look for. An unset list (or an
  # item with no recorded resolution) means no cutoff — search it.
  defp at_cutoff?(record, kind) do
    case Upgrade.preferred_resolutions(kind) do
      [best | _] -> record.imported_resolution == best
      _unset -> false
    end
  end

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
