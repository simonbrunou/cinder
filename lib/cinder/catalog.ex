defmodule Cinder.Catalog do
  @moduledoc """
  Discovery: search TMDB for movies and persist requested ones.

  TMDB is reached only through the `Cinder.Catalog.TMDB` behaviour, resolved from
  config (`config :cinder, :tmdb`) so tests use a Mox mock and never hit the network.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Acquisition.Release
  alias Cinder.Audit
  alias Cinder.Catalog.{BlockedRelease, Episode, Grab, Movie, Season, Series}
  alias Cinder.Download
  alias Cinder.Library
  alias Cinder.Notifier
  alias Cinder.Repo

  @topic "movies"
  @download_metric_fields [:download_progress, :download_speed, :download_eta]

  @doc """
  Searches TMDB for `query`. A blank/whitespace query short-circuits to `{:ok, []}`
  with no API call.
  """
  def search_movies(query) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      tmdb().search(query)
    end
  end

  @doc "TV-search variant of `search_movies/1`: blank query short-circuits to `{:ok, []}`."
  def search_tv(query) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      tmdb().search_tv(query)
    end
  end

  @doc """
  Combined Discover search: movies + TV for one query. Returns `{:ok, results}`
  where each result is a normalized search map plus a `:type` key (`:movie | :tv`),
  interleaved so both kinds surface near the top of the grid. A blank/whitespace
  query short-circuits to `{:ok, []}` with no API call. If *both* endpoints error,
  returns `{:error, :search_failed}`; if only one errors it is logged and its side
  is omitted — partial results beat none for discovery.

  ponytail: runs the two searches sequentially (matches the existing synchronous
  search style; household scale + 300ms debounce). Upgrade path if search latency
  bites: wrap each in Task.async/await_many to run them concurrently.
  """
  def search_discover(query) do
    if String.trim(query) == "" do
      {:ok, []}
    else
      merge_discover(search_movies(query), search_tv(query))
    end
  end

  defp merge_discover({:error, _} = movies, {:error, _} = tv) do
    Logger.warning("Discover search failed entirely: movies=#{inspect(movies)} tv=#{inspect(tv)}")
    {:error, :search_failed}
  end

  defp merge_discover(movies_res, tv_res) do
    {:ok, interleave(tag(movies_res, :movie), tag(tv_res, :tv))}
  end

  defp tag({:ok, list}, type), do: Enum.map(list, &Map.put(&1, :type, type))

  defp tag({:error, reason}, type) do
    Logger.warning("Discover #{type} search failed: #{inspect(reason)}")
    []
  end

  # Round-robin so a 2-col mobile grid shows both kinds near the top, then any tail.
  defp interleave(a, b) do
    0..max(length(a), length(b))
    |> Enum.flat_map(fn i -> [Enum.at(a, i), Enum.at(b, i)] end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Fetches series details (including seasons list) from TMDB by tmdb_id."
  def tmdb_series(tmdb_id), do: tmdb().get_series(tmdb_id)

  # Resolve the impl at runtime. compile_env! would inline the mock module, which —
  # being defined at runtime by Mox in test_helper.exs — doesn't exist at compile time
  # and warns under --warnings-as-errors. fetch_env! still fails fast if unconfigured.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)

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
  Admin metadata edit for a movie (title/year/poster/ids). Reuses `Movie.changeset/2`, which
  does NOT cast `:status` — status changes go through `transition/2` (the choke-point). On success
  broadcasts `{:movie_updated, movie}` (same helper `transition/2` uses) so other subscribed
  sessions refresh. Returns `{:ok, movie}` or `{:error, changeset}`.
  """
  def update_movie(%Movie{} = movie, attrs) do
    with {:ok, updated} <- movie |> Movie.changeset(attrs) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

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
  lightweight `get_series` fetch, not the full `refresh_series/1` season walk. Returns the
  refreshed `%Series{}` (or the row unchanged, logged, on a TMDB error). No broadcast — the caller
  reloads its own tree.
  """
  def enrich_series(%Series{} = series),
    do:
      backfill_metadata(
        series,
        &tmdb().get_series(&1.tmdb_id),
        &Series.metadata_changeset/2,
        "series"
      )

  # Shared descriptive-metadata refresh for a movie/series row. `fetch` and `changeset` are
  # the type's TMDB call + metadata changeset; `label` is for the log line. `updated_at` is
  # never written: this read-triggered refresh must not reorder the dashboard's Recent slice or
  # overwrite a concurrent pipeline transition's timestamp. On a TMDB error, log and return the
  # row unchanged so the page still renders.
  defp backfill_metadata(record, fetch, changeset, label) do
    case fetch.(record) do
      {:ok, info} ->
        changes = changeset.(record, info).changes

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

  @doc "Episodes with an imported file, season+series preloaded (subtitle-fetch candidates)."
  def list_episodes_with_file do
    Repo.all(from e in Episode, where: not is_nil(e.file_path), preload: [season: :series])
  end

  @doc """
  Applies a pipeline state transition and, on success, broadcasts
  `{:movie_updated, movie}` on the `"movies"` topic. This is the single
  choke-point for state changes — every transition broadcasts exactly once.
  `attrs` must set `:status`; it may also set `:download_id`, `:download_protocol`,
  `:imdb_id`, `:file_path`, `:import_attempts`, and `:search_attempts`.
  """
  def transition(movie, attrs, opts \\ [])

  def transition(%Movie{} = movie, attrs, []) do
    with {:ok, updated} <- movie |> Movie.transition_changeset(attrs) |> Repo.update() do
      broadcast({:movie_updated, updated})
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
    changeset = Movie.transition_changeset(movie, attrs)

    with %{valid?: true, changes: changes} <- changeset,
         {1, [updated]} <-
           Repo.update_all(
             from(m in Movie, where: m.id == ^movie.id and m.status == ^expected, select: m),
             set: Map.to_list(changes) ++ [updated_at: now()]
           ) do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    else
      {0, _} -> {:error, :stale_status}
      %Ecto.Changeset{} = invalid -> {:error, invalid}
    end
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
  def update_grab_download_metrics(%Grab{} = grab, attrs) do
    changes = metric_changes(grab, attrs)

    if changes == %{} do
      if Repo.exists?(from(g in Grab, where: g.id == ^grab.id and is_nil(g.content_path))) do
        {:ok, grab}
      else
        {:error, :stale_grab}
      end
    else
      case Repo.update_all(
             from(g in Grab,
               where: g.id == ^grab.id and is_nil(g.content_path),
               select: g
             ),
             set: Map.to_list(changes) ++ [updated_at: now()]
           ) do
        {1, [updated]} ->
          broadcast_series(series_id_for_grab(grab.id))
          {:ok, updated}

        {0, _} ->
          {:error, :stale_grab}
      end
    end
  end

  defp metric_changes(record, attrs) do
    attrs = Map.take(attrs, @download_metric_fields)
    if Map.take(record, @download_metric_fields) == attrs, do: %{}, else: attrs
  end

  # Parked terminal states a user can re-queue. An in-flight movie must never be
  # yanked back to :requested, so retry guards on status server-side (the /status
  # button is a client-sent event — don't trust it to only fire for parked rows).
  @retryable [:no_match, :search_failed, :import_failed]

  @doc """
  Re-queues a parked movie: resets it to `:requested` and zeroes the attempt
  counters so the poller picks it up fresh. Returns `{:error, :not_retryable}`
  for any non-parked movie. Replaces the old IEx reset.
  """
  def retry_movie(%Movie{status: status} = movie) when status in @retryable do
    # Clear the stale download fields too: a re-queued movie has no download yet,
    # so leaving an old download_id/protocol/file_path/release_title on a :requested
    # row is misleading and a latent misroute if anything reads them before re-download.
    # The blocklist row (keyed by movie_id) PERSISTS — clearing it would reintroduce the
    # re-grab loop; release_title here is stale download state, not the blocklist.
    # expect: — the caller's struct is a client-rendered snapshot; if the movie
    # already re-entered the pipeline (re-searched, downloading), the retry must
    # miss rather than yank an in-flight movie back and orphan its download.
    transition(
      movie,
      %{
        status: :requested,
        search_attempts: 0,
        import_attempts: 0,
        download_id: nil,
        download_protocol: nil,
        release_title: nil,
        file_path: nil
      },
      expect: movie.status
    )
  end

  def retry_movie(%Movie{}), do: {:error, :not_retryable}

  @doc """
  Grabs a specific user-chosen `release` for `movie`. An `:available` movie enters `:upgrading`
  (its library `file_path` and `imported_*` are preserved — the poller's upgrade clause swaps the
  file only on a successful re-import). A parked movie (`#{inspect(@retryable)}`) enters
  `:downloading` on the normal import path. Any other status returns `{:error, :not_grabbable}`
  (rejecting in-flight/`:upgrading`/`:cancelled`, which also blocks a double-click). A movie deleted
  mid-action surfaces `{:error, :stale_entry}`.
  """
  def manual_grab_movie(%Movie{status: :available} = movie, %Release{} = release) do
    Download.grab_movie(movie, release)
  end

  def manual_grab_movie(%Movie{status: status} = movie, %Release{} = release)
      when status in @retryable do
    Download.grab_movie(movie, release)
  end

  def manual_grab_movie(%Movie{}, %Release{}), do: {:error, :not_grabbable}

  @doc """
  Grabs a user-chosen `release` for one `season_number` of `series`. Recomputes the season's
  still-wanted episodes server-side (don't trust a stale panel snapshot) and creates the grab over
  exactly the wanted episodes the release covers (`episodes: nil` = a whole-season pack covers them
  all). `create_grab/5` itself skips any episode that already has a grab, so a concurrent sweep grab
  can't be double-linked. `{:error, :nothing_wanted}` when the season has nothing to grab.
  """
  def manual_grab_tv(%Series{id: series_id}, season_number, %Release{} = release) do
    wanted =
      wanted_episodes()
      |> Enum.filter(
        &(&1.season.series.id == series_id and &1.season.season_number == season_number)
      )

    covered = cover_numbers(release, Enum.map(wanted, & &1.episode_number))
    episode_ids = wanted |> Enum.filter(&(&1.episode_number in covered)) |> Enum.map(& &1.id)

    case episode_ids do
      [] -> {:error, :nothing_wanted}
      ids -> grab_and_create_grab(release, ids)
    end
  end

  # Grabs the release (a client.add side-effect returning a download_id), then links the grab over
  # `episode_ids`. If create_grab/5 rolls back — a concurrent sweep grabbed the episodes first
  # (:no_episodes_linked) or the insert failed — best-effort remove the just-added download so it
  # isn't orphaned in the client, then surface the error.
  defp grab_and_create_grab(%Release{} = release, episode_ids) do
    Download.grab_episodes(release, episode_ids)
  end

  # A whole-season pack (episodes: nil) covers every still-wanted number; an episode list covers its
  # intersection with what's wanted. Mirrors Scorer.coverage/2.
  defp cover_numbers(%Release{episodes: nil}, wanted_numbers), do: wanted_numbers

  defp cover_numbers(%Release{episodes: eps}, wanted_numbers),
    do: Enum.filter(wanted_numbers, &(&1 in eps))

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
    case movie |> Movie.language_changeset(%{preferred_language: language}) |> Repo.update() do
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
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
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
  def set_series_language(%Series{} = series, language) do
    result =
      Repo.transaction(fn ->
        case series
             |> Series.language_changeset(%{preferred_language: language})
             |> Repo.update() do
          {:ok, updated} ->
            from(e in Episode,
              join: s in Season,
              on: e.season_id == s.id,
              where:
                s.series_id == ^series.id and is_nil(e.file_path) and is_nil(e.grab_id) and
                  e.search_attempts > 0
            )
            |> Repo.update_all(set: [search_attempts: 0])

            updated

          # The row update + the episode reset are one transaction (mirroring
          # set_season_monitored/2): surface a write failure as {:error, changeset}, roll back.
          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, updated} <- result do
      broadcast_series(series.id)
      {:ok, updated}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # The active set a movie can be cancelled out of (mirrors @retryable's shape).
  # transition/2 does NOT validate transitions, so cancel/delete must guard on this
  # explicitly. delete_movie/2 (Phase 2) shares it: an active row with a download_id
  # must be cancelled (which removes the client download), never bare-deleted.
  @cancellable_movie_statuses [:requested, :searching, :downloading, :downloaded]

  @doc "True if `movie` is in an active status that can be cancelled (`#{inspect(@cancellable_movie_statuses)}`)."
  def cancellable?(%Movie{status: status}), do: status in @cancellable_movie_statuses

  @doc """
  Cancels an in-flight movie: removes the orphaned client download (if any) and transitions
  it to `:cancelled`. Guards `cancellable?/1` server-side (`transition/2` does not validate the
  transition). Returns `{:error, :not_cancellable}` for a terminal/available/parked movie.

  Client I/O runs OUTSIDE the DB transaction (external-I/O rule). The `:cancelled` transition +
  the audit row are written in one transaction so a rolled-back cancel leaves no orphan audit row;
  the `{:movie_updated, _}` broadcast (via the transition) fires after commit.
  """
  def cancel_movie(%Movie{} = movie, actor) do
    if cancellable?(movie) do
      Download.cancel_movie_intents(movie.id)
      movie = Repo.get(Movie, movie.id) || movie
      # Client removal is best-effort: a stuck movie must always be clearable even if
      # qBit/SAB is down. A failed remove is logged, not propagated (see remove_download/1).
      remove_download(movie)

      with {:ok, updated} <- do_cancel_txn(movie, actor) do
        broadcast({:movie_updated, updated})
        {:ok, updated}
      end
    else
      {:error, :not_cancellable}
    end
  end

  defp do_cancel_txn(movie, actor) do
    Repo.transaction(fn ->
      case movie |> Movie.transition_changeset(%{status: :cancelled}) |> Repo.update() do
        {:ok, updated} ->
          Audit.log_or_rollback(actor, :cancel_movie, updated, %{from: movie.status})
          updated

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

  Client I/O runs OUTSIDE the DB transaction (external-I/O rule). The `:available` revert +
  the audit row are written in one transaction so a rolled-back abort leaves no orphan audit row;
  the `{:movie_updated, _}` broadcast fires after commit.
  """
  def abort_upgrade(%Movie{status: :upgrading} = movie, actor) do
    Download.cancel_movie_intents(movie.id)
    remove_download(movie)

    result =
      Repo.transaction(fn ->
        case movie
             |> Movie.transition_changeset(%{
               status: :available,
               download_id: nil,
               download_protocol: nil,
               release_title: nil
             })
             |> Repo.update() do
          {:ok, updated} ->
            Audit.log_or_rollback(actor, :abort_upgrade, updated, %{from: :upgrading})
            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, updated} <- result do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
  end

  def abort_upgrade(%Movie{}, _actor), do: {:error, :not_upgrading}

  @doc """
  Deletes a movie's DB row. An active row with a tracked download is cancelled first (which
  removes the client download) so delete never orphans a live download. Broadcasts
  `{:movie_deleted, id}` on the `"movies"` topic. The delete + audit row are written in one
  transaction.

  Pass `delete_files: true` in `opts` to also unlink the on-disk library file after the row is
  deleted (best-effort: a failed unlink is logged, not propagated). Default leaves files on disk.
  """
  def delete_movie(%Movie{} = movie, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)
    Download.cancel_movie_intents(movie.id)
    # Client removal is best-effort (see maybe_cancel_download_for_delete/1).
    maybe_cancel_download_for_delete(movie)

    with {:ok, deleted} <- delete_with_audit(movie, actor, :delete_movie, delete_files?) do
      if delete_files?, do: best_effort_delete_file(movie.file_path)
      broadcast_movie_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  # Deletes a movie or series row and writes the audit entry in one transaction; a concurrent
  # delete (Repo.delete/1 raises) becomes a clean {:error, :stale_entry}.
  defp delete_with_audit(record, actor, action, delete_files?) do
    Repo.transaction(fn ->
      case Repo.delete(record) do
        {:ok, deleted} ->
          Audit.log_or_rollback(actor, action, deleted, %{
            title: deleted.title,
            files_deleted: delete_files?
          })

          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  # Remove the tracked client download if present; skip entirely when download_id is nil. Works on
  # any struct carrying download_id + download_protocol (a %Movie{} or a %Grab{}).
  # client_for/1 maps a nil protocol to :torrent; an unconfigured protocol (:error) is treated
  # as "nothing to remove" so a cancel/delete is never blocked by client resolution. Best-effort:
  # a client error is logged, not propagated, so a stuck item can always be cleared even with the
  # client down. Always returns :ok.
  defp remove_download(%{download_id: nil}), do: :ok

  defp remove_download(%{download_id: id, download_protocol: protocol}) do
    case Download.client_for(protocol) do
      {:ok, client} -> Download.best_effort_remove(client, id)
      :error -> :ok
    end
  end

  # For delete: only an active (cancellable) row with a tracked download needs the client removed.
  # A terminal/available row keeps its (already-imported or absent) download untouched.
  defp maybe_cancel_download_for_delete(%Movie{download_id: nil}), do: :ok

  defp maybe_cancel_download_for_delete(%Movie{} = movie) do
    if cancellable?(movie) or movie.status == :upgrading, do: remove_download(movie), else: :ok
  end

  # Best-effort library-file unlink shared by the movie and series delete paths: a failed unlink is
  # logged, never propagated, so it can't strand the row delete. Always returns :ok.
  # ponytail: no nil clause here — Library.delete_file/1 already guards nil/"" and returns :ok.
  defp best_effort_delete_file(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("library file delete failed for #{inspect(path)}: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Fetches a movie by TMDB id, or `nil`."
  def get_movie_by_tmdb_id(tmdb_id), do: Repo.get_by(Movie, tmdb_id: tmdb_id)

  @doc """
  Returns `{:ok, movie}` for the existing row (at its current status) if one already
  exists for `attrs.tmdb_id`, or inserts a new movie at `:requested` and broadcasts
  `{:movie_created, movie}` before returning `{:ok, movie}`.

  A lost insert race (unique_constraint on `:tmdb_id`) is handled by re-fetching
  the winner and returning it, so callers always get `{:ok, movie}`.
  """
  def find_or_create_at_requested(attrs) do
    case get_movie_by_tmdb_id(attrs.tmdb_id) do
      %Movie{} = movie -> {:ok, movie}
      nil -> do_insert_at_requested(attrs)
    end
  end

  defp do_insert_at_requested(attrs) do
    case %Movie{} |> Movie.changeset(attrs) |> Repo.insert() do
      {:ok, movie} ->
        broadcast({:movie_created, movie})
        {:ok, movie}

      {:error, changeset} ->
        # Lost the insert race (unique_constraint :tmdb_id) — the row now exists.
        case get_movie_by_tmdb_id(attrs.tmdb_id) do
          %Movie{} = movie -> {:ok, movie}
          nil -> {:error, changeset}
        end
    end
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @topic, message)

  @doc "Broadcasts `{:movie_deleted, id}` on the `\"movies\"` topic so open views drop the row."
  def broadcast_movie_deleted(id), do: broadcast({:movie_deleted, id})

  ## TV series (M4a) — admin-only direct add; movie loop untouched.
  #
  # No PubSub topic yet: nothing subscribes until the M4b series-detail LiveView.
  # The whole tree inserts in one Repo.insert (= one transaction = one writer, so
  # WAL + busy_timeout stays correct).

  @doc """
  Adds a TV series and its season/episode tree, fetched from TMDB, flagging episodes
  `monitored` per `monitor_strategy` (`:all` / `:future` / `:none`; default `:future`).

  Find-or-create by `tmdb_id`: an already-added series is returned as-is; re-sync is
  `refresh_series/1` (the periodic Refresher). Returns `{:ok, series}` (associations unloaded — preload
  `[seasons: :episodes]` to read the tree), `{:error, :invalid_monitor_strategy}` for an
  unknown strategy, or `{:error, reason}` if a TMDB fetch fails.
  """
  def add_series(tmdb_id, opts \\ []) do
    strategy = Keyword.get(opts, :monitor_strategy, :future)

    # Validate at the boundary: the strategy drives monitored?/3 (a function-clause match)
    # *before* the Ecto.Enum changeset would catch it, so an unknown atom would otherwise
    # crash rather than return a clean error.
    preferred = Keyword.get(opts, :preferred_language, "original")

    if strategy in Series.monitor_strategies() do
      case get_series_by_tmdb_id(tmdb_id) do
        %Series{} = series -> {:ok, series}
        nil -> create_series(tmdb_id, strategy, preferred)
      end
    else
      {:error, :invalid_monitor_strategy}
    end
  end

  @doc """
  Request-approval entry for TV: find-or-create the series tree (from TMDB, nothing monitored
  on first create) and monitor **only** `season_number` (cascading to its episodes), leaving other
  seasons untouched. Sets `series.monitored: true`. Idempotent and additive across seasons.

  Does TMDB I/O on first create, so it must NOT be called inside a `Repo.transaction`.
  Returns `{:ok, %Series{}}`, or `{:error, reason}` if the TMDB fetch fails or the season is absent.
  """
  def find_or_create_series_at_requested(tmdb_id, season_number, preferred \\ "original") do
    with {:ok, series} <- ensure_series(tmdb_id, preferred),
         {:ok, series} <- apply_requester_language(series, preferred),
         %Season{} = season <- season_in(series, season_number),
         {:ok, _} <- set_season_monitored(season, true),
         {:ok, updated} <- mark_series_monitored(series) do
      {:ok, updated}
    else
      nil -> {:error, :season_not_found}
      {:error, _} = err -> err
    end
  end

  # Create with monitor_strategy: :none so NOTHING is monitored by default; the requested season
  # is then flipped on explicitly. An existing series is returned as-is.
  defp ensure_series(tmdb_id, preferred),
    do: add_series(tmdb_id, monitor_strategy: :none, preferred_language: preferred)

  # Fill-if-default: an existing series whose language was never customized ("original") adopts the
  # requester's non-default pick; a series already customized to a non-default is left untouched
  # (first-customization-wins). A brand-new series already carries `preferred` from create_series.
  defp apply_requester_language(%Series{preferred_language: "original"} = series, preferred)
       when preferred != "original",
       do: set_series_language(series, preferred)

  defp apply_requester_language(series, _preferred), do: {:ok, series}

  defp season_in(series, season_number) do
    Repo.get_by(Season, series_id: series.id, season_number: season_number)
  end

  defp mark_series_monitored(series) do
    series |> Ecto.Changeset.change(monitored: true) |> Repo.update()
  end

  @doc "Fetches a series by TMDB id, or `nil`."
  def get_series_by_tmdb_id(tmdb_id), do: Repo.get_by(Series, tmdb_id: tmdb_id)

  @doc "Lists series, newest first."
  def list_series, do: Repo.all(from s in Series, order_by: [desc: s.id])

  @doc "Number of series in the catalog."
  def count_series, do: Repo.aggregate(Series, :count)

  @doc """
  Admin metadata edit for a series. Uses `Series.admin_changeset/2`, which excludes
  `monitor_strategy`/`monitored` so the edit never cascades a strategy change to existing
  seasons/episodes. Per-season/episode monitoring stays on `set_season_monitored/2` /
  `set_episode_monitored/2`. On success broadcasts `{:series_updated, series.id}` so other
  subscribed sessions refresh. Returns `{:ok, series}` or `{:error, changeset}`.
  """
  def update_series(%Series{} = series, attrs) do
    with {:ok, updated} <- series |> Series.admin_changeset(attrs) |> Repo.update() do
      broadcast_series(updated.id)
      {:ok, updated}
    end
  end

  defp create_series(tmdb_id, strategy, preferred) do
    with {:ok, info} <- tmdb().get_series(tmdb_id),
         {:ok, seasons} <- fetch_seasons(tmdb_id, info.seasons) do
      insert_series(tmdb_id, series_attrs(info, seasons, strategy, preferred))
    end
  end

  defp insert_series(tmdb_id, attrs) do
    case attrs |> Series.create_changeset() |> Repo.insert() do
      {:ok, series} ->
        # Return the re-read row (not the cast_assoc result) so every add path —
        # found-existing, freshly-inserted, race-loss — returns a series with its
        # associations unloaded. Callers preload [seasons: :episodes] to read the tree.
        # Fall back to the inserted struct if the re-read somehow misses, so the
        # contract stays {:ok, %Series{}} and never {:ok, nil}.
        {:ok, get_series_by_tmdb_id(tmdb_id) || series}

      {:error, %Ecto.Changeset{} = changeset} ->
        # A unique_constraint(:tmdb_id) race rolls the whole tree back (no partial
        # rows), so the winner now exists — return it. Any other changeset error
        # finds no winner and propagates unchanged.
        case get_series_by_tmdb_id(tmdb_id) do
          %Series{} = series -> {:ok, series}
          nil -> {:error, changeset}
        end
    end
  end

  # Fetch each season's episodes, short-circuiting on the first TMDB error so a
  # partial tree is never persisted.
  defp fetch_seasons(tmdb_id, season_stubs) do
    result =
      Enum.reduce_while(season_stubs, {:ok, []}, fn %{season_number: n}, {:ok, acc} ->
        case tmdb().get_season(tmdb_id, n) do
          {:ok, season} -> {:cont, {:ok, [season | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with {:ok, seasons} <- result, do: {:ok, Enum.reverse(seasons)}
  end

  defp series_attrs(info, seasons, strategy, preferred) do
    today = Date.utc_today()

    %{
      tmdb_id: info.tmdb_id,
      tvdb_id: info.tvdb_id,
      title: info.title,
      year: info.year,
      poster_path: info.poster_path,
      original_language: info[:original_language],
      preferred_language: preferred,
      monitored: strategy != :none,
      monitor_strategy: strategy,
      seasons:
        for season <- seasons do
          %{
            season_number: season.season_number,
            monitored: strategy != :none,
            episodes:
              for ep <- season.episodes do
                Map.put(ep, :monitored, monitored?(strategy, ep.air_date, today))
              end
          }
        end
    }
  end

  # Strategy is applied uniformly across seasons (specials included) — Sonarr-style
  # specials handling is an M6 monitoring concern. `:future` treats undated/TBA
  # episodes as monitored and counts "today" as eligible.
  defp monitored?(:all, _air_date, _today), do: true
  defp monitored?(:none, _air_date, _today), do: false
  defp monitored?(:future, nil, _today), do: true
  defp monitored?(:future, air_date, today), do: Date.compare(air_date, today) != :lt

  ## TV monitoring toggles + the "series" topic (M4b).
  #
  # Monitor flags are NOT pipeline state, so they don't go through `transition/2` (that's the
  # movie-status choke-point): each setter is its own single-writer with its own broadcast. The
  # "series" topic carries only `{:series_updated, series_id}` — the series-detail LiveView
  # subscribes so a second open tab reflects a toggle. No TV poller writes out-of-band yet (M5),
  # so nothing else needs it.

  @series_topic "series"

  @doc "Subscribes the caller to series-change broadcasts (`{:series_updated, series_id}`)."
  def subscribe_series, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @series_topic)

  @doc """
  Loads a series with its seasons (ordered by `season_number`) and each season's episodes
  (ordered by `episode_number`), or `nil` for a missing id.
  """
  def get_series_with_tree(id) do
    case Repo.get(Series, id) do
      nil ->
        nil

      series ->
        seasons_q = from(s in Season, order_by: s.season_number)
        eps_q = from(e in Episode, order_by: e.episode_number)
        Repo.preload(series, seasons: {seasons_q, [episodes: eps_q]})
    end
  end

  @doc "Sets one episode's `monitored` flag and broadcasts `{:series_updated, series_id}`."
  def set_episode_monitored(%Episode{} = episode, monitored?) do
    with {:ok, episode} <-
           episode |> Ecto.Changeset.change(monitored: monitored?) |> Repo.update() do
      broadcast_series(series_id_for_season(episode.season_id))
      {:ok, episode}
    end
  end

  @doc """
  Sets a season's `monitored` flag and cascades it to every episode in one transaction, then
  broadcasts `{:series_updated, series_id}`.
  """
  def set_season_monitored(%Season{} = season, monitored?) do
    result =
      Repo.transaction(fn ->
        case season |> Ecto.Changeset.change(monitored: monitored?) |> Repo.update() do
          {:ok, season} ->
            Repo.update_all(from(e in Episode, where: e.season_id == ^season.id),
              set: [monitored: monitored?, updated_at: now()]
            )

            season

          # Surface a write failure as {:error, changeset} (mirroring set_episode_monitored)
          # rather than raising — the cascade is one transaction, so roll the whole thing back.
          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, season} <- result do
      broadcast_series(season.series_id)
      {:ok, season}
    end
  end

  @doc """
  Single choke-point for episode **pipeline** writes (`file_path`, `grab_id`, attempt
  counters — no status enum; episode state is derived). On success broadcasts
  `{:series_updated, series_id}` on the `"series"` topic. `monitored` is NOT written here —
  it is not pipeline state and keeps `set_episode_monitored/2`.
  """
  def transition_episode(%Episode{} = episode, attrs) do
    with {:ok, updated} <- episode |> Episode.transition_changeset(attrs) |> Repo.update() do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end

  @doc """
  Deletes one episode's library file (Sonarr "delete episode file"): unlinks the file, then clears
  `file_path` so the episode reverts to its derived missing state — left monitored (the poller
  re-grabs next tick) unless `opts[:unmonitor]` also flips `monitored` off. A multi-episode file
  is shared, so its other episode rows are cleared too. The DB write + audit run in one transaction
  (mirroring `cancel_movie/2`); broadcasts `{:series_updated, series_id}` after commit. Returns
  `{:error, :no_file}` when there is no file, or the unlink's `{:error, reason}`
  (the DB is then untouched — the file is the whole point, so the error is surfaced, not best-effort).
  Ordering caveat: the unlink runs before the DB txn, so a (rare) txn failure after a successful
  unlink leaves `file_path` pointing at a now-deleted file (the episode reads falsely-available)
  until re-deleted — recoverable because `rm` of a missing file is idempotent (`:enoent` → `:ok`).
  """
  def delete_episode_file(episode, actor, opts \\ [])

  def delete_episode_file(%Episode{file_path: p}, _actor, _opts) when p in [nil, ""],
    do: {:error, :no_file}

  def delete_episode_file(%Episode{} = episode, actor, opts) do
    unmonitor? = Keyword.get(opts, :unmonitor, false)

    with :ok <- Library.delete_file(episode.file_path),
         {:ok, updated} <- do_delete_episode_file_txn(episode, actor, unmonitor?) do
      broadcast_series(series_id_for_season(updated.season_id))
      {:ok, updated}
    end
  end

  defp do_delete_episode_file_txn(episode, actor, unmonitor?) do
    Repo.transaction(fn ->
      changeset =
        episode
        |> Episode.transition_changeset(%{
          file_path: nil,
          # Zero the counter so a previously search-parked episode really is
          # re-grabbed next tick, as the docstring promises.
          search_attempts: 0,
          imported_resolution: nil,
          imported_size: nil,
          imported_language: nil,
          imported_source: nil,
          imported_audio_languages: nil,
          imported_embedded_subtitles: nil,
          imported_sidecar_subtitles: nil
        })
        |> maybe_unmonitor(unmonitor?)

      case Repo.update(changeset) do
        {:ok, updated} ->
          clear_shared_file_paths(episode.file_path)
          Audit.log_or_rollback(actor, :delete_episode_file, updated, %{unmonitored: unmonitor?})
          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_entry}
  end

  defp clear_shared_file_paths(path) do
    Repo.update_all(from(e in Episode, where: e.file_path == ^path),
      set: [
        file_path: nil,
        search_attempts: 0,
        imported_resolution: nil,
        imported_size: nil,
        imported_language: nil,
        imported_source: nil,
        imported_audio_languages: nil,
        imported_embedded_subtitles: nil,
        imported_sidecar_subtitles: nil,
        updated_at: now()
      ]
    )
  end

  defp maybe_unmonitor(changeset, true),
    do: Ecto.Changeset.put_change(changeset, :monitored, false)

  defp maybe_unmonitor(changeset, false), do: changeset

  @doc """
  Deletes every library file in a season (Sonarr per-season "delete episode files"): unlinks each
  episode's file (best-effort, per file), then clears `file_path` — and `monitored` off on
  `opts[:unmonitor]` — for the episodes whose file was actually removed, in ONE transaction + ONE
  `{:series_updated, _}` broadcast (mirrors `set_season_monitored/2`). A per-file unlink failure is
  logged and that episode keeps its `file_path` (so it isn't falsely marked missing). Returns
  `{:ok, cleared_count, failed_count}` where `failed_count` is the number of episodes whose unlink
  returned `{:error, _}` (callers should warn the user when `failed_count > 0`).
  """
  def delete_season_files(%Season{} = season, actor, opts \\ []) do
    unmonitor? = Keyword.get(opts, :unmonitor, false)

    # Bulk path mirrors set_season_monitored/2: the txn writes file_path/monitored via update_all
    # (NOT Episode.transition_changeset — file_path: nil has no validation to enforce), and the
    # read-then-write window (episodes read, files unlinked, then update_all) is the same one
    # set_season_monitored carries. Accepted at household scale (WAL + busy_timeout serializes the
    # writes; worst case a just-imported file is re-cleared and the user re-deletes).
    episodes =
      Repo.all(from e in Episode, where: e.season_id == ^season.id and not is_nil(e.file_path))

    results = Enum.map(episodes, fn ep -> {ep, Library.delete_file(ep.file_path)} end)
    cleared_ids = for {ep, :ok} <- results, do: ep.id
    failed_count = Enum.count(results, fn {_ep, r} -> r != :ok end)

    for {ep, {:error, reason}} <- results do
      Logger.warning(
        "library file delete failed for #{inspect(ep.file_path)}: #{inspect(reason)}"
      )
    end

    with {:ok, _} <- do_delete_season_files_txn(season, actor, cleared_ids, unmonitor?) do
      broadcast_series(season.series_id)
      {:ok, length(cleared_ids), failed_count}
    end
  end

  defp do_delete_season_files_txn(season, actor, cleared_ids, unmonitor?) do
    Repo.transaction(fn ->
      sets =
        [
          file_path: nil,
          # Zero the counter so previously search-parked episodes really are
          # re-grabbed next tick, as the docstring promises.
          search_attempts: 0,
          imported_resolution: nil,
          imported_size: nil,
          imported_language: nil,
          imported_source: nil,
          imported_audio_languages: nil,
          imported_embedded_subtitles: nil,
          imported_sidecar_subtitles: nil,
          updated_at: now()
        ] ++ if(unmonitor?, do: [monitored: false], else: [])

      Repo.update_all(from(e in Episode, where: e.id in ^cleared_ids), set: sets)

      Audit.log_or_rollback(actor, :delete_season_files, season, %{
        count: length(cleared_ids),
        unmonitored: unmonitor?
      })

      season
    end)
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  @doc """
  Creates a grab for `episode_ids` (a non-empty list of episodes in one series — a single
  episode or a season pack) and links them in one transaction, then broadcasts
  `{:series_updated, series_id}`. `release_title` (optional) records the chosen release's name
  on the grab so the blocklist can skip it if this download later parks. A changeset failure
  (e.g. a missing `download_id`) rolls the whole thing back as `{:error, changeset}` rather than
  raising, mirroring `set_season_monitored/2`.

  `opts` — `reset_attempts: true` zeroes the linked episodes' `search_attempts` in the same
  transaction (the manual-grab path uses it, mirroring `manual_grab_movie/2`): the user-chosen
  release gets a fresh search budget, and new grabs never carry a counter at/above the cap.
  """
  def create_grab(download_id, protocol, episode_ids, release_title \\ nil, opts \\ []) do
    result =
      Repo.transaction(fn ->
        insert_and_link_grab(download_id, protocol, episode_ids, release_title, opts)
      end)

    with {:ok, grab} <- result do
      # Post-commit side effect, best-effort: once the txn committed the grab is
      # real, and a blip here (a pool-checkout timeout on the series lookup) must
      # not surface as {:error, _} — the TvPoller's cleanup branch would then
      # remove the client download out from under a live grab and eventually
      # blocklist a good release.
      try do
        broadcast_series(series_id_for_grab(grab.id))
      rescue
        e -> Logger.warning("post-commit broadcast for grab #{grab.id} failed: #{inspect(e)}")
      catch
        kind, value ->
          Logger.warning("post-commit broadcast for grab #{grab.id} #{kind}: #{inspect(value)}")
      end

      {:ok, grab}
    end
  end

  defp insert_and_link_grab(download_id, protocol, episode_ids, release_title, opts) do
    case %Grab{}
         |> Grab.changeset(%{
           download_id: download_id,
           download_protocol: protocol,
           release_title: release_title
         })
         |> Repo.insert() do
      {:ok, grab} -> link_grab_episodes(grab, episode_ids, opts)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp link_grab_episodes(grab, episode_ids, opts) do
    # reset_attempts: the manual-grab path zeroes search_attempts (mirroring manual_grab_movie),
    # giving the user-chosen release a fresh budget — and keeping the counter from ever exceeding
    # the cap, which announce_search_exhausted's == max crossing check relies on.
    reset = if Keyword.get(opts, :reset_attempts, false), do: [search_attempts: 0], else: []
    # Guard `is_nil(grab_id)`: never re-link an episode another grab already owns (defends against
    # a same-tick double-link silently overwriting an earlier grab). Guard `monitored`: every
    # caller sources episode_ids from wanted_episodes (monitored-only), but the poller's search
    # pass holds that snapshot across seconds of indexer/client I/O — an admin cancel_series in
    # that window unmonitors the episodes, and linking them anyway would resurrect the download
    # the user just cancelled.
    {linked, _} =
      Repo.update_all(
        from(e in Episode,
          where: e.id in ^episode_ids and is_nil(e.grab_id) and e.monitored == true
        ),
        set: [grab_id: grab.id, updated_at: now()] ++ reset
      )

    # Every requested episode was already grabbed (or unmonitored meanwhile): roll back so we
    # don't leave an orphan grab (and so the caller doesn't start a download serving nothing).
    if linked == 0, do: Repo.rollback(:no_episodes_linked), else: grab
  end

  @doc """
  Marks a grab downloaded (records `content_path`, the at-rest path to import) and broadcasts.
  Also resets `download_attempts` at the download→import boundary (mirrors the movie poller's
  `import_attempts: 0` reset, `poller.ex:140`) so download-phase blips don't starve the shared
  grab-lifetime retry budget the import pass then draws from.
  """
  def mark_grab_downloaded(%Grab{} = grab, content_path) do
    changeset =
      Grab.changeset(grab, %{
        content_path: content_path,
        download_attempts: 0,
        download_progress: nil,
        download_speed: nil,
        download_eta: nil
      })

    with {:ok, grab} <- Repo.update(changeset) do
      broadcast_series(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  @doc """
  Bumps a grab's `download_attempts` — the single grab-lifetime retry counter the TV poller
  uses for both the advance and import passes — and broadcasts. The caller compares the
  pre-bump count against its bound to decide retry-vs-park.
  """
  def increment_grab_attempts(%Grab{} = grab) do
    Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
      inc: [download_attempts: 1],
      set: [download_progress: nil, download_speed: nil, download_eta: nil, updated_at: now()]
    )

    broadcast_series(series_id_for_grab(grab.id))
    :ok
  end

  @doc """
  Deletes a grab; the `grab_id` FK (`on_delete: :nilify_all`) unlinks its episodes. Broadcasts
  `{:series_updated, series_id}` (captured before the delete, while the links still exist).
  """
  def delete_grab(%Grab{} = grab) do
    series_id = series_id_for_grab(grab.id)

    # allow_stale: the TV poller may finish/park the same grab concurrently with a
    # user-initiated delete; an already-gone row is success for an idempotent delete.
    with {:ok, grab} <- Repo.delete(grab, allow_stale: true) do
      broadcast_series(series_id)
      {:ok, grab}
    end
  end

  @doc """
  Aborts one grab as a user action: removes its tracked client download (best-effort,
  outside any txn — mirrors `cancel_series/2`'s per-grab semantics), then deletes the
  grab row. Its episodes re-enter the wanted sweep and re-search cleanly — without the
  client removal the still-running download would collide with the re-grab
  (duplicate-add rejections) and complete with no grab left to import it.
  """
  def cancel_grab(%Grab{} = grab) do
    Download.cancel_episode_intents(episode_ids_for_grab(grab.id))
    remove_download(grab)
    delete_grab(grab)
  end

  @doc """
  Cancels an entire series WITHOUT deleting it: reaps every grab serving the series (any state,
  including `:downloaded` awaiting import — a surviving downloaded grab would re-import next tick),
  removing each tracked client download, then unmonitors every season and episode so the TV
  poller's `wanted_episodes` does not re-grab. Broadcasts `{:series_updated, id}`. Audited.

  Client I/O (best-effort — see `Cinder.Download.best_effort_remove/2`) runs BEFORE the DB transaction. The grab-row
  deletes, the season+episode unmonitor, and the audit row are then written in ONE transaction so
  there is no poller-visible window where an episode is grab-less but still monitored (which would
  re-grab and defeat the cancel), and a failed audit rolls the whole cancel back rather than leaving
  the series reaped-but-unaudited. The `{:series_updated, _}` broadcast fires after commit.
  """
  def cancel_series(%Series{} = series, actor) do
    Download.cancel_episode_intents(episode_ids_for_series(series.id))
    grabs = grabs_for_series(series.id)

    # External I/O outside the txn: best-effort, never blocks the cancel.
    for grab <- grabs, do: remove_download(grab)

    result =
      Repo.transaction(fn ->
        # allow_stale: the TV poller may have finished/parked a grab between the read
        # above and this txn; raising here would crash the cancel after the client
        # downloads were already removed.
        for grab <- grabs, do: Repo.delete!(grab, allow_stale: true)
        unmonitor_series_tree(series.id)
        Audit.log_or_rollback(actor, :cancel_series, series, %{title: series.title})
        series
      end)

    with {:ok, _} <- result do
      broadcast_series(series.id)
      {:ok, series}
    end
  end

  @doc """
  Deletes a series and its tree. Grabs are reaped FIRST (the `episode.grab_id` FK nilifies on the
  episode cascade, so after `Repo.delete(series)` the grabs would be unreachable for client removal
  and orphan their downloads). Each grab's tracked client download is removed (outside the txn),
  then `delete_grab/1`; then `Repo.delete(series)` cascades seasons/episodes at the DB. Broadcasts
  `{:series_deleted, id}`. Audited. Pass `delete_files: true` to also unlink every episode
  `file_path` after the cascade (best-effort, non-blocking).
  """
  def delete_series(%Series{} = series, actor, opts \\ []) do
    delete_files? = Keyword.get(opts, :delete_files, false)
    Download.cancel_episode_intents(episode_ids_for_series(series.id))
    reap_series_grabs(series.id)
    # Collect episode file paths BEFORE the cascade deletes the rows.
    paths = if delete_files?, do: episode_file_paths_for_series(series.id), else: []

    with {:ok, deleted} <- delete_with_audit(series, actor, :delete_series, delete_files?) do
      Enum.each(paths, &best_effort_delete_file/1)
      broadcast_series_deleted(deleted.id)
      {:ok, deleted}
    end
  end

  defp episode_file_paths_for_series(series_id) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id and not is_nil(e.file_path),
        select: e.file_path
    )
  end

  defp episode_ids_for_series(series_id) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id,
        select: e.id
    )
  end

  defp episode_ids_for_grab(grab_id) do
    Repo.all(from e in Episode, where: e.grab_id == ^grab_id, select: e.id)
  end

  # Remove every grab serving the series: client-remove the tracked download (best-effort, if any),
  # then delete_grab/1. Used by delete_series (the grabs must be reaped before Repo.delete(series)
  # cascades the tree, after which their downloads would be orphaned). cancel_series does its own
  # atomic reap+unmonitor+audit in one transaction; see cancel_series/2.
  defp reap_series_grabs(series_id) do
    for grab <- grabs_for_series(series_id) do
      remove_download(grab)
      delete_grab(grab)
    end

    :ok
  end

  # Grabs whose episodes belong to this series (via the episode→season join), ALL states.
  defp grabs_for_series(series_id) do
    Repo.all(
      from g in Grab,
        join: e in Episode,
        on: e.grab_id == g.id,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id,
        distinct: true
    )
  end

  # Unmonitor every season + episode of the series in one write each so wanted_episodes is empty.
  defp unmonitor_series_tree(series_id) do
    ts = now()

    Repo.update_all(from(s in Season, where: s.series_id == ^series_id),
      set: [monitored: false, updated_at: ts]
    )

    Repo.update_all(
      from(e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: s.series_id == ^series_id
      ),
      set: [monitored: false, updated_at: ts]
    )

    :ok
  end

  @doc """
  Finalizes a grab after import, in **one transaction**: sets `file_path` (and clears `grab_id`)
  on each imported episode, bumps `search_attempts` on the grab's still-missing episodes, then
  deletes the grab. `imported` is `[{episode_id, dest_path}]`. Broadcasts `{:series_updated, _}`
  and announces any season the import completes.

  The search_attempts bump on the non-imported episodes makes a pack that never yields a wanted
  episode re-search with backoff and eventually search-park, rather than re-grabbing forever. It
  **must** run before the delete: the `grab_id` FK nilifies on delete, after which the predicate
  would match nothing. Each imported episode is written individually (a single `update_all set:`
  could not give each its own dest); `n` is one season pack, so the per-row writes are cheap. The
  `file_path` XOR `grab_id` invariant (derived state) is maintained here, the single write site.
  """
  def finish_grab(%Grab{} = grab, imported \\ []) do
    imported_ids = imported |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    series_id = series_id_for_grab(grab.id)

    result =
      Repo.transaction(fn ->
        ts = now()

        for {episode_id, dest, q} <- imported do
          Repo.update_all(from(e in Episode, where: e.id == ^episode_id),
            set: [
              file_path: dest,
              grab_id: nil,
              imported_resolution: q.resolution,
              imported_size: q.size,
              imported_language: q.language,
              imported_source: q.source,
              imported_audio_languages: q.audio_languages,
              imported_embedded_subtitles: q.embedded_subtitles,
              imported_sidecar_subtitles: q.sidecar_subtitles,
              updated_at: ts
            ]
          )
        end

        # select: in the update_all (RETURNING) hands the bumped ids to the post-commit
        # exhaustion announce without a leading SELECT — a read-then-write transaction is
        # the SQLITE_BUSY class busy_timeout can't rescue (see config/test.exs), and the
        # delete below nilifies grab_id so the ids can't be re-derived afterwards.
        {_count, bumped_ids} =
          Repo.update_all(
            missing_episodes_query(grab.id, imported_ids) |> select([e], e.id),
            inc: [search_attempts: 1],
            set: [updated_at: ts]
          )

        completed_seasons = completed_seasons_for_imported_episodes(imported_ids)

        # allow_stale: a user cancel_grab may delete the same row while this import
        # finalizes; raising here would roll back the just-imported file_path writes.
        Repo.delete!(grab, allow_stale: true)
        {bumped_ids, completed_seasons}
      end)

    with {:ok, {bumped_ids, completed_seasons}} <- result do
      broadcast_series(series_id)
      announce_search_exhausted(bumped_ids)
      Enum.each(completed_seasons, &Notifier.notify({:season_available, &1}))
      {:ok, grab}
    end
  end

  # The grab's episodes that did not import. Branch on the empty case so we never interpolate
  # an empty list into `not in` (and so a park — empty `imported` — bumps every linked episode).
  defp missing_episodes_query(grab_id, []), do: from(e in Episode, where: e.grab_id == ^grab_id)

  defp missing_episodes_query(grab_id, imported_ids),
    do: from(e in Episode, where: e.grab_id == ^grab_id and e.id not in ^imported_ids)

  defp completed_seasons_for_imported_episodes([]), do: []

  defp completed_seasons_for_imported_episodes(imported_ids) do
    today = Date.utc_today()

    imported_season_ids =
      from e in Episode,
        where: e.id in ^imported_ids and not is_nil(e.air_date) and e.air_date <= ^today,
        select: e.season_id,
        distinct: true

    from([_episode, season, series] in available_seasons_query(today),
      where: season.id in subquery(imported_season_ids),
      select: %{
        title: series.title,
        season_number: season.season_number,
        poster_path: series.poster_path
      }
    )
    |> Repo.all()
  end

  @doc """
  Parks a grab: deletes it and bumps every linked episode's `search_attempts` (so they re-search,
  bounded, then search-park). The terminal-failure case of `finish_grab/2` (nothing imported).
  """
  def park_grab(%Grab{} = grab), do: finish_grab(grab, [])

  @doc """
  Records `movie`'s current `release_title` as blocked for that movie, so release selection
  skips it on the next search. A nil `release_title` (e.g. a pre-grab park) is a no-op.

  **Non-raising**: runs inside the poller's isolated park path, where a raise would re-fire
  every tick (`isolate` never parks). So it uses a non-bang insert, logs and swallows any
  `{:error, _}`, and always returns `:ok` (mirrors `Download.best_effort_remove/2`). No broadcast.
  """
  def block_release(%Movie{release_title: nil}, _reason), do: :ok

  def block_release(%Movie{release_title: title, id: movie_id}, reason),
    do:
      insert_blocked_release(fn ->
        %{release_title: title, reason: to_string(reason), movie_id: movie_id}
      end)

  @doc """
  Records `grab`'s `release_title` as blocked for its series. Resolves the series from the grab's
  still-linked episodes, so call it **before** `park_grab/1` deletes the grab (the FK nilifies the
  links on delete). A nil `release_title` is a no-op. **Non-raising** — see `block_release/2`.
  """
  def block_grab_release(%Grab{release_title: nil}, _reason), do: :ok

  def block_grab_release(%Grab{release_title: title, id: grab_id}, reason),
    do:
      insert_blocked_release(fn ->
        # series_id_for_grab is a DB query: building attrs lazily keeps it INSIDE the catch below,
        # so the TV park path's series resolution can't raise/exit out and abort park_grab.
        %{release_title: title, reason: to_string(reason), series_id: series_id_for_grab(grab_id)}
      end)

  # Non-raising on every path (mirrors `Download.best_effort_remove/2`): the attrs thunk is run
  # inside the try, so a changeset/constraint `{:error, _}` is logged-and-swallowed AND a
  # raised/exited DB failure (in the insert OR the lazy series-id query) is caught — because the
  # TV caller blocks BEFORE `park_grab` deletes the grab, a raise here would stop the park and
  # hot-loop the grab every tick.
  defp insert_blocked_release(build_attrs) do
    attrs = build_attrs.()

    case %BlockedRelease{} |> BlockedRelease.changeset(attrs) |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("block_release failed for #{inspect(attrs)}: #{inspect(changeset.errors)}")
        :ok
    end
  catch
    kind, value ->
      Logger.warning("block_release raised: #{inspect({kind, value})}")
      :ok
  end

  @doc "Downcased-or-not release titles blocked for `movie` (the exact strings stored)."
  def blocked_release_titles(%Movie{id: movie_id}),
    do:
      Repo.all(from b in BlockedRelease, where: b.movie_id == ^movie_id, select: b.release_title)

  @doc "Release titles blocked for the series `series_id`."
  def blocked_release_titles_for_series(series_id),
    do:
      Repo.all(
        from b in BlockedRelease, where: b.series_id == ^series_id, select: b.release_title
      )

  @doc """
  Bumps `search_attempts` (and `updated_at`, for the poller's search backoff) on the given
  episodes in one write, then broadcasts each affected series. Used by the search pass on
  no-match / client-add failure / indexer error (no grab exists yet on that path).
  """
  # The TV sweep's per-episode search-attempt cap. Lives here (not in the poller) because the
  # UI derives :search_parked from it — the sweep's skip bound and the badge must agree.
  # (Defined before its first use below; read via max_search_attempts/0 further down.)
  @max_search_attempts 10

  def increment_search_attempts([]), do: :ok

  def increment_search_attempts(episode_ids) when is_list(episode_ids) do
    Repo.update_all(from(e in Episode, where: e.id in ^episode_ids),
      inc: [search_attempts: 1],
      set: [updated_at: now()]
    )

    for series_id <- series_ids_for_episodes(episode_ids), do: broadcast_series(series_id)
    announce_search_exhausted(episode_ids)
    :ok
  end

  # After any search_attempts bump: episodes that just crossed the cap leave the sweep
  # permanently, and that moment must never be silent (the movie analogue parks visibly at
  # :search_failed). Lives at the write site so BOTH bump paths announce — the sweep's
  # increment_search_attempts and finish_grab/park_grab's non-imported bump. Re-selecting
  # fresh rows also makes the check immune to stale in-memory counters. Monitored-only: a
  # parked grab of a just-cancelled series bumps unmonitored episodes the sweep doesn't own.
  # Single-series by construction (both callers pass one grab/season group); the notifier
  # payload's episodes carry season: :series for the transports' summary line.
  defp announce_search_exhausted([]), do: :ok

  # Best-effort like create_grab's post-commit broadcast (and guarded the same way): it runs
  # AFTER the bump/finalize committed, so a re-select raise here (pool-checkout timeout,
  # SQLITE_BUSY) must not escape — in finish_grab's caller that would skip the client-download
  # removal and the availability notification for a grab row that is already gone.
  #
  # >= rather than ==: crossings normally land exactly at the cap (new grabs reset or start
  # below it), but pre-existing data can sit at the cap inside an in-flight grab and get
  # bumped past it. A capped episode can't re-announce — the sweep skips it and every grab
  # path resets — so >= adds no duplicates, only catches the above-cap stragglers.
  defp announce_search_exhausted(episode_ids) do
    exhausted =
      Repo.all(
        from e in Episode,
          where:
            e.id in ^episode_ids and e.search_attempts >= ^@max_search_attempts and
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

  defp series_ids_for_episodes(episode_ids) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.id in ^episode_ids,
        select: s.series_id,
        distinct: true
    )
  end

  @doc "Grabs still downloading (no `content_path` yet)."
  def list_grabs_downloading, do: Repo.all(from g in Grab, where: is_nil(g.content_path))

  @doc "Count of grabs still downloading (no `content_path` yet)."
  def count_grabs_downloading,
    do: Repo.aggregate(from(g in Grab, where: is_nil(g.content_path)), :count)

  @doc """
  Grabs downloaded and awaiting import (`content_path` set), with `episodes: [season: :series]`
  preloaded so the TV poller's import pass can map files → episodes and build library paths
  without reaching past the Catalog boundary.
  """
  def list_grabs_downloaded do
    Repo.all(
      from g in Grab,
        where: not is_nil(g.content_path),
        preload: [episodes: [season: :series]]
    )
  end

  @doc "All grabs newest-first, with `episodes: [season: :series]` preloaded for the admin /grabs view."
  def list_grabs do
    Repo.all(from g in Grab, order_by: [desc: g.id], preload: [episodes: [season: :series]])
  end

  @doc """
  Fetches one grab by id, or `nil`. User-initiated grab actions (e.g. /activity's
  delete) must re-read before acting: a grab resolved from a rendered snapshot may
  have finished importing meanwhile, and cancelling THAT would remove a completed,
  already-imported torrent from the client (stopping seeding) for nothing.
  """
  def get_grab(id), do: Repo.get(Grab, id)

  @doc """
  The SQL-expressible wanted set: monitored episodes with no file and no active grab whose
  `air_date` has passed (set and `<= today`). Preloads `season: :series` for the poller's
  search + season-grouping. Backoff/bound filtering (search_attempts, retry window) is applied
  by the TV poller, matching the movie poller's split. Gated on the leaf `episode.monitored`
  flag (the cascade/add keep it the single source of truth).

  Season 0 (specials) is excluded: the parser/scorer can't address it in M5 (a `{Season:0}`
  search yields nothing matchable), so including specials would only churn search attempts.
  Specials are M6 scope.
  """
  def wanted_episodes do
    Repo.all(from e in wanted_episodes_query(), preload: [season: :series])
  end

  @doc "Count of wanted episodes (see `wanted_episodes/0`)."
  def count_wanted_episodes, do: Repo.aggregate(wanted_episodes_query(), :count)

  @doc """
  `{series tmdb_id, season_number}` pairs whose content has fully landed: at least one
  episode file, and no aired episode still missing one — monitored or not, because a
  `:future`-strategy season with only its newest episode imported must NOT read Available
  (that would hide the Request affordance for a season that's 90% absent). Drives the
  requester-facing season badges — availability outranks a stale request status
  (mirroring the movie `title_state` precedence), otherwise a fully imported season
  reads "Approved"/"Denied" forever. Pass `tmdb_id` to scope to one series.
  """
  def available_season_keys(tmdb_id \\ nil) do
    today = Date.utc_today()

    query = available_seasons_query(today)

    query = if tmdb_id, do: where(query, [_e, _s, sr], sr.tmdb_id == ^tmdb_id), else: query

    query
    |> select([_e, s, sr], {sr.tmdb_id, s.season_number})
    |> Repo.all()
    |> MapSet.new()
  end

  defp available_seasons_query(today) do
    from e in Episode,
      join: s in assoc(e, :season),
      join: sr in assoc(s, :series),
      where: s.season_number > 0,
      group_by: [s.id, s.season_number, sr.id, sr.tmdb_id, sr.title, sr.poster_path],
      having:
        filter(count(e.id), not is_nil(e.file_path)) > 0 and
          filter(
            count(e.id),
            is_nil(e.file_path) and not is_nil(e.air_date) and e.air_date <= ^today
          ) == 0
  end

  @doc "Count of still-wanted episodes in one season of `series_id` (see `wanted_episodes/0`)."
  def count_wanted_episodes(series_id, season_number) do
    Repo.aggregate(
      from([e, s] in wanted_episodes_query(),
        where: s.series_id == ^series_id and s.season_number == ^season_number
      ),
      :count
    )
  end

  @doc "Count of all episodes in one season of `series_id`."
  def count_episodes(series_id, season_number) do
    Repo.aggregate(
      from(e in Episode,
        join: s in assoc(e, :season),
        where: s.series_id == ^series_id and s.season_number == ^season_number
      ),
      :count
    )
  end

  @doc "See `episode_state/2`: past this many search attempts the sweep skips the episode."
  def max_search_attempts, do: @max_search_attempts

  @doc """
  Derived pipeline state for an episode (episodes carry no status enum): a file ⇒ `:available`,
  an active grab ⇒ `:downloading`, unaired/undated ⇒ `:upcoming`, sweep gave up
  (`search_attempts >= max_search_attempts/0`) ⇒ `:search_parked` (a manual Search re-queues
  it via `search_episode_now/1`), else `:wanted`.
  """
  def episode_state(%Episode{} = episode, today \\ Date.utc_today()) do
    cond do
      episode.file_path -> :available
      episode.grab_id -> :downloading
      is_nil(episode.air_date) or Date.compare(episode.air_date, today) == :gt -> :upcoming
      episode.search_attempts >= @max_search_attempts -> :search_parked
      true -> :wanted
    end
  end

  @doc """
  Re-queues a single wanted `episode` for the TV sweep by zeroing its `search_attempts` (clearing
  any backoff/attempt-cap park). A no-op for an episode that already has a file or an active grab
  (it isn't wanted). The sweep picks it up within one poll interval.
  """
  def search_episode_now(%Episode{file_path: nil, grab_id: nil} = episode),
    do: transition_episode(episode, %{search_attempts: 0})

  def search_episode_now(%Episode{}), do: :ok

  @doc "Re-queues every still-wanted episode of one `season` (zeroes their `search_attempts`)."
  def search_season_now(%Season{id: season_id}) do
    wanted_episodes()
    |> Enum.filter(&(&1.season_id == season_id))
    |> Enum.each(&transition_episode(&1, %{search_attempts: 0}))
  end

  defp wanted_episodes_query do
    today = Date.utc_today()

    from e in Episode,
      join: s in assoc(e, :season),
      where:
        s.season_number > 0 and e.monitored and e.episode_number > 0 and is_nil(e.file_path) and
          is_nil(e.grab_id) and not is_nil(e.air_date) and e.air_date <= ^today
  end

  @doc """
  Monitored, dated episodes in a calendar window (`today - 7 .. today + 90`), ordered by air date,
  with `season: :series` preloaded for the calendar view. Excludes season 0 (specials, never
  searched in M5) so the view's derived "wanted" badge stays honest.
  """
  def upcoming_episodes do
    today = Date.utc_today()
    from_date = Date.add(today, -7)
    to_date = Date.add(today, 90)

    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where:
          s.season_number > 0 and e.monitored and not is_nil(e.air_date) and
            e.air_date >= ^from_date and e.air_date <= ^to_date,
        order_by: [asc: e.air_date],
        preload: [season: :series]
    )
  end

  @doc """
  Re-fetches `series` from TMDB and reconciles its season/episode tree in one transaction, then
  broadcasts `{:series_updated, series.id}` once. Existing episodes are matched by
  `tmdb_episode_id` (series-wide, so a renumber that moves an episode across seasons is handled)
  and updated in place — preserving `monitored`, `file_path`, `grab_id`, and the attempt counters.
  Genuinely new episodes are inserted with `monitored` per the series' `monitor_strategy`; new
  seasons are inserted; rows that vanished from TMDB are left untouched.

  Returns `{:ok, series}`, or `{:error, reason}` if a TMDB fetch fails (short-circuits before any
  write, mirroring `create_series/2`).
  """
  def refresh_series(%Series{} = series) do
    with {:ok, info} <- tmdb().get_series(series.tmdb_id),
         {:ok, seasons} <- fetch_seasons(series.tmdb_id, info.seasons) do
      {:ok, updated} =
        Repo.transaction(fn ->
          s = update_series_row(series, info)
          reconcile_tree(s, seasons)
          s
        end)

      broadcast_series(series.id)
      {:ok, updated}
    end
  end

  # Backfill the series row's TMDB-sourced fields (tvdb_id especially — the acquisition
  # disambiguation key, often nil at add time). Identity + user-controlled fields (tmdb_id,
  # monitored, monitor_strategy) are not cast, so they're preserved. On failure, log and keep the
  # existing row: a descriptive backfill failing must not abort the whole tree reconcile.
  defp update_series_row(series, info) do
    changeset =
      Series.refresh_changeset(series, %{
        tvdb_id: info.tvdb_id,
        title: info.title,
        year: info.year,
        poster_path: info.poster_path,
        original_language: info.original_language,
        # Descriptive backfill — Map.get (not dot) so a partial info map can't KeyError and abort
        # the whole tree reconcile. The real normalize_series always includes these.
        overview: Map.get(info, :overview),
        genres: Map.get(info, :genres),
        vote_average: Map.get(info, :vote_average),
        first_air_date: Map.get(info, :first_air_date)
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        updated

      {:error, cs} ->
        Logger.warning("refresh: series #{series.id} row update failed: #{inspect(cs.errors)}")
        series
    end
  end

  # Two-pass renumber. Building season targets first lets `ensure_season` insert any new seasons;
  # then we partition into matched (an existing row by tmdb_episode_id) vs new. PASS 1 parks every
  # matched row in a guaranteed-free slot, PASS 2 moves each to its final slot (now collision-free),
  # PASS 3 inserts the new rows. This handles within-season swaps and mid-season insertion shifts,
  # which the old one-at-a-time update couldn't (every move collided on the unique index).
  defp reconcile_tree(series, fetched_seasons) do
    existing_seasons = Map.new(seasons_for(series.id), &{&1.season_number, &1})
    by_tmdb = Map.new(episodes_for(series.id), &{&1.tmdb_episode_id, &1})

    # Step 1 — collect {fetched_episode, season} for each fetched season whose target season
    # exists (or was just inserted); skip a season ensure_season couldn't create. The full season
    # struct is carried so PASS 3 can use season.monitored as the source of truth for new
    # episodes (rather than the series-wide monitor_strategy, which is :none for per-season
    # requests even when a specific season is monitored).
    targets =
      Enum.flat_map(fetched_seasons, fn fs ->
        case ensure_season(series, existing_seasons, fs.season_number) do
          %Season{} = season -> Enum.map(fs.episodes, &{&1, season})
          nil -> []
        end
      end)

    # Step 2 — partition into matched (existing row found by tmdb_episode_id) vs new. Guard a nil
    # tmdb_episode_id (TMDB always sets it, but a nil never matches and must be treated as new).
    {matched, new} =
      Enum.split_with(targets, fn {fe, _season} ->
        not is_nil(fe.tmdb_episode_id) and Map.has_key?(by_tmdb, fe.tmdb_episode_id)
      end)

    matched =
      Enum.map(matched, fn {fe, season} ->
        {Map.fetch!(by_tmdb, fe.tmdb_episode_id), fe, season.id}
      end)

    # Never renumber an episode with an in-flight grab: its release's files are matched + named by
    # the episode's CURRENT SxxEyy at import, so moving it mid-download would mislabel them (or
    # leave them unmatched). Leave it untouched (like a vanished row); the next refresh after the
    # grab finishes reconciles it.
    matched = Enum.filter(matched, fn {existing, _fe, _season_id} -> is_nil(existing.grab_id) end)

    # PASS 1 — park each matched row's real slot with a unique non-colliding sentinel (-id) in its
    # current season (no season_id change here), so PASS 2 never collides matched-vs-matched. Carry
    # the parked struct forward: PASS 2's `cast` diffs against the struct's number, and a row whose
    # final number equals its *original* would otherwise be seen as unchanged and the SET would omit
    # episode_number, leaving it stuck at the sentinel. Diffing against the (negative) parked number
    # always fires.
    parked =
      Enum.map(matched, fn {existing, fe, season_id} ->
        {park_episode(existing), existing, fe, season_id}
      end)

    # PASS 2 — finalize each matched row to its final (season_id, episode_number). All matched slots
    # are now free, so matched-vs-matched never collides. The only residual is a target slot still
    # held by a *vanished* row (left untouched); finalize_or_restore then puts the row back at its
    # original positive slot rather than stranding it at the -id park sentinel.
    Enum.each(parked, fn {parked_ep, original, fe, season_id} ->
      finalize_or_restore(parked_ep, original, season_id, fe)
    end)

    # PASS 3 — insert new rows, after finalize so slots reflect final state. Use the season's
    # `monitored` flag as the source of truth: a per-season request sets monitor_strategy: :none
    # on the series but flips the requested season's monitored flag to true, so season.monitored
    # correctly reflects "do we want this season" while series.monitor_strategy does not.
    Enum.each(new, fn {fe, season} -> insert_episode(season.id, season.monitored, fe) end)
  end

  # Vacate a matched row's real slot before the finalize pass: -id never collides with a positive
  # TMDB number and is unique across the table (ids are unique). Returns the updated struct (number
  # = -id) for PASS 2 to diff against; on the should-never-happen failure, log and return the
  # original struct so the finalize pass still runs.
  defp park_episode(existing) do
    # Route through refresh_changeset (not raw change/2) so the (season_id, episode_number) unique
    # constraint is registered: a park can't realistically collide (-id is negative + unique), but
    # if it ever did it degrades to {:error} rather than raising and aborting the whole series.
    case existing
         |> Episode.refresh_changeset(%{episode_number: -existing.id})
         |> Repo.update() do
      {:ok, parked} ->
        parked

      {:error, changeset} ->
        log_reconcile_error({:error, changeset}, "park episode #{existing.id}")
        existing
    end
  end

  defp seasons_for(series_id), do: Repo.all(from s in Season, where: s.series_id == ^series_id)

  defp episodes_for(series_id) do
    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where: s.series_id == ^series_id and not is_nil(e.tmdb_episode_id)
    )
  end

  defp ensure_season(_series, existing, number) when is_map_key(existing, number),
    do: Map.fetch!(existing, number)

  defp ensure_season(series, _existing, number) do
    attrs = %{
      series_id: series.id,
      season_number: number,
      monitored: series.monitor_strategy != :none
    }

    case %Season{} |> Season.refresh_changeset(attrs) |> Repo.insert() do
      {:ok, season} ->
        season

      {:error, changeset} ->
        Logger.warning(
          "refresh skipped new season #{number} of series #{series.id}: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  # Finalize a parked row to its target slot (monitored/file_path/grab_id/counters omitted from the
  # cast → preserved). If the target slot is held by a row that vanished from TMDB — the one residual
  # the two-pass can't resolve without touching vanished rows — restore the row to its original
  # positive slot rather than leaving it at the -id park sentinel, which would otherwise leak a
  # negative episode_number into wanted_episodes → the TV poller's search/import.
  defp finalize_or_restore(parked_ep, original, season_id, fe) do
    changeset =
      Episode.refresh_changeset(parked_ep, %{
        season_id: season_id,
        episode_number: fe.episode_number,
        title: fe.title,
        air_date: fe.air_date
      })

    case Repo.update(changeset) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.warning(
          "refresh: episode #{original.id} target slot occupied by a vanished row; " <>
            "restoring to its original number #{original.episode_number} instead"
        )

        parked_ep
        |> Episode.refresh_changeset(%{
          season_id: original.season_id,
          episode_number: original.episode_number
        })
        |> Repo.update()
        |> log_reconcile_error("restore episode #{original.id}")
    end
  end

  defp insert_episode(season_id, season_monitored, fe) do
    %Episode{}
    |> Episode.refresh_changeset(%{
      season_id: season_id,
      tmdb_episode_id: fe.tmdb_episode_id,
      episode_number: fe.episode_number,
      title: fe.title,
      air_date: fe.air_date,
      monitored: season_monitored
    })
    |> Repo.insert()
    |> log_reconcile_error("insert episode tmdb_ep #{fe.tmdb_episode_id}")
  end

  defp log_reconcile_error({:ok, _} = ok, _context), do: ok

  defp log_reconcile_error({:error, changeset}, context) do
    # Residual reconcile conflict (e.g. a new/restored row whose target slot is still held by a row
    # that vanished from TMDB and is left untouched by design) — rare; log and continue so the rest
    # of the tree still reconciles rather than aborting the whole series.
    Logger.warning("refresh skipped #{context}: #{inspect(changeset.errors)}")
    :ok
  end

  defp series_id_for_grab(grab_id) do
    Repo.one(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.grab_id == ^grab_id,
        select: s.series_id,
        limit: 1
    )
  end

  defp series_id_for_season(season_id),
    do: Repo.one(from s in Season, where: s.id == ^season_id, select: s.series_id)

  # Convention: a movie event carries the full struct (a flat row a LiveView patches in place —
  # see broadcast/1's {:movie_updated, movie}); a series event carries only the id, because a
  # series is a tree the detail view re-derives on receipt. A new media type picks the shape that
  # matches it (flat row → struct, tree → id).
  #
  # A nil series_id (e.g. a grab whose episodes were all unlinked) is a no-op, so callers
  # don't each need to guard it.
  defp broadcast_series(nil), do: :ok

  defp broadcast_series(series_id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_updated, series_id})

  @doc "Broadcasts `{:series_deleted, id}` on the `\"series\"` topic so open views drop the row."
  def broadcast_series_deleted(id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_deleted, id})
end
