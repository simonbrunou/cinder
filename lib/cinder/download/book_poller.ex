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
  alias Cinder.Download.{ContentPolicy, StallReaper}
  alias Cinder.Library
  alias Cinder.Library.BookImport
  alias Cinder.Notifier

  @default_interval 5_000
  @search_retry_after 60

  use Cinder.Download.PollerSkeleton, log_prefix: "book poller"

  # An import failure that retrying cannot fix, because it is a fact about the PAYLOAD: the
  # bytes are not an importable book, or the destination is already someone else's. Park the
  # target `:held` immediately with the exact reason rather than burning the attempt budget
  # re-reading the same bytes. This is the contract's "preserve the failed artifact in a safe
  # parked state with an exact reason; never import a guessed match" — the download itself is
  # left on disk untouched.
  #
  # `:book_file_exists` belongs here rather than in the retry budget: another target already
  # claims that destination path, and no number of retries changes which work owns it. Retrying
  # would burn ten ticks and then hold with the same reason, hiding a genuine catalog conflict
  # (usually two works that fold to one author/title folder) behind a delay.
  #
  # Deliberately NOT here: `:library_not_configured` and `:download_roots_not_configured`. Those
  # are facts about CONFIGURATION, not about the payload, and an operator fixing the setting
  # should see the import resume. Holding on them deletes the grab, so the download would have to
  # be re-grabbed to recover from a typo — they take the retry budget instead, which re-derives
  # every tick and succeeds as soon as the setting is right.
  @permanent_import_errors [
    :no_book_file,
    :ambiguous_book_files,
    :unsupported_archive,
    :unsafe_source,
    :book_file_exists
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
        track_or_reap(grab, status)

      # The job is gone from the client — a household member deleted it, or the client's history
      # rolled over. NOT transient: no future tick can find it, and with no search pass in this
      # slice the target would sit `:monitored` holding a grab forever, refusing any new grab.
      {:error, :not_found} ->
        fail_download(grab, :download_missing)

      # A genuine transient client/network error must not drop a live download: leave the grab
      # alone and re-derive next tick.
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

  # An in-flight download gets the same two safety gates the movie and TV pollers apply:
  #
  # - `ContentPolicy.vet/2` inspects the file names the client will deliver and refuses a payload
  #   carrying blocked content (an executable alongside the book). Doing this DURING the download
  #   is the point — `BookSources` would silently filter that executable at import time and
  #   publish the book anyway, so the blocked-content verdict the B4b plan requires would never
  #   be reached. It is best-effort by contract: a client that cannot answer yet returns `{:ok,
  #   []}` and any error is "no opinion".
  # - `StallReaper.reap?/4` ends a job that reports `:downloading` forever with no speed and no
  #   progress, which is exactly what `BookGrab.download_progress_at` is maintained for.
  defp track_or_reap(grab, status) do
    cond do
      blocked_content(grab) == :blocked ->
        fail_download(grab, :blocked_content)

      stalled?(grab, status) ->
        fail_download(grab, :stalled)

      true ->
        track(grab, status)
    end
  end

  defp blocked_content(%BookGrab{download_id: id, download_protocol: protocol}) do
    case Download.client_for(protocol) do
      {:ok, client} -> if ContentPolicy.vet(client, id) == :ok, do: :ok, else: :blocked
      :error -> :ok
    end
  end

  defp stalled?(grab, status) do
    StallReaper.reap?(grab.updated_at, grab.download_progress_at, status, DateTime.utc_now())
  end

  defp track(grab, status) do
    Books.Grabs.track(grab, %{
      download_progress: Map.get(status, :progress),
      download_speed: Map.get(status, :speed),
      download_eta: Map.get(status, :eta)
    })

    :ok
  end

  # The client says this download is dead. Hold the target FIRST, then drop the grab, then ask
  # the client to remove the job.
  #
  # The order is the crash story. Holding first means a crash at any later point leaves a `:held`
  # target an operator can see and act on — the worst case is a stale grab row or an un-removed
  # remote job, both recoverable. The reverse order (remove, delete, hold) had two windows that
  # lost the failure entirely: a crash after the grab delete but before the hold left a
  # `:monitored` target with no grab and no intent, and since this slice has no search pass,
  # nothing would ever look at it again.
  #
  # `:held`, not back to `:monitored`: this slice has no automatic selection (there is no
  # `best_book_release/2`), so every grab exists because an operator chose a release. Returning
  # the target to `:monitored` would make a failed download indistinguishable from one nobody has
  # picked a release for yet. The contract's `held` is "operator-visible … conflict; never
  # auto-grab", and it carries the reason.
  defp fail_download(%BookGrab{} = grab, reason) do
    Logger.warning("book grab #{grab.id} download failed: #{inspect(reason)}")
    hold_orphaned_target(grab.book_target, reason)
    Books.Grabs.delete(grab)
    remove_from_client(grab)
    :ok
  end

  # A grab whose target vanished has nothing to hold; the grab row is already gone.
  #
  # Distinct from `hold/3` below: there the grab still exists and is deleted only if the hold
  # wins, so a lost race leaves it for the next tick to re-derive. Here the grab is already gone
  # (the remote download is dead and was removed), so there is nothing left to re-derive and a
  # lost race is simply someone else's more recent decision.
  defp hold_orphaned_target(%BookTarget{} = target, reason) do
    case Books.transition_target(target, %{status: :held, hold_reason: hold_reason(reason)},
           expect: :monitored
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
  #
  # `expect: :monitored`, not `expect: target.status`: the preloaded status is whatever the tick
  # read, so expecting it made the guard tautological and let a hold overwrite a decision an
  # operator had ALREADY applied — unmonitoring a target before the tick ran would still end in
  # `:held`. Only a still-monitored target is ours to park; anything else is the operator's more
  # recent word and the grab is dropped without touching the target.
  defp hold(grab, target, reason) do
    Logger.warning("book target #{target.id} held: #{inspect(reason)}")

    case Books.transition_target(target, %{status: :held, hold_reason: hold_reason(reason)},
           expect: :monitored
         ) do
      {:ok, _held} ->
        Books.Grabs.delete(grab)

      # The target is no longer `:monitored` — an operator unmonitored or held it, or another
      # unit made it available. Its state stands; drop the grab so this does not re-run forever.
      {:error, _reason} ->
        Books.Grabs.delete(grab)
    end

    :ok
  end

  # `inspect/1`, never `to_string/1`: a reason may be a tuple (`{:unexpected_destination_type,
  # :directory}`), and `String.Chars` is undefined for tuples — so `to_string/1` raised inside the
  # hold, `isolate/2` swallowed it, and the grab neither held nor cleared. It then re-raised on
  # every subsequent tick, forever.
  defp hold_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp hold_reason(reason), do: inspect(reason)

  defp reload(%BookTarget{id: id}), do: Books.get_target(id) || %BookTarget{id: id}
end
