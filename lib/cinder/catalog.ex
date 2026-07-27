defmodule Cinder.Catalog do
  @moduledoc """
  Discovery: search TMDB for movies and persist requested ones.

  TMDB is reached only through the `Cinder.Catalog.TMDB` behaviour, resolved from
  config (`config :cinder, :tmdb`) so tests use a Mox mock and never hit the network.

  This module is the public facade over the whole catalog: movie CRUD, the pipeline
  transition matrix (the single state-change choke-point for movies and episodes),
  deletion/audit, and broadcasts stay here. Discovery, the TV grab lifecycle, and
  series/season/episode management were carved out into sibling modules as plain
  code motion (`Cinder.Catalog.Discovery`, `Cinder.Catalog.Grabs`,
  `Cinder.Catalog.SeriesCatalog`, `Cinder.Catalog.SceneNumbering`,
  `Cinder.Catalog.SeriesRefresh`) once this file outgrew ~4,000 lines; every
  function they own is re-exported here unchanged via `defdelegate` so no caller
  anywhere needed to change.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Audit

  alias Cinder.Catalog.{
    Discovery,
    Episode,
    EpisodeTransition,
    Grabs,
    Identity,
    MediaProfiles,
    Movie,
    ReleaseVerification,
    SceneNumbering,
    Season,
    Series,
    SeriesCatalog,
    SeriesRefresh
  }

  alias Cinder.Download
  alias Cinder.Download.Intent
  alias Cinder.Library
  alias Cinder.Library.ImportStage
  alias Cinder.Notifier
  alias Cinder.Repo
  alias Cinder.Requests

  @topic "movies"
  @download_metric_fields [:download_progress, :download_speed, :download_eta]
  @max_search_attempts 10

  ## Discovery — TMDB search/trending/rails/localized lookups.
  # Carved out to `Cinder.Catalog.Discovery`; see that module for the implementation.

  defdelegate search_movies(query), to: Discovery
  defdelegate search_movies(query, locale), to: Discovery
  defdelegate search_tv(query), to: Discovery
  defdelegate search_tv(query, locale), to: Discovery
  defdelegate search_discover(query), to: Discovery
  defdelegate search_discover(query, locale), to: Discovery
  defdelegate trending(), to: Discovery
  defdelegate trending(locale), to: Discovery
  defdelegate popular_movies(), to: Discovery
  defdelegate popular_movies(locale), to: Discovery
  defdelegate top_rated_movies(), to: Discovery
  defdelegate top_rated_movies(locale), to: Discovery
  defdelegate now_playing_movies(), to: Discovery
  defdelegate now_playing_movies(locale), to: Discovery
  defdelegate popular_tv(), to: Discovery
  defdelegate popular_tv(locale), to: Discovery
  defdelegate top_rated_tv(), to: Discovery
  defdelegate top_rated_tv(locale), to: Discovery
  defdelegate movies_by_genre(genre_id), to: Discovery
  defdelegate movies_by_genre(genre_id, locale), to: Discovery
  defdelegate tv_by_genre(genre_id), to: Discovery
  defdelegate tv_by_genre(genre_id, locale), to: Discovery
  defdelegate search_person(query), to: Discovery
  defdelegate search_person(query, locale), to: Discovery
  defdelegate search_collection(query), to: Discovery
  defdelegate search_collection(query, locale), to: Discovery
  defdelegate get_person(tmdb_id), to: Discovery
  defdelegate get_person(tmdb_id, locale), to: Discovery
  defdelegate get_collection(tmdb_id), to: Discovery
  defdelegate get_collection(tmdb_id, locale), to: Discovery
  defdelegate tmdb_series(tmdb_id), to: Discovery
  defdelegate localized_title(media, locale), to: Discovery
  defdelegate localized_overview(media, locale), to: Discovery

  @doc """
  Persists a movie as `:requested`. Returns `{:ok, movie}` or
  `{:error, changeset}` (e.g. a duplicate `tmdb_id`).
  """
  def add_movie(attrs) do
    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Sets the operator-owned handling profile for a movie or series and broadcasts the update.
  Rescues a deleted-row race to `{:error, :stale_entry}` (mirrors write_movie_language/2) —
  the approval path calls this post-commit, where a raise would escape an already-committed
  approval.
  """
  defdelegate set_media_profile(title, profile), to: MediaProfiles

  @doc "Marks or clears the anime search-time hold; see `Cinder.Catalog.MediaProfiles`."
  defdelegate set_anime_hold(title, reason), to: MediaProfiles

  @doc "Series currently held at search time on unsatisfiable Anime preferences (see `set_anime_hold/2`); surfaced on `/activity`."
  defdelegate list_anime_held_series(), to: SeriesCatalog

  @doc "Returns selected/effective profile policy and bounded suggestion evidence."
  defdelegate media_profile_summary(title), to: MediaProfiles

  @doc "Returns the one series owning every supplied episode ID."
  defdelegate get_single_series_for_episode_ids(episode_ids), to: SeriesCatalog

  @doc "Lists sourced aliases for a movie or series."
  defdelegate list_title_aliases(owner), to: Identity, as: :list_aliases

  @doc "Adds an operator-owned alias."
  defdelegate save_manual_alias(owner, attrs), to: Identity

  @doc "Updates an operator-owned alias belonging to the supplied owner."
  defdelegate update_manual_alias(owner, alias_id, attrs), to: Identity

  @doc "Deletes an operator-owned alias belonging to the supplied owner."
  defdelegate delete_manual_alias(owner, alias_id), to: Identity

  @doc "Lists a series' coordinates with ordered episode memberships preloaded."
  defdelegate list_episode_coordinates(series), to: Identity, as: :list_coordinates

  ## Alternate-season numbering (A6) — carved out to `Cinder.Catalog.SceneNumbering`.

  defdelegate list_episode_groups(series), to: SceneNumbering
  defdelegate get_episode_group(group_id), to: SceneNumbering
  defdelegate preview_scene_mapping(group_detail, series), to: SceneNumbering
  defdelegate set_scene_numbering_group(series, group_id), to: SceneNumbering
  defdelegate set_scene_numbering_group(series, group_id, opts), to: SceneNumbering
  defdelegate preview_scene_offset(series, from, delta), to: SceneNumbering
  defdelegate save_scene_offset_coordinates(series, from, delta), to: SceneNumbering

  @doc "Builds the plain Catalog-owned identity context used for anime movie acquisition."
  defdelegate anime_movie_acquisition_context(movie), to: MediaProfiles

  @doc "Builds the plain Catalog-owned identity context used for anime series acquisition."
  defdelegate anime_series_acquisition_context(series), to: SeriesCatalog

  @doc "Lists movies, newest first."
  def list_movies do
    Repo.all(from m in Movie, order_by: [desc: m.id])
  end

  @doc "Maps every movie's `tmdb_id` to its pipeline `status`."
  def movie_status_map, do: Map.new(list_movies(), &{&1.tmdb_id, &1.status})

  @doc "Counts movies grouped by pipeline `status` (`%{status => count}`)."
  def movie_status_counts do
    Repo.all(from m in Movie, group_by: m.status, select: {m.status, count(m.id)}) |> Map.new()
  end

  @doc "The `limit` most-recently-updated movies, newest first (dashboard recent-activity slice)."
  def recent_movies(limit) do
    Repo.all(from m in Movie, order_by: [desc: m.updated_at], limit: ^limit)
  end

  @doc "Subscribes the caller to movie state-change broadcasts (`{:movie_updated, movie}`)."
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @doc "Fetches full movie details from TMDB (the details endpoint carries `imdb_id`)."
  def get_movie(tmdb_id), do: tmdb().get_movie(tmdb_id)

  @doc "Fetches a movie by primary key, or `nil`."
  def get_movie_by_id(id), do: Repo.get(Movie, id)

  @doc """
  Refreshes a movie's descriptive TMDB metadata (overview/runtime/genres/rating/release date).
  Returns the refreshed `%Movie{}`; on a TMDB error it logs and returns the row unchanged so the
  detail page still renders. Descriptive, not pipeline state — writes via
  `Movie.metadata_changeset/2`, never `transition/2`.

  """
  def enrich_movie(%Movie{} = movie),
    do:
      backfill_metadata(
        movie,
        &tmdb().get_movie(&1.tmdb_id),
        &Movie.metadata_changeset/2,
        "movie"
      )

  @doc """
  Refreshes a series' descriptive TMDB metadata (overview/genres/rating/first air date) with a
  lightweight `get_series` fetch, not the full `Cinder.Catalog.SeriesRefresh.refresh_series/1`
  season walk. Returns the refreshed `%Series{}` (or the row unchanged, logged, on a TMDB error).
  No broadcast — the caller reloads its own tree.
  """
  defdelegate enrich_series(series), to: SeriesCatalog

  # Field-wise, per-locale merge for localization maps: a locale absent from the incoming
  # payload keeps its stored entry, and incoming blank/nil fields never clobber a stored value —
  # a transient/partial TMDB payload can only add or refresh, never strip (stale beats gone for
  # display-only data). Public (not private): also called from `Cinder.Catalog.SeriesRefresh`'s
  # `update_series_row/2` and `finalize_or_restore/4` (episode localization merge).
  @doc false
  def merge_localizations(stored, new) do
    cleaned = for {locale, entry} <- new || %{}, into: %{}, do: {locale, drop_blank_fields(entry)}
    Map.merge(stored || %{}, cleaned, fn _locale, old, incoming -> Map.merge(old, incoming) end)
  end

  defp drop_blank_fields(entry),
    do: for({k, v} <- entry, is_binary(v) and v != "", into: %{}, do: {k, v})

  defp merge_info_localizations(record, info) do
    case Map.fetch(info, :localizations) do
      {:ok, new} -> Map.put(info, :localizations, merge_localizations(record.localizations, new))
      :error -> info
    end
  end

  # Shared descriptive-metadata refresh for a movie/series row. `fetch` and `changeset` are
  # the type's TMDB call + metadata changeset; `label` is for the log line. `updated_at` is
  # never written: this read-triggered refresh must not reorder the dashboard's Recent slice or
  # overwrite a concurrent pipeline transition's timestamp. On a TMDB error, log and return the
  # row unchanged so the page still renders. Public (not private): also called from
  # `Cinder.Catalog.SeriesCatalog.enrich_series/1`.
  @doc false
  def backfill_metadata(record, fetch, changeset, label) do
    case fetch.(record) do
      {:ok, info} ->
        changes = changeset.(record, merge_info_localizations(record, info)).changes

        if changes != %{} do
          schema = record.__struct__

          Repo.update_all(
            from(r in schema, where: r.id == ^record.id),
            set: Map.to_list(changes)
          )
        end

        Repo.get(record.__struct__, record.id) || record

      error ->
        Logger.warning("metadata backfill failed for #{label} #{record.id}: #{inspect(error)}")
        record
    end
  end

  @doc "Lists movies in a given pipeline `status`."
  def list_by_status(status) do
    Repo.all(from m in Movie, where: m.status == ^status)
  end

  @doc "Available movies that have an imported file (subtitle-fetch candidates)."
  def list_available_movies_with_file do
    Repo.all(from m in Movie, where: m.status == :available and not is_nil(m.file_path))
  end

  @doc "Episodes with an imported file, season+series+scene-coordinates preloaded (subtitle-fetch candidates)."
  defdelegate list_episodes_with_file(), to: SeriesCatalog

  @doc false
  def get_episode_by_id(id), do: Repo.get(Episode, id)

  # --- pipeline state matrix -----------------------------------------------------------------
  #
  # The legal from→to graph for movie pipeline transitions, inventoried from every real (lib/)
  # caller of transition/2,3: Cinder.Download.start/1 (search → downloading/no_match/
  # search_failed), Cinder.Download.Poller's advance/import/upgrade passes (downloading →
  # downloaded/import_failed/requested, downloaded → available/import_failed, available ⇄
  # upgrading), retry_movie/1 (a parked status → requested), and reconcile_movie/1's manual/
  # restart-recovery re-grab (a parked status → downloading). A self-transition (status
  # unchanged) is always legal — many writers re-affirm the current status while only touching a
  # counter or download-metric field (retry_or_fail/2, update_movie_download_metrics/2).
  #
  # `:requested` is kept a permissive source for every other status: real callers only ever jump
  # :requested → :searching/:downloading/:no_match/:search_failed (the last two via the
  # pre-:searching :no_imdb_id/:tmdb_unavailable branches of Download.start/1) and :requested →
  # :cancelled (transition/2's own documented contract — see catalog_test.exs "accepts :cancelled
  # as a valid status"), but the test suite also uses the unguarded API as a one-hop fixture
  # shortcut (test/support/catalog_fixtures.ex's movie_fixture/1) to seed a movie directly at
  # :available/:downloaded/:upgrading/:import_failed without walking the whole pipeline.
  # Allowing that here is a deliberate, flagged accommodation of test/fixture convenience, not a
  # real pipeline edge.
  #
  # `:downloading`/`:downloaded` → `:cancelled`: real per `@cancellable_movie_statuses` (a
  # `:downloading` or freshly-`:downloaded` movie can be cancelled) — production reaches it via
  # `cancel_movie/2`'s own `do_cancel_txn/2` (see the bypass note below), but the pair itself is a
  # genuine, intentional business rule, so it is listed here too rather than only tolerated.
  #
  # Bypasses NOT covered by this matrix (pre-existing, not introduced here): cancel_movie/1's
  # do_cancel_txn/1, abort_upgrade/2, and Cinder.Catalog.ReleaseVerification's hold/reject/retry
  # writers build `Movie.transition_changeset/2` directly and write via `Repo.update`/`update_all`
  # without ever calling transition/2,3 — they already carry their own guard (a pattern-matched
  # function head or a compare-and-swap on other fields), so they are unaffected by (and not
  # gated by) this matrix.
  @movie_transitions %{
    searching: [:downloading, :no_match, :search_failed, :cancelled],
    downloading: [:downloaded, :import_failed, :requested, :cancelled],
    downloaded: [:available, :import_failed, :cancelled],
    available: [:upgrading],
    upgrading: [:available],
    no_match: [:requested, :downloading],
    search_failed: [:requested, :downloading],
    import_failed: [:requested, :downloading],
    cancelled: []
  }

  defp legal_movie_transition?(from, to) when from == to, do: true
  defp legal_movie_transition?(:requested, _to), do: true
  defp legal_movie_transition?(from, to), do: to in Map.get(@movie_transitions, from, [])

  # Builds + matrix-checks the transition changeset without writing: {:ok, changeset} once the
  # changeset is valid AND `from → to` is legal, else {:error, invalid_changeset} or
  # {:error, {:illegal_transition, from, to}}. Shared by the unguarded and guarded write paths so
  # neither can drift from the other's notion of "legal."
  defp validate_movie_transition(movie, attrs, from) do
    case Movie.transition_changeset(movie, attrs) do
      %{valid?: false} = invalid -> {:error, invalid}
      %{valid?: true} = changeset -> check_movie_transition(changeset, from)
    end
  end

  defp check_movie_transition(changeset, from) do
    to = Ecto.Changeset.get_field(changeset, :status)

    if legal_movie_transition?(from, to),
      do: {:ok, changeset},
      else: {:error, {:illegal_transition, from, to}}
  end

  @doc """
  Applies a pipeline state transition and, on success, broadcasts
  `{:movie_updated, movie}` on the `"movies"` topic. This is the single
  choke-point for state changes — every transition broadcasts exactly once.
  `attrs` must set `:status`; it may also set `:download_id`, `:download_protocol`,
  `:imdb_id`, `:file_path`, `:content_path`, `:import_attempts`, and `:search_attempts`.

  Rejects an illegal from→to pair (per `@movie_transitions`) with
  `{:error, {:illegal_transition, from, to}}` before writing.
  """
  def transition(movie, attrs, opts \\ [])

  def transition(%Movie{status: from} = movie, attrs, []) do
    with {:ok, changeset} <- validate_movie_transition(movie, attrs, from),
         {:ok, updated} <- Repo.update(changeset) do
      broadcast({:movie_updated, updated})
      emit_transition(:movie, updated.status)
      {:ok, updated}
    end
  end

  # Guarded variant (`expect: status`): the write lands only if the row's status in the
  # DB still matches — one atomic conditional UPDATE. The pollers pass the status they
  # read at tick start, so a write-back after seconds of indexer/client I/O can never
  # resurrect a movie the user cancelled (or otherwise re-decided) in that window.
  # Returns {:error, :stale_status} on a miss; callers treat it as "skip, re-derive
  # next tick". `select: m` makes SQLite RETURNING hand back the post-update row, so
  # the broadcast payload is the fresh DB state, not the poller's tick-start snapshot
  # patched in memory (views upsert the payload directly into their assigns).
  def transition(%Movie{} = movie, attrs, expect: expected) do
    movie
    |> run_guarded_movie_transition(attrs, expected)
    |> publish_guarded_movie_transition()
  end

  def transition(%Movie{} = movie, attrs, opts) when is_list(opts) do
    expected = Keyword.fetch!(opts, :expect)
    stage_ids = Keyword.get(opts, :import_stage_ids, [])

    movie
    |> run_guarded_movie_transition(attrs, expected, fn _updated ->
      ImportStage.mark_committed!(stage_ids)
    end)
    |> publish_guarded_movie_transition()
  end

  @doc false
  def account_movie_intent_retry(
        %Intent{kind: :movie, status: :reserved} = intent,
        retry_attrs,
        reason
      )
      when is_map(retry_attrs) do
    result =
      Repo.transaction(fn ->
        case claim_intent_retry_generation(intent, retry_attrs) do
          {:ok, claimed} -> account_claimed_movie_retry(claimed)
          :stale_generation -> :stale_generation
        end
      end)

    publish_movie_intent_retry(result, reason)
  end

  defp claim_intent_retry_generation(intent, retry_attrs) do
    observed_attempt = intent.attempt_count || 0

    case Repo.update_all(
           from(i in Intent,
             where:
               i.id == ^intent.id and i.status == :reserved and
                 i.attempt_count == ^observed_attempt,
             select: i
           ),
           set: Map.to_list(retry_attrs) ++ [updated_at: now()]
         ) do
      {1, [claimed]} -> {:ok, claimed}
      {0, _} -> :stale_generation
    end
  end

  defp account_claimed_movie_retry(%Intent{target_id: movie_id}) do
    case Repo.get(Movie, movie_id) do
      %Movie{status: status} = movie when status in [:requested, :searching] ->
        account_active_movie_retry(movie)

      _other ->
        {:retry, nil}
    end
  end

  defp account_active_movie_retry(movie) do
    attempts = (movie.search_attempts || 0) + 1

    if attempts >= @max_search_attempts do
      case guarded_movie_transition(movie, %{status: :search_failed}, movie.status) do
        {:ok, parked} ->
          intent_ids = Download.fence_movie_cleanup(parked, include_remote: false)
          {:parked, parked, intent_ids}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      case guarded_movie_transition(
             movie,
             %{status: movie.status, search_attempts: attempts},
             movie.status
           ) do
        {:ok, updated} -> {:retry, updated}
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  # Transaction-safe state-change primitive: every guarded movie writer uses this exact changeset
  # and compare-and-swap update. It performs no publication, so callers publish only after their
  # encompassing transaction commits. The matrix check runs on the caller-declared `expected`
  # status (not a fresh read of `movie.status`, which may already be stale) — a pair the matrix
  # rejects short-circuits before ever attempting the DB write; a pair the matrix allows still
  # goes through the ordinary compare-and-swap, so a genuinely stale row (status moved on
  # concurrently) keeps returning {:error, :stale_status} exactly as before.
  defp guarded_movie_transition(movie, attrs, expected) do
    with {:ok, changeset} <- validate_movie_transition(movie, attrs, expected) do
      case Repo.update_all(
             from(m in Movie, where: m.id == ^movie.id and m.status == ^expected, select: m),
             set: Map.to_list(changeset.changes) ++ [updated_at: now()]
           ) do
        {1, [updated]} -> {:ok, updated}
        {0, _} -> {:error, :stale_status}
      end
    end
  end

  defp publish_movie_intent_retry({:ok, {:retry, nil}}, _reason), do: :ok
  defp publish_movie_intent_retry({:ok, :stale_generation}, _reason), do: :ok

  defp publish_movie_intent_retry({:ok, {:retry, updated}}, _reason) do
    broadcast({:movie_updated, updated})
    :ok
  end

  defp publish_movie_intent_retry({:ok, {:parked, parked, intent_ids}}, reason) do
    broadcast({:movie_updated, parked})
    Notifier.notify({:movie_failed, parked, reason})
    Download.cleanup_intents(intent_ids)
    :ok
  end

  defp publish_movie_intent_retry({:error, reason}, _submission_reason), do: {:error, reason}

  defp run_guarded_movie_transition(
         movie,
         attrs,
         expected,
         after_update \\ fn _updated -> :ok end
       ) do
    Repo.transaction(fn ->
      case guarded_movie_transition(movie, attrs, expected) do
        {:ok, updated} ->
          after_update.(updated)
          updated

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc false
  def publish_guarded_movie_transition({:ok, updated}) do
    broadcast({:movie_updated, updated})
    emit_transition(:movie, updated.status)
    {:ok, updated}
  end

  def publish_guarded_movie_transition({:error, reason}), do: {:error, reason}

  # `[:cinder, :transition]` fires once per successful write at Catalog's pipeline-state
  # choke-points (`transition/2,3`, `transition_episode/2`, and atomic episode adoption) — never
  # at a call site, so instrumentation can't drift from "every writer goes through Catalog".
  defp emit_transition(kind, to_status) when kind in [:movie, :episode] do
    :telemetry.execute([:cinder, :transition], %{count: 1}, %{kind: kind, to: to_status})
  end

  @doc "Updates a downloading movie's progress snapshot without broadcasting equal values."
  def update_movie_download_metrics(%Movie{} = movie, attrs) do
    changes = metric_changes(movie, attrs)

    if changes == %{} do
      {:ok, movie}
    else
      transition(movie, Map.put(changes, :status, movie.status), expect: movie.status)
    end
  end

  @doc "Updates an in-flight grab's progress snapshot and broadcasts its owning series."
  defdelegate update_grab_download_metrics(grab, attrs), to: Grabs

  defp metric_changes(record, attrs) do
    attrs =
      attrs
      |> Map.take(@download_metric_fields)
      |> keep_progress_high_water(record.download_progress)

    Map.reject(attrs, fn {field, value} -> Map.get(record, field) == value end)
  end

  defp keep_progress_high_water(%{download_progress: progress} = attrs, previous)
       when is_number(progress) and (is_nil(previous) or progress >= previous),
       do: attrs

  defp keep_progress_high_water(attrs, _previous), do: Map.delete(attrs, :download_progress)

  # Parked terminal states a user can re-queue. An in-flight movie must never be
  # yanked back to :requested, so retry guards on status server-side (the /status
  # button is a client-sent event — don't trust it to only fire for parked rows).
  @retryable [:no_match, :search_failed, :import_failed]

  @doc """
  Re-queues a parked movie: resets it to `:requested` and zeroes the attempt
  counters so the poller picks it up fresh. Returns `{:error, :not_retryable}`
  for any non-parked movie. Replaces the old IEx reset.
  """
  def retry_movie(%Movie{status: :import_failed, verification_hold_origin: origin} = movie)
      when origin in [:download, :upgrade] do
    status = if origin == :download, do: :downloaded, else: :upgrading

    ReleaseVerification.transition_verification_hold(movie, %{
      status: status,
      import_attempts: 0,
      verification_hold_origin: nil
    })
  end

  def retry_movie(%Movie{status: status} = movie) when status in @retryable do
    # Clear the stale download fields: a re-queued movie has no download yet, so leaving an old
    # download_id/protocol/file_path/content_path/release_title on a :requested row is misleading
    # and a latent misroute if anything reads them before re-download.
    # expect: — the caller's struct is a client-rendered snapshot; if the movie already re-entered
    # the pipeline (re-searched, downloading), the retry must miss rather than yank an in-flight
    # movie back and orphan its download.
    result =
      transition(
        movie,
        %{
          status: :requested,
          search_attempts: 0,
          import_attempts: 0,
          download_id: nil,
          download_protocol: nil,
          release_title: nil,
          release_policy_snapshot: nil,
          file_path: nil,
          content_path: nil
        },
        expect: movie.status
      )

    # Only after the re-queue commits: clear this movie's `:stalled` blocklist rows so the operator
    # gets one fresh chance at a stall-reaped release (a stall is a timeout, not a proven-bad
    # release; still dead ⇒ the reaper re-reaps and re-blocks). The deterministic rows
    # (:wrong_audio_language/:bad_torrent/…) PERSIST — clearing those would reintroduce the re-grab
    # loop. Post-commit so a `:stale_status` miss (the movie already left the parked state) leaves
    # no side effect, matching `reap_stalled_movie/1` and `park/3`.
    with {:ok, _requested} <- result, do: clear_stalled_blocklist(movie: movie.id)

    result
  end

  def retry_movie(%Movie{}), do: {:error, :not_retryable}

  @doc """
  Total items needing an operator action, for the admin Activity nav badge: parked/held movies
  that show a Retry (`#{inspect(@retryable)}`) plus grabs in a mapping/verification/residual hold
  (`Grabs.count_grab_holds/0`). Defined to match exactly what `CinderWeb.ActivityLive` renders
  actions for, so the badge and the page agree; `0` means "no badge".

  `@retryable` is the movie hold set on purpose: a movie verification hold parks at
  `:import_failed` (with `verification_hold_origin`), already in this set, and `anime_hold`
  movies (`:requested`/`:searching` + a hold reason) show no action, so they are excluded.
  """
  def count_operator_holds do
    movie_holds = Repo.aggregate(from(m in Movie, where: m.status in @retryable), :count)
    movie_holds + Grabs.count_grab_holds()
  end

  @doc """
  Reaps a stalled `:downloading` movie (the stall reaper): one transaction guard-resets it to
  `:requested` (clearing the dead download fields, bumping `search_attempts` for backoff) and fences
  the client download for removal; after commit the client job + reserved intent are torn down, the
  release is blocklisted `:stalled` (operator-recoverable via `retry_movie/1`), and the reset is
  announced. Returns `{:error, :stale_status}` if the movie left `:downloading` mid-tick (the poller
  ignores it and re-derives next tick). Mirrors the guarded-write + post-commit-publish pattern of
  `account_active_movie_retry/1`; the fence reads the **pre-clear** struct (its `download_id`).
  """
  def reap_stalled_movie(%Movie{status: :downloading} = movie) do
    result =
      Repo.transaction(fn ->
        case guarded_movie_transition(
               movie,
               %{
                 status: :requested,
                 search_attempts: (movie.search_attempts || 0) + 1,
                 download_id: nil,
                 download_protocol: nil,
                 release_title: nil,
                 release_policy_snapshot: nil,
                 content_path: nil
               },
               :downloading
             ) do
          {:ok, requested} -> {requested, Download.fence_movie_cleanup(movie)}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {requested, intent_ids}} <- result do
      Download.cleanup_intents(intent_ids)
      # `movie` (pre-clear) still carries release_title; `requested` has it nil. Post-commit so a
      # stale_status rollback never writes a spurious permanent row.
      block_release(movie, :stalled)
      broadcast({:movie_updated, requested})
      Notifier.notify({:movie_failed, requested, :stalled})
      {:ok, requested}
    end
  end

  def reap_stalled_movie(%Movie{}), do: {:error, :not_reapable}

  @doc """
  Reaps a stalled `:upgrading` movie (the stall reaper): reverts it to `:available` keeping the live
  library file (`file_path`/`imported_*` untouched), fences the stuck replacement download for
  removal, and blocklists the release `:stalled`. Mirrors `abort_upgrade/2` but guarded (a
  concurrent completion/abort makes it a `{:error, :stale_status}` no-op) and blocklisting. Removes
  the client job — unlike a plain revert, which would strand the dead replacement torrent.
  """
  def reap_stalled_upgrade(%Movie{status: :upgrading} = movie) do
    result =
      Repo.transaction(fn ->
        case guarded_movie_transition(
               movie,
               %{
                 status: :available,
                 download_id: nil,
                 download_protocol: nil,
                 release_title: nil,
                 release_policy_snapshot: nil
               },
               :upgrading
             ) do
          {:ok, reverted} -> {reverted, Download.fence_movie_cleanup(movie)}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {reverted, intent_ids}} <- result do
      Download.cleanup_intents(intent_ids)
      block_release(movie, :stalled)
      broadcast({:movie_updated, reverted})
      Notifier.notify({:movie_upgrade_failed, reverted, :stalled})
      {:ok, reverted}
    end
  end

  def reap_stalled_upgrade(%Movie{}), do: {:error, :not_reapable}

  @doc "Atomically parks an unverifiable Movie release without clearing its frozen ownership."
  defdelegate hold_movie_verification(movie, origin, attempts), to: ReleaseVerification

  ## Manual grab + the grab lifecycle — carved out to `Cinder.Catalog.Grabs`.

  defdelegate manual_grab_movie(movie, release), to: Grabs
  defdelegate manual_grab_tv(series, season_number, release), to: Grabs

  # Plain field write shared by set_movie_language/2 and the approval-fill
  # (fill_movie_language/2, via apply_requester_language/3): language_changeset + Repo.update,
  # no status/retry side effects.
  defp write_movie_language(movie, language) do
    movie |> Movie.language_changeset(%{preferred_language: language}) |> Repo.update()
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # Parked statuses where a language change should trigger a fresh search.
  # :import_failed means a release was found but couldn't be written — not a language issue.
  @language_retry_statuses [:no_match, :search_failed]

  @doc """
  Sets a movie's preferred language. If the movie is parked because no release in
  the desired language was found, re-queues it so the poller re-searches. Otherwise
  just updates the field — the download/import pipeline is not disturbed for
  in-flight or available movies (no quality-upgrade re-grab in this slice).
  """
  def set_movie_language(%Movie{} = movie, language) do
    case write_movie_language(movie, language) do
      {:ok, updated} ->
        if updated.status in @language_retry_statuses do
          retry_movie(updated)
        else
          broadcast({:movie_updated, updated})
          {:ok, updated}
        end

      {:error, _changeset} = error ->
        error
    end
  end

  # Status-neutral pick fill for request approval (apply_requester_language/3, via
  # apply_confirmed_media/3): writes the field and broadcasts, WITHOUT set_movie_language/2's
  # retry branch — approving a request for an existing PARKED movie must not silently re-queue
  # it (round-3 finding 2).
  defp fill_movie_language(movie, language) do
    case write_movie_language(movie, language) do
      {:ok, updated} ->
        broadcast({:movie_updated, updated})
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Persists the probed media info (audio languages + embedded/sidecar subtitle languages) onto a
  movie or episode. Descriptive-only — used by the import capture and the backfill task; not a
  status transition.
  """
  def set_media_info(%Movie{} = movie, info) do
    with {:ok, updated} <-
           movie |> Movie.media_info_changeset(media_info_attrs(info)) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  def set_media_info(%Episode{} = episode, info) do
    with {:ok, updated} <-
           episode |> Episode.media_info_changeset(media_info_attrs(info)) |> Repo.update() do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end

  # Translate the bare-keyed capture map to the imported_* column names the changeset casts.
  defp media_info_attrs(info) do
    %{
      imported_audio_languages: Map.get(info, :audio_languages, []),
      imported_embedded_subtitles: Map.get(info, :embedded_subtitles, []),
      imported_sidecar_subtitles: Map.get(info, :sidecar_subtitles, [])
    }
  end

  @doc """
  Sets a series' preferred language and zeroes `search_attempts` on its still-wanted
  episodes (no file, no grab) so a previously language-stranded season re-enters the
  search sweep. Available / in-flight episodes are untouched.
  """
  defdelegate set_series_language(series, language), to: SeriesCatalog

  # The active set a movie can be cancelled out of (mirrors @retryable's shape).
  # transition/2 does NOT validate transitions, so cancel/delete must guard on this
  # explicitly. delete_movie/2 (Phase 2) shares it: an active row with a download_id
  # must be cancelled (which removes the client download), never bare-deleted.
  @cancellable_movie_statuses [:requested, :searching, :downloading, :downloaded]

  @doc "True if `movie` is in an active status that can be cancelled (`#{inspect(@cancellable_movie_statuses)}`)."
  def cancellable?(%Movie{status: :import_failed, verification_hold_origin: :download}), do: true
  def cancellable?(%Movie{status: status}), do: status in @cancellable_movie_statuses

  @doc """
  Cancels an in-flight movie: removes the orphaned client download (if any) and transitions
  it to `:cancelled`. Guards `cancellable?/1` server-side (`transition/2` does not validate the
  transition). Returns `{:error, :not_cancellable}` for a terminal/available/parked movie.

  The `:cancelled` transition, audit row, and durable cleanup fence are written in one transaction.
  Client I/O runs only after commit; failures leave the fence for background reconciliation.
  """
  def cancel_movie(
        %Movie{status: :import_failed, verification_hold_origin: :download} = movie,
        actor
      ),
      do: ReleaseVerification.clear_verification_hold(movie, actor, :cancelled, :cancel_movie)

  def cancel_movie(%Movie{} = movie, actor) do
    if cancellable?(movie) do
      with {:ok, {updated, intent_ids}} <- do_cancel_txn(movie, actor) do
        Download.cleanup_intents(intent_ids)
        broadcast({:movie_updated, updated})
        {:ok, updated}
      end
    else
      {:error, :not_cancellable}
    end
  end

  defp do_cancel_txn(movie, actor) do
    Repo.transaction(fn ->
      case movie
           |> Movie.transition_changeset(%{status: :cancelled, release_policy_snapshot: nil})
           |> Repo.update() do
        {:ok, updated} ->
          updated = Repo.get!(Movie, updated.id)
          intent_ids = Download.fence_movie_cleanup(updated)
          Audit.log_or_rollback(actor, :cancel_movie, updated, %{from: movie.status})
          {updated, intent_ids}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Aborts an in-flight movie upgrade: removes the replacement download (best-effort) and reverts
  the movie to `:available`, keeping the existing library file. Distinct from `cancel_movie/2` —
  an `:upgrading` movie must NOT become `:cancelled` (it still has a good file). Returns
  `{:error, :not_upgrading}` otherwise.

  The `:available` revert, audit row, and durable cleanup fence are written in one transaction.
  Client I/O runs only after commit; failures leave the fence for background reconciliation.
  """
  def abort_upgrade(%Movie{status: :upgrading} = movie, actor) do
    result =
      Repo.transaction(fn ->
        cleanup_source = Repo.get!(Movie, movie.id)

        case cleanup_source
             |> Movie.transition_changeset(%{
               status: :available,
               download_id: nil,
               download_protocol: nil,
               release_title: nil,
               release_policy_snapshot: nil
             })
             |> Repo.update() do
          {:ok, updated} ->
            updated = Repo.get!(Movie, updated.id)
            intent_ids = Download.fence_movie_cleanup(cleanup_source)
            Audit.log_or_rollback(actor, :abort_upgrade, updated, %{from: :upgrading})
            {updated, intent_ids}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, {updated, intent_ids}} <- result do
      Download.cleanup_intents(intent_ids)
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  def abort_upgrade(
        %Movie{status: :import_failed, verification_hold_origin: :upgrade} = movie,
        actor
      ),
      do: ReleaseVerification.clear_verification_hold(movie, actor, :available, :abort_upgrade)

  def abort_upgrade(%Movie{}, _actor), do: {:error, :not_upgrading}

  @doc """
  Deletes a movie's DB row. An active row's tracked download is captured in a durable cleanup
  fence in the same transaction, then removed after commit. Broadcasts
  `{:movie_deleted, id}` on the `"movies"` topic.

  Pass `delete_files: true` in `opts` to also unlink the on-disk library file after the row is
  deleted (best-effort: a failed unlink is logged, not propagated). Default leaves files on disk.
  The audit row is written last, after the unlink is attempted, so `files_deleted` records what
  actually happened rather than the caller's intent — see `audit_deletion/5`.
  """
  def delete_movie(%Movie{} = movie, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)

    prepare = fn fresh ->
      # Reap this title's approved request(s) in the same transaction — a movie gone but its
      # :approved request left behind strands the requester on a stale "Approved" badge with the
      # Add button suppressed. Pending/denied are deliberately left (see reap_approved_for_target/2).
      Requests.reap_approved_for_target(["movie"], fresh.tmdb_id)

      include_remote? =
        cancellable?(fresh) or fresh.status == :upgrading or
          fresh.verification_hold_origin in [:download, :upgrade]

      Download.fence_movie_cleanup(fresh, include_remote: include_remote?)
    end

    with {:ok, {deleted, intent_ids}} <- delete_record(movie, prepare) do
      Download.cleanup_intents(intent_ids)

      unlinked =
        if delete_files?,
          do: [{deleted.file_path, best_effort_delete_file(deleted.file_path)}],
          else: []

      audit_deletion(actor, :delete_movie, deleted, delete_files?, unlinked)
      broadcast_movie_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  # Deletes a movie or series row (no audit write here — the caller writes it post-commit, after
  # any file unlink it performs, via audit_deletion/5, so the audit can record the true outcome
  # rather than the caller's intent). A concurrent delete (Repo.delete/1 raises) becomes a clean
  # {:error, :stale_entry}. Public (not private): also called from
  # `Cinder.Catalog.SeriesCatalog`'s `delete_series/3`.
  @doc false
  def delete_record(record, prepare) do
    Repo.transaction(fn ->
      module = record.__struct__

      case Repo.update_all(from(r in module, where: r.id == ^record.id), set: [updated_at: now()]) do
        {1, _} -> :ok
        {0, _} -> Repo.rollback(:stale_entry)
      end

      fresh = Repo.get!(module, record.id)
      prepared = prepare.(fresh)

      case Repo.delete(fresh) do
        {:ok, deleted} -> {deleted, prepared}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # Best-effort library-file unlink shared by the movie and series delete paths: a failed unlink is
  # logged, never propagated, so it can't strand the row delete — but (unlike before) the real
  # :ok/{:error, reason} outcome is returned so audit_deletion/5 can record it truthfully instead
  # of just echoing the caller's delete_files? intent.
  # ponytail: no nil clause here — Library.delete_file/1 already guards nil/"" and returns :ok.
  # Public (not private): also called from `Cinder.Catalog.SeriesCatalog`'s `delete_series/3`.
  @doc false
  def best_effort_delete_file(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("library file delete failed for #{inspect(path)}: #{inspect(reason)}")
        error
    end
  end

  # Writes the post-commit deletion audit row with the ACTUAL per-file unlink outcome: when
  # delete_files? is false nothing was attempted, so `files_deleted` is trivially false (unchanged
  # from before); when true, it's true only if every attempted unlink succeeded. A partial/total
  # failure is recorded with the leftover paths+reasons and logged loudly — there is no
  # outbox/retry here (household scale), so this log line + the audit detail are the only trace.
  # Runs strictly after the deletion transaction commits and the unlinks are attempted, so a
  # failure writing the audit row itself can only be logged, never rolled back into an
  # already-committed delete. Public (not private): also called from
  # `Cinder.Catalog.SeriesCatalog`'s `delete_series/3`.
  @doc false
  def audit_deletion(actor, action, deleted, delete_files?, unlink_results) do
    detail = deletion_audit_detail(deleted, delete_files?, unlink_results)

    case Audit.log(actor, action, deleted, detail) do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "#{action} audit row failed for #{inspect(deleted.__struct__)} #{deleted.id}: " <>
            inspect(changeset.errors)
        )
    end
  end

  defp deletion_audit_detail(deleted, false, _unlink_results) do
    %{title: deleted.title, files_deleted: false}
  end

  defp deletion_audit_detail(deleted, true, unlink_results) do
    failed = for {path, {:error, reason}} <- unlink_results, do: "#{path}: #{inspect(reason)}"
    file_paths = Enum.map(unlink_results, &elem(&1, 0))

    if failed == [] do
      %{title: deleted.title, files_deleted: true, file_paths: file_paths}
    else
      Logger.warning(
        "#{inspect(deleted.__struct__)} #{deleted.id} delete: #{length(failed)} file(s) left on disk: #{inspect(failed)}"
      )

      %{
        title: deleted.title,
        files_deleted: false,
        file_paths: file_paths,
        failed_unlinks: failed
      }
    end
  end

  @doc "Fetches a movie by TMDB id, or `nil`."
  def get_movie_by_tmdb_id(tmdb_id), do: Repo.get_by(Movie, tmdb_id: tmdb_id)

  @doc """
  Returns `{:ok, movie, :existing}` for the existing row (at its current status) if one
  already exists for `attrs.tmdb_id`, or `{:ok, movie, :created}` after inserting a new
  movie at `:requested`.

  No broadcast here — this may run inside a caller's transaction (a savepoint when joined
  to one already open), so announcing creation is the caller's post-commit job
  (`Cinder.Requests.finalize_movie_approval/2` broadcasts `{:movie_created, movie}` once
  its transaction has committed, using the returned `:created` marker).

  Confirm/fill (the requester's media-profile confirmation and language pick) is NOT applied
  here — `Cinder.Requests` calls `apply_confirmed_media/3` itself, after its approval
  transaction commits, so a fill/confirm failure can't roll back the atomic movie-creation +
  request-approval write. A fresh insert already carries both fields straight from `attrs`
  (`Movie.changeset/2` casts them), so nothing is lost for the create case.

  A lost insert race (unique_constraint on `:tmdb_id`) is handled by re-fetching the
  winner and returning it as `:existing`, so callers always get `{:ok, movie, marker}`.
  """
  def find_or_create_at_requested(attrs, aliases \\ []) do
    case get_movie_by_tmdb_id(attrs.tmdb_id) do
      %Movie{} = movie -> {:ok, movie, :existing}
      nil -> do_insert_at_requested(attrs, aliases)
    end
  end

  @doc """
  Adoption entry for movies: returns an existing row after transitioning it to `:available`, or
  inserts a new row already at `:available` with `file_path` set.

  A fresh row is never visible at `:requested`, so the movie poller cannot claim an on-disk file
  for download between creation and adoption. No broadcast on the create path — the caller
  announces `:created` after this insert commits, mirroring `find_or_create_at_requested/2`.
  """
  def find_or_create_at_available(attrs, file_path)
      when is_binary(file_path) and file_path != "" do
    case get_movie_by_tmdb_id(attrs.tmdb_id) do
      %Movie{} = movie -> transition_existing_movie_to_available(movie, file_path)
      nil -> do_insert_at_available(attrs, file_path)
    end
  end

  def find_or_create_at_available(_attrs, _file_path), do: {:error, :invalid_file_path}

  @doc "Fetches requested-movie details and aliases before any Catalog write."
  def prepare_requested_movie(attrs) do
    tmdb_id = Map.fetch!(attrs, :tmdb_id)

    case get_movie_by_tmdb_id(tmdb_id) do
      %Movie{} ->
        {:ok, %{attrs: attrs, aliases: []}}

      nil ->
        with {:ok, info} <- get_movie(tmdb_id),
             {:ok, aliases} <- tmdb().get_movie_alternative_titles(info.tmdb_id) do
          create_attrs =
            info
            |> Map.take([
              :tmdb_id,
              :imdb_id,
              :title,
              :year,
              :poster_path,
              :original_language,
              :localizations
            ])
            |> Map.merge(Map.take(attrs, [:preferred_language, :media_profile]))

          {:ok, %{attrs: create_attrs, aliases: aliases}}
        end
    end
  end

  defp do_insert_at_requested(attrs, aliases) do
    result =
      Repo.transaction(fn ->
        with {:ok, movie} <- %Movie{} |> Movie.changeset(attrs) |> Repo.insert(),
             {:ok, _aliases} <-
               Identity.replace_provider_aliases(
                 movie,
                 "tmdb",
                 "alternative_titles",
                 :inferred,
                 aliases
               ) do
          movie
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, movie} ->
        {:ok, movie, :created}

      {:error, reason} ->
        # Lost the insert race (unique_constraint :tmdb_id) — the row now exists.
        case get_movie_by_tmdb_id(attrs.tmdb_id) do
          %Movie{} = movie -> {:ok, movie, :existing}
          nil -> {:error, reason}
        end
    end
  end

  defp do_insert_at_available(attrs, file_path) do
    result =
      %Movie{status: :available, file_path: file_path}
      |> Movie.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, movie} ->
        {:ok, movie, :created}

      {:error, reason} ->
        case get_movie_by_tmdb_id(attrs.tmdb_id) do
          %Movie{} = movie -> transition_existing_movie_to_available(movie, file_path)
          nil -> {:error, reason}
        end
    end
  end

  defp transition_existing_movie_to_available(
         %Movie{file_path: existing_path},
         _file_path
       )
       when existing_path not in [nil, ""],
       do: {:error, :already_has_file}

  defp transition_existing_movie_to_available(%Movie{} = movie, file_path) do
    case transition(movie, %{status: :available, file_path: file_path}) do
      {:ok, updated} -> {:ok, updated, :existing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Shared confirm+fill sequence for an EXISTING movie or series:
  fills the requester's language pick (if still default), then confirms the requester's
  media-profile proposal (:auto → confirmed only). Order is fill-then-confirm, not the reverse:
  a failed confirm after a successful fill just leaves a plain fill-if-default — benign, and
  a retry picks up where it left off; confirm-then-fill would instead leave a committed profile
  flip with no clean retry surface if the fill then failed.

  Call this OUTSIDE any surrounding `Repo.transaction` — `Cinder.Requests` calls it after its
  approval transaction commits, so a fill/confirm failure here can't roll back an already-
  committed movie/request write. Season approval instead uses
  `Cinder.Catalog.SeriesCatalog.persist_requested_series/4` so request, profile/language,
  and monitoring changes share one transaction without broadcasting mid-transaction.
  """
  def apply_confirmed_media(media, profile, preferred) do
    pre_request_profile = media.media_profile

    with {:ok, media} <- apply_requester_language(media, preferred, pre_request_profile) do
      apply_confirmed_profile(media, profile)
    end
  end

  defp apply_confirmed_profile(%{media_profile: :auto} = media, profile)
       when profile in [:standard, :anime],
       do: set_media_profile(media, profile)

  defp apply_confirmed_profile(media, _profile), do: {:ok, media}

  # Fill-if-default: an existing movie/series whose language was never customized ("original")
  # adopts the requester's non-default pick; a title already customized to a non-default is left
  # untouched (first-customization-wins). A brand-new movie/series already carries `preferred`
  # from its creation attrs/changeset.
  #
  # Guarded on the title's PRE-REQUEST profile (captured by apply_confirmed_media/3 before this
  # or apply_confirmed_profile/2 runs), not its post-confirmation profile: the request that
  # establishes Anime also establishes its audio policy (the pick), while a title that was
  # ALREADY Anime before this request never has its pick mutated — that pick is that title's
  # release policy (audio-mode derivation, see `Cinder.Acquisition.AnimePreferences`), not a
  # discovery convenience, so only a deliberate detail-page edit may change it once a title is
  # Anime.
  #
  # The movie clause fills through fill_movie_language/2 (status-neutral), not
  # set_movie_language/2 — an approval fill must not re-queue a parked movie.
  #
  # One guard for both clauses — these drifted once (the series clause lacked the nil
  # exclusion), so they are deliberately not hand-synced twins anymore.
  defguardp fillable_pick(preferred, pre_request_profile)
            when preferred not in [nil, "original"] and pre_request_profile != :anime

  defp apply_requester_language(
         %Series{preferred_language: "original"} = series,
         preferred,
         pre_request_profile
       )
       when fillable_pick(preferred, pre_request_profile),
       do: SeriesCatalog.set_series_language(series, preferred)

  defp apply_requester_language(
         %Movie{preferred_language: "original"} = movie,
         preferred,
         pre_request_profile
       )
       when fillable_pick(preferred, pre_request_profile),
       do: fill_movie_language(movie, preferred)

  defp apply_requester_language(media, _preferred, _pre_request_profile), do: {:ok, media}

  @doc false
  def broadcast(message), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, message)

  @doc "Broadcasts `{:movie_deleted, id}` on the `\"movies\"` topic so open views drop the row."
  def broadcast_movie_deleted(id), do: broadcast({:movie_deleted, id})

  @doc "Broadcasts `{:movie_created, movie}` on the `\"movies\"` topic — called after a creation transaction commits (Catalog creation itself never broadcasts; see `find_or_create_at_requested/2` and `find_or_create_at_available/2`)."
  def broadcast_movie_created(%Movie{} = movie), do: broadcast({:movie_created, movie})

  ## TV series/season/episode CRUD, monitoring, refresh — carved out to
  ## `Cinder.Catalog.SeriesCatalog` and `Cinder.Catalog.SeriesRefresh`.

  defdelegate get_series_by_tmdb_id(tmdb_id), to: SeriesCatalog
  defdelegate list_series(), to: SeriesCatalog
  defdelegate count_series(), to: SeriesCatalog
  defdelegate series_library_sizes(), to: SeriesCatalog
  defdelegate add_series(tmdb_id), to: SeriesCatalog
  defdelegate add_series(tmdb_id, opts), to: SeriesCatalog
  defdelegate find_or_create_series_at_requested(tmdb_id, season_number), to: SeriesCatalog

  defdelegate find_or_create_series_at_requested(tmdb_id, season_number, preferred),
    to: SeriesCatalog

  defdelegate find_or_create_series_at_requested(
                tmdb_id,
                season_number,
                preferred,
                media_profile
              ),
              to: SeriesCatalog

  defdelegate prepare_requested_series(tmdb_id, preferred, media_profile), to: SeriesCatalog

  defdelegate persist_requested_series(prepared, season_number, preferred, media_profile),
    to: SeriesCatalog

  @series_topic "series"

  @doc "Subscribes the caller to series-change broadcasts (`{:series_updated, series_id}`)."
  def subscribe_series, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @series_topic)

  defdelegate get_series_with_tree(id), to: SeriesCatalog
  defdelegate set_episode_monitored(episode, monitored?), to: SeriesCatalog
  defdelegate set_season_monitored(season, monitored?), to: SeriesCatalog
  defdelegate set_series_monitor_strategy(series, strategy), to: SeriesCatalog

  @doc """
  Single choke-point for episode **pipeline** writes (`file_path`, `grab_id`, attempt counters;
  episode state is derived). On success broadcasts `{:series_updated, series_id}`. `monitored`
  stays in `set_episode_monitored/2`. `expect:` is atomic; `publish: false` defers publication.
  """
  def transition_episode(episode, attrs, opts \\ [])

  def transition_episode(%Episode{} = episode, attrs, []) do
    with {:ok, updated} <- episode |> Episode.transition_changeset(attrs) |> Repo.update() do
      broadcast_series(series_id_for_season(updated.season_id))
      emit_transition(:episode, SeriesCatalog.episode_state(updated))
      {:ok, updated}
    end
  end

  def transition_episode(%Episode{} = episode, attrs, opts) when is_list(opts) do
    expected = opts |> Keyword.fetch!(:expect) |> Map.new()

    with {:ok, updated} <- EpisodeTransition.guarded(episode, attrs, expected) do
      if Keyword.get(opts, :publish, true) do
        publish_episode_transition_batch([updated], series_id_for_season(updated.season_id))
      end

      {:ok, updated}
    end
  end

  @doc false
  def publish_episode_transition_batch(episodes, series_id) do
    broadcast_series(series_id)

    Enum.each(episodes, fn episode ->
      emit_transition(:episode, SeriesCatalog.episode_state(episode))
    end)

    :ok
  end

  defdelegate adopt_episode_files(actions), to: Cinder.Catalog.Adoption

  defdelegate delete_episode_file(episode, actor), to: SeriesCatalog
  defdelegate delete_episode_file(episode, actor, opts), to: SeriesCatalog
  defdelegate delete_season_files(season, actor), to: SeriesCatalog
  defdelegate delete_season_files(season, actor, opts), to: SeriesCatalog

  @doc false
  def now, do: DateTime.truncate(DateTime.utc_now(), :second)

  ## Grab lifecycle and blocklist implementation lives in `Cinder.Catalog.Grabs`.

  defdelegate create_grab(download_id, protocol, episode_ids), to: Grabs
  defdelegate create_grab(download_id, protocol, episode_ids, release_title), to: Grabs
  defdelegate create_grab(download_id, protocol, episode_ids, release_title, opts), to: Grabs
  defdelegate create_grab_from_intent(intent), to: Grabs
  defdelegate record_mapping_result(grab, preflight_result), to: Grabs
  defdelegate retry_grab_mapping(grab), to: Grabs
  defdelegate mark_grab_downloaded(grab, content_path), to: Grabs
  defdelegate increment_grab_attempts(grab), to: Grabs
  defdelegate hold_grab_verification(grab), to: Grabs
  defdelegate retry_grab_verification(grab), to: Grabs
  defdelegate cancel_grab(grab), to: Grabs
  defdelegate cancel_mapping_grab(grab), to: Grabs

  @doc """
  Cancels an entire series WITHOUT deleting it: reaps every grab serving the series (any state,
  including `:downloaded` awaiting import), removing each tracked client download, then
  unmonitors every season and episode so the TV poller's `wanted_episodes` does not re-grab.
  Broadcasts `{:series_updated, id}`. Audited.
  """
  defdelegate cancel_series(series, actor), to: SeriesCatalog

  @doc """
  Deletes a series and its tree. Broadcasts `{:series_deleted, id}`. Audited. Pass
  `delete_files: true` to also unlink every episode `file_path` after the cascade.
  """
  defdelegate delete_series(series, actor), to: SeriesCatalog
  defdelegate delete_series(series, actor, opts), to: SeriesCatalog

  defdelegate episode_ids_for_grab(grab_id), to: Grabs
  defdelegate series_id_for_grab(grab_id), to: Grabs
  defdelegate grab_cleanup_spec(grab, episode_ids), to: Grabs

  @doc """
  Atomically rejects one confirmed movie release: exact-title blocklist, durable remote cleanup,
  and guarded requeue. Upgrade rejection keeps the live library file and imported quality.
  """
  defdelegate reject_movie_release(expected, evidence), to: ReleaseVerification

  @doc """
  Atomically rejects one confirmed episodic release, guarding the resolved grab and its exact
  episode ownership before blocklisting, fencing cleanup, and deleting it.
  """
  defdelegate reject_grab_release(expected, evidence), to: Grabs

  defdelegate block_release(movie, reason), to: Grabs
  defdelegate clear_stalled_blocklist(scope), to: Grabs
  defdelegate block_grab_release(grab, reason), to: Grabs
  defdelegate blocked_release_titles(movie), to: Grabs
  defdelegate blocked_release_titles_for_series(series_id), to: Grabs
  defdelegate increment_search_attempts(episode_ids), to: Grabs
  defdelegate list_grabs_downloading(), to: Grabs
  defdelegate count_grabs_downloading(), to: Grabs
  defdelegate list_grabs_downloaded(), to: Grabs
  defdelegate list_grabs(), to: Grabs
  defdelegate list_mapping_grabs_for_series(series_id), to: Grabs
  defdelegate get_grab(id), to: Grabs
  defdelegate wanted_episodes(), to: SeriesCatalog
  defdelegate manual_search_episodes(series_id, season_number), to: SeriesCatalog
  defdelegate count_wanted_episodes(), to: SeriesCatalog
  defdelegate available_season_keys(), to: SeriesCatalog
  defdelegate available_season_keys(tmdb_id), to: SeriesCatalog
  defdelegate season_progress_keys(), to: SeriesCatalog
  defdelegate count_wanted_episodes(series_id, season_number), to: SeriesCatalog
  defdelegate count_episodes(series_id, season_number), to: SeriesCatalog
  defdelegate max_search_attempts(), to: SeriesCatalog
  defdelegate episode_state(episode), to: SeriesCatalog
  defdelegate episode_state(episode, today), to: SeriesCatalog
  defdelegate search_episode_now(episode), to: SeriesCatalog
  defdelegate search_season_now(season), to: SeriesCatalog
  defdelegate episode_searchable?(episode, profile), to: SeriesCatalog
  defdelegate episode_searchable?(episode, profile, today), to: SeriesCatalog
  defdelegate upcoming_episodes(), to: SeriesCatalog
  defdelegate refresh_series(series), to: SeriesRefresh
  defdelegate finish_grab(grab), to: Grabs
  defdelegate finish_grab(grab, imported), to: Grabs
  defdelegate finish_grab(grab, imported, stage_ids), to: Grabs
  defdelegate commit_grab_imports(grab, imported, residuals), to: Grabs
  defdelegate commit_grab_imports(grab, imported, residuals, stage_ids), to: Grabs
  defdelegate close_grab(grab), to: Grabs
  defdelegate decide_grab_file(file, episode, decision, stage), to: Grabs
  defdelegate park_grab(grab), to: Grabs
  defdelegate reap_stalled_grab(grab), to: Grabs

  defp series_id_for_season(season_id),
    do: Repo.one(from s in Season, where: s.id == ^season_id, select: s.series_id)

  # Resolve the impl at runtime. compile_env! would inline the mock module, which —
  # being defined at runtime by Mox in test_helper.exs — doesn't exist at compile time
  # and warns under --warnings-as-errors. fetch_env! still fails fast if unconfigured.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)

  # Convention: a movie event carries the full struct (a flat row a LiveView patches in place —
  # see broadcast/1's {:movie_updated, movie}); a series event carries only the id, because a
  # series is a tree the detail view re-derives on receipt. A new media type picks the shape that
  # matches it (flat row → struct, tree → id).
  #
  # A nil series_id (e.g. a grab whose episodes were all unlinked) is a no-op, so callers
  # don't each need to guard it.
  @doc false
  def broadcast_series(nil), do: :ok

  def broadcast_series(series_id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_updated, series_id})

  @doc "Broadcasts `{:series_deleted, id}` on the `\"series\"` topic so open views drop the row."
  def broadcast_series_deleted(id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_deleted, id})
end
