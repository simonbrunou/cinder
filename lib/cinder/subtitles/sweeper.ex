defmodule Cinder.Subtitles.Sweeper do
  @moduledoc """
  Periodic subtitle backfill. Each tick, for every imported movie/episode, fetches any missing
  wanted-language sidecar via `Cinder.Subtitles.fetch_missing/2`, halting the tick once a download
  hits the daily quota (406). Holds no state — re-derives its work from the DB + filesystem, so it
  recovers cleanly after a crash and catches subtitles uploaded after a release landed. 12h default,
  `:start_poller`-gated. A blank `subtitle_languages` setting makes each pass a no-op.

  Lifecycle is `Cinder.PeriodicWorker`. The interval is module config:
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.
  """
  alias Cinder.{Catalog, Subtitles}

  @default_interval :timer.hours(12)
  use Cinder.PeriodicWorker, log_prefix: "sweeper"

  defp do_poll do
    if Subtitles.wanted_languages() == [] do
      :ok
    else
      sweep()
    end
  end

  defp sweep do
    units =
      Enum.map(Catalog.list_available_movies_with_file(), fn m ->
        {"movie #{m.id}", fn -> Subtitles.movie_criteria(m) end, m.file_path}
      end) ++
        Enum.map(Catalog.list_episodes_with_file(), fn ep ->
          {"episode #{ep.id}", fn -> Subtitles.episode_criteria(ep) end, ep.file_path}
        end)

    # reduce_while so a quota hit halts the whole tick — see fetch_unit/2. Returns :ok either way.
    Enum.reduce_while(units, :ok, &fetch_unit/2)
  end

  # Fetch one unit's subtitles; stop the whole tick the moment a download hits the daily quota (406):
  # further downloads would just fail, and their searches would burn the rate-limit for nothing. The
  # next tick resumes.
  defp fetch_unit({label, criteria_fun, path}, _acc) do
    case isolate(label, fn -> Subtitles.fetch_missing(criteria_fun.(), path) end) do
      :quota_exceeded -> {:halt, :ok}
      _ -> {:cont, :ok}
    end
  end
end
