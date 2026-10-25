defmodule Cinder.Subtitles.SidecarTransaction.AtomicFile do
  @moduledoc """
  Publishes subtitle bytes with a descriptor-bound exchange and verified rollback, or, for a
  target that does not exist yet, a rename that never replaces anything (`swap/3`).

  The target and staged inodes stay open across the exchange. Every observable race is classified
  before cleanup so a concurrent pathname replacement is restored instead of displaced.
  """

  require Logger

  import Cinder.Subtitles.SafeFile, only: [fs: 0, safe_destination: 1, safe_read: 1, sha256: 1]

  @operation_id ~r/\A[A-Za-z0-9_-]{22}\z/

  @spec write(String.t(), binary(), binary()) :: :ok | {:error, term()}
  def write(target, content, expected_current) do
    operation_id = reversal_operation_id(target, sha256(expected_current), sha256(content))
    do_write(target, content, expected_current, operation_id)
  end

  @spec write(String.t(), binary(), binary(), String.t()) :: :ok | {:error, term()}
  def write(target, content, expected_current, operation_id) when is_binary(operation_id) do
    if Regex.match?(@operation_id, operation_id),
      do: do_write(target, content, expected_current, operation_id),
      else: {:error, :invalid_operation_id}
  end

  defp do_write(target, content, expected_current, operation_id) do
    directory = workspace_path(target, operation_id)
    staged_path = Path.join(directory, ".cinder-subtitle-sync-write-staged")

    with {:ok, target} <- safe_destination(target),
         {:ok, directory} <- safe_destination(directory),
         {:ok, staged_path} <- safe_destination(staged_path) do
      authorized_write(target, directory, staged_path, content, expected_current, operation_id)
    end
  end

  defp authorized_write(target, directory, staged_path, content, expected_current, _operation_id) do
    create_authorized_workspace(target, directory, staged_path, content, expected_current)
  end

  defp create_authorized_workspace(target, directory, staged_path, content, expected_current) do
    case mkdir_workspace(directory, target) do
      :ok ->
        in_workspace(directory, fn ->
          atomic_operation(target, staged_path, content, expected_current, :discard)
        end)

      {:error, :eexist} ->
        reuse_authorized_workspace(target, directory, staged_path, content, expected_current)

      {:error, {:effect_committed, _operation, _detail}} = error ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  # Runs `operation` with the workspace directory held open. A publication's committed marker
  # becomes its result only here, after the staged and target descriptors closed, so a close
  # failure after the effect stays a committed publication (`finish_bound_operation/2`).
  defp in_workspace(directory, operation) do
    with_bound(directory, [:read, :raw, :binary], fn _directory_bound ->
      {:directory_bound_result, acknowledged(operation.())}
    end)
  end

  defp acknowledged({:committed, :ok}), do: :ok

  defp acknowledged({:committed_unacknowledged, reason}),
    do: {:error, {:publication_committed, reason}}

  defp acknowledged(result), do: result

  # On mergerfs the workspace lands on the anchor's backing branch, so the anchor must exist.
  defp mkdir_workspace(directory, anchor) do
    filesystem = fs()

    if function_exported?(filesystem, :mkdir_exclusive_near, 3),
      do: filesystem.mkdir_exclusive_near(directory, anchor, 0o700),
      else: filesystem.mkdir_exclusive(directory, 0o700)
  end

  @doc """
  Moves `target` from `from` to `to`, each its bytes or `:absent`, only if it still is `from`,
  then removes its workspace. This is the fetch side's publication: no pending record names it,
  so nothing would ever read the workspace again.

    * bytes to bytes is `write/4`'s exchange, except that the displaced inode is never emptied,
      only its workspace name removed: a fetch may displace a release sidecar, which is a
      hardlink into a download that may still be seeding.
    * `:absent` to bytes stages the bytes, then renames them onto a name nothing holds yet.
    * bytes to `:absent` renames the target into the workspace and removes it only if it held
      `from`; anything else is renamed back.
    * `from == to` only checks the target.

  `{:error, :concurrent_change}` means the target was not `from`, or something replaced it right
  after the move and `to` could not be read back there: whatever holds the name now is left
  alone.
  `{:error, {:publication_committed, detail}}` means the target holds `to`, but a step after the
  effect was not acknowledged. Any other error leaves whatever the workspace still holds there.
  """
  @spec swap(String.t(), binary() | :absent, binary() | :absent) :: :ok | {:error, term()}
  def swap(target, same, same) when is_binary(same), do: verify_unchanged(target, same)

  def swap(target, from, to) when from != :absent or to != :absent,
    do: swap_through_workspace(target, from, to)

  defp verify_unchanged(target, expected) do
    case safe_read(target) do
      {:ok, ^expected} -> :ok
      {:ok, _changed} -> {:error, :concurrent_change}
      {:error, :enoent} -> {:error, :concurrent_change}
      {:error, _reason} = error -> error
    end
  end

  defp swap_through_workspace(target, from, to) do
    operation_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    directory = workspace_path(target, operation_id)
    staged_path = Path.join(directory, ".cinder-subtitle-sync-write-staged")

    with {:ok, target} <- safe_destination(target),
         {:ok, directory} <- safe_destination(directory),
         {:ok, staged_path} <- safe_destination(staged_path),
         :ok <- mkdir_workspace(directory, swap_anchor(target, from)) do
      result = in_workspace(directory, fn -> swap_in_workspace(target, staged_path, from, to) end)
      remove_swap_workspace(directory)
      settle_unverified(result, target, to)
    end
  end

  # After the bytes moved, a target that could not be verified (`{:moved_unverified, _}`: every
  # open error reads as a changed identity) or a descriptor that failed to close hides whether
  # `to` was published. The target's bytes answer that; unreadable bytes count as unpublished.
  defp settle_unverified({:error, {:moved_unverified, reason}}, target, to),
    do: settle_by_target(reason, target, to)

  defp settle_unverified({:error, {:descriptor_close_failed, _} = reason}, target, to)
       when is_binary(to),
       do: settle_by_target(reason, target, to)

  defp settle_unverified(result, _target, _to), do: result

  defp settle_by_target(reason, target, to) do
    if safe_read(target) == {:ok, to},
      do: {:error, {:publication_committed, reason}},
      else: {:error, reason}
  end

  defp swap_anchor(target, :absent), do: Path.dirname(target)
  defp swap_anchor(target, _from), do: target

  defp swap_in_workspace(target, staged_path, :absent, to), do: create(target, staged_path, to)

  defp swap_in_workspace(target, staged_path, from, :absent),
    do: retract(target, staged_path, from)

  defp swap_in_workspace(target, staged_path, from, to) do
    result =
      with_bound(target, [:read, :raw, :binary], fn current ->
        with_created_bound(staged_path, to, fn staged ->
          perform_atomic_operation(target, staged_path, current, staged, from, to, :unlink)
        end)
      end)

    if result == {:error, :enoent}, do: {:error, :concurrent_change}, else: result
  end

  defp create(target, staged_path, content) do
    with_created_bound(staged_path, content, fn staged ->
      operation =
        with :ok <- File.chmod(staged.path, 0o644),
             do: rename_onto_absent(target, staged_path, staged, content)

      finish_atomic_operation(operation, :unlink, staged_path, staged)
    end)
  end

  defp rename_onto_absent(target, staged_path, staged, content) do
    case fs().rename_exclusive(staged_path, target) do
      :ok ->
        verify_created(target, staged_path, staged, content, nil)

      {:error, {:effect_committed, _operation, _detail} = reason} ->
        verify_created(target, staged_path, staged, content, reason)

      {:error, :eexist} ->
        {:not_exchanged, {:error, :concurrent_change}}

      {:error, _reason} = error ->
        {:not_exchanged, error}
    end
  end

  defp verify_created(target, staged_path, staged, content, committed_warning) do
    with :ok <- verify_bound_path(target, staged),
         {:ok, ^content} <- File.read(staged.path) do
      committed_result(committed_warning)
    else
      _unverified ->
        if verify_bound_path(staged_path, staged) == :ok,
          do: {:not_exchanged, {:error, :concurrent_change}},
          else: {:moved_unverified, :concurrent_change}
    end
  end

  defp retract(target, staged_path, expected) do
    case fs().rename_exclusive(target, staged_path) do
      :ok ->
        verify_retracted(target, staged_path, expected)

      {:error, {:effect_committed, _op, _detail}} ->
        verify_retracted(target, staged_path, expected)

      {:error, :enoent} ->
        {:error, :concurrent_change}

      {:error, _reason} = error ->
        error
    end
  end

  # Anything short of proving the retracted file held `expected` puts it back: the name is only
  # ever taken when nothing holds it, so trying the restore is always safe.
  defp verify_retracted(target, staged_path, expected) do
    case with_bound(staged_path, [:read, :raw, :binary], &retracted_identity(&1, expected)) do
      {:matches, identity} ->
        remove_workspace_name(staged_path, %{identity: identity})

      :changed ->
        restore_retracted(staged_path, target, :concurrent_change)

      {:error, reason} ->
        restore_retracted(staged_path, target, {:retract_unverified, reason})
    end
  end

  defp retracted_identity(retracted, expected) do
    case File.read(retracted.path) do
      {:ok, ^expected} -> {:matches, retracted.identity}
      {:ok, _changed} -> :changed
      {:error, _reason} = error -> error
    end
  end

  defp restore_retracted(staged_path, target, reason) do
    case fs().rename_exclusive(staged_path, target) do
      :ok -> {:error, reason}
      {:error, restore_reason} -> {:error, {:retract_restore_failed, reason, restore_reason}}
    end
  end

  # Removes the workspace's one name, but only while it still names the inode we hold (`bound` or
  # its `identity`). A name that stays only keeps the workspace from being removed, so failing
  # here is logged, not returned.
  defp remove_workspace_name(path, bound) do
    with :ok <- verify_bound_path(path, bound),
         :ok <- fs().rm(path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("subtitle workspace entry kept at #{path}: #{inspect(reason)}")
        :ok
    end
  end

  # `rmdir` refuses a workspace that still holds a name, so whatever a preserved exchange or an
  # unrestorable retraction left there stays, at the path the warning names.
  defp remove_swap_workspace(directory) do
    case fs().rmdir(directory) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("subtitle workspace kept at #{directory}: #{inspect(reason)}")
    end
  end

  @spec cleanup_pending(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def cleanup_pending(target, operation_id, expected_sha256, applied_sha256) do
    if is_binary(operation_id) and Regex.match?(@operation_id, operation_id) do
      cleanup_pending_workspace(target, operation_id, expected_sha256, applied_sha256)
    else
      {:error, :invalid_operation_id}
    end
  end

  @spec cleanup_reversal(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def cleanup_reversal(target, expected_sha256, content_sha256) do
    operation_id = reversal_operation_id(target, expected_sha256, content_sha256)
    cleanup_pending(target, operation_id, expected_sha256, content_sha256)
  end

  @spec recover(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def recover(target, operation_id, expected_sha256, applied_sha256) do
    with true <- is_binary(operation_id) and Regex.match?(@operation_id, operation_id),
         {:ok, target} <- safe_destination(target),
         {:ok, directory} <- safe_destination(workspace_path(target, operation_id)),
         {:ok, staged_path} <-
           safe_destination(Path.join(directory, ".cinder-subtitle-sync-write-staged")) do
      case recovery_data(target, directory, staged_path, expected_sha256, applied_sha256) do
        :ok -> :ok
        {:resume, expected, applied} -> write(target, applied, expected, operation_id)
        {:error, _reason} = error -> error
      end
    else
      false -> {:error, :invalid_operation_id}
      {:error, _reason} = error -> error
    end
  end

  defp recovery_data(target, directory, staged_path, expected_sha256, applied_sha256) do
    with_bound(target, [:read, :raw, :binary], fn target_bound ->
      with {:ok, target_content} <- File.read(target_bound.path) do
        recover_target_content(
          target_content,
          directory,
          staged_path,
          expected_sha256,
          applied_sha256
        )
      end
    end)
  end

  defp recover_target_content(target, directory, staged_path, expected, applied) do
    cond do
      sha256(target) == applied -> :ok
      sha256(target) == expected -> recover_pre_exchange(target, directory, staged_path, applied)
      true -> {:error, :pending_workspace_mismatch}
    end
  end

  defp recover_pre_exchange(target, directory, staged_path, applied) do
    with_bound(directory, [:read, :raw, :binary], fn _directory_bound ->
      recover_staged_content(target, staged_path, applied)
    end)
  end

  defp recover_staged_content(target, staged_path, applied) do
    with_bound(staged_path, [:read, :raw, :binary], fn staged ->
      verify_recovery_staged(target, staged, applied)
    end)
  end

  defp verify_recovery_staged(target, staged, applied) do
    case File.read(staged.path) do
      {:ok, content} ->
        if sha256(content) == applied,
          do: {:resume, target, content},
          else: {:error, :pending_workspace_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp cleanup_pending_workspace(target, operation_id, expected_sha256, applied_sha256) do
    directory = workspace_path(target, operation_id)
    staged_path = Path.join(directory, ".cinder-subtitle-sync-write-staged")

    with {:ok, target} <- safe_destination(target),
         {:ok, directory} <- safe_destination(directory),
         {:ok, staged_path} <- safe_destination(staged_path) do
      cleanup_authorized_workspace(
        target,
        directory,
        staged_path,
        expected_sha256,
        applied_sha256
      )
    end
  end

  defp cleanup_authorized_workspace(target, directory, staged_path, expected, applied) do
    case fs().open_bound(directory, [:read, :raw, :binary]) do
      {:ok, directory_bound} ->
        finish_bound(directory_bound, fn directory_bound ->
          cleanup_authorized_bound(
            target,
            directory_bound,
            staged_path,
            expected,
            applied
          )
        end)

      {:error, :enoent} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp cleanup_authorized_bound(target, directory, staged_path, expected, applied) do
    with_bound(target, [:read, :raw, :binary], fn target_bound ->
      cleanup_workspace_contents(target_bound, directory, staged_path, expected, applied)
    end)
  end

  defp cleanup_workspace_contents(target, directory, staged_path, expected, applied) do
    case File.read(target.path) do
      {:ok, target_content} ->
        if sha256(target_content) == applied do
          :ok
        else
          cleanup_target_content(target_content, directory, staged_path, expected, applied)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp cleanup_target_content(target, directory, staged_path, expected, applied) do
    result =
      with_bound(staged_path, [:read, :raw, :binary], fn staged ->
        cleanup_bound_workspace(target, directory, staged_path, staged, expected, applied)
      end)

    case result do
      {:error, :enoent} -> cleanup_empty_workspace(target, expected, applied)
      result -> result
    end
  end

  defp cleanup_bound_workspace(target, _directory, _staged_path, staged, expected, applied) do
    with {:ok, staged_content} <- File.read(staged.path),
         do: verify_pending_workspace(target, staged_content, expected, applied)
  end

  defp cleanup_empty_workspace(target, expected, applied) do
    target_hash = sha256(target)

    cond do
      expected != applied and target_hash == applied -> :ok
      target_hash in [expected, applied] -> {:error, :unowned_empty_workspace}
      true -> {:error, :pending_workspace_mismatch}
    end
  end

  # A completed reversal's displaced content is truncated to empty by `discard_bound` after
  # exchange (see `finalize_exchange`), leaving this exact directory and an empty staged file as
  # a tombstone — nothing was ever published from it beyond what the exchange already verified,
  # so it's never itself a conflict. Recognized only when the target still reads as the
  # pre-reversal `expected_sha256`: empty content alone must not authorize reuse of a workspace
  # whose target has moved to some other, unaccounted-for state.
  defp verify_pending_workspace(target, staged, expected_sha256, applied_sha256) do
    cond do
      {sha256(target), sha256(staged)} in [
        {expected_sha256, applied_sha256},
        {applied_sha256, expected_sha256}
      ] ->
        :ok

      staged == "" and sha256(target) == expected_sha256 ->
        :ok

      true ->
        {:error, :pending_workspace_mismatch}
    end
  end

  defp atomic_operation(target, staged_path, content, expected_current, disposal) do
    with_bound(target, [:read, :raw, :binary], fn current ->
      with_created_bound(staged_path, content, fn staged ->
        perform_atomic_operation(
          target,
          staged_path,
          current,
          staged,
          expected_current,
          content,
          disposal
        )
      end)
    end)
  end

  defp reuse_authorized_workspace(target, directory, staged_path, content, expected_current) do
    in_workspace(directory, fn ->
      with_bound(target, [:read, :raw, :binary], fn current ->
        reuse_bound_workspace(
          target,
          staged_path,
          current,
          content,
          expected_current,
          :discard
        )
      end)
    end)
  end

  defp reuse_bound_workspace(
         target,
         staged_path,
         current,
         content,
         expected_current,
         disposal
       ) do
    case File.read(current.path) do
      {:ok, ^content} ->
        :ok

      {:ok, ^expected_current} ->
        reuse_expected_workspace(
          target,
          staged_path,
          current,
          content,
          expected_current,
          disposal
        )

      {:ok, _other} ->
        {:error, :concurrent_change}

      {:error, _reason} = error ->
        error
    end
  end

  defp reuse_expected_workspace(
         target,
         staged_path,
         current,
         content,
         expected_current,
         disposal
       ) do
    with_bound(staged_path, [:read, :raw, :binary], fn staged ->
      reuse_expected_staged(
        target,
        staged_path,
        current,
        staged,
        content,
        expected_current,
        disposal
      )
    end)
  end

  defp reuse_expected_staged(
         target,
         staged_path,
         current,
         staged,
         content,
         expected_current,
         disposal
       ) do
    case File.read(staged.path) do
      {:ok, ^content} ->
        perform_atomic_operation(
          target,
          staged_path,
          current,
          staged,
          expected_current,
          content,
          disposal
        )

      {:ok, ""} ->
        reuse_reclaimed_workspace(
          target,
          staged_path,
          current,
          staged,
          content,
          expected_current,
          disposal
        )

      {:ok, _other} ->
        {:error, :pending_workspace_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  # An empty staged file beside a target that already reads as `expected_current` (the caller
  # only reaches here after confirming that) is a reclaimed tombstone from a completed reversal,
  # or a crash before any byte was ever staged — either way nothing was published from it, so
  # restaging `content` and retrying the exchange is safe. Any other content is left untouched:
  # it may be a genuinely interrupted, resumable write that must not be overwritten.
  #
  # `mkdir_exclusive`/`mkdir_exclusive_near` only prove Cinder created *this* directory when the
  # deterministic name was genuinely free; a same-named directory pre-planted by another actor
  # (predicting the id from target path + content hashes needs no secret) would still route here
  # on `:eexist`. Emptiness alone doesn't prove the staged file is Cinder's own reclaimed
  # tombstone rather than a hard link to a file outside the library tree, so a link count other
  # than 1 is refused exactly like unrecognized content — nothing here writes through a path
  # some other name might also resolve to.
  defp reuse_reclaimed_workspace(
         target,
         staged_path,
         current,
         staged,
         content,
         expected_current,
         disposal
       ) do
    # `staged.path` may be the bound descriptor's own `/proc/<pid>/fd/<n>` reference rather than
    # the plain pathname (see `Disk.create_bound/2`/`open_bound/2`): `File.stat/1` follows that
    # reference to the still-open inode's live metadata, tying the check to the exact descriptor
    # `staged` already holds rather than re-walking a pathname a concurrent rename could swap.
    case File.stat(staged.path) do
      {:ok, %{links: 1}} ->
        restage_reclaimed_workspace(
          target,
          staged_path,
          current,
          staged,
          content,
          expected_current,
          disposal
        )

      {:ok, _multiply_linked} ->
        {:error, :pending_workspace_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp restage_reclaimed_workspace(
         target,
         staged_path,
         current,
         staged,
         content,
         expected_current,
         disposal
       ) do
    case fs().write_bound(staged, content) do
      :ok ->
        perform_atomic_operation(
          target,
          staged_path,
          current,
          staged,
          expected_current,
          content,
          disposal
        )

      {:error, reason} ->
        {:error, {:reclaim_write_failed, reason}}
    end
  end

  defp perform_atomic_operation(
         target,
         staged_path,
         current,
         staged,
         expected_current,
         content,
         disposal
       ) do
    operation =
      with :ok <- File.chmod(staged.path, 0o644) do
        exchange_if_current(
          target,
          staged_path,
          current,
          staged,
          expected_current,
          content,
          disposal
        )
      end

    finish_atomic_operation(operation, disposal, staged_path, staged)
  end

  defp exchange_if_current(target, staged_path, current, staged, expected, content, disposal) do
    case File.read(current.path) do
      {:ok, ^expected} ->
        case fs().exchange(staged_path, target) do
          :ok ->
            finalize_exchange(target, staged_path, current, staged, expected, content, disposal)

          {:error, {:effect_committed, _operation, _detail} = reason} ->
            finalize_exchange(
              target,
              staged_path,
              current,
              staged,
              expected,
              content,
              disposal,
              reason
            )

          {:error, _reason} = error ->
            {:not_exchanged, error}
        end

      {:ok, _changed} ->
        {:not_exchanged, {:error, :concurrent_change}}

      {:error, _reason} = error ->
        {:not_exchanged, error}
    end
  end

  defp finalize_exchange(
         target,
         staged_path,
         current,
         staged,
         expected,
         content,
         disposal,
         committed_warning \\ nil
       ) do
    case verify_exchanged_files(target, staged_path, current, staged, expected, content) do
      :ok ->
        dispose_displaced(staged_path, current, disposal, committed_warning)

      {:error, :published_target_changed} ->
        preserve_published_external(staged_path, current, disposal)

      {:error, :displaced_target_changed} ->
        rollback_displaced_exchange(
          target,
          staged_path,
          staged,
          disposal,
          {:error, :concurrent_change}
        )

      {:error, :captured_target_changed} = error ->
        rollback_exchange(target, staged_path, current, staged, disposal, error)

      {:error, _reason} = error ->
        {:preserved, error}
    end
  end

  # `:discard` empties the displaced inode and keeps its name as the workspace tombstone that
  # pending records and deterministic reversals read. `:unlink` (`swap/3`) only removes the
  # displaced inode's workspace name: a fetch may displace a release sidecar, which is a hardlink
  # into a download that may still be seeding, so its bytes must survive under that other name.
  defp dispose_displaced(_staged_path, current, :discard, committed_warning) do
    case fs().discard_bound(current) do
      :ok ->
        committed_result(committed_warning)

      {:error, {:effect_committed, _operation, _detail} = reason} ->
        {:committed_unacknowledged, merge_committed_warnings(committed_warning, reason)}

      {:error, reason} ->
        {:committed_unacknowledged,
         merge_committed_warnings(committed_warning, {:discard_failed, reason})}
    end
  end

  defp dispose_displaced(staged_path, current, :unlink, committed_warning) do
    remove_workspace_name(staged_path, current)
    committed_result(committed_warning)
  end

  defp committed_result(nil), do: {:committed, :ok}
  defp committed_result(reason), do: {:committed_unacknowledged, reason}

  defp merge_committed_warnings(nil, reason), do: reason
  defp merge_committed_warnings(first, second), do: {first, second}

  defp verify_exchanged_files(target, staged_path, current, staged, expected, content) do
    case {verify_bound_path(target, staged), verify_bound_path(staged_path, current)} do
      {:ok, :ok} ->
        verify_exchanged_bytes(current, staged, expected, content)

      {:ok, {:error, :concurrent_change}} ->
        {:error, :displaced_target_changed}

      {{:error, :concurrent_change}, :ok} ->
        {:error, :published_target_changed}

      _ ->
        {:error, :concurrent_change}
    end
  end

  defp verify_exchanged_bytes(current, staged, expected, content) do
    with {:ok, published} <- File.read(staged.path),
         {:ok, captured} <- File.read(current.path),
         do: classify_exchanged_bytes(published, captured, content, expected),
         else: (_ -> {:error, :concurrent_change})
  end

  defp classify_exchanged_bytes(content, expected, content, expected), do: :ok

  defp classify_exchanged_bytes(_published, expected, _content, expected),
    do: {:error, :published_target_changed}

  defp classify_exchanged_bytes(content, _captured, content, _expected),
    do: {:error, :captured_target_changed}

  defp classify_exchanged_bytes(_published, _captured, _content, _expected),
    do: {:error, :concurrent_change}

  # The target lost our inode after the exchange, or could not be opened to tell: `swap/3`
  # settles which from the target's bytes.
  defp preserve_published_external(staged_path, current, :unlink) do
    remove_workspace_name(staged_path, current)
    {:moved_unverified, :concurrent_change}
  end

  defp preserve_published_external(_staged_path, current, :discard) do
    case fs().discard_bound(current) do
      :ok -> {:external_preserved, {:error, :concurrent_change}}
      {:error, reason} -> {:preserved, {:error, {:external_preservation_discard_failed, reason}}}
    end
  end

  defp rollback_displaced_exchange(target, staged_path, staged, _disposal, original_error) do
    with :ok <- verify_bound_path(target, staged),
         {:ok, displaced_identity} <- path_identity(staged_path),
         :ok <- fs().exchange(staged_path, target),
         :ok <- verify_path_identity(target, displaced_identity),
         :ok <- verify_bound_path(staged_path, staged),
         :ok <- fs().discard_bound(staged) do
      {:rolled_back, original_error}
    else
      {:error, reason} ->
        {:preserved, {:error, {:exchange_rollback_failed, original_error, reason}}}
    end
  end

  defp rollback_exchange(target, staged_path, current, staged, _disposal, original_error) do
    with :ok <- verify_bound_path(target, staged),
         :ok <- verify_bound_path(staged_path, current),
         :ok <- fs().exchange(staged_path, target),
         :ok <- verify_bound_path(target, current),
         :ok <- verify_bound_path(staged_path, staged),
         :ok <- fs().discard_bound(staged) do
      {:rolled_back, original_error}
    else
      {:error, reason} ->
        {:preserved, {:error, {:exchange_rollback_failed, original_error, reason}}}
    end
  end

  defp verify_bound_path(path, bound), do: verify_path_identity(path, bound.identity)

  defp verify_path_identity(path, expected_identity) do
    case path_identity(path) do
      {:ok, ^expected_identity} -> :ok
      _other -> {:error, :concurrent_change}
    end
  end

  defp path_identity(path) do
    with_bound(path, [:read, :raw, :binary], fn bound -> {:ok, bound.identity} end)
  end

  defp with_bound(path, modes, callback) do
    case fs().open_bound(path, modes) do
      {:ok, bound} -> finish_bound(bound, callback)
      {:error, _reason} = error -> error
    end
  end

  defp with_created_bound(path, content, callback) do
    case fs().create_bound(path, content) do
      {:ok, bound} -> finish_bound(bound, callback)
      {:error, _reason} = error -> error
    end
  end

  defp finish_bound(bound, callback) do
    operation =
      try do
        {:returned, callback.(bound)}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    close_result = fs().close_bound(bound)
    finish_bound_operation(operation, close_result)
  end

  defp finish_bound_operation({:returned, {:directory_bound_result, result}}, :ok),
    do: result

  defp finish_bound_operation(
         {:returned, {:directory_bound_result, :ok}},
         {:error, reason}
       ) do
    Logger.warning(
      "directory descriptor close failed after subtitle publication: #{inspect(reason)}"
    )

    :ok
  end

  defp finish_bound_operation(
         {:returned,
          {:directory_bound_result, {:error, {:publication_committed, _detail}} = committed}},
         {:error, reason}
       ) do
    Logger.warning(
      "directory descriptor close failed after unacknowledged subtitle publication: #{inspect(reason)}"
    )

    committed
  end

  defp finish_bound_operation(
         {:returned, {:directory_bound_result, {:error, operation_reason}}},
         {:error, close_reason}
       ),
       do: {:error, {:operation_and_descriptor_close_failed, operation_reason, close_reason}}

  defp finish_bound_operation({:returned, result}, :ok), do: result

  # The bytes are published, but the failed close leaves them unacknowledged: the caller gets
  # `{:publication_committed, _}`, so a correction keeps its pending record for
  # `SidecarTransaction.recover/2`.
  defp finish_bound_operation({:returned, {:committed, :ok}}, {:error, reason}) do
    Logger.warning(
      "descriptor close failed after committed subtitle publication: #{inspect(reason)}"
    )

    {:committed_unacknowledged, {:descriptor_close_failed, reason}}
  end

  defp finish_bound_operation(
         {:returned, {:committed_unacknowledged, committed_warning}},
         {:error, reason}
       ) do
    Logger.warning(
      "descriptor close failed after unacknowledged subtitle publication: #{inspect(reason)}"
    )

    {:committed_unacknowledged,
     merge_committed_warnings(committed_warning, {:descriptor_close_failed, reason})}
  end

  defp finish_bound_operation({:returned, _result}, {:error, reason}),
    do: {:error, {:descriptor_close_failed, reason}}

  defp finish_bound_operation({:raised, kind, reason, stacktrace}, _close_result),
    do: :erlang.raise(kind, reason, stacktrace)

  # A committed marker leaves the staged and target bounds as it is: `in_workspace/2` turns it
  # into the result once they closed.
  defp finish_atomic_operation({marker, _detail} = committed, _disposal, _staged_path, _identity)
       when marker in [:committed, :committed_unacknowledged],
       do: committed

  # A rolled-back exchange put our own staged inode back in the workspace, already emptied.
  defp finish_atomic_operation({:rolled_back, {:error, _reason} = error}, :unlink, path, staged) do
    remove_workspace_name(path, staged)
    error
  end

  defp finish_atomic_operation(
         {:rolled_back, {:error, _reason} = error},
         _disposal,
         _path,
         _identity
       ),
       do: error

  defp finish_atomic_operation(
         {:preserved, {:error, _reason} = error},
         _disposal,
         _path,
         _identity
       ),
       do: error

  defp finish_atomic_operation(
         {:external_preserved, {:error, _reason} = error},
         _disposal,
         _path,
         _identity
       ),
       do: error

  defp finish_atomic_operation({:moved_unverified, reason}, :unlink, _path, _identity),
    do: {:error, {:moved_unverified, reason}}

  defp finish_atomic_operation(
         {:not_exchanged, {:error, _reason} = error},
         :unlink,
         staged_path,
         staged
       ) do
    remove_workspace_name(staged_path, staged)
    error
  end

  defp finish_atomic_operation(
         {:not_exchanged, {:error, _reason} = error},
         _disposal,
         _path,
         staged
       ) do
    case fs().discard_bound(staged) do
      :ok -> error
      {:error, reason} -> {:error, {:atomic_discard_failed, error, reason}}
    end
  end

  defp finish_atomic_operation({:error, _reason} = error, disposal, path, staged),
    do: finish_atomic_operation({:not_exchanged, error}, disposal, path, staged)

  defp reversal_operation_id(target, expected_sha256, content_sha256) do
    :crypto.hash(:sha256, [target, 0, expected_sha256, 0, content_sha256])
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  defp workspace_path(target, nil),
    do: temporary(target, ".cinder-subtitle-sync-cas-", "")

  defp workspace_path(target, operation_id),
    do: Path.join(Path.dirname(target), ".cinder-subtitle-sync-cas-#{operation_id}")

  defp temporary(path, prefix, extension) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join(Path.dirname(path), "#{prefix}#{token}#{extension}")
  end
end
