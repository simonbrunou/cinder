defmodule Cinder.Library.MediaInfo.Ffprobe do
  @moduledoc """
  `Cinder.Library.MediaInfo` via the `ffprobe` CLI (FFmpeg). Reads every stream's `codec_type`
  and `language` tag in one call, buckets audio vs subtitle streams, and drops untagged/`und`
  streams. Returns `{:ok, %{audio: codes, subtitles: codes}}` or `{:error, reason}` when `ffprobe`
  is missing or exits non-zero — the importer treats an error (or empty lists) as "can't verify"
  and imports anyway, so a host without `ffprobe` degrades rather than blocking imports.

  The binary is `ffprobe` on `PATH` by default; override with `config :cinder, :ffprobe_bin`.
  """
  @behaviour Cinder.Library.MediaInfo

  @ignored ~w(und unknown)

  @impl true
  def probe(path) do
    case System.cmd(bin(), args(path), stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse(out)}
      {out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
    end
  rescue
    e -> {:error, e}
  end

  # One line per stream: "codec_type,language" (language empty when the stream has no tag).
  defp args(path),
    do: ~w(-v error -show_entries stream=codec_type:stream_tags=language -of csv=p=0) ++ [path]

  @doc false
  def parse(out) do
    rows =
      out
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.map(&parse_row/1)

    %{
      audio: for({"audio", lang} <- rows, lang != nil, do: lang),
      subtitles: for({"subtitle", lang} <- rows, lang != nil, do: lang)
    }
  end

  # "audio,eng" -> {"audio", "eng"}; "video," / "audio,und" -> {_, nil} (dropped downstream).
  defp parse_row(line) do
    case String.split(line, ",", parts: 2) do
      [type, lang] -> {String.trim(type), normalize(lang)}
      [type] -> {String.trim(type), nil}
    end
  end

  defp normalize(lang) do
    code = lang |> String.trim() |> String.downcase()
    if code == "" or code in @ignored, do: nil, else: code
  end

  defp bin, do: Application.get_env(:cinder, :ffprobe_bin, "ffprobe")
end
