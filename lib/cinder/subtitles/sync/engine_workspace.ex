defmodule Cinder.Subtitles.Sync.EngineWorkspace do
  @moduledoc false

  alias Cinder.BoundedCommand

  # Elixir-side bound for every subprocess this module shells out to: `seal/1` and
  # `start_holder/0` (issue #591 -- same defect shape as #590's `Disk.run_rooted/2`/
  # `open_rooted_bound/4`; `System.cmd/3` has no `:timeout` option at all, and `start_holder/0`'s
  # own pre-existing 5s bound is the precedent for this value). Overridable only as a test seam
  # (mirrors `Cinder.Library.Filesystem.Disk.subprocess_timeout_ms/0`'s own convention) --
  # production never sets this. Named distinctly from Disk's own `:disk_subprocess_timeout_ms`
  # rather than reusing it: this is a different helper family (`priv/anonymous_file.py`, not
  # `priv/rooted_fs.py`) in a wholly separate subsystem -- subtitle sync's own per-video-path
  # lock (`Cinder.Subtitles.analyze_video/1`), not the household-wide import lock #590 protects
  # -- so sharing one knob would make it impossible to tune either bound independently, in tests
  # or in a future runtime override.
  @subprocess_timeout_ms 5_000

  defp subprocess_timeout_ms,
    do:
      Application.get_env(
        :cinder,
        :engine_workspace_subprocess_timeout_ms,
        @subprocess_timeout_ms
      )

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
      subprocess_timeout_ms() ->
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

  # Supervised `Port` + `SIGKILL`-by-`os_pid` (#591) via `Cinder.BoundedCommand.run/4` -- see
  # that module's moduledoc. `python3` is resolved from `PATH` inside `run/4` itself, exactly
  # like `System.cmd/3` did, so a missing binary still raises the equivalent
  # `%ErlangError{original: :enoent}` shape the `rescue` below already wraps. A timeout is
  # treated like a non-zero exit (`:timeout` in the status position) rather than routed through
  # `decode_seal/1`: unlike `Disk.run_rooted/2` (#590), `seal/1` already distinguishes a zero
  # exit from a non-zero one instead of decoding output unconditionally, so a killed-mid-seal
  # helper with an unknown exit status fits that existing non-zero-exit shape, not
  # `decode_seal/1`'s "exited 0 but produced garbage" one.
  defp seal(%{path: path}) do
    case BoundedCommand.run("python3", [helper(), "seal", path], subprocess_timeout_ms(),
           stderr_to_stdout: true
         ) do
      {:ok, output, 0} -> decode_seal(output)
      {:ok, output, status} -> {:error, {:anonymous_seal_exit, status, output}}
      {:error, {:timeout, output}} -> {:error, {:anonymous_seal_exit, :timeout, output}}
      {:error, error} -> {:error, {:anonymous_seal_exec_failed, error}}
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

  # Kills the OS process behind `port` by pid before closing it (#591) -- `Port.close/1` alone
  # does not terminate a child stuck in a blocking syscall against a wedged mount, the same
  # #510-class defect `Disk.close_rooted_port/1` (#590) fixed in the same helper family.
  # Delegates to `Cinder.BoundedCommand.kill_and_close/1`.
  defp close_holder(port), do: BoundedCommand.kill_and_close(port)

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  defp helper do
    Application.get_env(
      :cinder,
      :anonymous_file_helper,
      Path.join(:code.priv_dir(:cinder), "anonymous_file.py")
    )
  end
end
