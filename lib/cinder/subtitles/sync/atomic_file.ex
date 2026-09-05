defmodule Cinder.Subtitles.Sync.AtomicFile do
  @moduledoc """
  Publishes subtitle bytes with a descriptor-bound exchange and verified rollback.

  The target and staged inodes stay open across the exchange. Every observable race is classified
  before cleanup so a concurrent pathname replacement is restored instead of displaced.
  """

  require Logger

  alias Cinder.Library.PathPolicy
  alias Cinder.Settings

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
        with_bound(directory, [:read, :raw, :binary], fn directory_bound ->
          {:directory_bound_result,
           atomic_operation(target, staged_path, content, expected_current, directory_bound)}
        end)

      {:error, :eexist} ->
        reuse_authorized_workspace(target, directory, staged_path, content, expected_current)

      {:error, {:effect_committed, _operation, _detail}} = error ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp mkdir_workspace(directory, target) do
    filesystem = fs()

    if function_exported?(filesystem, :mkdir_exclusive_near, 3),
      do: filesystem.mkdir_exclusive_near(directory, target, 0o700),
      else: filesystem.mkdir_exclusive(directory, 0o700)
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

  defp atomic_operation(target, staged_path, content, expected_current, directory) do
    with_bound(target, [:read, :raw, :binary], fn current ->
      with_created_bound(staged_path, content, fn staged ->
        perform_atomic_operation(
          target,
          staged_path,
          current,
          staged,
          expected_current,
          content,
          directory
        )
      end)
    end)
  end

  defp reuse_authorized_workspace(target, directory, staged_path, content, expected_current) do
    with_bound(directory, [:read, :raw, :binary], fn directory_bound ->
      {:directory_bound_result,
       with_bound(target, [:read, :raw, :binary], fn current ->
         reuse_bound_workspace(
           target,
           staged_path,
           current,
           content,
           expected_current,
           directory_bound
         )
       end)}
    end)
  end

  defp reuse_bound_workspace(
         target,
         staged_path,
         current,
         content,
         expected_current,
         directory
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
          directory
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
         directory
       ) do
    with_bound(staged_path, [:read, :raw, :binary], fn staged ->
      reuse_expected_staged(
        target,
        staged_path,
        current,
        staged,
        content,
        expected_current,
        directory
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
         directory
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
          directory
        )

      {:ok, ""} ->
        reuse_reclaimed_workspace(
          target,
          staged_path,
          current,
          staged,
          content,
          expected_current,
          directory
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
         directory
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
          directory
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
         directory
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
          directory
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
         directory
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
          directory
        )
      end

    finish_atomic_operation(operation, directory, staged_path, staged)
  end

  defp exchange_if_current(target, staged_path, current, staged, expected, content, directory) do
    case File.read(current.path) do
      {:ok, ^expected} ->
        case fs().exchange(staged_path, target) do
          :ok ->
            finalize_exchange(target, staged_path, current, staged, expected, content, directory)

          {:error, {:effect_committed, _operation, _detail} = reason} ->
            finalize_exchange(
              target,
              staged_path,
              current,
              staged,
              expected,
              content,
              directory,
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
         directory,
         committed_warning \\ nil
       ) do
    case verify_exchanged_files(target, staged_path, current, staged, expected, content) do
      :ok ->
        case fs().discard_bound(current) do
          :ok ->
            committed_result(committed_warning)

          {:error, {:effect_committed, _operation, _detail} = reason} ->
            {:committed_unacknowledged, merge_committed_warnings(committed_warning, reason)}

          {:error, reason} ->
            {:committed_unacknowledged,
             merge_committed_warnings(committed_warning, {:discard_failed, reason})}
        end

      {:error, :published_target_changed} ->
        preserve_published_external(staged_path, current, directory)

      {:error, :displaced_target_changed} ->
        rollback_displaced_exchange(
          target,
          staged_path,
          staged,
          directory,
          {:error, :concurrent_change}
        )

      {:error, :captured_target_changed} = error ->
        rollback_exchange(target, staged_path, current, staged, directory, error)

      {:error, _reason} = error ->
        {:preserved, error}
    end
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

  defp preserve_published_external(_staged_path, current, _directory) do
    case fs().discard_bound(current) do
      :ok -> {:external_preserved, {:error, :concurrent_change}}
      {:error, reason} -> {:preserved, {:error, {:external_preservation_discard_failed, reason}}}
    end
  end

  defp rollback_displaced_exchange(target, staged_path, staged, _directory, original_error) do
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

  defp rollback_exchange(target, staged_path, current, staged, _directory, original_error) do
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

  defp finish_bound_operation({:returned, {:committed, _result} = committed}, {:error, reason}) do
    Logger.warning(
      "descriptor close failed after committed subtitle publication: #{inspect(reason)}"
    )

    committed
  end

  defp finish_bound_operation(
         {:returned, {:committed_unacknowledged, _reason} = committed},
         {:error, reason}
       ) do
    Logger.warning(
      "descriptor close failed after unacknowledged subtitle publication: #{inspect(reason)}"
    )

    committed
  end

  defp finish_bound_operation({:returned, _result}, {:error, reason}),
    do: {:error, {:descriptor_close_failed, reason}}

  defp finish_bound_operation({:raised, kind, reason, stacktrace}, _close_result),
    do: :erlang.raise(kind, reason, stacktrace)

  defp finish_atomic_operation({:committed, :ok}, _directory, _staged_path, _identity),
    do: :ok

  defp finish_atomic_operation(
         {:committed_unacknowledged, reason},
         _directory,
         _staged_path,
         _identity
       ),
       do: {:error, {:publication_committed, reason}}

  defp finish_atomic_operation(
         {:rolled_back, {:error, _reason} = error},
         _directory,
         _path,
         _identity
       ),
       do: error

  defp finish_atomic_operation(
         {:preserved, {:error, _reason} = error},
         _directory,
         _path,
         _identity
       ),
       do: error

  defp finish_atomic_operation(
         {:external_preserved, {:error, _reason} = error},
         _directory,
         _path,
         _identity
       ),
       do: error

  defp finish_atomic_operation(
         {:not_exchanged, {:error, _reason} = error},
         _directory,
         _path,
         staged
       ) do
    case fs().discard_bound(staged) do
      :ok -> error
      {:error, reason} -> {:error, {:atomic_discard_failed, error, reason}}
    end
  end

  defp finish_atomic_operation({:error, _reason} = error, directory, path, staged),
    do: finish_atomic_operation({:not_exchanged, error}, directory, path, staged)

  defp safe_destination(path),
    do: path_policy().destination(path, Settings.video_library_roots(), filesystem: fs())

  defp reversal_operation_id(target, expected_sha256, content_sha256) do
    :crypto.hash(:sha256, [target, 0, expected_sha256, 0, content_sha256])
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  defp workspace_path(target, nil),
    do: temporary(target, ".cinder-subtitle-sync-cas-", "")

  defp workspace_path(target, operation_id),
    do: Path.join(Path.dirname(target), ".cinder-subtitle-sync-cas-#{operation_id}")

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp temporary(path, prefix, extension) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join(Path.dirname(path), "#{prefix}#{token}#{extension}")
  end

  defp fs,
    do: Application.get_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)

  defp path_policy,
    do: Application.get_env(:cinder, :path_policy, PathPolicy)
end
