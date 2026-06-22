defmodule Cinder.Catalog do
  @moduledoc """
  Discovery + watchlist: search TMDB for movies and persist requested ones.

  TMDB is reached only through the `Cinder.Catalog.TMDB` behaviour, resolved from
  config (`config :cinder, :tmdb`) so tests use a Mox mock and never hit the network.
  """
  import Ecto.Query

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

  Find-or-create by `tmdb_id`: an already-added series is returned as-is — no re-sync
  (that's M6). Returns `{:ok, series}` (associations unloaded — preload
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
  Creates a grab for `episode_ids` (a single episode or a season pack) and links them in one
  transaction, then broadcasts `{:series_updated, series_id}`.
  """
  def create_grab(download_id, protocol, episode_ids) do
    result =
      Repo.transaction(fn ->
        grab =
          %Grab{}
          |> Grab.changeset(%{download_id: download_id, download_protocol: protocol})
          |> Repo.insert!()

        Repo.update_all(
          from(e in Episode, where: e.id in ^episode_ids),
          set: [grab_id: grab.id, updated_at: now()]
        )

        grab
      end)

    with {:ok, grab} <- result do
      broadcast_series(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  @doc "Marks a grab downloaded (records `content_path`, the at-rest path to import) and broadcasts."
  def mark_grab_downloaded(%Grab{} = grab, content_path) do
    with {:ok, grab} <- grab |> Grab.changeset(%{content_path: content_path}) |> Repo.update() do
      broadcast_series(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  @doc """
  Deletes a grab; the `grab_id` FK (`on_delete: :nilify_all`) unlinks its episodes. Broadcasts
  `{:series_updated, series_id}` (captured before the delete, while the links still exist).
  """
  def delete_grab(%Grab{} = grab) do
    series_id = series_id_for_grab(grab.id)

    with {:ok, grab} <- Repo.delete(grab) do
      if series_id, do: broadcast_series(series_id)
      {:ok, grab}
    end
  end

  @doc "Grabs still downloading (no `content_path` yet)."
  def list_grabs_downloading, do: Repo.all(from g in Grab, where: is_nil(g.content_path))

  @doc "Grabs downloaded and awaiting import (`content_path` set)."
  def list_grabs_downloaded, do: Repo.all(from g in Grab, where: not is_nil(g.content_path))

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

  defp broadcast_series(series_id),
    do: Phoenix.PubSub.broadcast(Cinder.PubSub, @series_topic, {:series_updated, series_id})
end
