defmodule Cinder.Download.BookPoller do
  @moduledoc """
  Polls in-flight book downloads on each tick:

  1. **advance_downloading** — checks each `Cinder.Books.BookGrab` with no `content_path`;
     records the client's progress and, on completion, stores the delivered path. A dead
     download drops the grab and returns the target to plain `:monitored`, so an operator can
     pick another release.
  2. **import_downloaded** — publishes each completed grab through `Cinder.Library.BookImport`
     and arms its target `:available`.

  **There is no search pass, and that is the milestone gate.** The video pollers sweep
  `:requested` titles into `Cinder.Download.start/1`, which calls the scorer's automatic
  selection. `Cinder.Acquisition.Books` deliberately exports no `best_book_release/2` — the
  roadmap enables automatic choice only once corpus precision is measured — so a book download
  begins only where an operator chose the release. Adding a sweep here would route around that
  gate, so this poller only ever advances downloads that already exist.

  Holds no in-flight state: every tick re-derives its work from the DB, so it recovers cleanly
  after a crash/restart.
  """
  require Logger

  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Download
  alias Cinder.Library
  alias Cinder.Library.BookImport
  alias Cinder.Notifier

  @default_interval 5_000
  @search_retry_after 60

  use Cinder.Download.PollerSkeleton, log_prefix: "book poller"

  # An import failure that retrying cannot fix: the payload is what it is. Park the target `:held`
  # immediately with the exact reason rather than burning the attempt budget re-reading the same
  # bytes. This is the contract's "preserve the failed artifact in a safe parked state with an
  # exact reason; never import a guessed match" — the download itself is left on disk untouched.
  @permanent_import_errors [
    :no_book_file,
    :ambiguous_book_files,
    :unsupported_archive,
    :unsafe_source,
    :library_not_configured,
    :download_roots_not_configured
  ]

  defp do_poll(_state) do
    isolate("stage reconciliation", fn -> Library.reconcile_stages() end)

    isolate("pending intent reconciliation", fn ->
      Download.reconcile_pending_intents([:book_target])
    end)

    advance_downloading()
    import_downloaded()
    :ok
  end

  defp advance_downloading do
    for grab <- Books.Grabs.list_downloading(),
        do: isolate("book grab #{grab.id}", fn -> advance(grab) end)
  end

  defp import_downloaded do
    for grab <- Books.Grabs.list_downloaded(),
        do: isolate("book grab #{grab.id}", fn -> import_with_stage_handoff(grab) end)
  end

  defp import_with_stage_handoff(grab),
    do: Library.with_stage_handoff(fn -> import_one(grab) end)

  # --- download phase ---

  defp advance(%BookGrab{} = grab) do
    case client_status(grab) do
      {:ok, %{state: :completed, content_path: path}} when is_binary(path) and path != "" ->
        mark_downloaded(grab, path)

      # Completed with no path: the client cannot tell us where the payload is, so there is
      # nothing to import. Treated as a failed download rather than an import failure — the same
      # call the movie poller makes.
      {:ok, %{state: :completed}} ->
        fail_download(grab, :missing_content_path)

      {:ok, %{state: :error} = status} ->
        fail_download(grab, Map.get(status, :reason) || :download_failed)

      {:ok, status} ->
        track(grab, status)

      # A transient client/network error must not drop a live download: leave the grab alone and
      # re-derive next tick.
      {:error, reason} ->
        Logger.info("book grab #{grab.id} status unavailable: #{inspect(reason)}")
        :ok
    end
  end

  defp client_status(%BookGrab{download_id: id, download_protocol: protocol}) do
    case Download.client_for(protocol) do
      {:ok, client} -> client.status(id)
      :error -> {:error, :no_client}
    end
  end

  defp mark_downloaded(grab, path) do
    case Books.Grabs.mark_downloaded(grab, path) do
      {:ok, _updated} -> :ok
      # Another tick won the race and already recorded it.
      {:error, :stale_book_grab} -> :ok
    end
  end

  defp track(grab, status) do
    Books.Grabs.track(grab, %{
      download_progress: Map.get(status, :progress),
      download_speed: Map.get(status, :speed),
      download_eta: Map.get(status, :eta)
    })

    :ok
  end

  # The client says this download is dead. Remove it, drop the grab, and hold the target with the
  # exact reason.
  #
  # `:held`, not back to `:monitored`: this slice has no automatic selection (there is no
  # `best_book_release/2`), so every grab exists because an operator chose a release. Returning
  # the target to `:monitored` would make a failed download indistinguishable from one nobody has
  # picked a release for yet — the failure would be silent and nothing would ever retry it. The
  # contract's `held` is "operator-visible … conflict; never auto-grab", and it carries the
  # reason, which is what B4 means by "preserve the failed artifact … with an exact reason".
  defp fail_download(%BookGrab{} = grab, reason) do
    Logger.warning("book grab #{grab.id} download failed: #{inspect(reason)}")
    remove_from_client(grab)
    target = grab.book_target
    Books.Grabs.delete(grab)
    hold_orphaned_target(target, reason)
  end

  # A grab whose target vanished has nothing to hold; the grab row is already gone.
  #
  # Distinct from `hold/3` below: there the grab still exists and is deleted only if the hold
  # wins, so a lost race leaves it for the next tick to re-derive. Here the grab is already gone
  # (the remote download is dead and was removed), so there is nothing left to re-derive and a
  # lost race is simply someone else's more recent decision.
  defp hold_orphaned_target(%BookTarget{} = target, reason) do
    case Books.transition_target(target, %{status: :held, hold_reason: to_string(reason)},
           expect: target.status
         ) do
      {:ok, _held} ->
        :ok

      # The target moved under us (an operator unmonitored it, or another unit already held it).
      # Its current state is more recent than this decision, so leave it alone.
      {:error, _reason} ->
        :ok
    end
  end

  defp hold_orphaned_target(_missing_target, _reason), do: :ok

  defp remove_from_client(%BookGrab{download_id: id, download_protocol: protocol}) do
    with {:ok, client} <- Download.client_for(protocol) do
      client.remove(id, delete_files: true)
    end

    :ok
  rescue
    error ->
      Logger.info("book download removal failed: #{inspect(error)}")
      :ok
  end

  # --- import phase ---

  defp import_one(%BookGrab{book_target: %BookTarget{} = target} = grab) do
    case BookImport.import_grab(grab) do
      {:ok, file} ->
        Logger.info("book target #{target.id} imported #{file.path}")
        Notifier.notify({:book_available, reload(target)})
        :ok

      {:error, reason} when reason in @permanent_import_errors ->
        hold(grab, target, reason)

      # The target moved under us (unmonitored, held, or already made available by another
      # import). Nothing to park: the grab is gone and the next tick re-derives.
      {:error, :stale_status} ->
        Books.Grabs.delete(grab)
        :ok

      {:error, reason} ->
        retry_or_hold(grab, target, reason)
    end
  end

  defp import_one(%BookGrab{} = grab) do
    Logger.warning("book grab #{grab.id} has no target; dropping")
    Books.Grabs.delete(grab)
    :ok
  end

  # A transient failure (a busy filesystem, a full disk, a locked stage) gets the shared attempt
  # budget; past it the target parks `:held` so it stops consuming ticks and becomes visible to an
  # operator.
  defp retry_or_hold(grab, target, reason) do
    attempts = (grab.import_attempts || 0) + 1

    if attempts >= @max_attempts do
      hold(grab, target, reason)
    else
      Logger.info("book grab #{grab.id} import failed (attempt #{attempts}): #{inspect(reason)}")
      Books.Grabs.bump_attempts(grab, attempts)
      :ok
    end
  end

  # The failed payload is left on disk untouched — the contract requires preserving the artifact
  # with an exact reason rather than discarding evidence an operator needs to decide.
  defp hold(grab, target, reason) do
    Logger.warning("book target #{target.id} held: #{inspect(reason)}")

    case Books.transition_target(target, %{status: :held, hold_reason: to_string(reason)},
           expect: target.status
         ) do
      {:ok, _held} -> Books.Grabs.delete(grab)
      # Lost a race against an operator's own write; leave the grab for the next tick to re-derive.
      {:error, _reason} -> :ok
    end

    :ok
  end

  defp reload(%BookTarget{id: id}), do: Books.get_target(id) || %BookTarget{id: id}
end
