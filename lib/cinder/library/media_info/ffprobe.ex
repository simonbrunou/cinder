defmodule Cinder.Library.MediaInfo.Ffprobe do
  @moduledoc """
  `Cinder.Library.MediaInfo` via the `ffprobe` CLI (FFmpeg). Reads each audio stream's `language`
  tag, dropping untagged/`und` streams. Returns `{:ok, codes}` (lowercased, possibly empty when no
  stream declares a language) or `{:error, reason}` when `ffprobe` is missing or exits non-zero —
  the importer treats an empty list or an error as "can't verify" and imports anyway, so a host
  without `ffprobe` degrades to the previous behaviour rather than blocking imports.

  The binary is `ffprobe` on `PATH` by default; override with `config :cinder, :ffprobe_bin`.
  """
  @behaviour Cinder.Library.MediaInfo

  @ignored ~w(und unknown)

  @impl true
  def audio_languages(path) do
    case System.cmd(bin(), args(path), stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse(out)}
      {out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
    end
  rescue
    # System.cmd raises ErlangError {:enoent} when the binary isn't installed; never let that
    # crash the import — surface it as an error the caller maps to "can't verify".
    e -> {:error, e}
  end

  # One line per audio stream with just its `language` tag value (empty when the stream has none).
  defp args(path),
    do: ~w(-v error -select_streams a -show_entries stream_tags=language -of csv=p=0) ++ [path]

  defp parse(out) do
    out
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == "" or &1 in @ignored))
  end

  defp bin, do: Application.get_env(:cinder, :ffprobe_bin, "ffprobe")
end
