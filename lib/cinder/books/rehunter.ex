defmodule Cinder.Books.Rehunter do
  @moduledoc """
  Periodically returns a `:held` book target to `:monitored` when its hold is worth an
  unattended second look — the books sibling of `Cinder.Catalog.Rehunter`, and the answer to the
  roadmap's "unattended retries are bounded and visible" Done-when for books specifically.

  Books have no automatic search pass (unchanged by this milestone: there is still no
  `best_book_release/2`), so this sweep can never itself trigger a download — it only flips a
  transient hold back to `:monitored` via the SAME `Books.retry_target/1` choke-point the manual
  Retry button uses, so the sweep and the button can never disagree about what a valid transition
  is. The retried release stays on its blocklist, so the very next manual search skips it.

  Only `hold_transient: true` targets are swept — a caller-stated fact
  (`Cinder.Books.hold_target/4`'s `transient` argument), not something inferred from the
  free-text `hold_reason` string, which has no closed vocabulary to classify safely.

  **On by default** — safe to default on because, structurally, it can never trigger a download;
  set `enabled: false` to disable. (`enabled?/0`'s own fallback is `false`, so an install with no
  config block at all stays off — fail-safe, mirroring `Cinder.Catalog.Rehunter`.)

  Lifecycle is `Cinder.Download.PollerSkeleton` (`stateful: false`): stateless, self-rescheduling,
  crash-recoverable. Interval and cooldown are module config
  (`config :cinder, #{inspect(__MODULE__)}, interval: <ms>, rehunt_after: <ms>`).
  """
  import Ecto.Query

  require Logger

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Repo

  @default_rehunt_after :timer.hours(24)
  @default_interval :timer.hours(6)

  use Cinder.Download.PollerSkeleton,
    log_prefix: "book rehunter",
    stateful: false,
    first_interval: :timer.minutes(2)

  @doc "Whether the rehunt sweep is enabled (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc "How long a transiently-held target rests before it is re-queued (ms)."
  def rehunt_after, do: Keyword.get(config(), :rehunt_after, @default_rehunt_after)

  defp do_poll do
    if enabled?() do
      cutoff = DateTime.add(DateTime.utc_now(), -rehunt_after(), :millisecond)
      isolate("book target rehunt", fn -> rehunt_targets(cutoff) end)
    end

    :ok
  end

  defp rehunt_targets(cutoff) do
    targets =
      Repo.all(
        from t in BookTarget,
          where: t.status == :held and t.hold_transient == true and t.updated_at < ^cutoff
      )

    # Per target, so one stale row can't abort the rest of the batch.
    for target <- targets,
        do: isolate("book target #{target.id}", fn -> rehunt_target(target) end)
  end

  # `retry_target/1` is guarded (`expect: :held`), so a target that left `:held` concurrently
  # simply misses rather than being yanked out from under an operator's own decision.
  defp rehunt_target(target) do
    case Books.retry_target(target) do
      {:ok, _requeued} ->
        Logger.info("book rehunter re-queued target #{target.id} from #{target.status}")

      {:error, reason} ->
        Logger.debug("book rehunter skipped target #{target.id}: #{inspect(reason)}")
    end
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
