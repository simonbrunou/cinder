defmodule Cinder.Subtitles.Sync.EngineWorkspace do
  @moduledoc false

  @spec run(map() | {:content, binary()}, map(), String.t(), String.t(), function()) ::
          {:ok, term()} | {:error, term()}
  def run(reference, input, reference_extension, input_extension, callback) do
    with_anonymous_file("", false, fn output ->
      with_reference(reference, fn reference ->
        execute(
          reference,
          input,
          output,
          reference_extension,
          input_extension,
          callback
        )
      end)
    end)
  end

  defp execute(reference, input, output, reference_extension, input_extension, callback) do
    operation =
      try do
        {:returned,
         callback.(
           reference.path,
           input.path,
           output.path,
           output,
           reference_extension,
           input_extension
         )}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    finish_execution(operation, output)
  end

  defp finish_execution({:returned, engine_result}, output) do
    with :ok <- seal(output),
         output_result <- File.read(output.path) do
      {:ok, {engine_result, output_result}}
    end
  end

  defp finish_execution({:raised, kind, reason, stacktrace}, _output),
    do: :erlang.raise(kind, reason, stacktrace)

  defp with_reference(%{path: _bound_path} = reference, callback), do: callback.(reference)

  defp with_reference({:content, content}, callback) when is_binary(content),
    do: with_anonymous_file(content, true, callback)

  defp with_anonymous_file(content, seal?, callback) do
    case open_anonymous(content, seal?) do
      {:ok, bound} -> finish_anonymous(bound, callback)
      {:error, _reason} = error -> error
    end
  end

  defp open_anonymous(content, seal?) do
    case start_holder() do
      {:ok, bound} -> initialize_anonymous(bound, content, seal?)
      {:error, _reason} = error -> error
    end
  end

  defp initialize_anonymous(bound, content, seal?) do
    result =
      with :ok <- File.write(bound.path, content),
           :ok <- maybe_seal(bound, seal?),
           :ok <- verify_content(bound, content, seal?),
           do: {:ok, bound}

    case result do
      {:ok, _bound} = success ->
        success

      {:error, _reason} = error ->
        close_holder(elem(bound.io, 1))
        error
    end
  end

  defp start_holder do
    python = System.find_executable("python3") || "python3"

    port =
      Port.open(
        {:spawn_executable, python},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [helper(), "hold"]
        ]
      )

    receive do
      {^port, {:data, output}} -> decode_holder(port, output)
      {^port, {:exit_status, status}} -> {:error, {:anonymous_helper_exit, status}}
    after
      5_000 ->
        close_holder(port)
        {:error, :anonymous_helper_timeout}
    end
  rescue
    error -> {:error, {:anonymous_helper_exec_failed, error}}
  end

  defp decode_holder(port, output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"ok" => %{"fd" => fd}}} when is_integer(fd) and fd >= 0 ->
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        path = "/proc/#{os_pid}/fd/#{fd}"

        case File.stat(path) do
          {:ok, stat} ->
            {:ok, %{io: {:anonymous, port}, path: path, identity: identity(stat)}}

          {:error, reason} ->
            close_holder(port)
            {:error, reason}
        end

      {:ok, %{"error" => error}} ->
        close_holder(port)
        {:error, {:anonymous_helper_error, error}}

      _ ->
        close_holder(port)
        {:error, {:anonymous_helper_malformed, output}}
    end
  end

  defp maybe_seal(bound, true), do: seal(bound)
  defp maybe_seal(_bound, false), do: :ok

  defp seal(%{path: path}) do
    python = System.find_executable("python3") || "python3"

    case System.cmd(python, [helper(), "seal", path], stderr_to_stdout: true) do
      {output, 0} -> decode_seal(output)
      {output, status} -> {:error, {:anonymous_seal_exit, status, output}}
    end
  rescue
    error -> {:error, {:anonymous_seal_exec_failed, error}}
  end

  defp decode_seal(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"ok" => "sealed"}} -> :ok
      {:ok, %{"error" => error}} -> {:error, {:anonymous_seal_failed, error}}
      _ -> {:error, {:anonymous_seal_malformed, output}}
    end
  end

  defp verify_content(bound, expected, true) do
    case File.read(bound.path) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :anonymous_content_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp verify_content(_bound, _expected, false), do: :ok

  defp finish_anonymous(bound, callback) do
    operation =
      try do
        {:returned, callback.(bound)}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    close_result = close_holder(elem(bound.io, 1))
    finish_anonymous_operation(operation, close_result)
  end

  defp finish_anonymous_operation({:returned, result}, :ok), do: result

  defp finish_anonymous_operation({:raised, kind, reason, stacktrace}, _close_result),
    do: :erlang.raise(kind, reason, stacktrace)

  defp close_holder(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  defp helper do
    Application.get_env(
      :cinder,
      :anonymous_file_helper,
      Path.join(:code.priv_dir(:cinder), "anonymous_file.py")
    )
  end
end
