defmodule Cinder.Test.BarrierFilesystem do
  @moduledoc false
  @behaviour Cinder.Library.Filesystem

  alias Cinder.Library.Filesystem.Disk

  @impl true
  defdelegate dir?(path), to: Disk
  @impl true
  defdelegate ls(path), to: Disk

  @impl true
  def find_files(path) do
    result = Disk.find_files(path)
    pause(:find_files, path)
    result
  end

  @impl true
  defdelegate mkdir_p(path), to: Disk

  @impl true
  def mkdir_exclusive(path, mode) do
    pause(:mkdir_exclusive, path, :before)
    Disk.mkdir_exclusive(path, mode)
  end

  @impl true
  def ln(source, dest) do
    case injected_failure(:ln, source, dest) do
      :ok ->
        result = Disk.ln(source, dest)
        pause(:ln, dest)
        result

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def cp(source, dest) do
    result = Disk.cp(source, dest)
    pause(:cp, dest)
    result
  end

  @impl true
  def cp_exclusive(source, dest, on_create) do
    pause(:cp_exclusive, dest, :before)

    file_module = Application.get_env(:cinder, :exclusive_copy_file_module, :file)

    Disk.cp_exclusive_with(
      source,
      dest,
      fn stat ->
        pause(:cp_exclusive_created, dest)

        with :ok <- on_create.(stat) do
          pause(:cp_exclusive, dest)
        end
      end,
      file_module
    )
  end

  @impl true
  def lstat(path) do
    result = Disk.lstat(path)
    pause(:lstat, path)
    result
  end

  @impl true
  def rename(source, dest) do
    case injected_failure(:rename, source, dest) do
      :ok ->
        result = Disk.rename(source, dest)
        pause(:rename, dest)
        result

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def rm(path) do
    pause(:rm, path, :before)

    case injected_failure(:rm, path, path) do
      :ok ->
        result = Disk.rm(path)
        pause(:rm, path)
        result

      {:post_effect_error, reason} ->
        case Disk.rm(path) do
          :ok -> {:error, {:effect_committed, "unlink", reason}}
          {:error, _reason} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  defdelegate rmdir(path), to: Disk

  @impl true
  defdelegate rm_rf(path), to: Disk
  @impl true
  defdelegate read(path), to: Disk
  @impl true
  defdelegate read_prefix(path, bytes), to: Disk

  @impl true
  def write(path, content) do
    pause(:write, path, :before)

    case injected_failure(:write, path, path) do
      :ok ->
        result = Disk.write(path, content)
        pause(:write, path)
        result

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def chmod(path, mode) do
    pause(:chmod, path, :before)
    Disk.chmod(path, mode)
  end

  @impl true
  def write_exclusive(path, content) do
    pause(:write_exclusive, path, :before)

    case injected_failure(:write_exclusive, path, path) do
      :ok ->
        result = Disk.write_exclusive(path, content)
        pause(:write_exclusive, path)
        result

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def open_bound(path, modes) do
    pause(:open_bound, path, :before)

    case Disk.open_bound(path, modes) do
      {:ok, bound} -> {:ok, Map.put(bound, :source_path, path)}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def create_bound(path, content) do
    pause(:create_bound, path, :before)

    case injected_failure(:create_bound, path, path) do
      :ok ->
        result = Disk.create_bound(path, content)
        pause(:create_bound, path)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def close_bound(bound) do
    source = Map.get(bound, :source_path, bound.path)

    case injected_failure(:close_bound, source, source) do
      :ok ->
        Disk.close_bound(bound)

      {:error, _reason} = error ->
        Disk.close_bound(bound)
        error
    end
  end

  @impl true
  def discard_bound(bound) do
    source = Map.get(bound, :source_path, bound.path)
    pause(:discard_bound, source, :before)

    case injected_failure(:discard_bound, source, source) do
      :ok ->
        result = Disk.discard_bound(bound)
        pause(:discard_bound, source)
        result

      {:post_effect_error, reason} ->
        case Disk.discard_bound(bound) do
          :ok -> {:error, {:effect_committed, "discard_bound", reason}}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def write_bound(bound, content) do
    source = Map.get(bound, :source_path, bound.path)
    pause(:write_bound, source, :before)

    case injected_failure(:write_bound, source, source) do
      :ok ->
        result = Disk.write_bound(bound, content)
        pause(:write_bound, source)
        result

      {:post_effect_error, reason} ->
        case Disk.write_bound(bound, content) do
          :ok -> {:error, {:effect_committed, "write_bound", reason}}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def exchange(source, dest) do
    pause(:exchange, source, :before)

    case injected_failure(:exchange, source, dest) do
      :ok ->
        result = Disk.exchange(source, dest)
        pause(:exchange, source)
        result

      {:post_effect_error, reason} ->
        case Disk.exchange(source, dest) do
          :ok -> {:error, {:effect_committed, "exchange", reason}}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def moviehash_data(path) do
    pause(:moviehash_data, path, :before)

    result =
      case injected_failure(:moviehash_data, path, path) do
        :ok -> Disk.moviehash_data(path)
        {:error, _} = error -> error
      end

    pause(:moviehash_data, path)
    result
  end

  defp pause(operation, path, phase \\ :after) do
    case Application.get_env(:cinder, :filesystem_barrier) do
      %{owner: owner, operation: ^operation, contains: contains} = barrier
      when phase == :after ->
        maybe_pause(barrier, owner, operation, path, contains)

      %{owner: owner, operation: ^operation, contains: contains, phase: ^phase} = barrier ->
        maybe_pause(barrier, owner, operation, path, contains)

      %{owner: owner, operations: operations, contains: contains} = barrier ->
        if phase == :after and operation in operations,
          do: maybe_pause(barrier, owner, operation, path, contains)

      _ ->
        :ok
    end
  end

  defp injected_failure(operation, source, _dest) do
    case sequence_failure(operation, source) do
      :no_match -> single_failure(operation, source)
      result -> result
    end
  end

  defp sequence_failure(operation, source) do
    case Application.get_env(:cinder, :filesystem_failures) do
      [failure | rest] -> match_sequence_failure(failure, rest, operation, source)
      _ -> :no_match
    end
  end

  defp match_sequence_failure(
         %{operation: operation, source_contains: contains, reason: reason} = failure,
         rest,
         operation,
         source
       )
       when is_binary(contains) do
    if String.contains?(source, contains) do
      store_failure_sequence(rest)
      run_failure_callback(failure)
      {:error, reason}
    else
      :no_match
    end
  end

  defp match_sequence_failure(_failure, _rest, _operation, _source), do: :no_match

  defp run_failure_callback(%{callback: callback}) when is_function(callback, 0), do: callback.()
  defp run_failure_callback(_failure), do: :ok

  defp store_failure_sequence([]), do: Application.delete_env(:cinder, :filesystem_failures)
  defp store_failure_sequence(rest), do: Application.put_env(:cinder, :filesystem_failures, rest)

  defp single_failure(operation, source) do
    case Application.get_env(:cinder, :filesystem_failure) do
      %{operation: ^operation, source_contains: contains, reason: reason} = failure ->
        failure_result(failure, source, contains, reason)

      _ ->
        :ok
    end
  end

  defp failure_result(failure, source, contains, reason) do
    if String.contains?(source, contains) do
      if Map.get(failure, :once, false),
        do: Application.delete_env(:cinder, :filesystem_failure)

      if Map.get(failure, :phase) == :post_effect,
        do: {:post_effect_error, reason},
        else: {:error, reason}
    else
      :ok
    end
  end

  defp maybe_pause(barrier, owner, operation, path, contains) do
    excluded? = String.contains?(path, Map.get(barrier, :excludes, "\0"))

    if String.contains?(path, contains) and not excluded? do
      if Map.get(barrier, :once, false), do: Application.delete_env(:cinder, :filesystem_barrier)
      ref = make_ref()
      send(owner, {:filesystem_barrier, self(), ref, operation, path})
      receive do: ({^ref, :continue} -> :ok)
    end
  end
end
