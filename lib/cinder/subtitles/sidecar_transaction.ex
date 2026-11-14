defmodule Cinder.Subtitles.SidecarTransaction do
  @moduledoc """
  The sidecar replacement transaction: every change to a managed sidecar's bytes goes through
  here, whether it is an automatic or manual correction, a reset, a newly fetched subtitle, or a
  removal.

  A `sidecar` is the map `Cinder.Subtitles.Sync.discover/1` returns: `video_path`,
  `sidecar_path`, `language`, `sync` (the final record the caller saw, which a rollback puts
  back) and the track's `managed_sha256`, `backup_tombstone` and `reset_cleanup_sync`.
  `replace/4` needs only the first three.

  Every function expects the caller to hold the video's lock,
  `:global.trans({{Cinder.Subtitles, video_path}, self()}, ...)`.

  Invariants of a correction (`publish/4`) and of recovering one:

    * No byte reaches the sidecar before a pending record names its hash.
    * The final record is written only after the bytes.
    * The correction's workspace is removed only after its final record.
    * `{:publication_committed, _}` is never rolled back; the pending record stays for
      `recover/2`.

  Invariants of retiring an immutable original:

    * The original a final record names is retired only after a cleanup journal holds that
      record (a reset, a replaced video, a fetched replacement).
    * Any original is retired to a zero-byte backup tombstone only when its hash and its inode
      both match the proof.

  The manifest's `sync`, cleanup-journal and backup-tombstone fields are this module's private
  storage: nothing else in `lib/` writes them.
  """

  require Logger

  alias Cinder.Subtitles.{Manifest, Moviehash, SafeFile}
  alias Cinder.Subtitles.SidecarTransaction.{AtomicFile, Backup, Recovery, Workspace}

  import SafeFile,
    only: [fs: 0, safe_destination: 1, safe_read: 1, sha256: 1]

  @type sidecar :: %{
          required(:video_path) => String.t(),
          required(:sidecar_path) => String.t(),
          required(:language) => String.t(),
          optional(atom()) => term()
        }
  @type review :: :externally_modified | :apply_recovery_failed | :replacement_cleanup_failed

  @doc """
  Replays the cleanup journals of every track of `video_path`: interrupted resets (for the
  current `moviehash` only) and interrupted replacements. Once both replay, removes up to 50
  workspaces in the video's folder that have not changed for an hour and that no record there
  names: workspace tombstones, interrupted disposals, and staged files holding the bytes of a
  track's sidecar or immutable original (`Workspace.sweep/3`). A manifest in the folder that it
  cannot read or decode, or that holds a record it cannot decode or one on a track with no
  sidecar file, stops the sweep with one warning. The sweep never fails the call.
  """
  @spec reconcile(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate reconcile(video_path, moviehash), to: Recovery

  @doc """
  Brings one sidecar to a settled state before anything reads or rewrites it: finishes or
  recovers a pending record, restores and retires the immutable original of a sidecar whose
  video or bytes were replaced, and flags bytes nobody accounts for. A pending manual correction
  whose staged bytes are gone is recomputed from the immutable original.

  The returned sidecar carries the record as it now stands, also on review.
  """
  @spec recover(sidecar(), String.t()) :: {:ok, sidecar()} | {:review, review(), sidecar()}
  defdelegate recover(sidecar, moviehash), to: Recovery

  @doc "Restores the immutable original and clears the final record, through the reset journal."
  @spec restore_original(sidecar(), String.t()) :: :ok | {:error, term()}
  defdelegate restore_original(sidecar, moviehash), to: Recovery

  @doc "Hidden immutable original adjacent to a corrected sidecar."
  @spec backup_path(String.t()) :: String.t()
  defdelegate backup_path(sidecar_path), to: Backup, as: :path

  @doc "Whether something other than a backup tombstone sits at the sidecar's backup path."
  @spec stranded_backup?(String.t()) :: boolean()
  def stranded_backup?(sidecar_path), do: sidecar_path |> Backup.path() |> Backup.active?()

  @doc """
  What a correction of `current` starts from: the immutable original when the sidecar has one,
  else `current` itself.
  """
  @spec original(sidecar(), binary()) :: {:ok, binary()} | {:error, term()}
  def original(sidecar, current) do
    cond do
      not stranded_backup?(sidecar.sidecar_path) -> {:ok, current}
      not Backup.immutable_expected?(sidecar.sync) -> {:error, :unexpected_backup}
      true -> Backup.read_original(sidecar.sidecar_path, sidecar.sync)
    end
  end

  @doc """
  Replaces `current` with `content` and records `record` as the sidecar's final record.

  When `content == current` nothing is rewritten: the sidecar's bytes and the video's moviehash
  are checked again and the record is written. Otherwise the immutable original (the bytes
  `record.source_sha256` names) is kept, a pending record is written, the bytes are exchanged
  only if the sidecar still holds `current`, and the final record follows. Any failure before
  the exchange commits puts the caller's record back; any failure after it also exchanges the
  bytes back.
  """
  @spec publish(sidecar(), binary(), binary(), map()) ::
          {:ok, :aligned | :review | :corrected, sidecar()} | {:error, term()}
  def publish(sidecar, current, content, record) do
    with :ok <- verify_current(sidecar.sidecar_path, current),
         :ok <- Moviehash.verify(sidecar.video_path, record.moviehash) do
      if content == current,
        do: record_only(sidecar, record),
        else: correct(sidecar, current, content, record)
    end
  end

  defp record_only(sidecar, record) do
    with :ok <- put_record(sidecar, record),
         do: {:ok, recorded(record), %{sidecar | sync: record}}
  end

  defp correct(sidecar, current, content, record) do
    with {:ok, original} <- correction_source(sidecar, current, record),
         {:ok, backup_created?} <- Backup.ensure(sidecar, original) do
      begin(sidecar, current, content, record, backup_created?)
    end
  end

  defp recorded(%{status: "review"}), do: :review
  defp recorded(_record), do: :aligned

  defp correction_source(sidecar, current, record) do
    if sha256(current) == record.source_sha256,
      do: {:ok, current},
      else: Backup.read_original(sidecar.sidecar_path, record)
  end

  defp begin(sidecar, current, content, record, backup_created?) do
    pending =
      record
      |> Map.put(:status, "applying")
      |> Map.put(:expected_sha256, sha256(current))
      |> Map.put(:operation_id, operation_id())

    with :ok <- Moviehash.verify(sidecar.video_path, record.moviehash),
         :ok <- put_record(sidecar, pending) do
      exchange(sidecar, current, content, record, backup_created?, pending.operation_id)
    else
      {:error, reason} -> cleanup_unpublished(sidecar, backup_created?, reason)
    end
  end

  defp exchange(sidecar, current, content, record, backup_created?, operation_id) do
    case AtomicFile.write(sidecar.sidecar_path, content, current, operation_id) do
      :ok ->
        commit(sidecar, current, content, record, backup_created?, operation_id)

      {:error, {:publication_committed, _detail}} = committed ->
        committed

      {:error, reason} ->
        abort(sidecar, reason)
    end
  end

  defp commit(sidecar, current, content, record, backup_created?, operation_id) do
    with :ok <- Moviehash.verify(sidecar.video_path, record.moviehash),
         :ok <- put_record(sidecar, record) do
      _removed_or_kept = Workspace.retire(sidecar.sidecar_path, operation_id)
      {:ok, :corrected, %{sidecar | sync: record}}
    else
      {:error, reason} -> rollback(sidecar, current, content, backup_created?, reason)
    end
  end

  defp put_record(sidecar, record) do
    case Manifest.put_sync(sidecar.video_path, sidecar.language, record) do
      :ok -> :ok
      {:error, reason} -> {:error, {:manifest, reason}}
    end
  end

  defp abort(sidecar, reason) do
    case restore_previous_record(sidecar) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {:apply_abort_failed, reason, cleanup_reason}}
    end
  end

  defp cleanup_unpublished(sidecar, backup_created?, reason) do
    with :ok <- restore_previous_record(sidecar),
         :ok <- remove_created_backup(sidecar, backup_created?) do
      {:error, reason}
    else
      {:error, cleanup_reason} ->
        {:error, {:prepublication_cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp rollback(sidecar, previous, applied, backup_created?, failure) do
    with :ok <- exchange_back(sidecar, previous, applied),
         :ok <- restore_previous_record(sidecar),
         :ok <- remove_created_backup(sidecar, backup_created?) do
      {:error, failure}
    else
      {:error, rollback_reason} -> {:error, rollback_failure(failure, rollback_reason)}
    end
  end

  defp rollback_failure({:manifest, reason}, rollback_reason),
    do: {:manifest_and_rollback_failed, reason, rollback_reason}

  defp rollback_failure(reason, rollback_reason),
    do: {:correction_and_rollback_failed, reason, rollback_reason}

  defp exchange_back(sidecar, previous, applied) do
    case safe_read(sidecar.sidecar_path) do
      {:ok, ^applied} -> AtomicFile.write(sidecar.sidecar_path, previous, applied)
      {:ok, _changed} -> {:error, :concurrent_change}
      {:error, _reason} = error -> error
    end
  end

  defp restore_previous_record(%{sync: nil} = sidecar),
    do: Manifest.clear_sync(sidecar.video_path, sidecar.language)

  defp restore_previous_record(sidecar),
    do: Manifest.put_sync(sidecar.video_path, sidecar.language, sidecar.sync)

  defp remove_created_backup(sidecar, true), do: Backup.remove_created(sidecar)
  defp remove_created_backup(_sidecar, false), do: :ok

  defp verify_current(path, expected) do
    case safe_read(path) do
      {:ok, ^expected} -> :ok
      {:ok, _changed} -> {:error, :concurrent_change}
      {:error, _reason} = error -> error
    end
  end

  defp operation_id,
    do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  @doc """
  Marks the sidecar's final record for operator review without touching any bytes.
  """
  @spec hold_for_review(sidecar(), atom()) :: {:ok, sidecar()} | {:error, {:manifest, term()}}
  def hold_for_review(%{sync: %{}} = sidecar, reason) do
    record = %{sidecar.sync | status: "review", reason: Atom.to_string(reason)}

    with :ok <- put_record(sidecar, record), do: {:ok, %{sidecar | sync: record}}
  end

  @doc """
  Replaces a sidecar with newly fetched bytes and a new manifest track (`origin`, the bytes'
  hash). The previous final record is journaled in the same manifest write, then its immutable
  original is retired and the journal closed; a retirement that fails stays journaled for
  `reconcile/2`.

  The bytes are published through `AtomicFile.swap/3` from the sidecar the snapshot saw: an
  exchange if it existed, a create that never replaces anything if it did not. A sidecar that
  changed, appeared or vanished since the snapshot is left alone (`{:error, {:write, {:error,
  :concurrent_change}}}`). There is no pending record: a crash between the publication and the
  manifest write leaves bytes `recover/2` holds for review. If the manifest write fails, the
  sidecar is swapped back to what the snapshot saw, but only while it still holds the fetched
  bytes. A manifest that `Manifest.load/1` cannot read stops the replacement before it publishes
  anything.

  `{:error, {:write, error}}` and `{:error, {:manifest, error}}` carry the failing call's own
  return value.

  `source_track` is the index of the embedded track the bytes came from, recorded for origin
  `embedded` only.
  """
  @spec replace(sidecar(), iodata(), String.t(), String.t() | nil, non_neg_integer() | nil) ::
          :ok | {:error, {:write | :manifest, term()}}
  def replace(
        %{video_path: video_path, language: language} = sidecar,
        content,
        origin,
        moviehash,
        source_track \\ nil
      ) do
    content = IO.iodata_to_binary(content)

    # A manifest that cannot be read hides the previous record the new track must journal, so
    # nothing is published.
    case Manifest.load(video_path) do
      {:ok, state} ->
        previous_sync =
          Manifest.replacement_cleanup_sync(state, language) || Manifest.sync(state, language)

        publish_replacement(sidecar, content, origin, moviehash, source_track, previous_sync)

      error ->
        {:error, {:manifest, error}}
    end
  end

  defp publish_replacement(
         %{video_path: video_path, sidecar_path: target, language: language},
         content,
         origin,
         moviehash,
         source_track,
         previous_sync
       ) do
    with {:ok, previous} <- snapshot(target),
         :ok <- publish_fetched(target, previous, content) do
      case Manifest.put(
             video_path,
             moviehash,
             language,
             origin,
             target,
             sha256(content),
             previous_sync,
             source_track
           ) do
        :ok ->
          retire_replaced(video_path, language, target, previous_sync)

        error ->
          rollback_fetched(target, content, previous)
          {:error, {:manifest, error}}
      end
    else
      error -> {:error, {:write, error}}
    end
  end

  defp retire_replaced(_video_path, _language, _target, nil), do: :ok

  defp retire_replaced(video_path, language, target, previous_sync) do
    case Recovery.retire_replaced(video_path, language, target, previous_sync) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "subtitle replacement cleanup remains journaled for #{target}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # The sidecar's bytes, or `:absent`: what `AtomicFile.swap/3` publishes from.
  defp snapshot(target) do
    with {:ok, target} <- safe_destination(target) do
      case fs().read(target) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:ok, :absent}
        {:error, _reason} = error -> error
      end
    end
  end

  # The bytes are verified at the target even when a step after the publication went
  # unacknowledged, and no pending record waits for `recover/2`, so the track is recorded.
  defp publish_fetched(target, previous, content) do
    case AtomicFile.swap(target, previous, content) do
      {:error, {:publication_committed, detail}} ->
        Logger.warning("subtitle publication unacknowledged for #{target}: #{inspect(detail)}")
        :ok

      result ->
        result
    end
  end

  defp rollback_fetched(target, content, previous) do
    case AtomicFile.swap(target, content, previous) do
      :ok -> :ok
      {:error, {:publication_committed, _detail}} -> :ok
      error -> Logger.warning("subtitle rollback failed for #{target}: #{inspect(error)}")
    end
  end

  @doc """
  Removes a sidecar of origin `origin` that still holds `content`, then its language's manifest
  track.

  Nothing is removed when the manifest cannot be read (`Manifest.load/1`'s error), when it has no
  track for the language (`{:error, :unknown_track}`) or one of another origin
  (`{:error, {:origin, other}}`), or when the sidecar changed or vanished since the caller read
  `content` (`AtomicFile.swap/3`'s error). The bytes go before the track, so a failure in between
  never leaves a sidecar that no track claims. A track that holds a record of this module stays:
  a later sidecar in the language needs the backup tombstone it records and the cleanup journal
  it replays (`Manifest.delete_track/3` refuses to drop one). Any other error from
  `Manifest.delete_track/3` comes after the sidecar is gone.
  """
  @spec remove(sidecar(), binary(), String.t()) :: :ok | {:error, term()}
  def remove(%{video_path: video_path, sidecar_path: target, language: language}, content, origin) do
    with {:ok, state} <- Manifest.load(video_path),
         :ok <- owned(state, language, origin),
         :ok <- AtomicFile.swap(target, content, :absent) do
      forget(video_path, language, origin)
    end
  end

  defp owned(state, language, origin) do
    case state.tracks[language] do
      %{origin: ^origin} -> :ok
      %{origin: other} -> {:error, {:origin, other}}
      nil -> {:error, :unknown_track}
    end
  end

  defp forget(video_path, language, origin) do
    case Manifest.delete_track(video_path, language, origin) do
      {:error, {:transaction_records, _fields}} -> :ok
      result -> result
    end
  end
end
