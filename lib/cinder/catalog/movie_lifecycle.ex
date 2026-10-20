defmodule Cinder.Catalog.MovieLifecycle do
  @moduledoc """
  The movie lifecycle: every write to a movie's `:status` goes through one of the verbs here.

  Each verb owns its legal edge, its race guard, the fields it clears, its blocklist decision and
  ordering, its cleanup fence, notification, telemetry and broadcast. Two rules hold for all of
  them:

    * **The struct the caller passes is the expectation.** A write is one compare-and-swap,
      `update_all ... where id and status == ^movie.status [and the verb's guard fields]`, with
      `select:` handing back the fresh row. A miss is `{:error, :stale_status}` (or the verb's own
      refusal atom) and writes nothing. Pollers pass the row they read at tick start, LiveViews
      the row they rendered. Two verbs read their own row instead: `record_submission_failure/3`
      under its intent claim, and `adopt/3` under its `:immediate` transaction.
    * **Publication happens once, after commit.** A committed write emits one
      `[:cinder, :transition]` (`%{kind: :movie, to: status}`) and broadcasts one
      `{:movie_updated, movie}` on the `"movies"` topic. A refused or stale call publishes nothing.

  Verbs, by phase:

    * search: `start_search/2`, `no_match/2`, `attach/2`, `record_submission_failure/3`
    * download: `track/2`, `mark_downloaded/2`
    * import: `import_staged/2`, `reject/2`
    * any failure a poller observes: `record_failure/2`
    * operator: `retry/1`, `cancel/2`, `abort_upgrade/2`, each refusing a movie that does not
      offer its action (`Cinder.Catalog.Attention`)
    * adoption: `adopt/3`

  Creating a movie is not a lifecycle edge: `Cinder.Requests` creates one at `:requested` through
  `Cinder.Catalog`, and `adopt/3` inserts an unknown one at `:available`. Both announce
  `{:movie_created, movie}` after commit and emit no `[:cinder, :transition]`.
  """

  import Ecto.Query
  require Logger

  alias Cinder.Audit
  alias Cinder.Catalog
  alias Cinder.Catalog.{Attention, BlockedRelease, Grabs, Movie, Profiles}
  alias Cinder.Download
  alias Cinder.Library
  alias Cinder.Library.{ImportStage, StagedImport}
  alias Cinder.Notifier
  alias Cinder.Repo

  # The legal from→to graph, one entry per status. A self-edge (status unchanged) is always legal:
  # the verbs that count a failure or record download progress re-affirm the current status.
  # `:import_failed → :available` is an upgrade's verification hold being aborted back to its live
  # file; adoption never takes it (`adopt/3` refuses a parked movie).
  @transitions %{
    requested: [:searching, :downloading, :search_failed, :cancelled, :available],
    searching: [:downloading, :no_match, :search_failed, :cancelled],
    downloading: [:downloaded, :import_failed, :requested, :cancelled],
    downloaded: [:available, :import_failed, :requested, :cancelled],
    available: [:upgrading],
    upgrading: [:available, :import_failed],
    no_match: [:requested, :downloading],
    search_failed: [:requested, :downloading],
    import_failed: [:requested, :downloading, :downloaded, :upgrading, :cancelled, :available],
    cancelled: []
  }

  # The complete split of `Movie`'s status enum. Views read it through `Cinder.Catalog.Attention`,
  # which also decides which operator verbs a movie offers:
  #   active: in-flight pipeline work         @pipeline_statuses
  #   parked: failed, awaiting a retry        @parked_statuses
  #   done:   terminal, nothing left to do    :available, :cancelled
  @pipeline_statuses [:requested, :searching, :downloading, :downloaded, :upgrading]
  @parked_statuses [:no_match, :search_failed, :import_failed]

  # The download a movie leaves behind when it is re-queued, reverted, cancelled or aborted:
  # leaving it on the row is misleading, and a latent misroute if anything reads it later.
  @drop_download %{
    download_id: nil,
    download_protocol: nil,
    release_title: nil,
    release_policy_snapshot: nil
  }

  # A movie sent back to `:requested` also loses the paths of that download.
  @requeue_clears Map.merge(@drop_download, %{file_path: nil, content_path: nil})

  # The failure budget of each phase: the strike that reaches it ends the phase.
  @failure_budget 10

  @doc "The legal movie status graph: `%{from => [to]}`. A self-edge is always legal."
  def transitions, do: @transitions

  @doc "True when the lifecycle allows a movie to move from `from` to `to`."
  def legal?(from, to) when from == to, do: true
  def legal?(from, to), do: to in Map.get(@transitions, from, [])

  @doc """
  The statuses with active in-flight pipeline work, in pipeline order. Excludes both the parked
  failures (`#{inspect(@parked_statuses)}`) and the terminal-done pair (`:available`,
  `:cancelled`).
  """
  def pipeline_statuses, do: @pipeline_statuses

  @doc """
  The statuses parked on a failure that needs a retry. Disjoint from `pipeline_statuses/0`;
  together with the terminal-done pair they cover the status enum exactly.
  """
  def parked_statuses, do: @parked_statuses

  # --- search ------------------------------------------------------------------------------------

  @doc """
  Starts a search: `:requested` (or a re-searched `:searching`) → `:searching`, recording
  `imdb_id`. `{:error, :not_searchable}` for any other status.
  """
  def start_search(%Movie{status: status} = movie, imdb_id)
      when status in [:requested, :searching],
      do: movie |> write(%{status: :searching, imdb_id: imdb_id}) |> publish()

  def start_search(%Movie{}, _imdb_id), do: {:error, :not_searchable}

  @doc """
  Parks a `:searching` movie that found nothing to grab at `:no_match`. `reason` is `:no_match`
  (silent) or `:no_language_match`, which also notifies the household: the title exists but not
  in the wanted language, which only a person can change. `{:error, :not_searching}` otherwise.
  """
  def no_match(%Movie{status: :searching} = movie, reason)
      when reason in [:no_match, :no_language_match] do
    with {:ok, parked} <-
           movie |> write(%{status: :no_match, release_policy_snapshot: nil}) |> publish() do
      if reason == :no_language_match, do: Notifier.notify({:movie_failed, parked, reason})
      {:ok, parked}
    end
  end

  def no_match(%Movie{}, _reason), do: {:error, :not_searching}

  @download_fields [:download_id, :download_protocol, :release_title, :release_policy_snapshot]

  @doc """
  Attaches the download a client accepted (`download_id`, `download_protocol`, `release_title`,
  `release_policy_snapshot`) with a fresh import budget:

    * `:requested` or `:searching` → `:downloading`;
    * a parked movie → `:downloading`, with a fresh search budget too (an operator's manual grab);
    * `:available` → `:upgrading`, keeping the live library file until the replacement imports.

  `{:error, :not_attachable}` for any other status.
  """
  def attach(%Movie{status: status} = movie, download) when status in [:requested, :searching],
    do: attach(movie, :downloading, %{}, download)

  def attach(%Movie{status: status} = movie, download) when status in @parked_statuses,
    do:
      attach(movie, :downloading, %{search_attempts: 0, verification_hold_origin: nil}, download)

  # The row's `content_path` stays nil through `:upgrading`: the replacement's source only ever
  # travels on the poller's local struct, so nothing can mistake a stale path for it.
  def attach(%Movie{status: :available} = movie, download),
    do: attach(movie, :upgrading, %{content_path: nil}, download)

  def attach(%Movie{}, _download), do: {:error, :not_attachable}

  defp attach(movie, status, extra, download) do
    attrs =
      download
      |> Map.take(@download_fields)
      |> Map.merge(extra)
      |> Map.merge(%{status: status, import_attempts: 0})

    movie |> write(attrs) |> publish()
  end

  @doc """
  Counts a download-client submission that failed for a `:requested` or `:searching` movie
  against its search budget, in one transaction with `claim`: the caller's write that marks this
  failure as counted (`:ok`), or `:stale` when another process already counted it. The strike
  that exhausts the budget parks the movie at `:search_failed` and fences its reserved intent for
  cleanup. Nothing is written when the claim is stale or the movie left the search pass.
  """
  def record_submission_failure(movie_id, reason, claim) when is_function(claim, 0) do
    fn ->
      with :ok <- claim.(),
           %Movie{status: status} = movie when status in [:requested, :searching] <-
             Repo.get(Movie, movie_id) do
        submission_strike(movie)
      else
        _stale_or_moved_on -> {:ok, :skipped}
      end
    end
    |> transact()
    |> publish_submission_failure(reason)
  end

  defp submission_strike(movie) do
    attempts = (movie.search_attempts || 0) + 1

    if attempts >= @failure_budget do
      with {:ok, parked} <- write(movie, %{status: :search_failed}) do
        {:ok, {:parked, parked, Download.fence_movie_cleanup(parked, include_remote: false)}}
      end
    else
      with {:ok, counted} <- write(movie, %{status: movie.status, search_attempts: attempts}),
           do: {:ok, {:counted, counted}}
    end
  end

  defp publish_submission_failure({:ok, :skipped}, _reason), do: :ok

  defp publish_submission_failure({:ok, {:counted, movie}}, _reason) do
    publish({:ok, movie})
    :ok
  end

  defp publish_submission_failure({:ok, {:parked, parked, intent_ids}}, reason) do
    publish({:ok, parked})
    announce_park(parked, reason, reason)
    Download.cleanup_intents(intent_ids)
    :ok
  end

  defp publish_submission_failure({:error, _reason} = error, _submission_reason), do: error

  # --- download and import -----------------------------------------------------------------------

  @download_metric_fields [:download_progress, :download_speed, :download_eta]

  @doc """
  Records an in-flight download's progress, speed and ETA (the download watch's writer) for a
  `:downloading` or `:upgrading` movie. Progress only moves forward; a call that changes nothing
  writes and publishes nothing and returns the movie as given. A self-edge: the status stays.
  `{:error, :not_downloading}` for any other status.
  """
  def track(%Movie{status: status} = movie, metrics) when status in [:downloading, :upgrading] do
    changes =
      metrics
      |> Map.take(@download_metric_fields)
      |> keep_progress_high_water(movie.download_progress)
      |> Map.reject(fn {field, value} -> Map.get(movie, field) == value end)

    if changes == %{},
      do: {:ok, movie},
      else: movie |> write(Map.put(changes, :status, movie.status)) |> publish()
  end

  def track(%Movie{}, _metrics), do: {:error, :not_downloading}

  defp keep_progress_high_water(%{download_progress: progress} = metrics, previous)
       when is_number(progress) and (is_nil(previous) or progress >= previous),
       do: metrics

  defp keep_progress_high_water(metrics, _previous), do: Map.delete(metrics, :download_progress)

  @doc """
  Hands a finished download to import: `:downloading` → `:downloaded` with the client's
  `content_path` and a fresh import budget. `{:error, :not_downloading}` otherwise.
  """
  def mark_downloaded(%Movie{status: :downloading} = movie, content_path)
      when is_binary(content_path) and content_path != "" do
    movie
    |> write(%{status: :downloaded, content_path: content_path, import_attempts: 0})
    |> publish()
  end

  def mark_downloaded(%Movie{}, _content_path), do: {:error, :not_downloading}

  @doc """
  Records a staged import (`Cinder.Library.stage_movie/2`) as the movie's library file:
  `:downloaded` or `:upgrading` → `:available`, with the imported quality. The write marks the
  staged files committed in the same transaction, and `Cinder.Library.StagedImport.commit/2`
  finishes them on disk (scan, subtitles, sidecars) before the post-import work:

    * a fresh import notifies `{:movie_available, movie}` and removes its download source;
    * an upgrade removes the superseded library files, removes the replacement's download source
      and notifies.

  The source removal is fenced on the just-committed row, so a client failure survives as a
  retryable cleanup intent. For an upgrade the caller passes the movie with `content_path` set to
  the replacement download (the row keeps `content_path` nil while upgrading), because the
  movie's own `file_path` is the live library file and must never be removed as a source.

  When the movie moved on since the caller read it, or the write fails, the staged files are
  rolled back so no row points at an orphaned file, and the error is returned.
  """
  def import_staged(%Movie{status: status} = movie, staged)
      when status in [:downloaded, :upgrading] do
    case StagedImport.commit(staged, &(movie |> write_available(&1, &2) |> publish())) do
      {:ok, available} ->
        after_import(movie, available)
        {:ok, available}

      {:error, :stale_status} = stale ->
        Logger.info(
          "movie #{movie.id} left the import pass mid-import; rolled back " <>
            StagedImport.record(staged).file_path
        )

        stale

      {:error, _reason} = error ->
        error
    end
  end

  def import_staged(%Movie{}, staged) do
    StagedImport.rollback(staged)
    {:error, :not_importing}
  end

  # The write half of `import_staged/2`: compare-and-swap to `:available` plus the staged files'
  # commit marker, in one transaction.
  defp write_available(movie, record, stage_ids) do
    attrs =
      %{
        status: :available,
        file_path: record.file_path,
        part_file_paths: record.part_file_paths
      }
      |> Map.merge(imported_attrs(record.quality))

    # A fresh import's `content_path` was the download copy; the library file replaces it.
    attrs = if movie.status == :downloaded, do: Map.put(attrs, :content_path, nil), else: attrs

    transact(fn ->
      with {:ok, available} <- write(movie, attrs, [:download_id]) do
        ImportStage.mark_committed!(stage_ids)
        {:ok, available}
      end
    end)
  end

  defp imported_attrs(quality) do
    %{
      imported_resolution: quality.resolution,
      imported_size: quality.size,
      imported_language: quality.language,
      imported_source: quality.source,
      imported_audio_languages: quality.audio_languages,
      imported_default_audio_language: quality.default_audio_language,
      imported_embedded_subtitles: quality.embedded_subtitles,
      imported_sidecar_subtitles: quality.sidecar_subtitles
    }
  end

  # The source is read off the caller's struct, never `available`: `available.content_path` is nil,
  # so `Movie.download_source/1` would fall back to its `file_path`, the just-imported library file.
  defp after_import(%Movie{status: :downloaded} = movie, available) do
    Notifier.notify({:movie_available, available})
    remove_source(movie, available)
  end

  defp after_import(%Movie{status: :upgrading} = movie, available) do
    movie
    |> Movie.file_paths()
    |> Kernel.--(Movie.file_paths(available))
    |> Enum.each(&remove_superseded/1)

    remove_source(movie, available)
    Notifier.notify({:movie_available, available})
  end

  defp remove_source(movie, available) do
    Download.remove_after_import(movie.download_protocol, movie.download_id, source(movie),
      fence: {:movie, available}
    )
  end

  defp remove_superseded(path) do
    case Library.delete_file(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("upgrade: couldn't remove old file #{inspect(path)}: #{inspect(reason)}")
    end
  end

  @doc """
  Rejects the release of a `:downloaded` or `:upgrading` movie that the import proved breaks the
  movie's release policy (`evidence`). In one transaction: the release is blocklisted, its client
  download fenced for removal, and the movie moves on without it, a fresh download back to
  `:requested` and an upgrade back to `:available` with its live file and quality. After commit
  the downloaded payload is removed under the usual move-on-import rule.

  Guarded on the caller's `release_title` and `release_policy_snapshot` too:
  `{:error, :stale_release}` when either changed or the movie moved on, with nothing blocklisted.
  """
  def reject(%Movie{status: status, release_title: title} = movie, evidence)
      when status in [:downloaded, :upgrading] and is_binary(title) do
    fn ->
      with {:ok, rejected} <-
             write(movie, reject_attrs(status), [
               :release_title,
               :release_policy_snapshot,
               :download_id
             ]),
           {:ok, _blocked} <- insert_policy_block(movie, evidence) do
        {:ok, {rejected, Download.fence_movie_cleanup(movie)}}
      end
    end
    |> transact()
    |> publish_with_cleanup(:stale_release)
    |> tap(fn
      {:ok, _rejected} ->
        Download.remove_after_import(movie.download_protocol, nil, source(movie))

      _miss ->
        :ok
    end)
  end

  # Nothing to blocklist means nothing stops the same release being staged again every tick, so
  # give the release up the way an unusable one is: a fresh download parks, an upgrade reverts.
  def reject(%Movie{status: status, release_title: nil} = movie, evidence)
      when status in [:downloaded, :upgrading] do
    Logger.warning(
      "movie #{movie.id} release breaks its policy (#{inspect(evidence)}) but has no title " <>
        "to blocklist; giving it up"
    )

    if status == :downloaded,
      do: park(movie, :import_failed, :release_policy_mismatch),
      else: revert_upgrade(movie, :release_policy_mismatch)
  end

  def reject(%Movie{}, _evidence), do: {:error, :stale_release}

  defp reject_attrs(:upgrading), do: Map.put(@drop_download, :status, :available)

  defp reject_attrs(:downloaded),
    do: Map.merge(@requeue_clears, %{status: :requested})

  defp insert_policy_block(movie, evidence) do
    %BlockedRelease{}
    |> BlockedRelease.changeset(%{
      movie_id: movie.id,
      release_title: movie.release_title,
      reason: inspect({:release_policy_mismatch, evidence})
    })
    |> Repo.insert()
  end

  # The download payload of `movie`: an upgrade's replacement is only ever on the caller's struct.
  defp source(%Movie{status: :upgrading, content_path: path}), do: path
  defp source(%Movie{} = movie), do: Movie.download_source(movie)

  # --- failures ----------------------------------------------------------------------------------

  # Retrying cannot help these, so they park (or revert an upgrade) on first sight.
  # :unsupported_download_url is an unknown URL scheme, :bad_torrent a malformed .torrent.
  @permanent_search_errors [:unsupported_download_url, :bad_torrent]

  # The release itself is unusable. :wrong_audio_language is the MediaInfo check rejecting a
  # confirmed wrong-language file: its audio will not change, so re-importing cannot help, and a
  # Retry re-searches (a soft Original/Any pick may re-grab it, but Retry is manual, so no loop).
  @permanent_import_errors [
    :no_file_path,
    :no_video_file,
    :wrong_audio_language,
    :ambiguous_multipart_movie,
    :unsupported_archive,
    :unsupported_disc
  ]

  # Download-side failures whose terminal handling blocklists the release. Each arrives only after
  # a retry bound, so a single network blip never blocks a good release.
  @download_failure_errors [:download_error, :torrent_not_found, :no_content_path]

  # A client-reported failure reads the same as a client-API blip for a tick or two; past this many
  # strikes the download has failed and re-queues.
  @client_failure_tolerance 3

  @doc """
  Records a failure a poller observed for a movie in flight, and decides what it means. `reason`
  is what the caller saw, unclassified: a download watch verdict (`{:failed, reason}`,
  `{:blocked_content, detail}`, `:stalled`, `:no_client`), a `Cinder.Library.stage_movie/2` error,
  or a search error.

  The outcome depends on the movie's phase and the reason:

    * **counted**: the movie keeps its status with one more strike against the phase's failure
      budget (`search_attempts` while searching, `import_attempts` after);
    * **parked** at `:search_failed` or `:import_failed` when the reason is permanent or the
      budget is spent, with `[:cinder, :park]`, a `{:movie_failed, ...}` notification, and a
      blocklisted release when the release is proven bad;
    * **re-queued** to `:requested` when the client reports the download failed or its content
      is blocked (the release blocklisted first, and the re-queue refused, parking instead, if the
      blocklist row cannot be confirmed: that row is the only bound on a re-queue loop), or when it
      stalled;
    * **reverted** to `:available` when an upgrade fails, keeping the live library file;
    * **held** for verification when the release-policy probe stayed unavailable.

  A search failure the download intent already counted (`record_submission_failure/3`) is not
  counted again. Returns `{:ok, movie}` with the movie's new state, `{:error, :stale_status}` when
  the movie moved on since the caller read it, or `{:error, :not_in_flight}` for a movie with
  nothing in flight.
  """
  def record_failure(movie, {:failed, reason}), do: record_failure(movie, reason)

  def record_failure(%Movie{status: status} = movie, reason)
      when status in [:requested, :searching] do
    cond do
      reason_code(reason) in @permanent_search_errors ->
        Logger.warning("movie #{movie.id} search failed permanently: #{inspect(reason)}")
        park(movie, :search_failed, reason)

      # A client submission failure that the download intent's own retry already counted, in the
      # same transaction as its claim (`record_submission_failure/3`): don't count it twice.
      Download.movie_retry_accounted?(movie.id) ->
        {:ok, movie}

      true ->
        count(movie, reason, :search_attempts, &park(movie, :search_failed, &1))
    end
  end

  def record_failure(%Movie{status: :downloading} = movie, :stalled),
    do: requeue_stalled(movie)

  def record_failure(%Movie{status: :downloading} = movie, {:blocked_content, _detail} = reason),
    do: requeue_blocklisted(movie, reason)

  def record_failure(%Movie{status: :downloading} = movie, reason)
      when reason in [:download_error, :torrent_not_found] or
             (is_tuple(reason) and elem(reason, 0) == :download_error) do
    attempts = (movie.import_attempts || 0) + 1

    if attempts < @client_failure_tolerance do
      Logger.info(
        "movie #{movie.id} download error #{attempts}/#{@client_failure_tolerance} " <>
          "(#{inspect(reason)}); will re-check"
      )

      strike(movie, :import_attempts, attempts)
    else
      requeue_blocklisted(movie, reason)
    end
  end

  def record_failure(%Movie{status: status} = movie, reason)
      when status in [:downloading, :downloaded] do
    if reason_code(reason) in @permanent_import_errors do
      Logger.warning("import permanently failed for movie #{movie.id}: #{inspect(reason)}")
      park(movie, :import_failed, reason)
    else
      count(movie, reason, :import_attempts, &park(movie, :import_failed, &1))
    end
  end

  def record_failure(%Movie{status: :upgrading} = movie, :stalled), do: reap_upgrade(movie)

  def record_failure(%Movie{status: :upgrading} = movie, {:blocked_content, detail}) do
    Logger.warning("movie #{movie.id} upgrade rejected: #{detail}")
    revert_upgrade(movie, :blocked_content)
  end

  def record_failure(%Movie{status: :upgrading} = movie, :no_client),
    do: revert_upgrade(movie, :no_client)

  def record_failure(%Movie{status: :upgrading} = movie, reason) do
    if reason_code(reason) in @permanent_import_errors,
      do: revert_upgrade(movie, reason),
      else: count(movie, reason, :import_attempts, &revert_upgrade(movie, &1))
  end

  def record_failure(%Movie{}, _reason), do: {:error, :not_in_flight}

  # One more strike against `field`'s budget, or, on the strike that spends it, `exhausted.(reason)`.
  # A release-policy probe that stayed unavailable all along is held for verification instead.
  defp count(movie, reason, field, exhausted) do
    attempts = (Map.get(movie, field) || 0) + 1

    cond do
      attempts < @failure_budget ->
        Logger.info(
          "movie #{movie.id} #{field} #{attempts}/#{@failure_budget} failed " <>
            "(#{inspect(reason)}); will retry"
        )

        strike(movie, field, attempts)

      match?({:release_policy_unavailable, _}, reason) and
          movie.status in [:downloaded, :upgrading] ->
        Logger.warning(
          "movie #{movie.id} #{field} exhausted after #{attempts}: #{inspect(reason)}"
        )

        hold(movie, attempts, reason)

      true ->
        Logger.warning(
          "movie #{movie.id} #{field} exhausted after #{attempts}: #{inspect(reason)}"
        )

        exhausted.(reason)
    end
  end

  # A counted failure: the status stays, the budget field takes the strike, and the live speed and
  # ETA clear (whatever was moving is not moving now).
  defp strike(movie, field, attempts) do
    movie
    |> write(%{field => attempts, status: movie.status, download_speed: nil, download_eta: nil})
    |> publish()
  end

  # A release a failure proves bad for this movie, so it is blocklisted (and an upgrade's client job
  # removed): every reason is either deterministic or arrives only after its retry bound.
  # `:release_policy_mismatch` only arrives here for a release with no title to blocklist.
  defp proven_bad?(code),
    do:
      code in @permanent_import_errors or code in @download_failure_errors or
        code == :release_policy_mismatch

  # A terminal park. The reason's human detail (`{:download_error, "paused"}`) is kept as
  # `failure_reason` for /activity; a proven-bad release is blocklisted after commit, best-effort
  # (`Grabs.block_release/2` never raises and ignores a pre-grab movie with no release).
  defp park(movie, status, reason) do
    code = reason_code(reason)

    with {:ok, parked} <-
           movie
           |> write(%{status: status, failure_reason: reason_detail(reason)})
           |> publish() do
      announce_park(parked, reason, code)
      if proven_bad?(code), do: Grabs.block_release(parked, code)
      {:ok, parked}
    end
  end

  # Only a binary detail survives the `:string` cast; anything else would fail the changeset and
  # silently skip the park.
  defp reason_detail({_code, detail}) when is_binary(detail), do: detail
  defp reason_detail(_reason), do: nil

  # A download the client reports failed, or blocked content: blocklist the release, confirm the
  # row is there, then re-queue. The row is the loop's only bound (each failed release shrinks the
  # candidate pool until the search parks `:no_match`), so with no confirmed row the movie parks
  # instead of re-grabbing the same release forever. It must be checked before the re-queue: the
  # matrix has no way back from `:requested` to a park.
  defp requeue_blocklisted(movie, reason) do
    code = reason_code(reason)

    case Grabs.block_release_and_confirm(movie, code) do
      :ok ->
        with {:ok, requeued} <- requeue(movie, code) do
          Logger.warning(
            "movie #{movie.id} download failed (#{inspect(reason)}); blocklisted, re-searching"
          )

          {:ok, requeued}
        end

      :error ->
        Logger.warning(
          "movie #{movie.id} download failed (#{inspect(reason)}); " <>
            "release could not be blocklisted, so re-queueing would loop; parking"
        )

        park(movie, :import_failed, reason)
    end
  end

  # A stall is a timeout, not a proven-bad release: the blocklist row is best-effort and written
  # after the re-queue, and `retry/1` clears it for a fresh chance.
  defp requeue_stalled(movie) do
    with {:ok, requeued} <- requeue(movie, :stalled) do
      Grabs.block_release(movie, :stalled)
      Logger.warning("movie #{movie.id} reaped: stalled download removed; re-searching")
      {:ok, requeued}
    end
  end

  # `:downloading` → `:requested` with the failed download cleared and fenced for removal in the
  # same transaction, and `search_attempts` bumped for the search backoff.
  defp requeue(movie, notify_reason) do
    attrs =
      Map.merge(@drop_download, %{
        status: :requested,
        search_attempts: (movie.search_attempts || 0) + 1,
        content_path: nil
      })

    with {:ok, requeued} <- movie |> fenced_write(attrs) |> publish() do
      Notifier.notify({:movie_failed, requeued, notify_reason})
      {:ok, requeued}
    end
  end

  # An upgrade that failed: back to `:available` keeping the live file. A replacement proven bad is
  # blocklisted so the next hunt does not re-pick it, and its client job is fenced for removal in
  # the revert's transaction, its payload deleted after commit under the move-on-import rule (a
  # torrent keeps seeding). `:blocked_content` already removed its job from the client, so it is
  # fenced too. Any other reason (a config glitch like `:no_client`) leaves the release alone.
  defp revert_upgrade(movie, reason) do
    code = reason_code(reason)
    blocked? = code == :blocked_content or proven_bad?(code)
    remove_payload? = blocked? and Download.move_on_import_removal?(movie.download_protocol)
    attrs = Map.put(@drop_download, :status, :available)

    result =
      if code == :blocked_content or remove_payload?,
        do: movie |> fenced_write(attrs) |> publish(),
        else: movie |> write(attrs, [:download_id]) |> publish()

    with {:ok, reverted} <- result do
      if blocked?, do: Grabs.block_release(movie, :upgrade_failed)

      # `movie.download_protocol`: `reverted` has cleared it. Only the payload is left to remove.
      if remove_payload?,
        do: Download.remove_after_import(movie.download_protocol, nil, source(movie))

      Logger.warning("movie #{movie.id} upgrade reverted to :available (#{inspect(reason)})")
      Notifier.notify({:movie_upgrade_failed, reverted, code})
      {:ok, reverted}
    end
  end

  # A stalled upgrade: revert keeping the live file, fence the stalled replacement for removal, and
  # blocklist it as stalled before the revert is announced.
  defp reap_upgrade(movie) do
    with {:ok, reverted} <- fenced_write(movie, Map.put(@drop_download, :status, :available)) do
      Grabs.block_release(movie, :stalled)
      publish({:ok, reverted})
      Logger.warning("movie #{movie.id} upgrade reaped: stalled replacement removed; reverted")
      Notifier.notify({:movie_upgrade_failed, reverted, :stalled})
      {:ok, reverted}
    end
  end

  # A write that drops the caller's download, with that download fenced for removal in the same
  # transaction (the fence reads the caller's struct: the row's `download_id` is cleared by then).
  # The fence drains after commit; the caller publishes.
  defp fenced_write(movie, attrs) do
    fn ->
      with {:ok, written} <- write(movie, attrs, [:download_id]),
           do: {:ok, {written, Download.fence_movie_cleanup(movie)}}
    end
    |> transact()
    |> drain_fence(:stale_status)
  end

  # The release-policy probe stayed unavailable through the whole budget: park at `:import_failed`
  # as a verification hold that keeps the release and its download for the operator. Guarded on
  # `release_title` too, so a changed release is never held.
  defp hold(%Movie{status: status} = movie, attempts, reason)
       when status in [:downloaded, :upgrading] do
    origin = if status == :downloaded, do: :download, else: :upgrade

    with {:ok, held} <-
           movie
           |> write(
             %{
               status: :import_failed,
               import_attempts: attempts,
               verification_hold_origin: origin
             },
             [:release_title]
           )
           |> publish() do
      Notifier.notify({:movie_failed, held, reason})
      {:ok, held}
    end
  end

  # A movie that just parked: `[:cinder, :park]` keyed on the classifying code, then the household
  # notification.
  defp announce_park(parked, reason, notify_reason) do
    :telemetry.execute([:cinder, :park], %{count: 1}, %{kind: :movie, reason: reason_code(reason)})

    Notifier.notify({:movie_failed, parked, notify_reason})
  end

  # A reason may carry a human detail (`{:download_error, "paused"}`); the code classifies it.
  defp reason_code({code, _detail}), do: code
  defp reason_code(code), do: code

  # --- operator verbs ----------------------------------------------------------------------------

  @doc """
  Re-queues a parked movie to `:requested` with its counters zeroed and its stale download
  cleared, then deletes its `:stalled` blocklist rows so a stall-reaped release gets one fresh
  chance (a stall is a timeout, not a proven-bad release; deterministic blocks stay).

  A verification hold is released instead: back to `:downloaded` or `:upgrading`, keeping its
  release, with `import_attempts` zeroed so the import gets a fresh budget.

  `{:error, :not_retryable}` for a movie that does not offer `:retry` (`Attention.offers?/2`);
  `{:error, :stale_status}` when the row moved on since the caller read it, a plain parked movie
  that has since become a verification hold included (the blocklist is left alone then).
  """
  def retry(%Movie{} = movie) do
    if Attention.offers?(movie, :retry), do: do_retry(movie), else: {:error, :not_retryable}
  end

  defp do_retry(%Movie{status: :import_failed, verification_hold_origin: origin} = movie)
       when origin in [:download, :upgrade] do
    status = if origin == :download, do: :downloaded, else: :upgrading

    movie
    |> write(%{status: status, import_attempts: 0, verification_hold_origin: nil}, [
      :verification_hold_origin,
      :release_title
    ])
    |> publish()
  end

  defp do_retry(%Movie{} = movie) do
    attrs =
      Map.merge(@requeue_clears, %{status: :requested, search_attempts: 0, import_attempts: 0})

    with {:ok, requested} <- movie |> write(attrs, [:verification_hold_origin]) |> publish() do
      Grabs.clear_stalled_blocklist(movie: movie.id)
      {:ok, requested}
    end
  end

  @doc """
  Cancels an in-flight movie (one that offers `:cancel`). The `:cancelled` write, the audit row
  and the durable cleanup fence for its client download commit together; the client removal runs
  after commit, and a failure there leaves the fence for background reconciliation.

  A verification hold on a fresh download is cancelled with its download dropped. Returns
  `{:error, :not_cancellable}` when the movie is not cancellable or moved on since the caller
  read it.
  """
  def cancel(%Movie{} = movie, actor) do
    if Attention.offers?(movie, :cancel),
      do: do_cancel(movie, actor),
      else: {:error, :not_cancellable}
  end

  defp do_cancel(
         %Movie{status: :import_failed, verification_hold_origin: :download} = movie,
         actor
       ),
       do: release_hold(movie, actor, :cancelled, :cancel_movie, :not_cancellable)

  defp do_cancel(%Movie{} = movie, actor) do
    fn ->
      with {:ok, cancelled} <- write(movie, %{status: :cancelled, release_policy_snapshot: nil}) do
        intent_ids = Download.fence_movie_cleanup(cancelled)
        Audit.log_or_rollback(actor, :cancel_movie, cancelled, %{from: movie.status})
        {:ok, {cancelled, intent_ids}}
      end
    end
    |> transact()
    |> publish_with_cleanup(:not_cancellable)
  end

  @doc """
  Aborts an upgrade (a movie that offers `:cancel_upgrade`): back to `:available` keeping the live
  library file and its quality, with the replacement download fenced for removal. Never
  `:cancelled`: the movie still has a good file. An upgrade on a verification hold is released the
  same way. Audited like `cancel/2`.

  Returns `{:error, :not_upgrading}` when there is no upgrade to abort, or it finished or changed
  since the caller read the movie.
  """
  def abort_upgrade(%Movie{} = movie, actor) do
    if Attention.offers?(movie, :cancel_upgrade),
      do: do_abort_upgrade(movie, actor),
      else: {:error, :not_upgrading}
  end

  defp do_abort_upgrade(%Movie{status: :upgrading} = movie, actor) do
    attrs = Map.put(@drop_download, :status, :available)

    fn ->
      with {:ok, reverted} <- write(movie, attrs, [:download_id]) do
        intent_ids = Download.fence_movie_cleanup(movie)
        Audit.log_or_rollback(actor, :abort_upgrade, reverted, %{from: :upgrading})
        {:ok, {reverted, intent_ids}}
      end
    end
    |> transact()
    |> publish_with_cleanup(:not_upgrading)
  end

  defp do_abort_upgrade(%Movie{verification_hold_origin: :upgrade} = movie, actor),
    do: release_hold(movie, actor, :available, :abort_upgrade, :not_upgrading)

  # Cancel or abort a verification hold: the hold's download is fenced for removal and its release
  # dropped. A fresh-download hold also loses its download paths; an upgrade hold keeps the live
  # library file.
  defp release_hold(movie, actor, status, action, miss) do
    dropped =
      if movie.verification_hold_origin == :download, do: @requeue_clears, else: @drop_download

    attrs = Map.merge(dropped, %{status: status, verification_hold_origin: nil})

    fn ->
      with {:ok, released} <-
             write(movie, attrs, [:verification_hold_origin, :release_title, :download_id]) do
        intent_ids = Download.fence_movie_cleanup(movie)
        Audit.log_or_rollback(actor, action, released, %{from: :import_failed})
        {:ok, {released, intent_ids}}
      end
    end
    |> transact()
    |> publish_with_cleanup(miss)
  end

  # --- adoption ----------------------------------------------------------------------------------

  # An existing movie in one of these, or on a verification hold, still owns an acquisition.
  @acquiring_statuses [:searching, :downloading, :downloaded, :upgrading]

  @doc """
  Adopts a library file found on disk as the movie `attrs.tmdb_id`. An unknown movie is inserted
  straight at `:available` (never visible at `:requested`, so the movie poller cannot grab it in
  between) and announced with `{:movie_created, movie}`. An existing `:requested` movie, or an
  `:available` one with no file, moves to `:available` like any other lifecycle edge. Returns
  `{:ok, movie, :created | :existing}`.

  Options:

    * `profile: {profile_id, legacy_handling}` assigns the operator's handling profile in the same
      transaction; without it the existing movie keeps its own.
    * `revalidate: fun` runs as `fun.(profile)` before any transaction opens, and its
      `{:error, reason}` stops the adoption. It is filesystem I/O that can stall on a network
      mount (#455), so it must not hold SQLite's database-wide write lock; the profile is
      re-resolved inside the `:immediate` transaction instead, which catches a profile deleted in
      the gap.

  Refuses with `{:error, :already_has_file}`, `{:error, :acquisition_in_progress}` (an
  acquisition in flight, a verification hold, or a grab whose submission is still pending, any of
  which would replace the adopted file), `{:error, {:illegal_transition, status, :available}}` for
  a parked or cancelled movie, or `{:error, :invalid_file_path}`.
  """
  def adopt(attrs, file_path, opts \\ [])

  def adopt(attrs, file_path, opts)
      when is_map(attrs) and is_binary(file_path) and file_path != "" do
    assignment = Keyword.get(opts, :profile)
    revalidate = Keyword.get(opts, :revalidate, fn _profile -> :ok end)

    with {:ok, profile, _handling} <- resolve_assignment(assignment),
         :ok <- revalidate.(profile) do
      fn -> adopt_in_transaction(attrs, file_path, assignment) end
      |> transact(mode: :immediate)
      |> publish_adoption()
    end
  end

  def adopt(_attrs, _file_path, _opts), do: {:error, :invalid_file_path}

  defp adopt_in_transaction(attrs, file_path, nil),
    do: adopt_resolved(attrs, file_path, nil)

  defp adopt_in_transaction(attrs, file_path, assignment) do
    with {:ok, profile, handling} <- resolve_assignment(assignment),
         do: adopt_resolved(attrs, file_path, {profile, handling})
  end

  defp resolve_assignment(nil), do: {:ok, nil, nil}

  defp resolve_assignment({profile_id, legacy_handling}),
    do: Profiles.resolve_assignment(profile_id, :movies, legacy_handling)

  defp adopt_resolved(attrs, file_path, assignment) do
    case Repo.get_by(Movie, tmdb_id: Map.get(attrs, :tmdb_id)) do
      nil ->
        %Movie{status: :available, file_path: file_path}
        |> Movie.changeset(Map.merge(attrs, assignment_fields(assignment)))
        |> Repo.insert()
        |> tag(:created)

      %Movie{} = movie ->
        movie |> adopt_existing(file_path, assignment) |> tag(:existing)
    end
  end

  defp adopt_existing(movie, file_path, assignment) do
    cond do
      Movie.file_paths(movie) != [] ->
        {:error, :already_has_file}

      movie.status in @acquiring_statuses or not is_nil(movie.verification_hold_origin) ->
        {:error, :acquisition_in_progress}

      # A grab whose submission is still pending would attach to the adopted movie as an upgrade
      # and replace the adopted file.
      Download.movie_intent_pending?(movie.id) ->
        {:error, :acquisition_in_progress}

      # A parked or cancelled movie stays where it is, as on main: retry or delete it first.
      movie.status not in [:requested, :available] ->
        {:error, {:illegal_transition, movie.status, :available}}

      true ->
        with :ok <- ensure_assignment_safe(movie, assignment),
             {:ok, adopted} <- write(movie, %{status: :available, file_path: file_path}) do
          assign(adopted, assignment)
        end
    end
  end

  defp ensure_assignment_safe(_movie, nil), do: :ok

  defp ensure_assignment_safe(movie, {profile, handling}),
    do: Profiles.ensure_assignment_safe(movie, profile, handling)

  defp assign(movie, nil), do: {:ok, movie}

  defp assign(movie, assignment) do
    movie
    |> Ecto.Changeset.change(assignment_fields(assignment))
    |> Ecto.Changeset.foreign_key_constraint(:profile_id)
    |> Ecto.Changeset.check_constraint(:profile_id, name: :movies_profile_integrity)
    |> Repo.update()
  end

  defp assignment_fields(nil), do: %{}

  defp assignment_fields({profile, handling}),
    do: %{profile_id: profile && profile.id, media_profile: handling}

  defp tag({:ok, movie}, marker), do: {:ok, {movie, marker}}
  defp tag({:error, _reason} = error, _marker), do: error

  defp publish_adoption({:ok, {movie, :created}}) do
    Catalog.broadcast_movie_created(movie)
    {:ok, movie, :created}
  end

  defp publish_adoption({:ok, {movie, :existing}}) do
    {:ok, movie} = publish({:ok, movie})
    {:ok, movie, :existing}
  end

  defp publish_adoption({:error, _reason} = error), do: error

  # --- the write and its publication ---------------------------------------------------------------

  # The one compare-and-swap every verb writes through. The matrix check runs first, on the
  # caller's status, so an illegal pair never reaches the database. The update then lands only if
  # the row still holds the caller's status and each `guards` field still holds the caller's value
  # (nil-safe), and `select:` returns the fresh row. Every attr the verb names is written, even when
  # the caller's struct already holds that value: the struct may be stale everywhere it is not
  # guarded. No publication: callers publish once their transaction has committed.
  defp write(%Movie{} = movie, attrs, guards \\ []) do
    changeset = Movie.transition_changeset(movie, attrs)
    to = Ecto.Changeset.get_field(changeset, :status)

    cond do
      not changeset.valid? -> {:error, changeset}
      not legal?(movie.status, to) -> {:error, {:illegal_transition, movie.status, to}}
      true -> compare_and_swap(movie, write_set(changeset, attrs), guards)
    end
  end

  defp write_set(changeset, attrs) do
    named =
      Map.new(attrs, fn {field, _value} -> {field, Ecto.Changeset.get_field(changeset, field)} end)

    named
    |> Map.merge(changeset.changes)
    |> Map.put(:updated_at, Catalog.now())
    |> Map.to_list()
  end

  defp compare_and_swap(movie, set, guards) do
    query =
      Enum.reduce(
        guards,
        from(m in Movie, where: m.id == ^movie.id and m.status == ^movie.status, select: m),
        fn field, query -> guard(query, field, Map.fetch!(movie, field)) end
      )

    case Repo.update_all(query, set: set) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, :stale_status}
    end
  end

  defp guard(query, field, nil), do: where(query, [m], is_nil(field(m, ^field)))
  defp guard(query, field, value), do: where(query, [m], field(m, ^field) == ^value)

  # Runs `fun` (`{:ok, value} | {:error, reason}`) in a transaction, rolling back on an error.
  defp transact(fun, opts \\ []) do
    Repo.transaction(
      fn ->
        case fun.() do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      opts
    )
  end

  # After commit: drain the cleanup fence the transaction wrote, then publish. A stale miss
  # becomes the verb's own refusal atom.
  defp publish_with_cleanup(result, miss), do: result |> drain_fence(miss) |> publish()

  defp drain_fence({:ok, {movie, intent_ids}}, _miss) do
    Download.cleanup_intents(intent_ids)
    {:ok, movie}
  end

  defp drain_fence({:error, :stale_status}, miss), do: {:error, miss}
  defp drain_fence({:error, reason}, _miss), do: {:error, reason}

  # The one publication of a committed write: `{:movie_updated, movie}` on the "movies" topic,
  # then `[:cinder, :transition]`. Never call it inside a transaction.
  defp publish({:ok, %Movie{} = movie}) do
    Catalog.broadcast({:movie_updated, movie})
    :telemetry.execute([:cinder, :transition], %{count: 1}, %{kind: :movie, to: movie.status})
    {:ok, movie}
  end

  defp publish({:error, _reason} = error), do: error
end
