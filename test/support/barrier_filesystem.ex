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
  defdelegate moviehash_data(path), to: Disk

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

      {:error, reason}
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
