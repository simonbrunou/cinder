defmodule Cinder.Library.Filesystem.Disk do
  @moduledoc """
  Real `Cinder.Library.Filesystem` impl over the local filesystem.
  `ln/2` is a hardlink (`File.ln/2`); when the library and downloads live on
  different filesystems the hardlink fails with `:exdev` and `Cinder.Library`
  falls back to an exclusive, bounded streaming copy instead.
  """
  @behaviour Cinder.Library.Filesystem

  alias Cinder.Library.PathPolicy
  alias Cinder.Settings

  @moviehash_chunk 65_536
  @moviehash_min 2 * @moviehash_chunk
  @copy_chunk 1_048_576
  @posix_reasons %{
    "EACCES" => :eacces,
    "EBADF" => :ebadf,
    "EBUSY" => :ebusy,
    "EEXIST" => :eexist,
    "EINVAL" => :einval,
    "EIO" => :eio,
    "EISDIR" => :eisdir,
    "ELOOP" => :eloop,
    "ENAMETOOLONG" => :enametoolong,
    "ENOENT" => :enoent,
    "ENOSPC" => :enospc,
    "ENOTDIR" => :enotdir,
    "ENOTEMPTY" => :enotempty,
    "EPERM" => :eperm,
    "EROFS" => :erofs,
    "EXDEV" => :exdev
  }
  @rooted_effect_operations ~w(chmod exchange rename unlink rmdir mkdir mkdir_near)

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
  def mkdir_exclusive(dir, mode) do
    case rooted_location(dir) do
      {:ok, root, relative} -> run_rooted("mkdir", [root, relative, Integer.to_string(mode, 8)])
      :outside_roots -> with :ok <- File.mkdir(dir), do: File.chmod(dir, mode)
    end
  end

  @doc false
  def mkdir_exclusive_near(dir, anchor, mode) do
    case {rooted_location(dir), rooted_location(anchor)} do
      {{:ok, root, relative}, {:ok, root, anchor_relative}} ->
        run_rooted("mkdir_near", [
          root,
          relative,
          anchor_relative,
          Integer.to_string(mode, 8)
        ])

      _ ->
        mkdir_exclusive(dir, mode)
    end
  end

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
  def read(path) do
    case rooted_location(path) do
      {:ok, root, relative} ->
        with_rooted_bound(root, relative, path, "read", &File.read(&1.path))

      :outside_roots ->
        File.read(path)
    end
  end

  @impl true
  def write(path, content) do
    case rooted_location(path) do
      {:ok, root, relative} -> rooted_write(root, relative, path, content, "write")
      :outside_roots -> unrooted_write(path, content)
    end
  end

  @impl true
  def chmod(path, mode) do
    case rooted_location(path) do
      {:ok, root, relative} -> run_rooted("chmod", [root, relative, Integer.to_string(mode, 8)])
      :outside_roots -> File.chmod(path, mode)
    end
  end

  defp unrooted_write(path, content) do
    with :ok <- File.write(path, content),
         :ok <- sync_file(path),
         do: sync_directories([Path.dirname(path)])
  end

  @impl true
  def write_exclusive(path, content) do
    with {:ok, bound} <- create_bound(path, content),
         do: close_bound(bound)
  end

  @impl true
  def open_bound(path, modes) do
    case rooted_location(path) do
      {:ok, root, relative} ->
        if :write in modes,
          do: {:error, :unsupported_rooted_open_mode},
          else: open_rooted_bound(root, relative, path, "read")

      :outside_roots ->
        open_unrooted_bound(path, modes)
    end
  end

  defp open_unrooted_bound(path, modes) do
    with {:ok, io} <- File.open(path, modes) do
      case bind_open_file(path, io) do
        {:ok, bound} ->
          {:ok, bound}

        {:error, _reason} = error ->
          File.close(io)
          error
      end
    end
  end

  @impl true
  def close_bound(%{io: {:rooted, port}}), do: close_rooted_port(port)
  def close_bound(%{io: io}), do: File.close(io)

  @impl true
  def discard_bound(bound), do: write_bound(bound, "")

  @impl true
  def write_bound(%{path: descriptor_path}, content) do
    with :ok <- File.write(descriptor_path, content), do: sync_file(descriptor_path)
  end

  @impl true
  def create_bound(path, content) do
    case rooted_location(path) do
      {:ok, root, relative} -> rooted_create_bound(root, relative, path, content)
      :outside_roots -> create_unrooted_bound(path, content)
    end
  end

  defp create_unrooted_bound(path, content) do
    with {:ok, io} <- File.open(path, [:read, :write, :exclusive, :raw, :binary]) do
      case :file.write(io, content) do
        :ok -> sync_created_bound(path, io)
        {:error, _reason} = error -> close_bound_error(io, error)
      end
    end
  end

  defp sync_created_bound(path, io) do
    with :ok <- :file.sync(io),
         :ok <- sync_directories([Path.dirname(path)]),
         do: finish_created_bound(path, io),
         else: ({:error, _reason} = error -> close_bound_error(io, error))
  end

  defp finish_created_bound(path, io) do
    case bind_open_file(path, io) do
      {:ok, bound} -> {:ok, bound}
      {:error, _reason} = error -> close_bound_error(io, error)
    end
  end

  @impl true
  def exchange(source, dest) do
    case {rooted_location(source), rooted_location(dest)} do
      {{:ok, source_root, source_relative}, {:ok, dest_root, dest_relative}} ->
        run_rooted("exchange", [source_root, source_relative, dest_root, dest_relative])

      _ ->
        unrooted_exchange(source, dest)
    end
  end

  defp unrooted_exchange(source, dest) do
    executable = System.find_executable("mv") || "mv"

    case run_command(
           executable,
           ["--exchange", "--no-copy", "--no-target-directory", source, dest]
         ) do
      {:ok, _output} -> sync_directories([Path.dirname(source), Path.dirname(dest)])
      {:error, _reason} = error -> error
    end
  end

  defp run_command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:exchange_failed, status, output}}
    end
  rescue
    error -> {:error, {:exchange_exec_failed, error}}
  catch
    kind, reason -> {:error, {:exchange_exec_failed, {kind, reason}}}
  end

  defp close_bound_error(io, error) do
    File.close(io)
    error
  end

  defp bind_open_file(path, io) do
    with handle when is_binary(handle) <- :prim_file.get_handle(io),
         fd = :binary.decode_unsigned(handle, :little),
         descriptor_path = "/proc/#{System.pid()}/fd/#{fd}",
         {:ok, path_stat} <- File.lstat(path),
         {:ok, descriptor_stat} <- File.stat(descriptor_path),
         true <- same_regular_file?(path_stat, descriptor_stat) do
      {:ok, %{io: io, path: descriptor_path, identity: identity(path_stat)}}
    else
      false -> {:error, :unsafe_path}
      {:error, _reason} = error -> error
      _ -> {:error, :unsupported_descriptor}
    end
  end

  defp same_regular_file?(
         %File.Stat{type: :regular} = left,
         %File.Stat{type: :regular} = right
       ) do
    {left.major_device, left.minor_device, left.inode} ==
      {right.major_device, right.minor_device, right.inode}
  end

  defp same_regular_file?(_left, _right), do: false

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  @impl true
  def lstat(path), do: File.lstat(path)

  @impl true
  def rename(source, dest) do
    case {rooted_location(source), rooted_location(dest)} do
      {{:ok, source_root, source_relative}, {:ok, dest_root, dest_relative}} ->
        run_rooted("rename", [source_root, source_relative, dest_root, dest_relative])

      _ ->
        with :ok <- File.rename(source, dest),
             do: sync_directories([Path.dirname(source), Path.dirname(dest)])
    end
  end

  @impl true
  def rm(path) do
    case rooted_location(path) do
      {:ok, root, relative} -> run_rooted("unlink", [root, relative])
      :outside_roots -> with :ok <- File.rm(path), do: sync_directories([Path.dirname(path)])
    end
  end

  @impl true
  def rmdir(dir) do
    case rooted_location(dir) do
      {:ok, root, relative} -> run_rooted("rmdir", [root, relative])
      :outside_roots -> with :ok <- File.rmdir(dir), do: sync_directories([Path.dirname(dir)])
    end
  end

  @impl true
  def rm_rf(path), do: File.rm_rf(path)

  defp rooted_location(path) do
    expanded = Path.expand(path)

    Settings.library_roots()
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.find_value(:outside_roots, fn root ->
      root = Path.expand(root)

      if expanded == root or String.starts_with?(expanded, root <> "/") do
        {:ok, root, Path.relative_to(expanded, root)}
      else
        false
      end
    end)
  end

  defp run_rooted(operation, args) do
    python = System.find_executable("python3") || "python3"

    case System.cmd(python, [rooted_helper(), operation | args], stderr_to_stdout: true) do
      {output, _status} -> decode_rooted_result(output, operation)
    end
  rescue
    error -> {:error, {:rooted_helper_exec_failed, operation, error}}
  catch
    kind, reason -> {:error, {:rooted_helper_exec_failed, operation, {kind, reason}}}
  end

  defp decode_rooted_result(output, operation) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"ok" => _value}} ->
        :ok

      {:ok, %{"error" => %{"phase" => "post_effect"}}} when operation == "rename" ->
        :ok

      {:ok, %{"error" => %{"phase" => "post_effect"} = error}} ->
        {:error, {:effect_committed, operation, error}}

      {:ok, %{"error" => error}} ->
        {:error, rooted_reason(error)}

      _ when operation in @rooted_effect_operations ->
        {:error,
         {:effect_committed, operation, {:helper_outcome_unknown, String.slice(output, 0, 500)}}}

      _ ->
        {:error, {:rooted_helper_malformed, operation, output}}
    end
  end

  defp rooted_reason(%{"reason" => reason}),
    do: Map.get(@posix_reasons, reason, {:rooted_error, reason})

  defp rooted_helper do
    Application.get_env(
      :cinder,
      :rooted_filesystem_helper,
      Path.join(:code.priv_dir(:cinder), "rooted_fs.py")
    )
  end

  defp open_rooted_bound(root, relative, source_path, mode) do
    python = System.find_executable("python3") || "python3"

    port =
      Port.open(
        {:spawn_executable, python},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [rooted_helper(), "hold", root, relative, mode]
        ]
      )

    receive do
      {^port, {:data, output}} ->
        decode_rooted_hold(port, output, source_path)

      {^port, {:exit_status, status}} ->
        {:error, {:rooted_helper_exit, status}}
    after
      5_000 ->
        close_rooted_port(port)
        {:error, :rooted_helper_timeout}
    end
  rescue
    error -> {:error, {:rooted_helper_exec_failed, "hold", error}}
  end

  defp decode_rooted_hold(port, output, source_path) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"ok" => %{"fd" => fd}}} when is_integer(fd) and fd >= 0 ->
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        descriptor_path = "/proc/#{os_pid}/fd/#{fd}"

        case File.stat(descriptor_path) do
          {:ok, stat} ->
            {:ok,
             %{
               io: {:rooted, port},
               path: descriptor_path,
               source_path: source_path,
               identity: identity(stat)
             }}

          {:error, reason} ->
            close_rooted_port(port)
            {:error, reason}
        end

      {:ok, %{"error" => error}} ->
        close_rooted_port(port)
        {:error, rooted_reason(error)}

      _ ->
        close_rooted_port(port)
        {:error, {:rooted_helper_malformed, "hold", output}}
    end
  end

  defp close_rooted_port(port) do
    if Port.info(port) do
      Port.close(port)
      :ok
    else
      :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp with_rooted_bound(root, relative, source_path, mode, callback) do
    with {:ok, bound} <- open_rooted_bound(root, relative, source_path, mode) do
      result = callback.(bound)

      close_rooted_port(elem(bound.io, 1))
      result
    end
  end

  defp rooted_create_bound(root, relative, path, content) do
    case open_rooted_bound(root, relative, path, "create") do
      {:ok, bound} ->
        case write_and_sync_rooted(bound, root, relative, content) do
          :ok ->
            {:ok, bound}

          {:error, _reason} = error ->
            close_rooted_port(elem(bound.io, 1))
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp rooted_write(root, relative, path, content, mode) do
    with {:ok, bound} <- open_rooted_bound(root, relative, path, mode) do
      result = write_and_sync_rooted(bound, root, relative, content)
      close_result = close_rooted_port(elem(bound.io, 1))
      if result == :ok, do: close_result, else: result
    end
  end

  defp write_and_sync_rooted(bound, root, relative, content) do
    with :ok <- File.write(bound.path, content),
         :ok <- sync_file(bound.path),
         do: run_rooted("sync_parent", [root, relative])
  end

  defp sync_file(path) do
    with {:ok, io} <- File.open(path, [:read, :raw, :binary]) do
      sync_result = :file.sync(io)
      close_result = File.close(io)
      combine_io_results(sync_result, close_result)
    end
  end

  defp sync_directories(paths) do
    paths
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case sync_directory(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sync_directory(path) do
    executable = System.find_executable("sync") || "sync"

    case System.cmd(executable, ["-d", "--", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:directory_sync_failed, status, output}}
    end
  rescue
    error -> {:error, {:directory_sync_exec_failed, error}}
  catch
    kind, reason -> {:error, {:directory_sync_exec_failed, {kind, reason}}}
  end

  @impl true
  def moviehash_data(path) do
    case open_bound(path, [:read, :raw, :binary]) do
      {:ok, bound} ->
        result = moviehash_bound(bound.path)

        case close_bound(bound) do
          :ok -> result
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp moviehash_bound(descriptor_path) do
    with {:ok, %{size: size}} <- File.stat(descriptor_path),
         true <- size >= @moviehash_min || :too_small,
         {:ok, io} <- File.open(descriptor_path, [:read, :binary]) do
      try do
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
      {:error, _reason} = error -> error
    end
  end
end
