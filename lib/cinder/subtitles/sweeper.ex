defmodule Cinder.Subtitles.Sweeper do
  @moduledoc """
  Periodic subtitle backfill. Each tick, for every imported movie/episode, fetches any missing
  wanted-language sidecar via `Cinder.Subtitles.fetch_missing/3`, halting the tick once a download
  hits the daily quota (406). Holds no state — re-derives its work from the DB + filesystem, so it
  recovers cleanly after a crash and catches subtitles uploaded after a release landed. 12h default,
  `:start_poller`-gated. A blank `subtitle_languages` setting makes each pass a no-op.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`). The interval is module config:
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.
  """
  alias Cinder.{Catalog, Subtitles}
  alias Cinder.Catalog.{Episode, Movie}

  @default_interval :timer.hours(12)
  # The video's own track (spec 069, `Cinder.Subtitles.OwnTrack`): finding one reads the whole file
  # twice, a probe and an extraction of 45–135 s each on prod (measured 2026-10-13), and the first
  # sweeps after it shipped find one for thousands of files already in the library. Each sweep
  # spends at most this long on new own-track work, then carries on with the OpenSubtitles checks
  # alone; the next sweep resumes where it left off, since finished files are stable.
  @own_track_budget :timer.hours(6)
  use Cinder.Download.PollerSkeleton, log_prefix: "sweeper", stateful: false

  defp do_poll do
    if Subtitles.wanted_languages() == [] do
      :ok
    else
      sweep()
    end
  end

  defp sweep do
    own_track_until = System.monotonic_time(:millisecond) + @own_track_budget

    units =
      Enum.flat_map(Catalog.list_available_movies_with_file(), &movie_units/1) ++
        Enum.flat_map(Catalog.list_episodes_with_file(), &episode_units/1)

    # reduce_while so a quota hit halts the whole tick — see fetch_unit/3. Returns :ok either way.
    Enum.reduce_while(units, :ok, &fetch_unit(&1, &2, own_track_until))
  end

  # Fetch one unit's subtitles; stop the whole tick the moment a download hits the daily quota (406):
  # further downloads would just fail, and their searches would burn the rate-limit for nothing. The
  # next tick resumes.
  defp fetch_unit({label, criteria_fun, path, kind}, _acc, own_track_until) do
    fetch = fn ->
      criteria_fun.()
      |> Map.put(:own_track_until, own_track_until)
      |> Subtitles.fetch_missing(path, kind)
    end

    case isolate(label, fetch) do
      :quota_exceeded -> {:halt, :ok}
      _ -> {:cont, :ok}
    end
  end

  defp episode_units(episode) do
    Enum.map(Episode.file_paths(episode), fn path ->
      {"episode #{episode.id}", fn -> Subtitles.episode_criteria(episode) end, path, :tv}
    end)
  end

  defp movie_units(%Movie{} = movie) do
    Enum.map(Movie.file_paths(movie), fn path ->
      {"movie #{movie.id}", fn -> Subtitles.movie_criteria(movie) end, path, :movies}
    end)
  end
end
