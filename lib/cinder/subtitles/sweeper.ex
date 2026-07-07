defmodule Cinder.Subtitles.Sweeper do
  @moduledoc """
  Periodic subtitle backfill. Each tick, for every imported movie/episode, fetches any missing
  wanted-language sidecar via `Cinder.Subtitles.fetch_missing/2`. Holds no state — re-derives its
  work from the DB + filesystem, so it recovers cleanly after a crash and catches subtitles
  uploaded after a release landed. Mirrors `Cinder.Catalog.Refresher`: self-rescheduling, 12h
  default, `:start_poller`-gated. A blank `subtitle_languages` setting makes each pass a no-op.

  The interval is module config (no string->int seam in `Cinder.Settings`):
  `config :cinder, #{inspect(__MODULE__)}, interval: <ms>`.
  """
  use GenServer

  require Logger

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Series}
  alias Cinder.Subtitles

  @default_interval :timer.hours(12)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one sweep synchronously (tests). The scheduled timer path is asynchronous."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, :infinity)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, config_interval())
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    do_poll()
    {:reply, :ok, state}
  end

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
        {"movie #{m.id}", fn -> movie_criteria(m) end, m.file_path}
      end) ++
        Enum.map(Catalog.list_episodes_with_file(), fn ep ->
          {"episode #{ep.id}", fn -> episode_criteria(ep) end, ep.file_path}
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

  defp movie_criteria(%Movie{imdb_id: imdb_id, tmdb_id: tmdb_id}),
    do: %{imdb_id: imdb_id, tmdb_id: tmdb_id}

  defp episode_criteria(%Episode{
         episode_number: number,
         season: %{season_number: season, series: %Series{tmdb_id: tmdb_id}}
       }),
       do: %{tmdb_id: tmdb_id, season: season, episode: number}

  # fetch_missing/2 is already best-effort, but a DB/preload surprise on one item shouldn't sink
  # the whole tick — same belt-and-suspenders guarantee as Refresher's per-series isolation.
  defp isolate(label, fun) do
    fun.()
  rescue
    e -> Logger.error("sweeper skipped #{label}: #{Exception.message(e)}")
  catch
    kind, value -> Logger.error("sweeper skipped #{label}: #{inspect({kind, value})}")
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp config_interval do
    :cinder
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:interval, @default_interval)
  end
end
