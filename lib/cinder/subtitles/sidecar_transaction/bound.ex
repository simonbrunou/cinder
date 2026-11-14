defmodule Cinder.Subtitles.SidecarTransaction.Bound do
  @moduledoc false
  # Descriptor-bound file steps that `AtomicFile` and `Workspace` share: a file held open across
  # a callback and closed after it, and checks that a pathname still names a held inode.

  require Logger

  import Cinder.Subtitles.SafeFile, only: [fs: 0]

  @doc "Whether `path` still names the inode `bound` holds: `:ok` or `{:error, :concurrent_change}`."
  @spec verify_bound_path(String.t(), map()) :: :ok | {:error, :concurrent_change}
  def verify_bound_path(path, bound), do: verify_path_identity(path, bound.identity)

  @spec verify_path_identity(String.t(), term()) :: :ok | {:error, :concurrent_change}
  def verify_path_identity(path, expected_identity) do
    case path_identity(path) do
      {:ok, ^expected_identity} -> :ok
      _other -> {:error, :concurrent_change}
    end
  end

  @spec path_identity(String.t()) :: {:ok, term()} | {:error, term()}
  def path_identity(path) do
    with_bound(path, [:read, :raw, :binary], fn bound -> {:ok, bound.identity} end)
  end

  @doc "Opens `path`, runs `callback` with the bound, and closes it (`finish_bound/2`)."
  @spec with_bound(String.t(), [atom()], (map() -> term())) :: term()
  def with_bound(path, modes, callback) do
    case fs().open_bound(path, modes) do
      {:ok, bound} -> finish_bound(bound, callback)
      {:error, _reason} = error -> error
    end
  end

  @doc "Creates `path` holding `content`, runs `callback` with the bound, and closes it."
  @spec with_created_bound(String.t(), binary(), (map() -> term())) :: term()
  def with_created_bound(path, content, callback) do
    case fs().create_bound(path, content) do
      {:ok, bound} -> finish_bound(bound, callback)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Runs `callback` with `bound`, closes `bound`, and merges a failed close into the result: a
  committed publication marker stays committed, `{:workspace_kept, directory}` becomes
  `{:workspace_kept, directory, {:descriptor_close_failed, reason}}`, anything else becomes
  `{:error, {:descriptor_close_failed, reason}}`. A raise is re-raised after the close.
  """
  @spec finish_bound(map(), (map() -> term())) :: term()
  def finish_bound(bound, callback) do
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

  # A disposal that kept its workspace already logged the folder's path (`AtomicFile`'s
  # `finish_displaced/2`), so the caller still learns which folder it kept (#1290).
  defp finish_bound_operation({:returned, {:workspace_kept, directory}}, {:error, reason}),
    do: {:workspace_kept, directory, {:descriptor_close_failed, reason}}

  defp finish_bound_operation({:returned, _result}, {:error, reason}),
    do: {:error, {:descriptor_close_failed, reason}}

  defp finish_bound_operation({:raised, kind, reason, stacktrace}, _close_result),
    do: :erlang.raise(kind, reason, stacktrace)

  @doc "Two committed warnings as one: the first alone when there is no earlier one."
  @spec merge_committed_warnings(term(), term()) :: term()
  def merge_committed_warnings(nil, reason), do: reason
  def merge_committed_warnings(first, second), do: {first, second}
end
