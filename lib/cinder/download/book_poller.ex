defmodule Cinder.Download.BookPoller do
  @moduledoc """
  Polls in-flight book downloads on each tick:

  1. **advance_downloading** — checks each `Cinder.Books.BookGrab` with no `content_path`;
     records the client's progress and, on completion, stores the delivered path. A dead
     download drops the grab and returns the target to plain `:monitored`, so an operator can
     pick another release.
  2. **import_downloaded** — publishes each completed grab through `Cinder.Library.BookImport`
     (or `Cinder.Library.AudiobookImport`) and arms its target `:available`.
  3. **request_audiobookshelf_scans** — when any `:available` audiobook target has not been told
     about yet (`audiobookshelf_scanned_at: nil`), requests exactly ONE whole-library rescan
     through `Cinder.Library.AudiobookServer` — covering every pending target at once, since the
     API offers no per-book scan — and stamps every one of them on success. A failed scan leaves
     all of them here to be retried the very next tick, deliberately never a one-shot claim — see
     `request_audiobookshelf_scans/0`.

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
  alias Cinder.Disk
  alias Cinder.Download
  alias Cinder.Download.{ContentPolicy, StallReaper}
  alias Cinder.Library
  alias Cinder.Library.{AudiobookImport, AudiobookServer, BookImport}
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
  #
  # `:mixed_book_filenames`, `:mixed_book_tags`, `:track_order_unknown`,
  # `:track_order_contradictory`, `:container_mismatch`, `:too_many_tracks` (B7b) are every one
  # of them a fact about the audiobook PAYLOAD too — an ambiguous, contradictory, or oversized
  # multi-track set never resolves itself by retrying the same bytes. `:audio_probe_unavailable`
  # is deliberately NOT a reason at all: a missing/erroring `Cinder.Library.AudioProbe` degrades
  # the ORDERING signal (falls back to filename evidence), it never surfaces as its own import
  # error.
  @permanent_import_errors [
    :no_book_file,
    :ambiguous_book_files,
    :unsupported_archive,
    :unsafe_source,
    :book_file_exists,
    :archive_entry_limit,
    :archive_size_limit,
    :archive_entry_unsafe,
    :archive_corrupt,
    :archive_timeout,
    :mixed_book_filenames,
    :mixed_book_tags,
    :track_order_unknown,
    :track_order_contradictory,
    :container_mismatch,
    :too_many_tracks
  ]

  defp do_poll(_state) do
    isolate("stage reconciliation", fn -> Library.reconcile_stages() end)

    isolate("pending intent reconciliation", fn ->
      Download.reconcile_pending_intents([:book_target])
    end)

    advance_downloading()
    import_downloaded()
    request_audiobookshelf_scans()
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
        retry_or_fail(grab, :missing_content_path)

      {:ok, %{state: :error} = status} ->
        retry_or_fail(grab, Map.get(status, :reason) || :download_failed)

      {:ok, status} ->
        track_or_reap(grab, status)

      # The job is gone from the client — a household member deleted it, or the client's history
      # rolled over. Terminal, not transient: no future tick can find it, and with no search pass
      # in this slice the target would sit `:monitored` holding a grab forever, refusing any new
      # grab. Bounded rather than immediate, though — see `retry_or_fail/2`.
      {:error, :not_found} ->
        retry_or_fail(grab, :download_missing)

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

  # An in-flight download gets the same two safety gates the movie and TV pollers apply, wired the
  # same way they wire them:
  #
  # - `ContentPolicy.vet/2` inspects the file names the client will deliver and refuses a payload
  #   carrying blocked content (an executable alongside the book). Doing this DURING the download
  #   is the point — `BookSources` would silently filter that executable at import time and
  #   publish the book anyway, so the blocked-content verdict the B4b plan requires would never
  #   be reached. It is best-effort by contract: a client that cannot answer yet returns `{:ok,
  #   []}` and any error is "no opinion". The verdict's `detail` names the offending file and is
  #   carried into the hold reason — `ContentPolicy.detail/1` sanitizes it for exactly that.
  # - `StallReaper.reap?/4` ends a job that reports `:downloading` forever with no speed and no
  #   progress, which is exactly what `BookGrab.download_progress_at` is maintained for.
  defp track_or_reap(grab, status) do
    case blocked_content(grab) do
      {:blocked, detail} -> fail_download(grab, {:blocked_content, detail})
      :ok -> track_and_reap(grab, status)
    end
  end

  defp blocked_content(%BookGrab{download_id: id, download_protocol: protocol}) do
    case Download.client_for(protocol) do
      {:ok, client} -> ContentPolicy.vet(client, id)
      :error -> :ok
    end
  end

  # Metrics first, reap second, on the clock the write returns — `track_and_reap/2` in
  # `Download.Poller` and `Download.TvPoller`, matched deliberately.
  #
  # Reaping on the struct as loaded at tick start kills healthy downloads: after the app is down
  # longer than `max_downloading_timeout` (24h by default) the row's `download_progress_at` is
  # stale by definition, and checking it BEFORE recording this tick's genuine progress reaps a
  # job that is downloading fine. `Books.Grabs.track/2` advances the clock only on real forward
  # motion, so the post-write value is the honest one.
  defp track_and_reap(grab, status) do
    case Books.Grabs.track(grab, track_attrs(status)) do
      {:ok, tracked} ->
        maybe_reap(grab, tracked.download_progress_at, status)

      # Never silent: a rejected metrics write freezes the progress clock, and a frozen clock is
      # what the absolute cap reads.
      {:error, reason} ->
        Logger.warning("book grab #{grab.id} progress not recorded: #{inspect(reason)}")
        :ok
    end
  end

  defp track_attrs(status) do
    %{
      download_progress: Map.get(status, :progress),
      download_speed: Map.get(status, :speed),
      download_eta: Map.get(status, :eta)
    }
  end

  # `StallReaper.enabled?()` is the operator switch, and it is checked here for the same reason
  # both siblings check it: `reap?/4` is a pure predicate that knows nothing about the config, so
  # calling it unguarded reaped book downloads on an install that had turned reaping off.
  #
  # The seed window keeps the tick-start `updated_at` and the absolute cap uses the post-write
  # progress clock — `TvPoller.maybe_reap/3`'s split, unchanged.
  defp maybe_reap(grab, download_progress_at, status) do
    if StallReaper.enabled?() and
         StallReaper.reap?(grab.updated_at, download_progress_at, status, DateTime.utc_now()),
       do: fail_download(grab, :stalled),
       else: :ok
  end

  # The download-phase failure budget, on the same `import_attempts` column the import phase uses.
  # One counter across both phases is the movie poller's own arrangement (`poller.ex:216-221`), and
  # the two cannot interleave here: a grab is in the download phase only while `content_path` is
  # nil, and `Books.Grabs.mark_downloaded/2` resets the counter on the edge between them — the
  # download→import reset `Catalog.Grabs` documents at the same boundary.
  #
  # Bounded rather than immediate because every verdict routed here is derived from a SUCCESSFUL
  # client response, not from a transport failure: all four adapters return `{:error, :not_found}`
  # for an empty 200 queue/history lookup, which is exactly what a client reports for the moment a
  # job moves between queue and history. Acting on the first sighting made a routine blip
  # destructive — `fail_download/2` removes the remote job with `delete_files: true` — and held a
  # target whose bytes were fine. All three video sites bound the same verdicts
  # (`Poller.fail_download/2`, `Poller.retry_or_revert/2`, `TvPoller.retry_or_park/2`).
  #
  # `:blocked_content` and `:stalled` deliberately do NOT come through here: the first is a
  # deterministic fact about the file list the client already gave us, and the second has a
  # multi-hour window built into it. Both siblings act on those immediately too.
  defp retry_or_fail(%BookGrab{} = grab, reason) do
    attempts = (grab.import_attempts || 0) + 1

    if attempts >= @max_attempts do
      fail_download(grab, reason)
    else
      Logger.info(
        "book grab #{grab.id} download failing (attempt #{attempts}/#{@max_attempts}): " <>
          "#{inspect(reason)}"
      )

      Books.Grabs.bump_attempts(grab, attempts)
      :ok
    end
  end

  # The client says this download is dead. Hold the target FIRST, then fence-and-drop the grab,
  # then ask the client to remove the job.
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
  #
  # #398: the client removal used to be a bare best-effort call with the grab (its only durable
  # record of `download_id`/`download_protocol`) already deleted — a transient removal failure
  # leaked the remote job forever. `Download.fence_book_cleanup/1` now persists a
  # `download_intents` `:cleanup_pending` row and deletes the grab in the SAME transaction (no
  # crash window between them), and `cleanup_intents/1` makes the immediate best-effort attempt;
  # a failure there leaves the row for `reconcile_pending_intents/1`'s bounded retry to drain on
  # a later tick instead of losing it.
  defp fail_download(%BookGrab{} = grab, reason) do
    Logger.warning("book grab #{grab.id} download failed: #{inspect(reason)}")

    hold_orphaned_target(
      grab.book_target,
      reason,
      grab.release_title,
      transient_download?(reason),
      grab.replace
    )

    {:ok, intent_ids} = Download.fence_book_cleanup(grab)
    Download.cleanup_intents(intent_ids)
    :ok
  end

  # A deterministic fact about the payload (a blocked file) is not transient; every other
  # download-phase failure routed here — a missing content path, a client-reported download
  # failure, or a stall — has already survived `@max_attempts` retries and is worth one more
  # unattended look later (`Cinder.Books.Rehunter`).
  defp transient_download?({:blocked_content, _detail}), do: false
  defp transient_download?(_reason), do: true

  defp hold_orphaned_target(%BookTarget{} = target, reason, release_title, transient, replace?) do
    case Books.hold_target(target, reason, release_title, transient, replace: replace?) do
      {:ok, _held} ->
        :ok

      # The target moved under us (an operator unmonitored it, or another unit already held it).
      # Its current state is more recent than this decision, so leave it alone.
      {:error, _reason} ->
        :ok
    end
  end

  # A grab whose target vanished has nothing to hold — but the grab row (and its
  # download_id/download_protocol) is still very much alive, so `fail_download/2` must still
  # fence and drain it; this clause only says the hold itself has nothing to act on.
  #
  # Distinct from `hold/3` below: there the grab still exists and is deleted only if the hold
  # wins, so a lost race leaves it for the next tick to re-derive. Here `fail_download/2` is
  # already committed to dropping the grab regardless of this outcome, so a lost race (an
  # operator deleting the target concurrently) is simply someone else's more recent decision.
  defp hold_orphaned_target(_missing_target, _reason, _release_title, _transient, _replace?),
    do: :ok

  # --- import phase ---

  # Pre-import disk guard on the books library root, matching `Poller.import_one/1` and
  # `TvPoller.import_grab/1`. Hold without bumping the attempt budget: the download is finished
  # and waiting, and a full disk is fixable, so burning ten ticks on it and then parking the
  # target `:held` turns "free some space" into "notice the hold and re-grab". Throttled so a
  # persistently full disk does not flood the log every tick.
  defp import_one(%BookGrab{book_target: %BookTarget{} = target} = grab) do
    if Disk.import_space_available?(target.media_kind, target),
      do: do_import_one(grab, target),
      else: warn_disk_full(target)
  end

  # A grab whose target is gone. `book_grabs.book_target_id` cascades on delete, so this is
  # belt-and-braces rather than a reachable state; dropping the row is the only sane response.
  defp import_one(%BookGrab{} = grab) do
    Logger.warning("book grab #{grab.id} has no target; dropping")
    Books.Grabs.delete(grab)
    :ok
  end

  defp warn_disk_full(%BookTarget{} = target) do
    warn_throttled(
      {:disk_import, target.id},
      "book target #{target.id} import held: books library root is nearly full; " <>
        "will retry when space frees"
    )
  end

  # --- audiobookshelf scan phase ---

  # Retryable, not one-shot: unlike the video pollers' `StageEngine.claim_post_commit_effects/1`
  # (which marks a post-commit effect claimed regardless of its own success), this re-derives its
  # work from `audiobookshelf_scanned_at: nil` every tick, so a scan failure simply leaves the
  # target here to be retried next tick — the roadmap's "refresh failure is recoverable without
  # re-downloading" requirement. The already-`:available`, already-on-disk file is never touched
  # by any of this: the download/import path and this scan-request path share no failure state.
  #
  # `AudiobookServer.scan/0` takes no per-book argument — it triggers a WHOLE-LIBRARY rescan, the
  # only shape Audiobookshelf's API offers. Calling it once per pending target would issue N
  # sequential, functionally identical HTTP requests in one tick for a backlog of N (exactly the
  # scenario this mechanism exists for: Audiobookshelf down or slow), each bounded by
  # `HTTPPolicy`'s own request timeout — stalling this poller's unrelated download/import phases
  # behind it, since ticks are strictly sequential in one process. One call per tick, covering
  # every pending target at once, is both correct (a single library scan picks up every new file
  # regardless of which target it came from) and bounded (one HTTP call per tick, always).
  defp request_audiobookshelf_scans do
    case Books.list_pending_audiobook_scans() do
      [] ->
        :ok

      pending ->
        isolate("audiobookshelf scan for #{length(pending)} pending target(s)", fn ->
          scan_pending(pending)
        end)
    end
  end

  @scan_failed_key {__MODULE__, :audiobookshelf_scan_failed}

  defp scan_pending(pending) do
    case AudiobookServer.impl().scan() do
      :ok ->
        Enum.each(pending, &Books.mark_audiobookshelf_scanned(&1.id))
        maybe_log_scan_recovered()

      {:error, reason} ->
        maybe_log_scan_failure(reason)
        warn_audiobookshelf_scan_failed(reason)
    end
  end

  # Both written only on their respective transition (`:persistent_term`, not the GenServer's own
  # state or Process dictionary: this poller's whole design re-derives every tick's work from the
  # DB so a crash/restart resumes cleanly (see the moduledoc), and the failed/recovered signal has
  # to survive that same restart to stay meaningful — a scan that failed, then a crash, then a
  # scan that succeeds on the freshly restarted process IS a recovery an operator should see, not
  # a transition this mechanism silently swallows because the flag lived in the dead process.
  # `:persistent_term` is VM-global and already this module's sibling `PollerSkeleton`'s own
  # choice for exactly this kind of cross-restart tick state, its `:last_run`/`:started_at`
  # stamps). See `Cinder.Books.log_scan_failure/1`'s doc for why this call site logs only the
  # first failure of a run rather than one row per tick: at this poller's 5-second interval, a
  # continuously unreachable Audiobookshelf for the whole two-week dogfood window would otherwise
  # write 241,920 rows. One row marking when an outage started, paired with one marking when it
  # ended, is what an operator can actually read.
  defp maybe_log_scan_failure(reason) do
    unless :persistent_term.get(@scan_failed_key, false) do
      :persistent_term.put(@scan_failed_key, true)
      Books.log_scan_failure(inspect(reason))
    end
  end

  defp maybe_log_scan_recovered do
    if :persistent_term.get(@scan_failed_key, false) do
      :persistent_term.erase(@scan_failed_key)
      Books.log_scan_recovered()
    end
  end

  # Not bounded by `@max_attempts`, deliberately, matching `warn_disk_full/1` above: a failed
  # scan request is a fact about Audiobookshelf's configuration/connectivity, not about the
  # payload, so there is nothing to hold on and no reason a fixed operator typo (or a down
  # consumer) should need a re-download to recover from once corrected. Throttled so a
  # persistently unreachable Audiobookshelf does not flood the log every tick — the bound on
  # retry *frequency* (never on retry *count*). One throttle key for the whole batch, matching the
  # one-call-per-tick shape above — there is no longer a per-target call to key it by.
  defp warn_audiobookshelf_scan_failed(reason) do
    warn_throttled(
      :audiobookshelf_scan,
      "audiobookshelf scan failed: #{inspect(reason)}; will retry next tick"
    )
  end

  defp do_import_one(%BookGrab{} = grab, %BookTarget{media_kind: :ebook} = target) do
    handle_import_result(BookImport.import_grab(grab, replace: grab.replace), grab, target)
  end

  defp do_import_one(%BookGrab{} = grab, %BookTarget{media_kind: :audiobook} = target) do
    handle_import_result(AudiobookImport.import_grab(grab, replace: grab.replace), grab, target)
  end

  # `file` is a single `BookFile.t()` for the e-book branch and a LIST of `BookFile.t()` for the
  # audiobook branch — every clause here already treats it as an opaque value handed straight to
  # `finish_import/2`/`unlink_superseded/1`'s caller, so no clause needs to know which shape it
  # got; only `finish_import/2`'s own log line (below) formats the two shapes differently.
  defp handle_import_result({:ok, file}, _grab, target), do: finish_import(target, file)

  defp handle_import_result({:ok, file, superseded_paths}, _grab, target) do
    Enum.each(superseded_paths, &unlink_superseded/1)
    finish_import(target, file)
  end

  defp handle_import_result({:error, reason}, grab, target)
       when reason in @permanent_import_errors,
       do: hold(grab, target, reason)

  # The target moved under us (unmonitored, held, or already made available by another import).
  # Nothing to park: the grab is gone and the next tick re-derives.
  defp handle_import_result({:error, :stale_status}, grab, _target) do
    Books.Grabs.delete(grab)
    :ok
  end

  defp handle_import_result({:error, reason}, grab, target),
    do: retry_or_hold(grab, target, reason)

  defp finish_import(target, file) do
    Logger.info("book target #{target.id} imported #{import_log_detail(file)}")
    Notifier.notify({:book_available, reload(target)})
    :ok
  end

  # A single `BookFile.t()` (e-book) logs its path; a list of them (audiobook — one per track)
  # logs a count rather than every path, matching the existing terse one-line-per-import style.
  defp import_log_detail(files) when is_list(files), do: "#{length(files)} track(s)"
  defp import_log_detail(%{path: path}), do: path

  # Post-commit, best-effort removal of a file "Find a better match" just replaced — mirrors
  # `Download.remove_after_import/3`'s own "best-effort, after commit, log and continue" contract.
  # A stale/already-gone path is not an error: `Library.delete_file/1` is idempotent on `:enoent`.
  defp unlink_superseded(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "book replace: couldn't remove superseded file #{path}: #{inspect(reason)}"
        )
    end
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
  #
  # `replace: grab.replace` below makes this effectively `expect: [:monitored, :available]` for a
  # "Find a better match" grab: its target stays `:available` for its whole download/import
  # cycle (`Books.hold_target/5`'s own doc), so the guard has to accept that status too, not just
  # `:monitored` — a plain grab's target is never `:available` mid-flight, so nothing changes for
  # it.
  defp hold(grab, target, reason) do
    Logger.warning("book target #{target.id} held: #{inspect(reason)}")

    transient = reason not in @permanent_import_errors

    case Books.hold_target(target, reason, grab.release_title, transient, replace: grab.replace) do
      {:ok, _held} ->
        Books.Grabs.delete(grab)

      # The target is no longer eligible for this hold (`:monitored`/`:available` per
      # `grab.replace` — an operator unmonitored or held it, or another unit made it available).
      # Its state stands; drop the grab so this does not re-run forever.
      {:error, _reason} ->
        Books.Grabs.delete(grab)
    end

    :ok
  end

  defp reload(%BookTarget{id: id}), do: Books.get_target(id) || %BookTarget{id: id}
end
