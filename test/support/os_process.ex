defmodule Cinder.Test.OsProcess do
  @moduledoc """
  Tells whether an OS process a test spawned has stopped running code, for the tests that prove
  a kill reached a process the command forked (`Cinder.BoundedCommandTest`, `Cinder.DiskTest`).

  A forked child whose parent died is reparented, and the CI job container's PID 1 may never
  reap it. A zombie still answers `kill -0`, so `dead?/1` reads the process state from `/proc`
  instead.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @attempts 50
  @poll_ms 20

  @doc """
  Polls `/proc/<pid>/stat` for up to 1 s, since a `SIGKILL` is not instantaneous from here. Gone,
  zombie (`Z`) or dead (`X`) all count as dead. A process reaped mid-read answers `:esrch`. The
  command name in parentheses may hold spaces, so the state is the first field after the last
  `)`. Flunks on a host without `/proc`, where every pid would read as gone.
  """
  @spec dead?(pos_integer()) :: boolean()
  def dead?(pid), do: dead?(pid, @attempts)

  defp dead?(_pid, 0), do: false

  defp dead?(pid, attempts) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        state =
          stat |> String.split(")") |> List.last() |> String.trim_leading() |> String.first()

        if state in ["Z", "X"] do
          true
        else
          Process.sleep(@poll_ms)
          dead?(pid, attempts - 1)
        end

      {:error, reason} when reason in [:enoent, :esrch] ->
        File.dir?("/proc/self") or flunk("OsProcess.dead?/1 reads /proc, which this host lacks")
    end
  end
end
