defmodule Cinder.Catalog.Episodes do
  @moduledoc """
  The episode write every catalog concept shares: an episode's derived state, its search budget,
  the guarded write of its pipeline fields and what a committed episode write announces.

  Episodes carry no status enum. Their state is derived from `file_path`, `grab_id`, `air_date`
  and `search_attempts` (`state/2`), and the only race-safe write of those fields is
  `transition/3`. Episode adoption and a grab's residual Part decision write episodes their own
  way and announce through `announce/2` too; `Grabs.finish_grab` and `Cinder.Catalog.TitleDeletion`
  still write and announce their own way (see `docs/agents/architecture.md`, #788).
  """
  import Ecto.Query

  alias Cinder.Catalog.{Episode, EpisodeTransition, Events, Season}
  alias Cinder.{GuardedWrite, Repo, Settings}

  # How many fruitless searches an episode takes before the TV sweep parks it (`:search_parked`).
  @max_search_attempts 10

  @doc "Past this many search attempts the TV sweep skips an episode (see `state/2`)."
  def max_search_attempts, do: @max_search_attempts

  @doc """
  Derived pipeline state for an episode: a file ⇒ `:available`, an active grab ⇒ `:downloading`,
  unaired or undated ⇒ `:upcoming`, the sweep gave up (`search_attempts >= max_search_attempts/0`)
  ⇒ `:search_parked` (a manual Search re-queues it), else `:wanted`.
  """
  def state(%Episode{} = episode, today \\ Settings.household_date()) do
    cond do
      episode.file_path -> :available
      episode.grab_id -> :downloading
      is_nil(episode.air_date) or Date.compare(episode.air_date, today) == :gt -> :upcoming
      episode.search_attempts >= @max_search_attempts -> :search_parked
      true -> :wanted
    end
  end

  @doc """
  The choke-point for episode **pipeline** writes (`file_path`, `grab_id`, attempt counters), as
  a guarded write (`Cinder.GuardedWrite`). `expect:` names the values the row must still hold
  (`%{field => value}`); a miss is `{:error, :stale_status}`. Publishes through `announce/2`
  after commit. `monitored` is not a pipeline field.
  """
  def transition(%Episode{} = episode, attrs, opts \\ []) do
    expect = opts |> Keyword.get(:expect, %{}) |> Enum.to_list()
    GuardedWrite.write(EpisodeTransition, episode, attrs, expect)
  end

  @doc "The id of the series that holds `episode`, or `nil` once the episode is gone."
  def series_id(%Episode{id: id}), do: id |> List.wrap() |> series_ids() |> List.first()

  @doc "The distinct ids of the series that hold the episodes `episode_ids`."
  def series_ids(episode_ids) do
    Repo.all(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.id in ^episode_ids,
        select: s.series_id,
        distinct: true
    )
  end

  @doc """
  Announces committed episode writes: one `{:series_updated, id}` per series that holds one of
  `episodes`, plus each id in `extra_series_ids` (a series whose change wrote no episode), then
  one `[:cinder, :transition]` per episode with its derived state. Call it after commit.
  """
  def announce(episodes, extra_series_ids \\ []) do
    series_ids = episodes |> Enum.map(& &1.id) |> series_ids()

    (extra_series_ids ++ series_ids) |> Enum.uniq() |> Enum.each(&Events.series_updated/1)
    Enum.each(episodes, &Events.transitioned(:episode, state(&1)))
  end
end
