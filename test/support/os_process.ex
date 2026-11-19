defmodule Cinder.Test.OsProcess do
  @moduledoc """
  Tells whether an OS process a test spawned has stopped running code, for the tests that prove
  a kill reached a process the command forked (`Cinder.BoundedCommandTest`, `Cinder.DiskTest`,
  `Cinder.MutationCheckScriptTest`, `Cinder.Subtitles.Sync.FfsubsyncTest`). `await_record/1` waits for the pid a stub records,
  its own or its child's, for the tests whose bound can kill that stub before it writes it
  (`Cinder.BoundedCommandTest`, `Cinder.DiskTest`, `Cinder.Library.MediaInfo.FfprobeTest`,
  `Cinder.Subtitles.Sync.FfsubsyncTest`).

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

  @doc """
  Reads `path` up to 50 times, 20 ms apart, for the record a stub writes (a pid, its arguments):
  `{:ok, contents}` once the file holds something, `:none` when it never does. With no record
  the wait lasts at least 1 s. An empty file counts as none: the
  shell creates the file before it writes it, and a stub killed in between leaves it empty
  (#1043).

  On a loaded runner a short bound can kill the command before its stub starts, so the stub
  never records (docs/agents/testing.md). A stub the bound left alive records once it
  starts, so a caller that checks the kill on `{:ok, _}` and passes on `:none` still fails a
  missing kill when the stub starts within the wait.
  """
  @spec await_record(Path.t()) :: {:ok, String.t()} | :none
  def await_record(path), do: await_record(path, @attempts)

  defp await_record(_path, 0), do: :none

  defp await_record(path, attempts) do
    case File.read(path) do
      {:ok, contents} when contents != "" ->
        {:ok, contents}

      missing when missing in [{:ok, ""}, {:error, :enoent}] ->
        Process.sleep(@poll_ms)
        await_record(path, attempts - 1)
    end
  end

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
