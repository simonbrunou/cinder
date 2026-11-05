defmodule Cinder.RawFile do
  @moduledoc """
  The `File` writes Cinder makes on import, library and descriptor paths, without the VM's one
  file server (`:file_server_2`). Every plain `File` call queues behind that server, so a write
  hung on a wedged mount there would block every `File` call in the app until the mount answers.
  These calls reach the filesystem from the calling process instead, so one hung on a mount pins
  only that process. They carry no deadline of their own (#1146).

  Each function returns what the `File` function of the same name returns in Elixir 1.20.5 on
  Linux, and raises where it raises. `Cinder.CodeHealth.MountPathRawCallsTest` fails a plain
  `File` or `:file` write in the modules that write those paths.
  """

  require Record

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @doc "Same as `File.write/2`."
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix() | :badarg | :terminated}
  def write(path, content), do: File.write(path, content, [:raw])

  @doc "Same as `File.chmod/2`."
  @spec chmod(Path.t(), non_neg_integer()) :: :ok | {:error, File.posix() | :badarg}
  def chmod(path, mode),
    do: :file.write_file_info(IO.chardata_to_string(path), file_info(mode: mode), [:raw])

  @doc "Same as `File.mkdir/1`."
  @spec mkdir(Path.t()) :: :ok | {:error, File.posix() | :badarg}
  def mkdir(path), do: :prim_file.make_dir(IO.chardata_to_string(path))

  @doc """
  Same as `File.mkdir_p/1`: `:ok` when the directory already exists, `{:error, :enotdir}` when
  a file holds the path or one of its parents.
  """
  @spec mkdir_p(Path.t()) :: :ok | {:error, File.posix() | :badarg}
  def mkdir_p(path), do: do_mkdir_p(IO.chardata_to_string(path))

  defp do_mkdir_p("/"), do: :ok

  defp do_mkdir_p(path) do
    parent = Path.dirname(path)

    if parent == path,
      do: :ok,
      else: with(:ok <- do_mkdir_p(parent), do: make_missing_dir(path))
  end

  defp make_missing_dir(path) do
    case :prim_file.make_dir(path) do
      {:error, :eexist} -> if File.dir?(path, [:raw]), do: :ok, else: {:error, :enotdir}
      other -> other
    end
  end

  @doc "Same as `File.rm/1`."
  @spec rm(Path.t()) :: :ok | {:error, File.posix() | :badarg}
  def rm(path), do: :prim_file.delete(IO.chardata_to_string(path))

  @doc "Same as `File.rmdir/1`."
  @spec rmdir(Path.t()) :: :ok | {:error, File.posix() | :badarg}
  def rmdir(path), do: :prim_file.del_dir(IO.chardata_to_string(path))

  @doc """
  Same as `File.rm_rf/1`: `{:ok, removed_paths}`, `{:ok, []}` for a missing path, or
  `{:error, posix, path}`. It lists with `lstat`, so it removes a symlink and never follows it.
  """
  @spec rm_rf(Path.t()) :: {:ok, [binary()]} | {:error, File.posix() | :badarg, binary()}
  def rm_rf(path) do
    path = IO.chardata_to_string(path)

    if String.contains?(path, <<0>>) do
      raise ArgumentError,
            "cannot execute #{inspect(__MODULE__)}.rm_rf/1 for path with null byte, got: " <>
              inspect(path)
    end

    do_rm_rf(path, [])
  end

  defp do_rm_rf(path, acc) do
    case list_for_removal(path) do
      {:ok, entries} when is_list(entries) ->
        acc = Enum.reduce(entries, acc, &rm_rf_entry(Path.join(path, &1), &2))
        remove_directory(path, acc)

      {:ok, :directory} ->
        remove_unlisted_directory(path, acc)

      {:ok, :regular} ->
        remove_file(path, acc)

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason, path}
    end
  end

  # As in `File.rm_rf/1`, an entry that cannot be removed leaves the walk going: the directory's
  # own removal then reports the failure.
  defp rm_rf_entry(path, acc) do
    case do_rm_rf(path, acc) do
      {:ok, acc} -> acc
      {:error, _reason, _path} -> acc
    end
  end

  # A directory it cannot list is still removed when empty, as in `File.rm_rf/1`. Anything but a
  # directory, a symlink included, is removed as a file.
  defp list_for_removal(path) do
    case :file.read_link_info(path, [:raw]) do
      {:ok, file_info(type: :directory)} -> list_directory(path)
      {:ok, _info} -> {:ok, :regular}
      {:error, _reason} = error -> error
    end
  end

  defp list_directory(path) do
    case :prim_file.list_dir_all(path) do
      {:ok, entries} -> {:ok, entries}
      {:error, _reason} -> {:ok, :directory}
    end
  end

  defp remove_directory(path, acc) do
    case rmdir(path) do
      :ok -> {:ok, [path | acc]}
      {:error, :enoent} -> {:ok, acc}
      {:error, reason} -> {:error, reason, path}
    end
  end

  defp remove_unlisted_directory(path, acc) do
    case rmdir(path) do
      :ok -> {:ok, [path | acc]}
      {:error, :enotdir} -> remove_file(path, acc)
      {:error, :enoent} -> {:ok, acc}
      {:error, reason} -> {:error, reason, path}
    end
  end

  defp remove_file(path, acc) do
    case rm(path) do
      :ok -> {:ok, [path | acc]}
      {:error, :enoent} -> {:ok, acc}
      {:error, reason} -> {:error, reason, path}
    end
  end

  @doc "Same as `File.ln/2`: a hard link."
  @spec ln(Path.t(), Path.t()) :: :ok | {:error, File.posix() | :badarg}
  def ln(existing, new),
    do: :prim_file.make_link(IO.chardata_to_string(existing), IO.chardata_to_string(new))

  @doc "Same as `File.rename/2`."
  @spec rename(Path.t(), Path.t()) :: :ok | {:error, File.posix() | :badarg}
  def rename(source, destination),
    do: :prim_file.rename(IO.chardata_to_string(source), IO.chardata_to_string(destination))

  @doc """
  Same as `File.cp/2`: it replaces an existing destination's content, then sets the
  destination's mode to the source's. A destination that names the source itself is left alone.
  """
  @spec cp(Path.t(), Path.t()) :: :ok | {:error, File.posix() | :badarg | :terminated}
  def cp(source, destination) do
    source = IO.chardata_to_string(source)
    destination = IO.chardata_to_string(destination)

    case copy(source, destination, [:exclusive]) do
      {:ok, _bytes} ->
        copy_file_mode(source, destination)

      {:error, :eexist} ->
        if Path.expand(source) == Path.expand(destination),
          do: :ok,
          else: replace(source, destination)

      {:error, _reason} = error ->
        error
    end
  end

  defp replace(source, destination) do
    with {:ok, _bytes} <- copy(source, destination, []),
         do: copy_file_mode(source, destination)
  end

  # The order and the results of the copy the file server runs for `File.cp/2`: the source opens
  # first, the copy's own answer wins and the closes are not checked. `:file.copy/2` between two
  # raw descriptors stays in this process, unlike one between two `{path, modes}` pairs.
  defp copy(source, destination, destination_modes) do
    with {:ok, input} <- :file.open(source, [:read, :binary, :raw]) do
      result =
        case :file.open(destination, [:write, :binary, :raw | destination_modes]) do
          {:ok, output} ->
            copied = :file.copy(input, output)
            _ = :file.close(output)
            copied

          {:error, _reason} = error ->
            error
        end

      _ = :file.close(input)
      result
    end
  end

  # As `File.cp/2` does, it writes back the destination's whole stat with the source's mode.
  defp copy_file_mode(source, destination) do
    with {:ok, destination_stat} <- File.stat(destination, [:raw]),
         {:ok, source_stat} <- File.stat(source, [:raw]) do
      File.write_stat(destination, %{destination_stat | mode: source_stat.mode}, [:raw])
    end
  end
end
