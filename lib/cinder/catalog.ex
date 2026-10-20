defmodule Cinder.Catalog do
  @moduledoc """
  Discovery: search TMDB for movies and persist requested ones.

  TMDB is reached only through the `Cinder.Catalog.TMDB` behaviour, resolved from
  config (`config :cinder, :tmdb`) so tests use a Mox mock and never hit the network.

  This module is the public facade over the whole catalog: movie CRUD, the episode
  state-change choke-point, deletion/audit, and broadcasts stay here. Every movie status
  write lives in `Cinder.Catalog.MovieLifecycle`, which callers use directly. Discovery, the TV grab lifecycle, and
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
    Attention,
    Discovery,
    Episode,
    EpisodeTransition,
    Grabs,
    Identity,
    MediaProfiles,
    Movie,
    MovieLifecycle,
    Profiles,
    ReleaseVerification,
    SceneNumbering,
    Season,
    SeriesCatalog,
    SeriesDeletion,
    SeriesRefresh
  }

  alias Cinder.Download
  alias Cinder.GuardedWrite
  alias Cinder.Library
  alias Cinder.Library.ImportedQuality
  alias Cinder.Repo
  alias Cinder.Requests

  @topic "movies"

  ## Discovery — TMDB search/trending/rails/localized lookups.
  # Carved out to `Cinder.Catalog.Discovery`; see that module for the implementation.

  defdelegate search_movies(query), to: Discovery
  defdelegate search_movies(query, locale), to: Discovery
  defdelegate search_tv(query), to: Discovery
  defdelegate search_tv(query, locale), to: Discovery
  defdelegate search_discover(query), to: Discovery
  defdelegate search_discover(query, locale), to: Discovery
  defdelegate trending(locale), to: Discovery
  defdelegate popular_movies(locale), to: Discovery
  defdelegate top_rated_movies(locale), to: Discovery
  defdelegate now_playing_movies(locale), to: Discovery
  defdelegate popular_tv(locale), to: Discovery
  defdelegate top_rated_tv(locale), to: Discovery
  defdelegate movies_by_genre(genre_id, locale), to: Discovery
  defdelegate tv_by_genre(genre_id, locale), to: Discovery
  defdelegate recommended_movies(tmdb_id, locale), to: Discovery
  defdelegate recommended_tv(tmdb_id, locale), to: Discovery
  defdelegate get_person(tmdb_id, locale), to: Discovery
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
  defdelegate apply_confirmed_media(media, profile, preferred), to: MediaProfiles

  defdelegate apply_confirmed_media(media, profile, preferred, pre_request_profile),
    to: MediaProfiles

  defdelegate list_profiles(), to: Profiles
  defdelegate list_profiles(kind), to: Profiles
  defdelegate get_profile(id), to: Profiles
  defdelegate create_profile(attrs), to: Profiles
  defdelegate update_profile(profile, attrs), to: Profiles
  defdelegate delete_profile(profile), to: Profiles
  defdelegate assign_profile(title, profile, opts \\ []), to: Profiles

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

  @doc "Builds the plain Catalog-owned identity context used for movie acquisition."
  defdelegate movie_acquisition_context(movie), to: MediaProfiles

  @doc "Builds the plain Catalog-owned identity context used for anime series acquisition."
  defdelegate anime_series_acquisition_context(series), to: SeriesCatalog

  @doc "Lists movies, newest first."
  def list_movies do
    Repo.all(from m in Movie, order_by: [desc: m.id])
  end

  @doc "Movies and episodes whose stored `file_path` has a dot-prefixed path component (#399)."
  defdelegate dot_folder_files(), to: Cinder.Catalog.LibraryVisibility

  defdelegate reconcile_media_server_items(kind, items),
    to: Cinder.Catalog.MediaServerReconciliation,
    as: :reconcile

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
  `Movie.metadata_changeset/2`, never a `Cinder.Catalog.MovieLifecycle` verb.

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
  defdelegate list_episodes_with_file(series_id), to: SeriesCatalog

  # `[:cinder, :transition]` fires once per successful episode write at Catalog's choke-points
  # (`transition_episode/3` through `publish_episode_transition_batch/2`, and atomic episode
  # adoption) — never at a call site, so
  # instrumentation can't drift from "every writer goes through Catalog". Movie writes emit it from
  # `Cinder.Catalog.MovieLifecycle`.
  defp emit_transition(:episode = kind, to_status) do
    :telemetry.execute([:cinder, :transition], %{count: 1}, %{kind: kind, to: to_status})
  end

  @doc "Updates an in-flight grab's progress snapshot and broadcasts its owning series."
  defdelegate update_grab_download_metrics(grab, attrs), to: Grabs

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
          MovieLifecycle.retry(updated)
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
  @doc false
  def fill_movie_language(movie, language) do
    case write_movie_language(movie, language) do
      {:ok, updated} ->
        broadcast({:movie_updated, updated})
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Persists the media-info languages of `quality` (audio, default audio, embedded and sidecar
  subtitles) onto a movie or episode; its ranked fields are not written. Descriptive-only — used
  by the backfill task; not a status transition.
  """
  def set_media_info(%Movie{} = movie, %ImportedQuality{} = quality) do
    with {:ok, updated} <-
           movie
           |> Movie.media_info_changeset(ImportedQuality.columns(quality, Movie))
           |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  def set_media_info(%Episode{} = episode, %ImportedQuality{} = quality) do
    with {:ok, updated} <-
           episode
           |> Episode.media_info_changeset(ImportedQuality.columns(quality, Episode))
           |> Repo.update() do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end

  @doc """
  Sets a series' preferred language and zeroes `search_attempts` on its still-wanted
  episodes (no file, no grab) so a previously language-stranded season re-enters the
  search sweep. Available / in-flight episodes are untouched.
  """
  defdelegate set_series_language(series, language), to: SeriesCatalog

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

      # Still owns a client download: it can be cancelled or have its upgrade aborted.
      include_remote? =
        Attention.offers?(fresh, :cancel) or Attention.offers?(fresh, :cancel_upgrade) or
          fresh.verification_hold_origin in [:download, :upgrade]

      Download.fence_movie_cleanup(fresh, include_remote: include_remote?)
    end

    with {:ok, {deleted, intent_ids}} <- delete_record(movie, prepare) do
      Download.cleanup_intents(intent_ids)

      unlinked =
        if delete_files?,
          do: Enum.map(Movie.file_paths(deleted), &{&1, best_effort_delete_file(&1)}),
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
  (`Cinder.Requests.Approval.Movie.publish/2` broadcasts `{:movie_created, movie}` once
  the approval transaction has committed, using the returned `:created` marker).

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
            |> Map.take(Movie.creation_fields())
            |> Map.merge(Map.take(attrs, [:preferred_language, :media_profile, :profile_id]))

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

  @doc false
  def broadcast(message), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, message)

  @doc "Broadcasts `{:movie_deleted, id}` on the `\"movies\"` topic so open views drop the row."
  def broadcast_movie_deleted(id), do: broadcast({:movie_deleted, id})

  @doc "Broadcasts `{:movie_created, movie}` on the `\"movies\"` topic — called after a creation transaction commits (Catalog creation itself never broadcasts; see `find_or_create_at_requested/2`)."
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
  episode state is derived), as a guarded write (`Cinder.GuardedWrite`). `expect:` names the
  values the row must still hold (`%{field => value}`); a miss is `{:error, :stale_status}`.
  Publishes `{:series_updated, series_id}` after commit. `monitored` stays in
  `set_episode_monitored/2`.
  """
  def transition_episode(%Episode{} = episode, attrs, opts \\ []) do
    expect = opts |> Keyword.get(:expect, %{}) |> Enum.to_list()
    GuardedWrite.write(EpisodeTransition, episode, attrs, expect)
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

  defdelegate adopt_series_files(series, actions, profile_id, legacy_handling, validator),
    to: Cinder.Catalog.Adoption

  defdelegate delete_episode_file(episode, actor), to: SeriesDeletion
  defdelegate delete_episode_file(episode, actor, opts), to: SeriesDeletion
  defdelegate delete_season_files(season, actor), to: SeriesDeletion
  defdelegate delete_season_files(season, actor, opts), to: SeriesDeletion

  @doc false
  def now, do: DateTime.truncate(DateTime.utc_now(), :second)

  ## Grab lifecycle and blocklist implementation lives in `Cinder.Catalog.Grabs`.

  defdelegate create_grab(download_id, protocol, episode_ids), to: Grabs
  defdelegate create_grab(download_id, protocol, episode_ids, release_title), to: Grabs
  defdelegate create_grab(download_id, protocol, episode_ids, release_title, opts), to: Grabs
  defdelegate create_grab_from_intent(intent), to: Grabs
  defdelegate record_mapping_result(grab, preflight_result), to: Grabs

  @doc """
  Releases a mapping hold: the operator has fixed the files on disk (e.g. renamed them), so this
  flips the grab back to `:resolved` (resetting `download_attempts`, mirroring
  `retry_grab_verification/1`) and lets the TV poller's next import tick run a fresh preflight
  over the current files. A preflight that fails again simply re-holds with an updated reason —
  there is no separate retry budget for the hold itself, since re-entry only happens on this
  explicit operator action, never automatically.
  """
  defdelegate retry_grab_mapping(grab), to: ReleaseVerification

  defdelegate mark_grab_downloaded(grab, content_path), to: Grabs
  defdelegate increment_grab_attempts(grab), to: Grabs

  @doc "Atomically holds a downloaded resolved grab after its final verification attempt."
  defdelegate hold_grab_verification(grab), to: ReleaseVerification
  @doc "Atomically releases a verification hold and resets only its verification attempts."
  defdelegate retry_grab_verification(grab), to: ReleaseVerification
  defdelegate import_grab_anyway(grab, actor), to: ReleaseVerification
  defdelegate block_cancelled_hold(grab), to: ReleaseVerification

  defdelegate cancel_grab(grab), to: Grabs
  defdelegate cancel_mapping_grab(grab), to: Grabs

  @doc """
  Cancels an entire series WITHOUT deleting it: reaps every grab serving the series (any state,
  including `:downloaded` awaiting import), removing each tracked client download, then
  unmonitors every season and episode so the TV poller's `wanted_episodes` does not re-grab.
  Broadcasts `{:series_updated, id}`. Audited.
  """
  defdelegate cancel_series(series, actor), to: SeriesDeletion

  @doc """
  Deletes a series and its tree. Broadcasts `{:series_deleted, id}`. Audited. Pass
  `delete_files: true` to also unlink every episode `file_path` after the cascade.
  """
  defdelegate delete_series(series, actor), to: SeriesDeletion
  defdelegate delete_series(series, actor, opts), to: SeriesDeletion

  defdelegate episode_ids_for_grab(grab_id), to: Grabs
  defdelegate series_id_for_grab(grab_id), to: Grabs
  defdelegate grab_cleanup_spec(grab, episode_ids), to: Grabs

  @doc """
  Atomically rejects one confirmed episodic release, guarding the resolved grab and its exact
  episode ownership before blocklisting, fencing cleanup, and deleting it.
  """
  defdelegate reject_grab_release(expected, evidence), to: ReleaseVerification

  defdelegate block_release(movie, reason), to: Grabs
  defdelegate block_release_and_confirm(movie, reason), to: Grabs
  defdelegate clear_stalled_blocklist(scope), to: Grabs
  defdelegate block_grab_release(grab, reason), to: Grabs
  defdelegate blocked_release_titles(movie), to: Grabs
  defdelegate blocked_release_titles_for_series(series_id), to: Grabs
  defdelegate blocked_release_titles_for_series(series_id, opts), to: Grabs
  defdelegate increment_search_attempts(episode_ids), to: Grabs
  defdelegate list_grabs_downloading(), to: Grabs
  defdelegate count_grabs_downloading(), to: Grabs
  defdelegate list_grabs_downloaded(), to: Grabs
  defdelegate list_grabs(), to: Grabs
  defdelegate unresolved_grab_files(grab), to: Grabs
  defdelegate list_mapping_grabs_for_series(series_id), to: Grabs
  defdelegate get_grab(id), to: Grabs
  defdelegate wanted_episodes(), to: SeriesCatalog
  defdelegate manual_search_episodes(series_id, season_number), to: SeriesCatalog
  defdelegate season_manual_searchable?(season, profile), to: SeriesCatalog
  defdelegate count_wanted_episodes(), to: SeriesCatalog
  defdelegate available_season_keys(), to: SeriesCatalog
  defdelegate available_season_keys(tmdb_id), to: SeriesCatalog
  defdelegate season_progress_keys(tmdb_id \\ nil), to: SeriesCatalog
  defdelegate count_wanted_episodes(series_id, season_number), to: SeriesCatalog
  defdelegate count_episodes(series_id, season_number), to: SeriesCatalog
  defdelegate max_search_attempts(), to: SeriesCatalog
  defdelegate episode_state(episode), to: SeriesCatalog
  defdelegate episode_state(episode, today), to: SeriesCatalog
  defdelegate search_episode_now(episode), to: SeriesCatalog
  defdelegate rehunt_parked_episodes(cutoff), to: SeriesCatalog
  defdelegate search_season_now(season), to: SeriesCatalog
  defdelegate episode_searchable?(episode, profile), to: SeriesCatalog
  defdelegate episode_kind_wanted?(episode, season, profile), to: SeriesCatalog
  defdelegate upcoming_episodes(), to: SeriesCatalog
  defdelegate refresh_series(series), to: SeriesRefresh
  defdelegate finish_grab(grab), to: Grabs
  defdelegate finish_grab(grab, imported), to: Grabs
  defdelegate finish_grab(grab, imported, stage_ids), to: Grabs
  defdelegate commit_grab_imports(grab, imported, residuals), to: Grabs
  defdelegate commit_grab_imports(grab, imported, residuals, stage_ids), to: Grabs
  defdelegate close_grab(grab), to: Grabs
  defdelegate decide_grab_file(file, episode, decision, stage), to: Grabs
  defdelegate discard_grab_file(file), to: Grabs
  defdelegate park_grab(grab), to: Grabs
  defdelegate park_grab_and_remove(grab), to: Grabs
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
