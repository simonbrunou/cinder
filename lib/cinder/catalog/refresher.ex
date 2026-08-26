defmodule Cinder.Catalog.Refresher do
  @moduledoc """
  Periodically re-fetches every globally monitored series, plus any unmonitored series with a
  directly monitored episode, from TMDB and reconciles its tree via
  `Cinder.Catalog.refresh_series/1`, so a late-filled `air_date` or a newly-announced
  episode/season becomes visible to the TV poller's wanted-episodes sweep. Runs on a long interval
  (12h by default) — household-scale TMDB load is trivial. `:start_poller`-gated like the pollers,
  so the suite doesn't auto-run it.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`) (self-rescheduling, stateless, `:infinity` poll). The
  interval is module config: `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.
  """
  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Locales
  alias Cinder.Repo
  alias Cinder.Requests.Request
  alias Cinder.Settings

  @default_interval :timer.hours(12)
  @localization_resync_key "localization_resync_v1"
  @localization_trim_key "localization_trim_v1"
  use Cinder.Download.PollerSkeleton,
    log_prefix: "refresher",
    stateful: false,
    first_interval: :timer.minutes(1)

  defp do_poll do
    for series <- series_requiring_refresh() do
      isolate("series #{series.id}", fn -> refresh_one(series) end)
    end

    # Localization catch-up. Each pass is wrapped in the same `isolate/2` as the per-series loop:
    # trim/copy write through `Repo.update_all`, which skips `to_constraints` and so raises a RAW
    # `Exqlite.Error` on a transient SQLite-busy — outside `isolate` one blip crashed the whole
    # Refresher and re-ran the per-series TMDB sweep from the top. `trim_localizations_once` is the
    # only genuinely one-time backfill (legacy bloated maps; new writes only ever store
    # noncanonical locales — `TMDB.HTTP.localizations_from/1`) so it is gated by a done-flag and
    # stops scanning once caught up. The empty-map enrich/copy passes stay (self-heal for a row
    # created empty during a TMDB outage — see the refresher tests) but query only the still-empty
    # rows instead of loading the whole table each tick.
    isolate("trim localizations", &trim_localizations_once/0)
    isolate("enrich localizations", &enrich_localizations/0)
    isolate("copy request localizations", &copy_request_localizations/0)

    :ok
  end

  defp series_requiring_refresh do
    monitored_episode =
      from e in Episode,
        join: season in Season,
        on: season.id == e.season_id,
        where: season.series_id == parent_as(:series).id and e.monitored,
        select: 1

    Repo.all(
      from series in Series,
        as: :series,
        where: series.monitored or exists(subquery(monitored_episode)),
        order_by: [desc: series.id]
    )
  end

  # Empty (or NULL) localizations map, matched in SQL — stored as JSON text, so an empty map is the
  # literal "{}". Lets the enrich/copy passes scan only rows still needing a backfill.
  defp empty_localizations,
    do: dynamic([r], fragment("coalesce(?, '{}') = '{}'", r.localizations))

  defp trim_localizations_once do
    unless Settings.get(@localization_trim_key) == "true" do
      trim_localizations(Movie)
      trim_localizations(Series)
      Settings.put(@localization_trim_key, "true")
    end
  end

  defp trim_localizations(schema) do
    allowed = Locales.noncanonical()

    for record <- Repo.all(schema),
        current = record.localizations || %{},
        trimmed = Map.take(current, allowed),
        trimmed != current do
      schema
      |> where([r], r.id == ^record.id)
      |> Repo.update_all(set: [localizations: trimmed])
    end
  end

  defp enrich_localizations do
    if Settings.get(@localization_resync_key) == "true" do
      enrich_movies()
      enrich_unmonitored_series()
    else
      resync_localizations()
      Settings.put(@localization_resync_key, "true")
    end
  end

  defp resync_localizations do
    records =
      Repo.all(Movie) ++ Repo.all(from s in Series, where: not s.monitored)

    records
    |> Enum.with_index()
    |> Enum.each(fn {record, index} ->
      if index > 0, do: Process.sleep(250)
      enrich_record(record)
    end)
  end

  defp enrich_record(%Movie{} = movie),
    do: isolate("movie #{movie.id}", fn -> Catalog.enrich_movie(movie) end)

  defp enrich_record(%Series{} = series),
    do: isolate("series metadata #{series.id}", fn -> Catalog.enrich_series(series) end)

  # Empty maps are deliberately retried every tick so transient TMDB/DB drift self-heals — but
  # only the still-empty rows are queried (not the whole table) so a caught-up instance does a
  # cheap indexless-but-narrow scan returning nothing.
  defp enrich_movies do
    Movie
    |> where(^empty_localizations())
    |> Repo.all()
    |> Enum.with_index()
    |> Enum.each(fn {movie, index} ->
      if index > 0, do: Process.sleep(250)
      isolate("movie #{movie.id}", fn -> Catalog.enrich_movie(movie) end)
    end)
  end

  defp enrich_unmonitored_series do
    query = from(s in Series, where: not s.monitored) |> where(^empty_localizations())

    for series <- Repo.all(query) do
      isolate("series metadata #{series.id}", fn -> Catalog.enrich_series(series) end)
    end
  end

  defp copy_request_localizations do
    Request
    |> where(^empty_localizations())
    |> Repo.all()
    |> Enum.each(fn request ->
      case catalog_localizations(request) do
        localizations when map_size(localizations) > 0 ->
          Request
          |> where([r], r.id == ^request.id)
          |> Repo.update_all(set: [localizations: localizations])

        _ ->
          :ok
      end
    end)
  end

  defp catalog_localizations(%Request{target_type: "movie", target_id: tmdb_id}) do
    case Repo.get_by(Movie, tmdb_id: tmdb_id) do
      nil -> %{}
      movie -> Map.take(movie.localizations || %{}, Locales.noncanonical())
    end
  end

  defp catalog_localizations(%Request{
         target_type: type,
         target_id: tmdb_id
       })
       when type in ["series", "season", "episode"] do
    case Repo.get_by(Series, tmdb_id: tmdb_id) do
      nil -> %{}
      series -> Map.take(series.localizations || %{}, Locales.noncanonical())
    end
  end

  defp catalog_localizations(%Request{}), do: %{}

  defp refresh_one(series) do
    case Catalog.refresh_series(series) do
      {:ok, _} ->
        :ok

      # A {:error, reason} (TMDB 404/timeout/expired token) short-circuits before any write and
      # does NOT raise, so isolate/2 wouldn't surface it. Log it so a wedged refresh is visible.
      {:error, reason} ->
        Logger.warning("refresher: series #{series.id} refresh failed: #{inspect(reason)}")
    end
  end
end
