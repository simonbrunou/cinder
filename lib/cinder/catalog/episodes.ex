defmodule Cinder.Catalog.Episodes do
  @moduledoc """
  The episode write every catalog concept shares: an episode's derived state, its search budget,
  the guarded write of its pipeline fields and what a committed episode write announces.

  Episodes carry no status enum. Their state is derived from `file_path`, `grab_id`, `air_date`
  and `search_attempts` (`state/2`). Every application write of `file_path`, `part_file_paths` or
  `grab_id`, and every `search_attempts` write on the episodes a grab owns inside that grab's
  frame, goes through `transition/3`. The exceptions, which `docs/agents/architecture.md`
  ("Guarded writes have one contract") points to:

    * Three bulk `search_attempts` writes stay one `update_all` each, over a set a query chose and
      outside any grab. `EpisodeSearch.increment_search_attempts/1` bumps the counter over the
      episodes one search covered. `EpisodeSearch.rehunt_parked_episodes/1` and the reset in
      `MediaProfiles.set_series_language_in_transaction/2` zero it and leave `updated_at` alone on
      purpose, so the sweep's own bump restarts the backoff clock; a guarded write always stamps
      `updated_at`, and the resets can touch every episode of a series.
    * Deleting a grab clears its episodes' `grab_id` through the `episodes.grab_id` foreign key
      (`ON DELETE SET NULL`), in the delete's own statement: `Grabs.cancel_grab/1`,
      `cancel_mapping_grab/1`, `reject_grab_release/2` and `TitleDeletion.cancel_series/2` and
      `delete_series/3`. Those paths write no other pipeline field of those rows. A grab that
      finishes, parks or is reaped releases its episodes with a guarded write instead, since it
      writes those rows anyway.
    * `monitored` is not a pipeline field: `Episode.transition_changeset/2` does not cast it, so a
      `monitored` key in `transition/3`'s attrs writes the caller's struct value back. Its writers
      write it directly.
  """
  import Ecto.Query
  require Logger

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
  `EpisodeTransition` publishes through it.

  Best-effort, like `Grabs.announce/1`: once the write committed, a failure here (a
  pool-checkout timeout on the series lookup, a broadcast that raises) is logged and never
  reaches the writer. `Cinder.Download`'s intent reconcile treats any raise from
  `Grabs.create_grab/5` or `create_grab_from_intent/1` as failed ownership and removes the client
  download, even after the grab committed.
  """
  def announce(episodes, extra_series_ids \\ []) do
    series_ids = episodes |> Enum.map(& &1.id) |> series_ids()

    (extra_series_ids ++ series_ids) |> Enum.uniq() |> Enum.each(&Events.series_updated/1)
    Enum.each(episodes, &Events.transitioned(:episode, state(&1)))
  rescue
    e -> warn_announce_failed(episodes, inspect(e))
  catch
    kind, value -> warn_announce_failed(episodes, "#{kind}: #{inspect(value)}")
  end

  defp warn_announce_failed(episodes, reason) do
    ids = Enum.map(episodes, & &1.id)
    Logger.warning("post-commit announce for episodes #{inspect(ids)} failed: #{reason}")
  end
end
