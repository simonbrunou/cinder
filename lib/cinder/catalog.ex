defmodule Cinder.Catalog do
  @moduledoc """
  Discovery + watchlist: search TMDB for movies and persist requested ones.

  TMDB is reached only through the `Cinder.Catalog.TMDB` behaviour, resolved from
  config (`config :cinder, :tmdb`) so tests use a Mox mock and never hit the network.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Catalog.{Episode, Grab, Movie, Season, Series}
  alias Cinder.Repo

  @topic "movies"

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

  # Resolve the impl at runtime. compile_env! would inline the mock module, which —
  # being defined at runtime by Mox in test_helper.exs — doesn't exist at compile time
  # and warns under --warnings-as-errors. fetch_env! still fails fast if unconfigured.
  defp tmdb, do: Application.fetch_env!(:cinder, :tmdb)

  @doc """
  Adds a movie to the watchlist as `:requested`. Returns `{:ok, movie}` or
  `{:error, changeset}` (e.g. a duplicate `tmdb_id`).
  """
  def add_to_watchlist(attrs) do
    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists watchlisted movies, newest first."
  def list_watchlist do
    Repo.all(from m in Movie, order_by: [desc: m.id])
  end

  @doc "Subscribes the caller to movie state-change broadcasts (`{:movie_updated, movie}`)."
  def subscribe, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @topic)

  @doc "Fetches full movie details from TMDB (the details endpoint carries `imdb_id`)."
  def get_movie(tmdb_id), do: tmdb().get_movie(tmdb_id)

  @doc "Fetches a watchlisted movie by primary key, or `nil`."
  def get_movie_by_id(id), do: Repo.get(Movie, id)

  @doc "Lists movies in a given pipeline `status`."
  def list_by_status(status) do
    Repo.all(from m in Movie, where: m.status == ^status)
  end

  @doc """
  Applies a pipeline state transition and, on success, broadcasts
  `{:movie_updated, movie}` on the `"movies"` topic. This is the single
  choke-point for state changes — every transition broadcasts exactly once.
  `attrs` must set `:status`; it may also set `:download_id`, `:download_protocol`,
  `:imdb_id`, `:file_path`, `:import_attempts`, and `:search_attempts`.
  """
  def transition(%Movie{} = movie, attrs) do
    with {:ok, updated} <- movie |> Movie.transition_changeset(attrs) |> Repo.update() do
      broadcast({:movie_updated, updated})
      {:ok, updated}
    end
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
    # so leaving an old download_id/protocol/file_path on a :requested row is
    # misleading and a latent misroute if anything reads them before re-download.
    transition(movie, %{
      status: :requested,
      search_attempts: 0,
      import_attempts: 0,
      download_id: nil,
      download_protocol: nil,
      file_path: nil
    })
  end

  def retry_movie(%Movie{}), do: {:error, :not_retryable}

  @doc "Fetches a watchlisted movie by TMDB id, or `nil`."
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
  def add_series_to_watchlist(tmdb_id, opts \\ []) do
    strategy = Keyword.get(opts, :monitor_strategy, :future)

    # Validate at the boundary: the strategy drives monitored?/3 (a function-clause match)
    # *before* the Ecto.Enum changeset would catch it, so an unknown atom would otherwise
    # crash rather than return a clean error.
    if strategy in Series.monitor_strategies() do
      case get_series_by_tmdb_id(tmdb_id) do
        %Series{} = series -> {:ok, series}
        nil -> create_series(tmdb_id, strategy)
      end
    else
      {:error, :invalid_monitor_strategy}
    end
  end

  @doc "Fetches a watchlisted series by TMDB id, or `nil`."
  def get_series_by_tmdb_id(tmdb_id), do: Repo.get_by(Series, tmdb_id: tmdb_id)

  @doc "Fetches a watchlisted series by primary key, or `nil`."
  def get_series_by_id(id), do: Repo.get(Series, id)

  @doc "Lists watchlisted series, newest first."
  def list_series, do: Repo.all(from s in Series, order_by: [desc: s.id])

  defp create_series(tmdb_id, strategy) do
    with {:ok, info} <- tmdb().get_series(tmdb_id),
         {:ok, seasons} <- fetch_seasons(tmdb_id, info.seasons) do
      insert_series(tmdb_id, series_attrs(info, seasons, strategy))
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

  defp series_attrs(info, seasons, strategy) do
    today = Date.utc_today()

    %{
      tmdb_id: info.tmdb_id,
      tvdb_id: info.tvdb_id,
      title: info.title,
      year: info.year,
      poster_path: info.poster_path,
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
    now = DateTime.truncate(DateTime.utc_now(), :second)

    result =
      Repo.transaction(fn ->
        case season |> Ecto.Changeset.change(monitored: monitored?) |> Repo.update() do
          {:ok, season} ->
            Repo.update_all(from(e in Episode, where: e.season_id == ^season.id),
              set: [monitored: monitored?, updated_at: now]
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

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  @doc """
  Creates a grab for `episode_ids` (a non-empty list of episodes in one series — a single
  episode or a season pack) and links them in one transaction, then broadcasts
  `{:series_updated, series_id}`. A changeset failure (e.g. a missing `download_id`) rolls the
  whole thing back as `{:error, changeset}` rather than raising, mirroring `set_season_monitored/2`.
  """
  def create_grab(download_id, protocol, episode_ids) do
    result = Repo.transaction(fn -> insert_and_link_grab(download_id, protocol, episode_ids) end)

    with {:ok, grab} <- result do
      broadcast_series(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  defp insert_and_link_grab(download_id, protocol, episode_ids) do
    case %Grab{}
         |> Grab.changeset(%{download_id: download_id, download_protocol: protocol})
         |> Repo.insert() do
      {:ok, grab} -> link_grab_episodes(grab, episode_ids)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp link_grab_episodes(grab, episode_ids) do
    # Guard `is_nil(grab_id)`: never re-link an episode another grab already owns (defends against
    # a same-tick double-link silently overwriting an earlier grab).
    {linked, _} =
      Repo.update_all(
        from(e in Episode, where: e.id in ^episode_ids and is_nil(e.grab_id)),
        set: [grab_id: grab.id, updated_at: now()]
      )

    # Every requested episode was already grabbed: roll back so we don't leave an orphan grab
    # (and so the caller doesn't start a download serving nothing).
    if linked == 0, do: Repo.rollback(:no_episodes_linked), else: grab
  end

  @doc """
  Marks a grab downloaded (records `content_path`, the at-rest path to import) and broadcasts.
  Also resets `download_attempts` at the download→import boundary (mirrors the movie poller's
  `import_attempts: 0` reset, `poller.ex:140`) so download-phase blips don't starve the shared
  grab-lifetime retry budget the import pass then draws from.
  """
  def mark_grab_downloaded(%Grab{} = grab, content_path) do
    changeset = Grab.changeset(grab, %{content_path: content_path, download_attempts: 0})

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
      set: [updated_at: now()]
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

    with {:ok, grab} <- Repo.delete(grab) do
      broadcast_series(series_id)
      {:ok, grab}
    end
  end

  @doc """
  Finalizes a grab after import, in **one transaction**: sets `file_path` (and clears `grab_id`)
  on each imported episode, bumps `search_attempts` on the grab's still-missing episodes, then
  deletes the grab. `imported` is `[{episode_id, dest_path}]`. Broadcasts `{:series_updated, _}`.

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

        for {episode_id, dest} <- imported do
          Repo.update_all(from(e in Episode, where: e.id == ^episode_id),
            set: [file_path: dest, grab_id: nil, updated_at: ts]
          )
        end

        Repo.update_all(missing_episodes_query(grab.id, imported_ids),
          inc: [search_attempts: 1],
          set: [updated_at: ts]
        )

        Repo.delete!(grab)
      end)

    with {:ok, _} <- result do
      broadcast_series(series_id)
      {:ok, grab}
    end
  end

  # The grab's episodes that did not import. Branch on the empty case so we never interpolate
  # an empty list into `not in` (and so a park — empty `imported` — bumps every linked episode).
  defp missing_episodes_query(grab_id, []), do: from(e in Episode, where: e.grab_id == ^grab_id)

  defp missing_episodes_query(grab_id, imported_ids),
    do: from(e in Episode, where: e.grab_id == ^grab_id and e.id not in ^imported_ids)

  @doc """
  Parks a grab: deletes it and bumps every linked episode's `search_attempts` (so they re-search,
  bounded, then search-park). The terminal-failure case of `finish_grab/2` (nothing imported).
  """
  def park_grab(%Grab{} = grab), do: finish_grab(grab, [])

  @doc """
  Bumps `search_attempts` (and `updated_at`, for the poller's search backoff) on the given
  episodes in one write, then broadcasts each affected series. Used by the search pass on
  no-match / client-add failure / indexer error (no grab exists yet on that path).
  """
  def increment_search_attempts([]), do: :ok

  def increment_search_attempts(episode_ids) when is_list(episode_ids) do
    Repo.update_all(from(e in Episode, where: e.id in ^episode_ids),
      inc: [search_attempts: 1],
      set: [updated_at: now()]
    )

    for series_id <- series_ids_for_episodes(episode_ids), do: broadcast_series(series_id)
    :ok
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
    today = Date.utc_today()

    Repo.all(
      from e in Episode,
        join: s in assoc(e, :season),
        where:
          s.season_number > 0 and e.monitored and is_nil(e.file_path) and is_nil(e.grab_id) and
            not is_nil(e.air_date) and e.air_date <= ^today,
        preload: [season: :series]
    )
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
        poster_path: info.poster_path
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
    today = Date.utc_today()
    existing_seasons = Map.new(seasons_for(series.id), &{&1.season_number, &1})
    by_tmdb = Map.new(episodes_for(series.id), &{&1.tmdb_episode_id, &1})

    # Step 1 — collect {fetched_episode, target_season_id} for each fetched season whose target
    # season exists (or was just inserted); skip a season ensure_season couldn't create.
    targets =
      Enum.flat_map(fetched_seasons, fn fs ->
        case ensure_season(series, existing_seasons, fs.season_number) do
          %Season{id: season_id} -> Enum.map(fs.episodes, &{&1, season_id})
          nil -> []
        end
      end)

    # Step 2 — partition into matched (existing row found by tmdb_episode_id) vs new. Guard a nil
    # tmdb_episode_id (TMDB always sets it, but a nil never matches and must be treated as new).
    {matched, new} =
      Enum.split_with(targets, fn {fe, _season_id} ->
        not is_nil(fe.tmdb_episode_id) and Map.has_key?(by_tmdb, fe.tmdb_episode_id)
      end)

    matched =
      Enum.map(matched, fn {fe, season_id} ->
        {Map.fetch!(by_tmdb, fe.tmdb_episode_id), fe, season_id}
      end)

    # PASS 1 — park each matched row's real slot with a unique non-colliding sentinel (-id) in its
    # current season (no season_id change here), so PASS 2 never collides matched-vs-matched. Carry
    # the parked struct forward: PASS 2's `cast` diffs against the struct's number, and a row whose
    # final number equals its *original* would otherwise be seen as unchanged and the SET would omit
    # episode_number, leaving it stuck at the sentinel. Diffing against the (negative) parked number
    # always fires.
    parked =
      Enum.map(matched, fn {existing, fe, season_id} ->
        {park_episode(existing), fe, season_id}
      end)

    # PASS 2 — finalize each matched row to its final (season_id, episode_number). All real slots
    # are now free. The UPDATE keys by id; the parked struct guarantees the episode_number diff.
    Enum.each(parked, fn {existing, fe, season_id} -> update_episode(existing, season_id, fe) end)

    # PASS 3 — insert new rows, after finalize so slots reflect final state.
    Enum.each(new, fn {fe, season_id} -> insert_episode(series, season_id, fe, today) end)
  end

  # Vacate a matched row's real slot before the finalize pass: -id never collides with a positive
  # TMDB number and is unique across the table (ids are unique). Returns the updated struct (number
  # = -id) for PASS 2 to diff against; on the should-never-happen failure, log and return the
  # original struct so the finalize pass still runs.
  defp park_episode(existing) do
    case existing |> Ecto.Changeset.change(episode_number: -existing.id) |> Repo.update() do
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

  # monitored/file_path/grab_id/counters omitted from attrs → preserved.
  defp update_episode(existing, season_id, fe) do
    existing
    |> Episode.refresh_changeset(%{
      season_id: season_id,
      episode_number: fe.episode_number,
      title: fe.title,
      air_date: fe.air_date
    })
    |> Repo.update()
    |> log_reconcile_error("update episode #{existing.id}")
  end

  defp insert_episode(series, season_id, fe, today) do
    %Episode{}
    |> Episode.refresh_changeset(%{
      season_id: season_id,
      tmdb_episode_id: fe.tmdb_episode_id,
      episode_number: fe.episode_number,
      title: fe.title,
      air_date: fe.air_date,
      monitored: monitored?(series.monitor_strategy, fe.air_date, today)
    })
    |> Repo.insert()
    |> log_reconcile_error("insert episode tmdb_ep #{fe.tmdb_episode_id}")
  end

  defp log_reconcile_error({:ok, _} = ok, _context), do: ok

  defp log_reconcile_error({:error, changeset}, context) do
    # The two-pass renumber handles reorders/swaps/shifts. The remaining {:error, changeset} case
    # is a target reusing a slot still held by a row that *vanished* from TMDB (left untouched by
    # design) — rare; log and continue so the rest of the tree still reconciles.
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

  # A nil series_id (e.g. a grab whose episodes were all unlinked) is a no-op, so callers
  # don't each need to guard it.
  defp broadcast_series(nil), do: :ok

  defp broadcast_series(series_id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_updated, series_id})
end
