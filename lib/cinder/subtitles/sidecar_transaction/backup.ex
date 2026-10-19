defmodule Cinder.Subtitles.SidecarTransaction.Backup do
  @moduledoc false
  # The immutable original beside a corrected sidecar: exclusive creation, verification of an
  # existing original, guarded reactivation of a backup tombstone (a retired, zero-byte
  # container), and retirement back to a tombstone once a proof says the bytes are ours.

  alias Cinder.Library.Filesystem
  alias Cinder.Subtitles.{Manifest, SafeFile}

  import SafeFile, only: [fs: 0, safe_destination: 1, safe_read: 1, sha256: 1, regular_file?: 1]

  @doc "Hidden original adjacent to a corrected sidecar."
  @spec path(String.t()) :: String.t()
  def path(sidecar_path) do
    Path.join(
      Path.dirname(sidecar_path),
      ".#{Path.basename(sidecar_path)}.cinder-sync-original"
    )
  end

  @doc """
  Whether the backup path holds anything but a tombstone: an immutable original, a file Cinder
  cannot prove is its own, or a path PathPolicy refuses.
  """
  @spec active?(String.t()) :: boolean()
  def active?(path) do
    case safe_destination(path) do
      {:ok, path} ->
        case fs().lstat(path) do
          {:ok, %File.Stat{type: :regular, size: 0}} -> false
          {:error, :enoent} -> false
          _other -> true
        end

      {:error, _reason} ->
        true
    end
  end

  @doc "Whether a final record names an original distinct from its applied bytes."
  @spec immutable_expected?(map() | nil) :: boolean()
  def immutable_expected?(%{source_sha256: source, applied_sha256: applied})
      when is_binary(source) and byte_size(source) == 64 and is_binary(applied) and
             byte_size(applied) == 64,
      do: source != applied

  def immutable_expected?(_sync), do: false

  @doc """
  Ensures the backup container holds `expected_source`.

  Returns `{:ok, created?}` where `created?` says whether this call created the
  container, so the caller knows whether to remove it when rolling back.
  """
  @spec ensure(map(), binary()) :: {:ok, boolean()} | {:error, term()}
  def ensure(item, expected_source) do
    backup = path(item.sidecar_path)

    with {:ok, backup} <- safe_destination(backup) do
      create_or_verify(backup, expected_source, item)
    end
  end

  @doc "Reads the immutable original and proves it is the one `sync` names."
  @spec read_original(String.t(), map() | nil) :: {:ok, binary()} | {:error, term()}
  def read_original(sidecar_path, sync) do
    with {:ok, original} <- safe_read(path(sidecar_path)),
         :ok <- verify_provenance(sync, original),
         do: {:ok, original}
  end

  @doc "Proves the immutable original is present and is the one `sync` names."
  @spec verify_present(String.t(), map()) :: :ok | {:error, term()}
  def verify_present(sidecar_path, sync) do
    if regular_file?(path(sidecar_path)) do
      with {:ok, _original} <- read_original(sidecar_path, sync), do: :ok
    else
      {:error, :missing_backup}
    end
  end

  @spec verify_provenance(map() | nil, binary()) :: :ok | {:error, term()}
  def verify_provenance(%{source_sha256: expected}, source) do
    if sha256(source) == expected, do: :ok, else: {:error, :backup_mismatch}
  end

  def verify_provenance(nil, _source), do: {:error, :unexpected_backup}

  @doc """
  Retires a sidecar's backup after its bytes stopped being the sidecar's original (a new
  download, a reset, a video replaced at the same path). `sync` is the proof: the record whose
  `source_sha256` the backup must hold. No active backup is already done.
  """
  @spec discard(String.t(), String.t(), String.t(), map() | nil) :: :ok | {:error, term()}
  def discard(video_path, language, sidecar_path, sync) do
    backup = path(sidecar_path)
    tombstone = Manifest.backup_tombstone(Manifest.read(video_path), language)

    cond do
      not active?(backup) -> :ok
      is_nil(sync) -> {:error, :unexpected_backup}
      regular_file?(backup) -> retire(backup, sync, tombstone)
      true -> {:error, :unexpected_backup}
    end
  end

  @doc "Retires a reset's backup: the original it restored, or a proven duplicate (#347)."
  @spec retire_after_reset(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def retire_after_reset(video_path, language, sidecar_path, sync) do
    backup = path(sidecar_path)
    tombstone = Manifest.backup_tombstone(Manifest.read(video_path), language)

    cond do
      immutable_expected?(sync) -> retire(backup, sync, tombstone)
      regular_file?(backup) and is_map(tombstone) -> retire(backup, sync, tombstone)
      regular_file?(backup) -> {:error, :unexpected_backup}
      true -> :ok
    end
  end

  @doc "Retires a backup this correction created, proven by the sidecar's current bytes."
  @spec remove_created(map()) :: :ok | {:error, term()}
  def remove_created(item) do
    tombstone = Manifest.backup_tombstone(Manifest.read(item.video_path), item.language)

    with {:ok, current} <- safe_read(item.sidecar_path),
         do: retire(path(item.sidecar_path), %{source_sha256: sha256(current)}, tombstone)
  end

  defp with_bound(path, modes, callback) do
    case fs().open_bound(path, modes) do
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

    case {operation, fs().close_bound(bound)} do
      {{:returned, result}, :ok} -> result
      {{:returned, _result}, {:error, reason}} -> {:error, {:descriptor_close_failed, reason}}
      {{:raised, kind, reason, stacktrace}, _close} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp retire(backup, sync, %{identity: identity})
       when is_list(identity) and length(identity) == 3 do
    expected_identity = List.to_tuple(identity)

    with_bound(backup, [:read, :raw, :binary], fn bound ->
      with true <- Filesystem.identity?(bound, expected_identity) || {:error, :unexpected_backup},
           {:ok, content} <- File.read(bound.path),
           :ok <- retire_content(bound, content, sync) do
        verify_bound_identity(backup, bound.identity)
      end
    end)
  end

  defp retire(_backup, _sync, _tombstone), do: {:error, :missing_backup_tombstone}

  defp retire_content(_bound, "", _sync), do: :ok

  defp retire_content(bound, content, sync) do
    with :ok <- verify_provenance(sync, content) do
      case fs().discard_bound(bound) do
        :ok -> verify_discarded(bound)
        {:error, {:effect_committed, _operation, _reason}} -> verify_discarded(bound)
        {:error, _reason} = error -> error
      end
    end
  end

  defp verify_discarded(bound) do
    case File.read(bound.path) do
      {:ok, ""} -> :ok
      {:ok, _other} -> {:error, :backup_retirement_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp verify_bound_identity(path, expected_identity) do
    with_bound(path, [:read, :raw, :binary], fn rebound ->
      if rebound.identity == expected_identity, do: :ok, else: {:error, :concurrent_change}
    end)
  end

  defp create_or_verify(backup, expected_source, item) do
    case fs().create_bound(backup, expected_source) do
      {:ok, bound} ->
        register_created(item, bound)

      {:error, :eexist} ->
        existing(backup, expected_source, item)

      # A mergerfs logical path whose containers span backing branches fails
      # exclusive creation with a post-effect EEXIST instead of a plain :eexist,
      # so the reactivation path below was unreachable and the track stayed
      # failed until an operator deleted the duplicates by hand. Reconcile the
      # duplicates only when they are proven owned zero-byte tombstones, then
      # take the same guarded reactivation path.
      # Two producers reach here: check_logical_absence, which observes
      # duplicates without creating anything, and wait_for_unique_path, which
      # leaks a fresh zero-byte container. Reconciliation handles both -- the
      # leak simply becomes one more proven duplicate.
      {:error, {:effect_committed, _operation, %{"reason" => "EEXIST"}}} = error ->
        reconcile_duplicates(backup, expected_source, item, error)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing(backup, expected_source, item) do
    cond do
      immutable_expected?(item.sync) ->
        verify_existing(backup, expected_source)

      Map.has_key?(item, :backup_tombstone) and is_map(item.backup_tombstone) ->
        reactivate_container(backup, expected_source, item.backup_tombstone, item)

      true ->
        {:error, :unexpected_backup}
    end
  end

  defp reconcile_duplicates(
         backup,
         expected_source,
         %{backup_tombstone: %{identity: identity}} = item,
         error
       )
       when is_list(identity) and length(identity) == 3 do
    case reconcile_duplicate_containers(backup, List.to_tuple(identity)) do
      :ok -> existing(backup, expected_source, item)
      {:error, :unsupported_filesystem} -> error
      {:error, _reason} = refused -> refused
    end
  end

  # Without a recorded tombstone nothing proves the duplicates are ours, so
  # surface the original post-effect error rather than minting a new atom.
  defp reconcile_duplicates(_backup, _expected_source, _item, error), do: error

  # Only the rooted disk implementation can prove and remove duplicate backing
  # containers; any other filesystem stays fail-closed.
  defp reconcile_duplicate_containers(backup, identity) do
    filesystem = fs()

    # Code.ensure_loaded? matters: under interactive mix the module may not be
    # loaded yet, and a bare function_exported? would silently fail-closed.
    if Code.ensure_loaded?(filesystem) and
         function_exported?(filesystem, :reconcile_duplicate_containers, 2),
       do: filesystem.reconcile_duplicate_containers(backup, identity),
       else: {:error, :unsupported_filesystem}
  end

  defp register_created(item, bound) do
    manifest_result =
      Manifest.put_backup_tombstone(item.video_path, item.language, bound.identity)

    close_result = fs().close_bound(bound)

    case {manifest_result, close_result} do
      {:ok, :ok} -> {:ok, true}
      {{:error, reason}, _close} -> {:error, {:backup_provenance_manifest_failed, reason}}
      {:ok, {:error, reason}} -> {:error, {:backup_descriptor_close_failed, reason}}
    end
  end

  defp reactivate_container(backup, expected_source, %{identity: identity}, item)
       when is_list(identity) and length(identity) == 3 do
    expected_identity = List.to_tuple(identity)

    with_bound(backup, [:read, :raw, :binary], fn bound ->
      with true <- Filesystem.identity?(bound, expected_identity) || {:error, :unexpected_backup},
           {:ok, current} <- File.read(bound.path),
           :ok <- reactivate_bytes(bound, current, expected_source),
           :ok <- Manifest.put_backup_tombstone(item.video_path, item.language, bound.identity),
           :ok <- verify_bound_identity(backup, bound.identity) do
        {:ok, true}
      end
    end)
  end

  defp reactivate_container(_backup, _expected_source, _tombstone, _item),
    do: {:error, :invalid_backup_tombstone}

  defp reactivate_bytes(_bound, expected_source, expected_source), do: :ok

  defp reactivate_bytes(bound, "", expected_source),
    do: fs().write_bound(bound, expected_source)

  defp reactivate_bytes(_bound, _current, _expected), do: {:error, :backup_mismatch}

  defp verify_existing(backup, expected_source) do
    case safe_read(backup) do
      {:ok, ^expected_source} -> {:ok, false}
      {:ok, _other} -> {:error, :backup_mismatch}
      {:error, _reason} = error -> error
    end
  end
end
