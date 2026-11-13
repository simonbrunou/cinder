defmodule Cinder.LowPriority do
  @moduledoc """
  Prefixes a command with `ionice -c3 -t nice -n 10`, for a subprocess that reads or decodes a
  whole video: `Cinder.Library.MediaInfo.Ffprobe`'s whole-file reads (#862) and the
  `Cinder.Subtitles.Sync.Ffsubsync` engine (#954). Playback, imports, ffprobe checks and the web
  UI then get the disk and the CPU first.

  The I/O class counts only under a disk scheduler that honours it (BFQ, mq-deadline), and only
  when the disk sees the command's reads at that class. Through a FUSE mount, by default the
  mount's daemon issues them, at its own priority. A mount that passes reads through to the
  backing file leaves them to the command: `docs/operating.md` "Subtitles" says how mergerfs 2.41
  and later do that. When #953 measured prod on 2026-11-13, its mergerfs 2.42 pool ran with
  `passthrough.io=rw`, and the live release ran an extraction `ffmpeg` at the idle class on an
  uncached 3.80 GB movie. The `ffmpeg`'s own `read_bytes` reached 3.72 GB by the last sample,
  about 1 s before it exited. Over the whole run, the branch disk read 3.81 GB and the mergerfs
  daemon 1.1 MB. `nice -n 10` is relative to the caller's own niceness and stops at 19.

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
