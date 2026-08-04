defmodule Cinder.Disk.CommandProbe do
  @moduledoc false

  use GenServer

  @missing_path_status 66
  @reap_wait 100
  @call_headroom 1_000
  @probe_script """
  if [ ! -d "$1" ]; then
    exit #{@missing_path_status}
  fi
  exec "$2" -kP "$1"
  """

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :idle, name: __MODULE__)
  end

  @spec run(String.t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def run(path, timeout) when is_binary(path) and is_integer(timeout) and timeout >= 0 do
    GenServer.call(__MODULE__, {:run, path, timeout}, timeout + @call_headroom)
  catch
    :exit, reason -> {:error, {:probe_unavailable, reason}}
  end

  def run(_path, _timeout), do: {:error, :invalid_probe_timeout}

  @impl true
  def init(:idle) do
    Process.flag(:trap_exit, true)
    {:ok, :idle}
  end

  @impl true
  def handle_call({:run, path, timeout}, from, :idle) do
    case open_probe(path) do
      {:ok, port} ->
        timer = Process.send_after(self(), {:probe_timeout, port}, timeout)
        {:noreply, {:active, port, from, [], timer}}

      {:error, _reason} = error ->
        {:reply, error, :idle}
    end
  end

  def handle_call(
        {:run, _path, _timeout},
        _from,
        {:active, _port, _caller, _output, _timer} = state
      ) do
    {:reply, {:error, :probe_busy}, state}
  end

  def handle_call({:run, _path, _timeout}, _from, {:terminating, _port, _caller, _timer} = state) do
    {:reply, {:error, :probe_draining}, state}
  end

  def handle_call({:run, _path, _timeout}, _from, {:draining, _port} = state) do
    {:reply, {:error, :probe_draining}, state}
  end

  @impl true
  def handle_info(
        {port, {:data, data}},
        {:active, port, caller, output, timer}
      ) do
    {:noreply, {:active, port, caller, [data | output], timer}}
  end

  def handle_info(
        {port, {:exit_status, status}},
        {:active, port, caller, output, timer}
      ) do
    Process.cancel_timer(timer)
    GenServer.reply(caller, exit_result(status, output))
    {:noreply, :idle}
  end

  def handle_info(
        {:EXIT, port, reason},
        {:active, port, caller, _output, timer}
      ) do
    Process.cancel_timer(timer)
    GenServer.reply(caller, {:error, {:port_exit, reason}})
    {:noreply, :idle}
  end

  def handle_info(
        {:probe_timeout, port},
        {:active, port, caller, _output, _timer}
      ) do
    kill(port)
    timer = Process.send_after(self(), {:reap_deadline, port}, @reap_wait)
    {:noreply, {:terminating, port, caller, timer}}
  end

  def handle_info({port, {:data, _data}}, {:terminating, port, _caller, _timer} = state),
    do: {:noreply, state}

  def handle_info(
        {port, {:exit_status, _status}},
        {:terminating, port, caller, timer}
      ) do
    Process.cancel_timer(timer)
    GenServer.reply(caller, {:error, :timeout})
    {:noreply, :idle}
  end

  def handle_info(
        {:EXIT, port, _reason},
        {:terminating, port, caller, timer}
      ) do
    Process.cancel_timer(timer)
    GenServer.reply(caller, {:error, :timeout})
    {:noreply, :idle}
  end

  def handle_info(
        {:reap_deadline, port},
        {:terminating, port, caller, _timer}
      ) do
    GenServer.reply(caller, {:error, :timeout})

    if Port.info(port) == nil do
      {:noreply, :idle}
    else
      {:noreply, {:draining, port}}
    end
  end

  def handle_info({port, {:data, _data}}, {:draining, port} = state), do: {:noreply, state}
  def handle_info({port, {:exit_status, _status}}, {:draining, port}), do: {:noreply, :idle}
  def handle_info({:EXIT, port, _reason}, {:draining, port}), do: {:noreply, :idle}
  def handle_info(_message, state), do: {:noreply, state}

  defp open_probe(path) do
    shell_bin = Application.get_env(:cinder, :disk_probe_shell, "/bin/sh")
    df_bin = Application.get_env(:cinder, :disk_df_bin, "df")
    operand = path_operand(path)

    with {:ok, shell} <- find_executable(shell_bin, :probe_shell_not_found),
         {:ok, df} <- find_executable(df_bin, :df_not_found) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(shell)},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args:
              Enum.map(
                ["-c", @probe_script, "cinder-disk-probe", operand, df],
                &String.to_charlist/1
              )
          ]
        )

      {:ok, port}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp find_executable(name, error) do
    case System.find_executable(name) do
      nil -> {:error, error}
      executable -> {:ok, executable}
    end
  end

  # Prefix a relative leading dash without relying on GNU's non-POSIX `--` terminator.
  defp path_operand("-" <> _rest = path), do: "./" <> path
  defp path_operand(path), do: path

  defp exit_result(0, output),
    do: {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}

  defp exit_result(@missing_path_status, _output), do: {:error, :enoent}
  defp exit_result(status, _output), do: {:error, {:df_exit, status}}

  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      killer = Application.get_env(:cinder, :disk_probe_killer, &kill_os_process/1)
      _ = killer.(pid)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp kill_os_process(pid) do
    System.cmd(
      "/bin/sh",
      ["-c", ~S|kill -KILL "$1"|, "kill", Integer.to_string(pid)],
      stderr_to_stdout: true
    )
  end
end
