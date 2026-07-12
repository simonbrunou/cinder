defmodule Cinder.Library.Filesystem.Disk do
  @moduledoc """
  Real `Cinder.Library.Filesystem` impl over the local filesystem.
  `ln/2` is a hardlink (`File.ln/2`); when the library and downloads live on
  different filesystems the hardlink fails with `:exdev` and `Cinder.Library`
  falls back to an exclusive, bounded streaming copy instead.
  """
  @behaviour Cinder.Library.Filesystem

  alias Cinder.Library.PathPolicy

  @moviehash_chunk 65_536
  @moviehash_min 2 * @moviehash_chunk
  @copy_chunk 1_048_576

  @impl true
  def dir?(path), do: File.dir?(path)

  @impl true
  def ls(path), do: File.ls(path)

  # ANY unlistable directory in the tree — the root or a nested one — propagates as
  # {:error, reason}: an EACCES permission mismatch or an unmounted downloads volume must
  # read as a transient FS failure (a bounded retry), not as {:ok, []}, which callers
  # classify as a deterministic release defect and answer with a permanent park + blocklist.
  # (The common torrent layout is a single video-bearing subfolder, so nested failures are
  # the same bug one level down.) Unstat-able individual ENTRIES stay best-effort and are skipped:
  # one broken sidecar file shouldn't block importing the rest.
  @impl true
  def find_files(dir),
    do: PathPolicy.walk(dir, filesystem: __MODULE__)

  @impl true
  def mkdir_p(dir), do: File.mkdir_p(dir)

  @impl true
  def ln(source, dest), do: File.ln(source, dest)

  @impl true
  def cp(source, dest), do: File.cp(source, dest)

  @impl true
  def cp_exclusive(source, dest, on_create),
    do: cp_exclusive_with(source, dest, on_create, :file)

  @doc false
  def cp_exclusive_with(source, dest, on_create, file) do
    with {:ok, output} <- file.open(dest, [:write, :exclusive, :binary, :raw]) do
      operation =
        try do
          {:returned, copy_to_open_output(source, output, on_create, file)}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      close_result = file.close(output)
      finish_open_output(operation, close_result)
    end
  end

  defp finish_open_output({:returned, operation}, close_result),
    do: finish_exclusive_copy(operation, close_result)

  defp finish_open_output({:raised, kind, reason, stacktrace}, _close_result),
    do: :erlang.raise(kind, reason, stacktrace)

  defp copy_to_open_output(source, output, on_create, file) do
    case file.read_file_info(output) do
      {:ok, record} ->
        stat = File.Stat.from_record(record)

        operation =
          try do
            case on_create.(stat) do
              :ok -> {:copy, copy_from_source(source, output, file)}
              {:error, _} = error -> {:callback_error, error}
            end
          catch
            kind, reason -> {:callback_raise, kind, reason, __STACKTRACE__}
          end

        operation

      {:error, _} = error ->
        {:copy, error}
    end
  end

  defp copy_from_source(source, output, file) do
    with {:ok, input} <- file.open(source, [:read, :binary, :raw]) do
      operation =
        try do
          {:returned, stream_copy(input, output, file)}
        catch
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      close_result = file.close(input)
      finish_io_operation(operation, close_result)
    end
  end

  defp finish_io_operation({:returned, result}, close_result),
    do: combine_io_results(result, close_result)

  defp finish_io_operation({:raised, kind, reason, stacktrace}, _close_result),
    do: :erlang.raise(kind, reason, stacktrace)

  defp combine_io_results(:ok, close_result), do: close_result
  defp combine_io_results({:error, _} = error, _close_result), do: error

  defp finish_exclusive_copy({:copy, result}, close_result),
    do: combine_io_results(result, close_result)

  # POSIX has no portable atomic "unlink only if this path still names this inode" operation.
  # Retain the output on callback failure so a concurrent pathname replacement can never be
  # deleted by a check-then-unlink race. Library's durable journal recovers or quarantines it.
  defp finish_exclusive_copy({:callback_error, error}, _close_result), do: error

  defp finish_exclusive_copy(
         {:callback_raise, kind, reason, stacktrace},
         _close_result
       ),
       do: :erlang.raise(kind, reason, stacktrace)

  defp stream_copy(input, output, file) do
    case file.read(input, @copy_chunk) do
      {:ok, bytes} ->
        case file.write(output, bytes) do
          :ok -> stream_copy(input, output, file)
          {:error, _} = error -> error
        end

      :eof ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def read(path), do: File.read(path)

  @impl true
  def write(path, content), do: File.write(path, content)

  @impl true
  def lstat(path), do: File.lstat(path)

  @impl true
  def rename(source, dest), do: File.rename(source, dest)

  @impl true
  def rm(path), do: File.rm(path)

  @impl true
  def rmdir(dir), do: File.rmdir(dir)

  @impl true
  def moviehash_data(path) do
    with {:ok, %{size: size}} <- lstat(path),
         true <- size >= @moviehash_min || :too_small,
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        # Guard the chunk sizes: a file shrunk between lstat and pread yields :eof or a short read;
        # keep moviehash_data within its declared spec instead of leaking either out.
        with {:ok, head} when byte_size(head) == @moviehash_chunk <-
               :file.pread(io, 0, @moviehash_chunk),
             {:ok, tail} when byte_size(tail) == @moviehash_chunk <-
               :file.pread(io, size - @moviehash_chunk, @moviehash_chunk) do
          {:ok, {size, head, tail}}
        else
          _ -> {:error, :read_failed}
        end
      after
        File.close(io)
      end
    else
      :too_small -> :too_small
      {:error, _} = err -> err
    end
  end
end
