defmodule Cinder.LowPriority do
  @moduledoc """
  Prefixes a command with `ionice -c3 -t nice -n 10`, for a subprocess that reads or decodes a
  whole video: `Cinder.Library.MediaInfo.Ffprobe`'s whole-file reads (#862) and the
  `Cinder.Subtitles.Sync.Ffsubsync` engine (#954). Playback, imports, ffprobe checks and the web
  UI then get the disk and the CPU first.

  The I/O class counts only under a disk scheduler that honours it (BFQ, mq-deadline), and only
  when the command's own process issues the reads: through a FUSE mount such as mergerfs without
  passthrough, the mount's daemon reads at its own priority. `nice -n 10` is relative to the
  caller's own niceness and stops at 19.

  Both tools exec their command, so the command keeps the pid they started under. A tool missing
  from `PATH` is skipped, and `-t` runs the command even if the kernel refuses the idle class.
  Neither tool checks the command first: a missing one exits 127, as it would under coreutils
  `timeout`.
  """

  @spec command(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def command(executable, args) do
    {executable, args}
    |> prefixed("nice", ["-n", "10"])
    |> prefixed("ionice", ["-c3", "-t"])
  end

  defp prefixed({executable, args}, tool, flags) do
    case System.find_executable(tool) do
      nil -> {executable, args}
      path -> {path, flags ++ [executable | args]}
    end
  end
end
