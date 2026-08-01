defmodule Cinder.Catalog.Rehunter do
  @moduledoc """
  Periodically re-queues titles the pipeline gave up on, so a request that had no release the week
  it was made isn't dead forever — the household's standing "keep looking" loop.

  Both pollers bound their search retries (`Catalog.max_search_attempts/0`) and park what never
  resolves. Parking is the right call *per tick* — hammering an indexer for a release that does not
  exist yet is pointless — but nothing ever un-parked, so until now the only way back was a human
  clicking Retry. This sweep is that click, on a timer:

  - **movies** in `:no_match` / `:search_failed` untouched since the cooldown go back to
    `:requested` via `Catalog.retry_movie/1` (which also clears their `:stalled` blocklist rows).
  - **episodes** at the attempt cap get `search_attempts` zeroed via
    `Catalog.rehunt_parked_episodes/1`, re-entering the TV sweep.

  `:import_failed` is deliberately **excluded** even though it is a `Catalog.parked_statuses/0`
  member: that is a broken import, not a missing release — re-searching cannot help, and
  `retry_movie/1` gives it verification-hold semantics instead of a re-queue.

  **On by default** — the shipped `config/config.exs` sets `enabled: true`; set `enabled: false` to
  disable. (`enabled?/0`'s own fallback is `false`, so an install with no config block at all stays
  off — fail-safe, mirroring `Cinder.Download.StallReaper`.)

  A title that re-parks is re-notified once per cooldown (≤1/day at the defaults) — the price of
  the loop, and the signal that a request is genuinely unobtainable rather than silently forgotten.

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`): stateless, self-rescheduling,
  crash-recoverable. Interval and cooldown are module config
  (`config :cinder, #{inspect(__MODULE__)}, interval: <ms>, rehunt_after: <ms>`).
  """
  import Ecto.Query

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Repo

  @default_interval :timer.hours(6)
  @default_rehunt_after :timer.hours(24)

  # Parked for want of a release — the states a fresh search can actually resolve.
  @rehuntable [:no_match, :search_failed]

  use Cinder.Download.PollerSkeleton,
    log_prefix: "rehunter",
    stateful: false,
    first_interval: :timer.minutes(2)

  @doc "Whether the rehunt sweep is enabled (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc "How long a parked title rests before it is re-queued (ms)."
  def rehunt_after, do: Keyword.get(config(), :rehunt_after, @default_rehunt_after)

  defp do_poll do
    if enabled?() do
      cutoff = DateTime.add(DateTime.utc_now(), -rehunt_after(), :millisecond)

      isolate("movie rehunt", fn -> rehunt_movies(cutoff) end)
      isolate("episode rehunt", fn -> rehunt_episodes(cutoff) end)
    end

    :ok
  end

  defp rehunt_movies(cutoff) do
    movies =
      Repo.all(
        from m in Movie,
          where: m.status in ^@rehuntable and m.updated_at < ^cutoff
      )

    # Per movie, so one stale row can't abort the rest of the batch.
    for movie <- movies, do: isolate("movie #{movie.id}", fn -> rehunt_movie(movie) end)
  end

  # `retry_movie/1` is guarded (`expect:`), so a movie that left the parked state concurrently
  # simply misses rather than being yanked out of a live pipeline.
  defp rehunt_movie(movie) do
    case Catalog.retry_movie(movie) do
      {:ok, _requeued} ->
        Logger.info("rehunter re-queued movie #{movie.id} from #{movie.status}")

      {:error, reason} ->
        Logger.debug("rehunter skipped movie #{movie.id}: #{inspect(reason)}")
    end
  end

  defp rehunt_episodes(cutoff) do
    case Catalog.rehunt_parked_episodes(cutoff) do
      0 -> :ok
      count -> Logger.info("rehunter re-queued #{count} search-parked episode(s)")
    end
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
