defmodule Cinder.Subtitles.Sync.Backup do
  @moduledoc false
  # Acquisition of the hidden original that backs a correction: exclusive
  # creation, verification of an existing backup, and the guarded reactivation
  # of a retired (zero-byte) tombstone container. Retirement and restoration
  # stay in `Cinder.Subtitles.Sync`.

  alias Cinder.Library.Filesystem
  alias Cinder.Subtitles.{Manifest, Sync}

  @doc """
  Ensures the backup container holds `expected_source`.

  Returns `{:ok, created?}` where `created?` says whether this call created the
  container, so the caller knows whether to remove it when rolling back.
  """
  @spec ensure(map(), binary()) :: {:ok, boolean()} | {:error, term()}
  def ensure(item, expected_source) do
    backup = Sync.backup_path(item.sidecar_path)

    with {:ok, backup} <- Sync.safe_destination(backup) do
      create_or_verify(backup, expected_source, item)
    end
  end

  defp create_or_verify(backup, expected_source, item) do
    case Sync.fs().create_bound(backup, expected_source) do
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
      Sync.immutable_backup_expected?(item.sync) ->
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
    filesystem = Sync.fs()

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

    close_result = Sync.fs().close_bound(bound)

    case {manifest_result, close_result} do
      {:ok, :ok} -> {:ok, true}
      {{:error, reason}, _close} -> {:error, {:backup_provenance_manifest_failed, reason}}
      {:ok, {:error, reason}} -> {:error, {:backup_descriptor_close_failed, reason}}
    end
  end

  defp reactivate_container(backup, expected_source, %{identity: identity}, item)
       when is_list(identity) and length(identity) == 3 do
    expected_identity = List.to_tuple(identity)

    Sync.with_bound(backup, [:read, :raw, :binary], fn bound ->
      with true <- Filesystem.identity?(bound, expected_identity) || {:error, :unexpected_backup},
           {:ok, current} <- File.read(bound.path),
           :ok <- reactivate_bytes(bound, current, expected_source),
           :ok <- Manifest.put_backup_tombstone(item.video_path, item.language, bound.identity),
           :ok <- Sync.verify_bound_source_identity(backup, bound.identity) do
        {:ok, true}
      end
    end)
  end

  defp reactivate_container(_backup, _expected_source, _tombstone, _item),
    do: {:error, :invalid_backup_tombstone}

  defp reactivate_bytes(_bound, expected_source, expected_source), do: :ok

  defp reactivate_bytes(bound, "", expected_source),
    do: Sync.fs().write_bound(bound, expected_source)

  defp reactivate_bytes(_bound, _current, _expected), do: {:error, :backup_mismatch}

  defp verify_existing(backup, expected_source) do
    case Sync.safe_read(backup) do
      {:ok, ^expected_source} -> {:ok, false}
      {:ok, _other} -> {:error, :backup_mismatch}
      {:error, _reason} = error -> error
    end
  end
end
