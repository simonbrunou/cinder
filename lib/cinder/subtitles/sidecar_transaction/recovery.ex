defmodule Cinder.Subtitles.SidecarTransaction.Recovery do
  @moduledoc false
  # Everything that finishes or undoes a sidecar replacement transaction a crash or a changed
  # file left behind: cleanup journals, pending records, stale immutable originals, resets.

  alias Cinder.Subtitles.{Manifest, Moviehash}
  alias Cinder.Subtitles.SidecarTransaction.{AtomicFile, Backup}
  alias Cinder.Subtitles.Sync.Timing

  import Cinder.Subtitles.SafeFile,
    only: [safe_read: 1, sha256: 1, file_sha256: 1, regular_file?: 1]

  @spec reconcile(String.t(), String.t()) :: :ok | {:error, term()}
  def reconcile(video_path, moviehash) do
    with :ok <- reduce_tracks(video_path, &reconcile_reset(&1, video_path, moviehash)),
         do: reduce_tracks(video_path, &reconcile_replacement(&1, video_path))
  end

  defp reduce_tracks(video_path, reconcile) do
    video_path
    |> Manifest.read()
    |> Map.fetch!(:tracks)
    |> Enum.reduce_while(:ok, fn track, :ok -> reconcile.(track) end)
  end

  defp reconcile_reset({_language, %{reset_cleanup_sync_invalid?: true}}, _video_path, _hash),
    do: {:halt, {:error, :invalid_reset_cleanup_journal}}

  defp reconcile_reset({language, %{file: file, reset_cleanup_sync: sync}}, video_path, hash) do
    if sync.moviehash == hash do
      item = %{
        video_path: video_path,
        sidecar_path: Path.join(Path.dirname(video_path), file),
        language: language,
        sync: sync,
        reset_cleanup_sync: sync
      }

      case complete_reset(item, sync) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:reset_cleanup_failed, reason}}}
      end
    else
      {:halt, {:error, :reset_video_changed}}
    end
  end

  defp reconcile_reset({_language, %{reset_cleanup_sync: _sync}}, _video_path, _hash),
    do: {:halt, {:error, :invalid_reset_cleanup_journal}}

  defp reconcile_reset({_language, _track}, _video_path, _hash), do: {:cont, :ok}

  defp reconcile_replacement({_language, %{replacement_cleanup_sync_invalid?: true}}, _video),
    do: {:halt, {:error, :invalid_replacement_cleanup_journal}}

  defp reconcile_replacement({language, %{file: file, replacement_cleanup_sync: sync}}, video) do
    case retire_replaced(video, language, Path.join(Path.dirname(video), file), sync) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:replacement_cleanup_failed, reason}}}
    end
  end

  defp reconcile_replacement({_language, _track}, _video_path), do: {:cont, :ok}

  @doc """
  The last two steps of a replacement whose cleanup journal is open: retire the backup the
  journaled record proves, then close the journal.
  """
  @spec retire_replaced(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def retire_replaced(video_path, language, sidecar_path, sync) do
    with :ok <- Backup.discard(video_path, language, sidecar_path, sync),
         do: Manifest.clear_replacement_cleanup(video_path, language)
  end

  @spec recover(map(), String.t()) :: {:ok, map()} | {:review, atom(), map()}
  def recover(%{sync: nil} = item, _moviehash) do
    case file_sha256(item.sidecar_path) do
      {:ok, current_hash} when current_hash == item.managed_sha256 ->
        proof = %{source_sha256: item.managed_sha256}

        case Backup.discard(item.video_path, item.language, item.sidecar_path, proof) do
          :ok -> {:ok, item}
          {:error, _reason} -> block_cleanup(item)
        end

      {:ok, _other_hash} ->
        {:review, :externally_modified, item}

      {:error, _reason} ->
        block_cleanup(item)
    end
  end

  def recover(item, moviehash) do
    case reconcile_reversal(item) do
      :ok -> recover_reconciled(item, moviehash)
      {:error, _reason} -> {:review, :apply_recovery_failed, item}
    end
  end

  defp recover_reconciled(item, moviehash) do
    case file_sha256(item.sidecar_path) do
      {:ok, current_hash} -> recover(item, moviehash, current_hash)
      {:error, _reason} -> block_cleanup(item)
    end
  end

  defp recover(item, moviehash, current_hash) do
    cond do
      item.sync.status == "applying" and item.sync.moviehash == moviehash ->
        recover_pending(item, current_hash)

      item.sync.moviehash == moviehash and current_hash == item.sync.applied_sha256 ->
        {:ok, item}

      current_hash == item.sync.source_sha256 ->
        clean_replacement(item, current_hash)

      item.sync.moviehash == moviehash ->
        {:review, :externally_modified, item}

      current_hash in [item.sync.source_sha256, item.sync.applied_sha256] ->
        clean_replacement(item, current_hash)

      true ->
        {:review, :externally_modified, item}
    end
  end

  defp recover_pending(item, current_hash) do
    cond do
      current_hash == item.sync.applied_sha256 -> finalize(item)
      item.sync.method == "manual" and current_hash == item.sync.expected_sha256 -> replay(item)
      current_hash == item.sync.expected_sha256 -> resume_staged(item)
      true -> {:review, :externally_modified, item}
    end
  end

  # A manual correction is a pure function of the immutable original, so one interrupted before
  # its staged bytes existed is recomputed from the pending record's own offset and rate. The
  # result is published only if it is exactly the bytes the record promised.
  defp replay(item) do
    sync = item.sync

    with :ok <- Backup.verify_present(item.sidecar_path, sync),
         {:ok, current} <- safe_read(item.sidecar_path),
         true <- sha256(current) == sync.expected_sha256,
         {:ok, source} <- safe_read(Backup.path(item.sidecar_path)),
         {:ok, adjusted} <-
           Timing.retime(source, Path.extname(item.sidecar_path), sync.offset_ms, sync.rate),
         true <- sha256(adjusted) == sync.applied_sha256,
         :ok <- Moviehash.verify(item.video_path, sync.moviehash),
         :ok <- AtomicFile.write(item.sidecar_path, adjusted, current, sync.operation_id),
         :ok <- Moviehash.verify(item.video_path, sync.moviehash) do
      finalize(item)
    else
      _ -> {:review, :apply_recovery_failed, item}
    end
  end

  defp resume_staged(item) do
    sync = item.sync

    with :ok <- Backup.verify_present(item.sidecar_path, sync),
         :ok <-
           AtomicFile.recover(
             item.sidecar_path,
             sync.operation_id,
             sync.expected_sha256,
             sync.applied_sha256
           ),
         :ok <- Moviehash.verify(item.video_path, sync.moviehash) do
      finalize(item)
    else
      {:error, _reason} -> {:review, :apply_recovery_failed, item}
    end
  end

  defp finalize(item) do
    sync = item.sync

    record =
      sync
      |> Map.delete(:expected_sha256)
      |> Map.delete(:operation_id)
      |> Map.put(:status, "aligned")

    with :ok <- Backup.verify_present(item.sidecar_path, sync),
         :ok <-
           AtomicFile.cleanup_pending(
             item.sidecar_path,
             sync.operation_id,
             sync.expected_sha256,
             sync.applied_sha256
           ),
         :ok <- Manifest.put_sync(item.video_path, item.language, record) do
      {:ok, %{item | sync: record}}
    else
      {:error, _reason} -> {:review, :apply_recovery_failed, item}
    end
  end

  defp clean_replacement(item, current_hash) do
    with :ok <- restore_applied_original(item, current_hash),
         :ok <- Manifest.begin_replacement_cleanup(item.video_path, item.language, item.sync) do
      cleaned = %{item | sync: nil}

      case retire_replaced(item.video_path, item.language, item.sidecar_path, item.sync) do
        :ok -> {:ok, cleaned}
        {:error, _reason} -> block_cleanup(cleaned)
      end
    else
      {:error, _reason} -> block_cleanup(item)
    end
  end

  defp restore_applied_original(item, current_hash) do
    cond do
      current_hash != item.sync.applied_sha256 ->
        :ok

      item.sync.source_sha256 == item.sync.applied_sha256 ->
        :ok

      not regular_file?(Backup.path(item.sidecar_path)) ->
        {:error, :missing_backup}

      true ->
        with {:ok, current} <- safe_read(item.sidecar_path),
             {:ok, original} <- Backup.read_original(item.sidecar_path, item.sync),
             do: AtomicFile.write(item.sidecar_path, original, current)
    end
  end

  defp block_cleanup(item), do: {:review, :replacement_cleanup_failed, item}

  @spec restore_original(map(), String.t()) :: :ok | {:error, term()}
  def restore_original(%{reset_cleanup_sync: %{moviehash: moviehash} = sync} = item, moviehash),
    do: complete_reset(item, sync)

  def restore_original(%{reset_cleanup_sync: %{}}, _moviehash),
    do: {:error, :reset_video_changed}

  def restore_original(item, moviehash) do
    case recover(item, moviehash) do
      {:ok, %{sync: nil}} ->
        :ok

      {:ok, item} ->
        with :ok <- Manifest.begin_reset_cleanup(item.video_path, item.language, item.sync),
             do: complete_reset(%{item | reset_cleanup_sync: item.sync}, item.sync)

      {:review, reason, _item} ->
        {:error, reason}
    end
  end

  defp complete_reset(item, sync) do
    with :ok <- reconcile_reversal(%{item | sync: sync}),
         :ok <- restore_for_reset(item, sync),
         :ok <- Backup.retire_after_reset(item.video_path, item.language, item.sidecar_path, sync),
         do: Manifest.finish_reset_cleanup(item.video_path, item.language)
  end

  defp restore_for_reset(item, sync) do
    with {:ok, current} <- safe_read(item.sidecar_path),
         do: restore_current(item, sync, current, sha256(current))
  end

  defp restore_current(_item, %{source_sha256: source}, _current, source), do: :ok

  defp restore_current(
         item,
         %{source_sha256: source, applied_sha256: applied} = sync,
         current,
         applied
       )
       when source != applied do
    if regular_file?(Backup.path(item.sidecar_path)) do
      with {:ok, original} <- Backup.read_original(item.sidecar_path, sync),
           do: AtomicFile.write(item.sidecar_path, original, current)
    else
      {:error, :missing_backup}
    end
  end

  defp restore_current(_item, _sync, _current, _hash), do: {:error, :concurrent_change}

  # A completed reversal (a reset or rollback) leaves a deterministic workspace beside the
  # sidecar; it must be reconciled before any later write reuses that name.
  defp reconcile_reversal(%{
         sidecar_path: sidecar_path,
         sync: %{status: "applying", applied_sha256: expected, expected_sha256: content}
       })
       when expected != content,
       do: AtomicFile.cleanup_reversal(sidecar_path, expected, content)

  defp reconcile_reversal(%{
         sidecar_path: sidecar_path,
         sync: %{applied_sha256: expected, source_sha256: content}
       })
       when expected != content,
       do: AtomicFile.cleanup_reversal(sidecar_path, expected, content)

  defp reconcile_reversal(_item), do: :ok
end
