defmodule Cinder.Catalog.Grabs do
  @moduledoc """
  The TV grab lifecycle: reserving a release as a `%Grab{}` (manual or sweep-driven) and
  tracking it through download/import (create/mark/commit/close/finish/park/reap). Changes are
  announced through `Cinder.Catalog.Events`.
  """
  import Ecto.Query
  require Logger

  alias Cinder.Audit

  alias Cinder.Catalog.{
    Adoption,
    Attention,
    BlockedReleases,
    Episode,
    Episodes,
    EpisodeSearch,
    Events,
    Grab,
    GrabFile,
    Identity,
    Season
  }

  alias Cinder.Catalog.SeriesCatalog
  alias Cinder.Download
  alias Cinder.Download.Progress
  alias Cinder.GuardedWrite
  alias Cinder.Library.{ImportedQuality, ImportStage}
  alias Cinder.Notifier
  alias Cinder.Repo

  @doc "Updates an in-flight grab's progress snapshot and broadcasts its owning series."
  def update_grab_download_metrics(%Grab{} = grab, attrs) do
    changes = Progress.changes(grab, attrs)

    if changes == %{} do
      if Repo.exists?(from(g in Grab, where: g.id == ^grab.id and is_nil(g.content_path))) do
        {:ok, grab}
      else
        {:error, :stale_grab}
      end
    else
      now = DateTime.utc_now(:second)

      changes =
        if Progress.advanced?(grab.download_progress, Map.get(changes, :download_progress)),
          do: Map.put(changes, :download_progress_at, now),
          else: changes

      case Repo.update_all(
             from(g in Grab,
               where: g.id == ^grab.id and is_nil(g.content_path),
               select: g
             ),
             set: Map.to_list(changes) ++ [updated_at: now]
           ) do
        {1, [updated]} ->
          Events.series_updated(series_id_for_grab(grab.id))
          {:ok, updated}

        {0, _} ->
          {:error, :stale_grab}
      end
    end
  end

  @doc """
  Creates a grab for `episode_ids` (a non-empty list of episodes in one series — a single
  episode or a season pack) and links them in one transaction, then broadcasts
  `{:series_updated, series_id}`. `release_title` (optional) records the chosen release's name so
  the blocklist can skip it if this download later parks. A changeset failure (e.g. a missing
  `download_id`) rolls back as `{:error, changeset}` rather than raising, mirroring
  `set_season_monitored/2`.

  `opts` — `reset_attempts: true` zeroes the linked episodes' `search_attempts` in the same
  transaction (mirrors `manual_grab_movie/2`): the user-chosen release gets a fresh search budget.
  `allow_available: true` is reserved for the durable manual-upgrade path.
  `arbitrate_at_import: true` marks the grab so the import, not the grab, decides each episode's
  swap — the unattended upgrade sweep sets it; the manual path leaves it off and forces (#250).
  """
  def create_grab(download_id, protocol, episode_ids, release_title \\ nil, opts \\ []) do
    result =
      Repo.transaction(fn ->
        insert_and_link_grab(download_id, protocol, episode_ids, release_title, opts)
      end)

    with {:ok, grab} <- result do
      broadcast_grab_series(grab)
      {:ok, grab}
    end
  end

  @doc "Atomically transfers an anime intent's frozen mapping snapshot and episode ownership."
  def create_grab_from_intent(%Cinder.Download.Intent{} = intent) do
    result =
      Repo.transaction(fn ->
        fresh = Repo.get(Cinder.Download.Intent, intent.id)
        if is_nil(fresh), do: Repo.rollback(:stale_intent)

        attrs = %{
          download_id: fresh.remote_id,
          download_protocol: fresh.protocol,
          release_title: fresh.release["title"],
          mapping_snapshot: fresh.mapping_snapshot,
          release_policy_snapshot: fresh.release_policy_snapshot,
          mapping_status: :resolved
        }

        grab =
          %Grab{arbitrate_at_import: fresh.release["arbitrate_at_import"] == true}
          |> Grab.reservation_changeset(attrs)
          |> Repo.insert()
          |> case do
            {:ok, grab} -> grab
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {linked, _rows} = link_intent_episodes(fresh, grab)

        if linked != length(fresh.episode_ids), do: Repo.rollback(:episode_ownership_changed)

        Repo.delete!(fresh)
        grab
      end)

    with {:ok, grab} <- result do
      broadcast_grab_series(grab)
      {:ok, grab}
    end
  end

  defp link_intent_episodes(intent, grab) do
    allow_available? = intent.release["operator_initiated"] == true

    Repo.update_all(
      from(e in Episode,
        where:
          e.id in ^intent.episode_ids and is_nil(e.grab_id) and
            ((e.monitored == true and is_nil(e.file_path)) or
               (^allow_available? and not is_nil(e.file_path)))
      ),
      set: [grab_id: grab.id, updated_at: DateTime.utc_now(:second)]
    )
  end

  @doc "Persists an anime mapping preflight outcome (resolved, or held with its reason) and broadcasts."
  def record_mapping_result(%Grab{} = grab, {:ok, _preflight}) do
    persist_mapping_result(grab, %{mapping_status: :resolved, mapping_issue: nil})
  end

  def record_mapping_result(
        %Grab{mapping_status: prior} = grab,
        {:needs_mapping, %{issue: issue}}
      ) do
    with {:ok, held} <-
           persist_mapping_result(grab, %{mapping_status: :needs_mapping, mapping_issue: issue}) do
      # Emit only on a fresh hold (resolved → needs_mapping), never on a re-observation of a grab
      # already held — the operator hears once per hold, not once per import tick.
      if prior != :needs_mapping, do: Notifier.notify({:operator_hold, held, :needs_mapping})
      {:ok, held}
    end
  end

  defp persist_mapping_result(grab, attrs) do
    case grab |> Grab.mapping_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        broadcast_grab_series(updated)
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  defp broadcast_grab_series(grab) do
    # Post-commit side effect, best-effort: once the txn committed the grab is
    # real, and a blip here (a pool-checkout timeout on the series lookup) must
    # not surface as {:error, _} — the TvPoller's cleanup branch would then
    # remove the client download out from under a live grab and eventually
    # blocklist a good release.
    Events.series_updated(series_id_for_grab(grab.id))
  rescue
    e -> Logger.warning("post-commit broadcast for grab #{grab.id} failed: #{inspect(e)}")
  catch
    kind, value ->
      Logger.warning("post-commit broadcast for grab #{grab.id} #{kind}: #{inspect(value)}")
  end

  defp insert_and_link_grab(download_id, protocol, episode_ids, release_title, opts) do
    case %Grab{arbitrate_at_import: Keyword.get(opts, :arbitrate_at_import, false)}
         |> Grab.changeset(%{
           download_id: download_id,
           download_protocol: protocol,
           release_title: release_title
         })
         |> Repo.insert() do
      {:ok, grab} -> link_grab_episodes(grab, episode_ids, opts)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # No episodes to link is a rollback, not a vacuous success — `linked == length(episode_ids)`
  # below is satisfied by 0 == 0, and would leave an orphan grab owning nothing.
  defp link_grab_episodes(_grab, [], _opts), do: Repo.rollback(:no_episodes_linked)

  defp link_grab_episodes(grab, episode_ids, opts) do
    # reset_attempts: the manual-grab path zeroes search_attempts (mirroring manual_grab_movie),
    # giving the user-chosen release a fresh budget — and keeping the counter from ever exceeding
    # the cap, which `EpisodeSearch.announce_search_exhausted/1`'s crossing check relies on.
    reset = if Keyword.get(opts, :reset_attempts, false), do: [search_attempts: 0], else: []
    allow_available? = Keyword.get(opts, :allow_available, false)
    # Guard `is_nil(grab_id)`: never re-link an episode another grab already owns (defends against
    # a same-tick double-link silently overwriting an earlier grab). Missing episodes must remain
    # monitored; an available episode may be manually upgraded even when monitoring is off.
    {linked, _} =
      Repo.update_all(
        from(e in Episode,
          where:
            e.id in ^episode_ids and is_nil(e.grab_id) and
              ((e.monitored == true and is_nil(e.file_path)) or
                 (^allow_available? and not is_nil(e.file_path)))
        ),
        set: [grab_id: grab.id, updated_at: DateTime.utc_now(:second)] ++ reset
      )

    # All or nothing, as `create_grab_from_intent/1` already does for the anime path. A partial link
    # used to be tolerated, and it silently manufactured operator work: the release still downloads
    # in full, so every episode that slipped away between the search and this write arrives at
    # import with no owner and becomes an undecided `grab_file` — a residual hold keeping the grab
    # open (#247). Rolling back gets the just-added download removed
    # (`Download.cleanup_failed_ownership/2`) and the next sweep re-searches for what is still
    # wanted.
    if linked == length(episode_ids), do: grab, else: Repo.rollback(link_failure(linked))
  end

  defp link_failure(0), do: :no_episodes_linked
  defp link_failure(_partial), do: :episode_ownership_changed

  @doc """
  Marks a grab downloaded (records `content_path`, the at-rest path to import) and broadcasts.
  Also resets `download_attempts` at the download→import boundary (mirrors the movie poller's
  `import_attempts: 0` reset) so download-phase blips don't starve the shared retry budget.
  """
  def mark_grab_downloaded(%Grab{} = grab, content_path) do
    changeset =
      Grab.changeset(grab, %{
        content_path: content_path,
        download_attempts: 0,
        download_progress: nil,
        download_speed: nil,
        download_eta: nil
      })

    with {:ok, grab} <- Repo.update(changeset) do
      Events.series_updated(series_id_for_grab(grab.id))
      {:ok, grab}
    end
  end

  @doc """
  Bumps a grab's `download_attempts` — the single grab-lifetime retry counter the TV poller
  uses for both the advance and import passes — and broadcasts. The caller compares the
  pre-bump count against its bound to decide retry-vs-park.
  """
  def increment_grab_attempts(%Grab{} = grab) do
    Repo.update_all(from(g in Grab, where: g.id == ^grab.id),
      inc: [download_attempts: 1],
      set: [
        download_speed: nil,
        download_eta: nil,
        updated_at: DateTime.utc_now(:second)
      ]
    )

    Events.series_updated(series_id_for_grab(grab.id))
    :ok
  end

  # Verification and mapping holds: the post-download, pre-import safety net
  # `Cinder.Library.PolicyVerifier` writes into, and the operator's way out of each. The movie half
  # lives in `Cinder.Catalog.MovieLifecycle` (`record_failure/2` holds, `retry/1`, `cancel/2` and
  # `abort_upgrade/2` release, `reject/2` rejects).

  @doc "Atomically holds a downloaded resolved grab after its final verification attempt."
  def hold_grab_verification(%Grab{} = grab) do
    observed_attempts = grab.download_attempts || 0

    case Repo.update_all(
           from(g in Grab,
             where:
               g.id == ^grab.id and g.mapping_status == :resolved and
                 g.download_attempts == ^observed_attempts and not is_nil(g.content_path),
             select: g
           ),
           set: [
             mapping_status: :verification_blocked,
             download_attempts: observed_attempts + 1,
             updated_at: DateTime.utc_now(:second)
           ]
         ) do
      {1, [held]} ->
        # Guarded on `mapping_status == :resolved`, so this fires once per hold (resolved →
        # verification_blocked), never on a re-observation of an already-held grab.
        Notifier.notify({:operator_hold, held, :verification_blocked})
        broadcast_grab_and_ok(held)

      {0, _} ->
        {:error, :stale_grab}
    end
  end

  # The operator actions below refuse a grab that does not offer them (`Attention.offers?/2`), then
  # claim the hold the classification read with a compare-and-swap on `mapping_status`.

  @doc "Atomically releases a verification hold and resets only its verification attempts."
  def retry_grab_verification(%Grab{} = grab),
    do: retry_grab(grab, :retry_verification, :verification_blocked, :verification_not_held)

  @doc """
  Releases a mapping hold: the operator has fixed the files on disk (e.g. renamed them), so this
  flips the grab back to `:resolved` (resetting `download_attempts`, mirroring
  `retry_grab_verification/1`) and lets the TV poller's next import tick run a fresh preflight
  over the current files. A preflight that fails again simply re-holds with an updated reason —
  there is no separate retry budget for the hold itself, since re-entry only happens on this
  explicit operator action, never automatically.
  """
  def retry_grab_mapping(%Grab{} = grab),
    do: retry_grab(grab, :retry_mapping, :needs_mapping, :mapping_not_held)

  defp retry_grab(grab, action, from_status, error_atom) do
    if Attention.offers?(grab, action),
      do: claim_retry(grab, from_status, error_atom),
      else: {:error, error_atom}
  end

  defp claim_retry(grab, from_status, error_atom) do
    case Repo.update_all(
           from(g in Grab,
             where: g.id == ^grab.id and g.mapping_status == ^from_status,
             select: g
           ),
           set: [
             mapping_status: :resolved,
             download_attempts: 0,
             updated_at: DateTime.utc_now(:second)
           ]
         ) do
      {1, [retried]} -> broadcast_grab_and_ok(retried)
      {0, _} -> {:error, error_atom}
    end
  end

  @doc """
  The operator's "Import anyway" on a TV verification hold (GitHub #630): releases the hold like
  `retry_grab_verification/1`, but also flags THIS grab row `verification_waived`, so its next
  import skips the checks whose outcome was unknown (`PolicyVerifier`'s `:waive_unavailable`; a
  decidable mismatch still rejects). The claim is guarded on the live hold, so a grab the poller
  or a concurrent Retry already released is `:verification_not_held`; the audit row commits with
  the flip or not at all, and the one broadcast follows the commit.
  """
  def import_grab_anyway(%Grab{} = grab, actor) do
    if Attention.offers?(grab, :import_anyway),
      do: waive_verification(grab, actor),
      else: {:error, :verification_not_held}
  end

  defp waive_verification(grab, actor) do
    result =
      Repo.transaction(fn ->
        case Repo.update_all(
               from(g in Grab,
                 where: g.id == ^grab.id and g.mapping_status == :verification_blocked,
                 select: g
               ),
               set: [
                 mapping_status: :resolved,
                 verification_waived: true,
                 download_attempts: 0,
                 updated_at: DateTime.utc_now(:second)
               ]
             ) do
          {1, [released]} ->
            Audit.log_or_rollback(actor, :import_grab_anyway, released, %{
              release_title: released.release_title,
              from: :verification_blocked
            })

            released

          {0, _} ->
            Repo.rollback(:verification_not_held)
        end
      end)

    with {:ok, released} <- result, do: broadcast_grab_and_ok(released)
  end

  # Called by `cancel_grab/2` inside its transaction, after the cancel claim, before the delete
  # unlinks the episodes. Reads the live row rather than the caller's struct, so a grab the poller
  # or a Retry just resolved is never blocklisted. Non-raising (`block_grab_release/2`).
  defp block_cancelled_hold(%Grab{id: id}) do
    case Repo.one(
           from g in Grab, where: g.id == ^id and g.mapping_status == :verification_blocked
         ) do
      nil -> :ok
      held -> block_grab_release(held, :verification_cancelled)
    end
  end

  defp broadcast_grab_and_ok(grab) do
    Events.series_updated(series_id_for_grab(grab.id))
    {:ok, grab}
  end

  @doc """
  Atomically rejects one confirmed episodic release, guarding the resolved grab and its exact
  episode ownership before blocklisting, fencing cleanup, and deleting it.
  """
  def reject_grab_release(%Grab{} = expected, evidence) do
    expected_episode_ids = expected_grab_episode_ids(expected)

    result =
      Repo.transaction(fn ->
        {claimed, _} =
          Repo.update_all(
            reject_grab_query(expected),
            set: [updated_at: DateTime.utc_now(:second)]
          )

        if claimed != 1, do: Repo.rollback(:stale_release)
        fresh = Repo.get!(Grab, expected.id)
        episode_ids = episode_ids_for_grab(fresh.id) |> Enum.sort()
        series_ids = Episodes.series_ids(episode_ids)

        if stale_grab_ownership?(episode_ids, expected_episode_ids, series_ids),
          do: Repo.rollback(:stale_release)

        [series_id] = series_ids

        {:ok, _blocked} =
          BlockedReleases.block_policy_mismatch(
            [series: series_id],
            fresh.release_title,
            evidence
          )

        intent_ids =
          Download.fence_episode_cleanup(episode_ids, [
            grab_cleanup_spec(fresh, episode_ids)
          ])

        deleted = Repo.delete!(fresh)
        {deleted, intent_ids, series_id}
      end)

    with {:ok, {deleted, intent_ids, series_id}} <- result do
      Download.cleanup_intents(intent_ids)
      Events.series_updated(series_id)
      {:ok, deleted}
    end
  end

  defp reject_grab_query(expected) do
    from g in Grab,
      where:
        g.id == ^expected.id and g.mapping_status == :resolved and
          g.release_title == ^expected.release_title and
          g.release_policy_snapshot == ^expected.release_policy_snapshot
  end

  defp stale_grab_ownership?(episode_ids, expected_episode_ids, series_ids),
    do: episode_ids == [] or episode_ids != expected_episode_ids or length(series_ids) != 1

  defp expected_grab_episode_ids(%Grab{episodes: episodes}) when is_list(episodes),
    do: episodes |> Enum.map(& &1.id) |> Enum.sort()

  defp expected_grab_episode_ids(%Grab{
         mapping_snapshot: %{"reserved_episode_ids" => episode_ids}
       })
       when is_list(episode_ids),
       do: Enum.sort(episode_ids)

  defp expected_grab_episode_ids(%Grab{}), do: :unknown

  @doc """
  Aborts one grab as a user action (a grab that offers `:cancel`: any grab not held for mapping,
  which `cancel_mapping_grab/1` discards instead). Its delete and durable cleanup fence commit
  together; remote cleanup retries from the fence. Episodes rejoin the sweep; a verification hold
  is blocklisted. A grab already gone is `{:ok, grab}`; one held for mapping, as the caller saw it
  or since, is `{:error, :not_cancellable}`.
  """
  def cancel_grab(%Grab{} = grab) do
    if Attention.offers?(grab, :cancel),
      do: cancel_grab(grab, :not_mapping),
      else: {:error, :not_cancellable}
  end

  @doc """
  Aborts a grab only while it is still held for mapping (one that offers `:discard`). The
  held-state claim, cleanup fence, and delete share one transaction so a concurrent mapping
  resume cannot be cancelled afterward.
  """
  def cancel_mapping_grab(%Grab{} = grab) do
    if Attention.offers?(grab, :discard),
      do: cancel_grab(grab, :needs_mapping),
      else: {:error, :mapping_not_held}
  end

  defp cancel_grab(grab, required_state) do
    result =
      Repo.transaction(fn ->
        case Repo.update_all(cancel_grab_query(grab.id, required_state),
               set: [updated_at: DateTime.utc_now(:second)]
             ) do
          {0, _} when required_state == :needs_mapping ->
            Repo.rollback(:mapping_not_held)

          {0, _} ->
            missed_cancel(grab)

          {1, _} ->
            episode_ids = episode_ids_for_grab(grab.id)
            series_id = series_id_for_grab(grab.id)
            block_cancelled_hold(grab)

            intent_ids =
              Download.fence_episode_cleanup(episode_ids, [grab_cleanup_spec(grab, episode_ids)])

            {:ok, deleted} = Repo.delete(grab, allow_stale: true)
            {deleted, intent_ids, series_id}
        end
      end)

    with {:ok, {deleted, intent_ids, series_id}} <- result do
      Download.cleanup_intents(intent_ids)
      Events.series_updated(series_id)
      {:ok, deleted}
    end
  end

  # A cancel claim that matched no row: the grab is gone (idempotent success) or now held for
  # mapping, which `cancel_grab/1` does not offer.
  defp missed_cancel(grab) do
    if Repo.exists?(from g in Grab, where: g.id == ^grab.id),
      do: Repo.rollback(:not_cancellable),
      else: {grab, [], nil}
  end

  defp cancel_grab_query(id, :any_state), do: from(g in Grab, where: g.id == ^id)

  defp cancel_grab_query(id, :not_mapping),
    do: from(g in Grab, where: g.id == ^id and g.mapping_status != :needs_mapping)

  defp cancel_grab_query(id, :needs_mapping),
    do: from(g in Grab, where: g.id == ^id and g.mapping_status == :needs_mapping)

  @doc """
  Records `grab`'s `release_title` as blocked for its series. Resolves the series from the grab's
  still-linked episodes, so call it **before** `park_grab/1` deletes the grab (the FK nilifies the
  links on delete). A nil `release_title` is a no-op. **Non-raising**
  (`Cinder.Catalog.BlockedReleases.block_series_release/3`): the series lookup runs inside its
  guard, so the TV park path's series resolution can't raise out and abort `park_grab`.
  """
  def block_grab_release(%Grab{release_title: title, id: grab_id}, reason),
    do: BlockedReleases.block_series_release(fn -> series_id_for_grab(grab_id) end, title, reason)

  @doc "Grabs still downloading (no `content_path` yet)."
  def list_grabs_downloading, do: Repo.all(from g in Grab, where: is_nil(g.content_path))

  @doc "Count of grabs still downloading (no `content_path` yet)."
  def count_grabs_downloading,
    do: Repo.aggregate(from(g in Grab, where: is_nil(g.content_path)), :count)

  @doc """
  The undecided residual videos of a standard-TV grab: inventoried at import time with no
  fold/part decision yet. A non-empty result puts the grab on a `:residual_files` hold
  (`Cinder.Catalog.Attention.classify/1`) and is exactly what `/activity` renders resolution
  actions for. An unloaded `grab_files` association classifies as none.
  """
  def unresolved_grab_files(%{grab_files: files}) when is_list(files),
    do: Enum.filter(files, &is_nil(&1.decision))

  def unresolved_grab_files(_grab), do: []

  @doc """
  Grabs downloaded and awaiting import (`content_path` set), preloaded so the TV poller's
  import pass can map files → episodes and build library paths without reaching past Catalog.
  """
  def list_grabs_downloaded do
    Repo.all(
      from g in Grab,
        where: not is_nil(g.content_path) and g.mapping_status == :resolved,
        # scene coordinates preloaded so the import-time subtitle fetch can query the provider
        # with A6 scene numbering (issue #143).
        preload: [:grab_files, episodes: [:episode_coordinates, season: :series]]
    )
  end

  @list_grabs_limit 200

  @doc """
  All grabs newest-first, preloaded for the admin /grabs view. No terminal grab row survives to
  prune (every terminal transition deletes it), so instead of a retention sweep this bounds cost
  with a limit that never drops a hold, regardless of age (#459). The hold predicate here only
  bounds the list; `Cinder.Catalog.Attention` decides what needs attention.
  """
  def list_grabs do
    Repo.all(
      from g in Grab,
        as: :grab,
        where:
          g.mapping_status in [:needs_mapping, :verification_blocked] or
            exists(
              from f in GrabFile, where: f.grab_id == parent_as(:grab).id and is_nil(f.decision)
            ) or
            g.id in subquery(
              from g2 in Grab, order_by: [desc: g2.id], limit: ^list_grabs_limit(), select: g2.id
            ),
        order_by: [desc: g.id],
        preload: [:grab_files, episodes: [season: :series]]
    )
  end

  defp list_grabs_limit,
    do: Application.get_env(:cinder, __MODULE__, [])[:list_grabs_limit] || @list_grabs_limit

  @doc "Lists held mapping grabs for one series, oldest first, with their series tree preloaded."
  def list_mapping_grabs_for_series(series_id) do
    Repo.all(
      from g in Grab,
        join: episode in assoc(g, :episodes),
        join: season in assoc(episode, :season),
        where: season.series_id == ^series_id and g.mapping_status == :needs_mapping,
        distinct: true,
        order_by: [asc: g.id],
        preload: [episodes: [season: :series]]
    )
  end

  @doc """
  Fetches one grab by id, or `nil`. User-initiated grab actions (e.g. /activity's delete) must
  re-read before acting: a grab resolved from a rendered snapshot may have finished importing
  meanwhile, and cancelling THAT would remove a completed, already-imported torrent for nothing.
  """
  def get_grab(id), do: Repo.get(Grab, id)

  @doc """
  Loads an unresolved residual file and one explicitly selected episode from its grab.

  A decided row returns `:noop` before episode validation so resubmission stays idempotent.
  """
  def get_grab_file_resolution(file_id, episode_id) do
    case Repo.get(GrabFile, file_id) do
      nil ->
        {:error, :grab_file_not_found}

      %GrabFile{decision: decision} = file when not is_nil(decision) ->
        {:ok, :noop, Repo.preload(file, :grab)}

      %GrabFile{} = file ->
        file = Repo.preload(file, :grab)

        episode =
          Repo.one(
            from e in Episode,
              join: season in assoc(e, :season),
              where: e.id == ^episode_id and e.grab_id == ^file.grab_id,
              preload: [season: :series]
          )

        if episode,
          do: {:ok, :pending, file, episode},
          else: {:error, :episode_not_in_grab}
    end
  end

  @doc """
  Loads an unresolved residual file for a decision that names no episode (Discard).

  The file-only sibling of `get_grab_file_resolution/2`: there is no episode to validate, so a
  file whose content belongs to an episode outside this grab is still loadable. A decided row
  returns `:noop` so resubmission stays idempotent.
  """
  def get_grab_file(file_id) do
    case Repo.get(GrabFile, file_id) do
      nil -> {:error, :grab_file_not_found}
      %GrabFile{decision: nil} = file -> {:ok, :pending, Repo.preload(file, :grab)}
      %GrabFile{} = file -> {:ok, :noop, Repo.preload(file, :grab)}
    end
  end

  @doc """
  Commits the clean matches from one standard-TV staging pass and durably inventories every
  unmatched video: a clean pass closes the grab in this transaction; a residual pass leaves the
  grab and its unimported episodes intact for explicit per-file decisions.
  """
  def commit_grab_imports(%Grab{} = grab, imported, residuals, stage_ids \\ []) do
    # Resolved BEFORE the transaction on purpose: it walks the grab's episode links, and
    # `transition_imported_episode!` clears `grab_id` on every imported episode below — so a lazy
    # lookup inside would find nothing and `bound_unplaced_release/3` would silently skip (#274).
    series_id = series_id_for_grab(grab.id)
    imported_ids = imported |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    episodes = Map.new(grab.episodes, &{&1.id, &1})

    result =
      GuardedWrite.transaction(fn ->
        claim_import_grab!(grab)

        if Repo.exists?(from f in GrabFile, where: f.grab_id == ^grab.id),
          do: Repo.rollback(:grab_has_residual_files)

        imported_episodes =
          Enum.map(imported, fn entry ->
            {episode_id, dest, quality, placed?} = normalize_imported(entry)
            episode = Map.get(episodes, episode_id) || Repo.rollback(:stale_grab)

            transition_imported_episode!(
              grab.id,
              episode,
              dest,
              quality,
              residuals != [],
              placed?
            )
          end)

        insert_grab_files(grab.id, residuals)
        ImportStage.mark_committed!(stage_ids)
        bound_unplaced_release(grab, series_id, imported)

        if residuals == [] do
          missing = Enum.reject(grab.episodes, &(&1.id in imported_ids))
          bumped = Enum.map(missing, &transition_missing_episode!(grab.id, &1))
          completed = completed_seasons_for_imported_episodes(imported_ids)
          Repo.delete!(grab)
          {:closed, imported_episodes ++ bumped, Enum.map(bumped, & &1.id), completed}
        else
          completed = completed_seasons_for_imported_episodes(imported_ids)
          {:open, imported_episodes, [], completed}
        end
      end)

    publish_grab_import_result(result, grab, series_id)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_grab}
  end

  @doc "Closes a standard-TV grab once every residual file has an explicit fold/part decision; imported episodes are released unchanged, genuinely missing ones are released and backed off."
  def close_grab(%Grab{} = grab) do
    grab = Repo.preload(grab, :episodes, force: true)
    series_id = series_id_for_grab(grab.id)

    result =
      GuardedWrite.transaction(fn ->
        claim_import_grab!(grab)

        if Repo.exists?(from f in GrabFile, where: f.grab_id == ^grab.id and is_nil(f.decision)),
          do: Repo.rollback(:unresolved_grab_files)

        bumped_ids =
          for %Episode{id: id, file_path: path} <- grab.episodes, path in [nil, ""], do: id

        closed = Enum.map(grab.episodes, &transition_closed_episode!(grab.id, &1))
        Repo.delete!(grab)
        {:closed, closed, bumped_ids, []}
      end)

    publish_grab_import_result(result, grab, series_id)
  rescue
    Ecto.StaleEntryError -> {:error, :stale_grab}
  end

  # A 3-tuple is a placement, the shape every caller used before #250 added the keep case.
  defp normalize_imported({episode_id, dest, quality}), do: {episode_id, dest, quality, true}
  defp normalize_imported({_id, _dest, _quality, _placed?} = entry), do: entry

  # #274: an import where every entry is a #250 arbitrated keep placed NOTHING, and that outcome
  # is otherwise indistinguishable from a real import — the grab closes, no episode is missing, so
  # nothing bounds the sweep that grabbed it. It can disagree with the import forever:
  # `Upgrade.candidate?/4` judges the RELEASE TITLE while the import re-reads the FILE that
  # release produced, and `ImportedQuality.capture/3` backfills only nil fields from the title
  # (deliberately), so an episode whose own token is worse than the pack's title stays "improvable"
  # by it on every rotation. Recording the title under a reason only the upgrade sweep reads bounds
  # that loop and leaves the pack grabbable everywhere else (`BlockedReleases.block_unplaced_pack/2`).
  defp bound_unplaced_release(%Grab{release_title: title}, series_id, imported)
       when is_binary(title) and is_integer(series_id) do
    if imported != [] and Enum.all?(imported, &(elem(normalize_imported(&1), 3) == false)) do
      BlockedReleases.block_unplaced_pack(series_id, title)
    end

    :ok
  end

  defp bound_unplaced_release(_grab, _series_id, _imported), do: :ok

  defp claim_import_grab!(grab) do
    query =
      from g in Grab,
        where:
          g.id == ^grab.id and g.mapping_status == :resolved and
            g.content_path == ^grab.content_path

    case Repo.update_all(query, set: [updated_at: DateTime.utc_now(:second)]) do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:stale_grab)
    end
  end

  # `placed?` false is the arbitrated keep (#250): nothing was written, the episode is committed
  # only to release its grab_id. Parts belong to the primary they were folded onto, so a NEW
  # primary drops them — but here the primary is unchanged, and clearing them would orphan the
  # row's parts and hand them to `remove_superseded_episode_files/1` to delete off disk.
  defp transition_imported_episode!(grab_id, episode, dest, quality, retain_grab?, placed?) do
    if episode.monitored or not is_nil(episode.file_path) do
      attrs =
        Map.merge(
          %{
            file_path: dest,
            part_file_paths: if(placed?, do: [], else: episode.part_file_paths),
            grab_id: if(retain_grab?, do: grab_id)
          },
          ImportedQuality.columns(quality, Episode)
        )

      expected = %{
        grab_id: grab_id,
        file_path: episode.file_path,
        monitored: episode.monitored
      }

      case Episodes.transition(episode, attrs, expect: expected) do
        {:ok, updated} -> updated
        {:error, _reason} -> Repo.rollback(:stale_grab)
      end
    else
      Repo.rollback(:stale_grab)
    end
  end

  defp transition_missing_episode!(grab_id, episode) do
    attrs = %{grab_id: nil, search_attempts: episode.search_attempts + 1}

    expected = %{
      grab_id: grab_id,
      file_path: episode.file_path,
      monitored: episode.monitored,
      search_attempts: episode.search_attempts
    }

    case Episodes.transition(episode, attrs, expect: expected) do
      {:ok, updated} -> updated
      {:error, _reason} -> Repo.rollback(:stale_grab)
    end
  end

  defp transition_closed_episode!(grab_id, %Episode{file_path: path} = episode)
       when is_binary(path) and path != "" do
    expected = %{
      grab_id: grab_id,
      file_path: episode.file_path,
      part_file_paths: episode.part_file_paths,
      monitored: episode.monitored
    }

    case Episodes.transition(episode, %{grab_id: nil}, expect: expected) do
      {:ok, updated} -> updated
      {:error, _reason} -> Repo.rollback(:stale_grab)
    end
  end

  defp transition_closed_episode!(grab_id, episode),
    do: transition_missing_episode!(grab_id, episode)

  @doc """
  Atomically records one Fold/Part decision. The guarded file claim makes a decided row a no-op;
  coordinate, episode-part, and import-stage writes roll back together on any failure. A Part
  decision passes `{dest, stage_ids}`: the staged part's destination and its one journal id.
  """
  def decide_grab_file(file, episode, decision, part \\ nil)

  def decide_grab_file(%GrabFile{} = file, %Episode{} = episode, decision, part)
      when decision in [:fold, :part] do
    result =
      Repo.transaction(fn ->
        attrs = decision_attrs(decision, episode.id, part)

        case Repo.update_all(
               from(f in GrabFile,
                 where: f.id == ^file.id and is_nil(f.decision),
                 select: f
               ),
               set: Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:second)]
             ) do
          {0, _} ->
            existing_grab_file_decision(file.id)

          {1, [decided]} ->
            apply_grab_file_decision!(decided, episode.id, decision, part)
        end
      end)

    publish_grab_file_decision(result)
  end

  def decide_grab_file(%GrabFile{}, %Episode{}, _decision, _part),
    do: {:error, :invalid_grab_file_decision}

  @doc """
  Atomically records one Discard decision — the file-only path.

  `decide_grab_file/4` needs an `%Episode{}` of this grab, because both its decisions bind the
  file to one (Fold writes the provider coordinate onto it, Part stages bytes at its `-part`
  path); a residual belonging to an episode *outside* the grab has no such episode to pass.
  Discard takes none: it claims the row the same guarded way (a decided row is a no-op), writes
  only the decision, and derives its post-commit broadcast from the grab, not an episode.
  """
  def discard_grab_file(%GrabFile{} = file) do
    result =
      Repo.transaction(fn ->
        case Repo.update_all(
               from(f in GrabFile,
                 where: f.id == ^file.id and is_nil(f.decision),
                 select: f
               ),
               set: [decision: :discard, updated_at: DateTime.utc_now(:second)]
             ) do
          {0, _} ->
            existing_grab_file_decision(file.id)

          {1, [decided]} ->
            grab = Repo.get(Grab, decided.grab_id) || Repo.rollback(:stale_grab)
            claim_import_grab!(grab)
            {:decided, decided, nil, series_id_for_grab(grab.id)}
        end
      end)

    publish_grab_file_decision(result)
  end

  defp existing_grab_file_decision(file_id) do
    case Repo.get(GrabFile, file_id) do
      %GrabFile{} = decided -> {:noop, decided, nil}
      nil -> Repo.rollback(:grab_file_not_found)
    end
  end

  defp decision_attrs(:fold, episode_id, nil),
    do: %{decision: :fold, episode_id: episode_id, destination: nil, import_stage_id: nil}

  defp decision_attrs(:part, episode_id, {dest, [stage_id]})
       when is_binary(dest) and is_integer(stage_id),
       do: %{
         decision: :part,
         episode_id: episode_id,
         destination: dest,
         import_stage_id: stage_id
       }

  defp decision_attrs(_decision, _episode_id, _part), do: Repo.rollback(:invalid_import_stage)

  defp apply_grab_file_decision!(file, episode_id, decision, part) do
    grab = Repo.get(Grab, file.grab_id) || Repo.rollback(:stale_grab)
    claim_import_grab!(grab)

    episode =
      Repo.one(
        from e in Episode,
          join: season in assoc(e, :season),
          where: e.id == ^episode_id and e.grab_id == ^file.grab_id,
          preload: [season: :series]
      ) || Repo.rollback(:episode_not_in_grab)

    updated_episode =
      case decision do
        :fold ->
          bind_grab_file_coordinate!(file, episode)
          nil

        :part ->
          {dest, stage_ids} = part
          ImportStage.mark_committed!(stage_ids)
          adopt_grab_file_part!(episode, dest)
      end

    {:decided, file, updated_episode, episode.season.series_id}
  end

  defp bind_grab_file_coordinate!(file, episode) do
    case grab_file_coordinate(file) do
      nil ->
        :ok

      attrs ->
        case Identity.bind_manual_coordinate(episode.season.series, attrs, episode) do
          {:ok, _coordinate} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  @provider_fields [:source, :scheme, :namespace, :canonical_value]

  defp grab_file_coordinate(file) do
    values = Map.take(file, @provider_fields)

    cond do
      Enum.all?(@provider_fields, &(Map.get(values, &1) in [nil, ""])) ->
        nil

      Enum.all?(@provider_fields, fn field ->
        value = Map.get(values, field)
        is_binary(value) and value != ""
      end) ->
        values

      true ->
        Repo.rollback(:invalid_provider_evidence)
    end
  end

  defp adopt_grab_file_part!(episode, destination) do
    case Adoption.adopt_episode_part(episode, destination) do
      {:ok, %Episode{} = updated} -> updated
      {:ok, nil} -> episode
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp publish_grab_file_decision({:ok, {:noop, file, nil}}), do: {:ok, :noop, file}

  defp publish_grab_file_decision({:ok, {:decided, file, updated_episode, series_id}}) do
    if updated_episode,
      do: Episodes.announce([updated_episode]),
      else: Events.series_updated(series_id)

    {:ok, :decided, file}
  end

  defp publish_grab_file_decision({:error, reason}), do: {:error, reason}

  defp insert_grab_files(_grab_id, []), do: :ok

  defp insert_grab_files(grab_id, residuals) do
    timestamp = DateTime.utc_now(:second)

    rows =
      Enum.map(residuals, fn residual ->
        @provider_fields
        |> Map.new(&{&1, Map.get(residual, &1)})
        |> Map.merge(Map.take(residual, [:relative_path, :size, :device, :inode]))
        |> Map.merge(%{
          grab_id: grab_id,
          inserted_at: timestamp,
          updated_at: timestamp
        })
      end)

    Repo.insert_all(GrabFile, rows, on_conflict: :nothing)
    :ok
  end

  # The episode writes published as their frame committed; a pass that wrote none still announces
  # the grab's own change.
  defp publish_grab_import_result(
         {:ok, {state, episodes, bumped_ids, completed_seasons}},
         grab,
         series_id
       ) do
    if episodes == [], do: Events.series_updated(series_id)
    EpisodeSearch.announce_search_exhausted(bumped_ids)
    Enum.each(completed_seasons, &Notifier.notify({:season_available, &1}))

    # `:open` means residual files were just inventoried with no decision — a fresh operator hold
    # (this commit runs once per grab, guarded against re-entry, so no per-tick re-emit).
    if state == :open, do: Notifier.notify({:operator_hold, grab, :residual_files})
    {:ok, state, grab}
  end

  defp publish_grab_import_result({:error, reason}, _grab, _series_id), do: {:error, reason}

  @doc """
  Finalizes a grab after import, in **one transaction**: sets `file_path`, clears
  `part_file_paths` and `grab_id` on each imported episode, bumps `search_attempts` on the
  non-imported ones (backoff toward search-park instead of re-grabbing forever) — **before** the
  delete, since the `grab_id` FK nilifies on delete and the bump's predicate would then match
  nothing — then deletes the grab. `imported` is `[{episode_id, dest_path}]`; each is written
  individually since a single `update_all set:` can't give each its own dest (cheap: `n` is one
  season pack). Broadcasts `{:series_updated, _}` and announces any completed season.

  `opts[:fence_client]` additionally fences a durable cleanup intent for the grab's
  `download_id`/`download_protocol` in the same transaction as the delete, removed from the
  client after commit — `park_grab_and_remove/1`'s use (the `:blocked_content` park, whose grab
  is still an active remote job, and a blocklisted park whose download `move_on_import` removes).
  """
  def finish_grab(%Grab{} = grab, imported \\ []), do: finish_grab(grab, imported, [])

  def finish_grab(%Grab{} = grab, imported, stage_ids, opts \\ []) do
    imported_ids = imported |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    series_id = series_id_for_grab(grab.id)

    result =
      Repo.transaction(fn ->
        ts = DateTime.utc_now(:second)

        for {episode_id, dest, q} <- imported do
          update_imported_episode!(grab.id, episode_id, dest, q, ts)
        end

        # select: in the update_all (RETURNING) hands the bumped ids to the post-commit
        # exhaustion announce without a leading SELECT — a read-then-write transaction is
        # the SQLITE_BUSY class busy_timeout can't rescue (see config/test.exs), and the
        # delete below nilifies grab_id so the ids can't be re-derived afterwards.
        {_count, bumped_ids} =
          Repo.update_all(
            missing_episodes_query(grab.id, imported_ids) |> select([e], e.id),
            inc: [search_attempts: 1],
            set: [updated_at: ts]
          )

        completed_seasons = completed_seasons_for_imported_episodes(imported_ids)

        ImportStage.mark_committed!(stage_ids)
        intent_ids = if opts[:fence_client], do: fence_client_intent_ids(grab), else: []
        Repo.delete!(grab)
        {bumped_ids, completed_seasons, intent_ids}
      end)

    with {:ok, {bumped_ids, completed_seasons, intent_ids}} <- result do
      Events.series_updated(series_id)
      EpisodeSearch.announce_search_exhausted(bumped_ids)
      Enum.each(completed_seasons, &Notifier.notify({:season_available, &1}))
      Download.cleanup_intents(intent_ids)
      {:ok, grab}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_grab}
  end

  # A live grab can't reach zero episodes (every grab-delete here unlinks episodes in the SAME
  # transaction) — empty means a concurrent Discard/cancel won; roll back to :stale_grab.
  defp fence_client_intent_ids(grab) do
    case episode_ids_for_grab(grab.id) do
      [] -> Repo.rollback(:stale_grab)
      ids -> Download.fence_episode_cleanup(ids, [grab_cleanup_spec(grab, ids)])
    end
  end

  defp update_imported_episode!(grab_id, episode_id, dest, quality, timestamp) do
    query =
      from e in Episode,
        where:
          e.id == ^episode_id and e.grab_id == ^grab_id and
            (e.monitored == true or not is_nil(e.file_path))

    updates =
      [file_path: dest, part_file_paths: [], grab_id: nil, updated_at: timestamp] ++
        Map.to_list(ImportedQuality.columns(quality, Episode))

    case Repo.update_all(query, set: updates) do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:stale_grab)
    end
  end

  # The grab's episodes that did not import. Branch on the empty case so we never interpolate
  # an empty list into `not in` (and so a park — empty `imported` — bumps every linked episode).
  defp missing_episodes_query(grab_id, []), do: from(e in Episode, where: e.grab_id == ^grab_id)

  defp missing_episodes_query(grab_id, imported_ids),
    do: from(e in Episode, where: e.grab_id == ^grab_id and e.id not in ^imported_ids)

  defp completed_seasons_for_imported_episodes([]), do: []

  defp completed_seasons_for_imported_episodes(imported_ids) do
    today = Cinder.Settings.household_date()

    imported_season_ids =
      from e in Episode,
        where: e.id in ^imported_ids and not is_nil(e.air_date) and e.air_date <= ^today,
        select: e.season_id,
        distinct: true

    from([_episode, season, series] in SeriesCatalog.available_seasons_query(today),
      where: season.id in subquery(imported_season_ids),
      select: %{
        tmdb_id: series.tmdb_id,
        title: series.title,
        season_number: season.season_number,
        poster_path: series.poster_path
      }
    )
    |> Repo.all()
  end

  @doc """
  Parks a grab: deletes it and bumps every linked episode's `search_attempts` (so they re-search,
  bounded, then search-park). The terminal-failure case of `finish_grab/2` (nothing imported).
  """
  def park_grab(%Grab{} = grab), do: finish_grab(grab, [])

  @doc """
  Parks a grab like `park_grab/1`, but also fences+removes its active client download
  (`finish_grab/4`'s `:fence_client`) — `:blocked_content` and blocklisted `move_on_import` parks.
  """
  def park_grab_and_remove(%Grab{} = grab), do: finish_grab(grab, [], [], fence_client: true)

  @doc """
  Reaps a stalled downloading grab (the stall reaper): one transaction blocklists its release
  `:stalled`, bumps every linked episode's `search_attempts` (backoff), fences the client download
  for removal, then deletes the grab; after commit the remote job + reserved intent are torn down
  and the series is announced, so the episodes re-search a *different* release next tick.

  Claims the grab with a compare-and-swap `update_all` **first** (like `cancel_grab/2`): the
  poller reaps off a tick-start snapshot, so a concurrent user Discard/cancel can delete the same
  grab in the `client.status/1` window — `{0, _}` ⇒ already gone ⇒ `{:error, :stale_grab}` no-op.
  After a `{1, _}` claim the grab still exists, so the block and bump read its still-linked
  episodes before the `Repo.delete` (which nilifies `grab_id`) runs last.
  """
  def reap_stalled_grab(%Grab{} = grab) do
    series_id = series_id_for_grab(grab.id)

    result =
      Repo.transaction(fn ->
        case Repo.update_all(cancel_grab_query(grab.id, :any_state),
               set: [updated_at: DateTime.utc_now(:second)]
             ) do
          {0, _} ->
            :already_gone

          {1, _} ->
            episode_ids = episode_ids_for_grab(grab.id)
            block_grab_release(grab, :stalled)

            Repo.update_all(missing_episodes_query(grab.id, []),
              inc: [search_attempts: 1],
              set: [updated_at: DateTime.utc_now(:second)]
            )

            intent_ids =
              Download.fence_episode_cleanup(episode_ids, [grab_cleanup_spec(grab, episode_ids)])

            {:ok, _deleted} = Repo.delete(grab, allow_stale: true)
            {:reaped, intent_ids}
        end
      end)

    case result do
      {:ok, {:reaped, intent_ids}} ->
        Download.cleanup_intents(intent_ids)
        Events.series_updated(series_id)
        Notifier.notify({:grab_failed, grab, :stalled})
        {:ok, grab}

      {:ok, :already_gone} ->
        {:error, :stale_grab}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Ids of the episodes `grab_id` still owns (empty once the grab is deleted)."
  def episode_ids_for_grab(grab_id) do
    Repo.all(from e in Episode, where: e.grab_id == ^grab_id, select: e.id)
  end

  @doc """
  The durable cleanup spec for `grab`'s client download, over `episode_ids`: what
  `Cinder.Download.fence_episode_cleanup/2` records so the remote job is removed after commit.
  """
  def grab_cleanup_spec(grab, episode_ids) do
    %{
      remote_id: grab.download_id,
      protocol: grab.download_protocol,
      title: grab.release_title,
      episode_ids: episode_ids
    }
  end

  defp series_id_for_grab(grab_id) do
    Repo.one(
      from e in Episode,
        join: s in Season,
        on: s.id == e.season_id,
        where: e.grab_id == ^grab_id,
        select: s.series_id,
        limit: 1
    )
  end
end
