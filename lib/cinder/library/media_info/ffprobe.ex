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

  alias Cinder.Acquisition.Parser

  @ignored ~w(und unknown)
  @text_codecs ~w(subrip ass ssa mov_text text webvtt)
  @aliases for {iso1, codes} <- Parser.audio_codes(), code <- codes, into: %{}, do: {code, iso1}
  @stderr_env "CINDER_FFMPEG_STDERR"
  @health_timeout 3_000

  @impl true
  def probe(path), do: run_probe(path, &parse/1)

  @impl true
  def probe_policy(path), do: run_probe(path, &parse_policy/1)

  # `-version` is a cheap no-file call: proves the binary exists and runs, bounded to
  # @health_timeout so a hung binary can't stall /status or "Test connection" (mirrors the
  # ~3s bound every other service's health/0 uses). The missing-binary rescue runs INSIDE the
  # task: Task.async links the caller to the task, so an uncaught raise there (e.g. `:enoent`)
  # would crash the caller via the link's EXIT signal rather than return `{:error, _}`.
  @impl true
  def health do
    task =
      Task.async(fn ->
        try do
          System.cmd(bin(), ["-version"], stderr_to_stdout: true)
        rescue
          e -> {:error, e}
        end
      end)

    case Task.yield(task, @health_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, _} = error} -> error
      {:ok, {_out, 0}} -> :ok
      {:ok, {out, code}} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
      nil -> {:error, :timeout}
    end
  end

  defp run_probe(path, parser) do
    case System.cmd(bin(), args(path), stderr_to_stdout: true) do
      {out, 0} -> {:ok, parser.(out)}
      {out, code} -> {:error, {:ffprobe_exit, code, String.trim(out)}}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def subtitle_tracks(path) do
    case System.cmd(bin(), subtitle_track_args(path), stderr_to_stdout: true) do
      {out, 0} ->
        with {:ok, metadata} <- Jason.decode(out) do
          {:ok, parse_subtitle_tracks(metadata)}
        end

      {out, code} ->
        {:error, {:ffprobe_exit, code, String.trim(out)}}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def extract_subtitle(path, index) do
    stderr_path =
      Path.join(System.tmp_dir!(), "cinder-ffmpeg-#{System.unique_integer([:positive])}.stderr")

    try do
      case System.cmd(
             "/bin/sh",
             [
               "-c",
               "exec \"$@\" 2> \"$#{@stderr_env}\"",
               "--",
               ffmpeg_executable!() | ffmpeg_args(path, index)
             ],
             env: [{@stderr_env, stderr_path}]
           ) do
        {out, 0} -> {:ok, out}
        {_out, code} -> {:error, {:ffmpeg_exit, code, read_stderr(stderr_path)}}
      end
    after
      File.rm(stderr_path)
    end
  rescue
    e -> {:error, e}
  end

  # One line per stream: "codec_type,language" (language empty when the stream has no tag).
  defp args(path),
    do: ~w(-v error -show_entries stream=codec_type:stream_tags=language -of csv=p=0) ++ [path]

  @doc false
  def parse(out) do
    rows = parse_rows(out)

    %{
      audio: Enum.uniq(for({"audio", lang} <- rows, lang != nil, do: lang)),
      subtitles: Enum.uniq(for({"subtitle", lang} <- rows, lang != nil, do: lang))
    }
  end

  @doc false
  def parse_policy(out) do
    rows = parse_rows(out)

    %{
      audio: Enum.uniq(for({"audio", lang} <- rows, is_binary(lang), do: lang)),
      subtitles: Enum.uniq(for({"subtitle", lang} <- rows, is_binary(lang), do: lang)),
      audio_unknown?: Enum.any?(rows, &match?({"audio", nil}, &1)),
      subtitle_unknown?: Enum.any?(rows, &match?({"subtitle", nil}, &1))
    }
  end

  @doc false
  def parse_subtitle_tracks(%{"streams" => streams}) when is_list(streams) do
    for %{"index" => index, "codec_name" => codec_name} = stream <- streams,
        is_integer(index) and index >= 0,
        codec_name in @text_codecs do
      %{
        index: index,
        language: subtitle_language(stream),
        default?: disposition?(stream, "default"),
        forced?: disposition?(stream, "forced")
      }
    end
  end

  def parse_subtitle_tracks(_), do: []

  # "audio,eng" -> {"audio", "eng"}; "video," / "audio,und" -> {_, nil} (dropped downstream).
  defp parse_rows(out) do
    out
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&parse_row/1)
  end

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

  defp subtitle_track_args(path) do
    ~w(-v error -select_streams s
      -show_entries stream=index,codec_name:stream_disposition=default,forced:stream_tags=language
      -of json) ++ [path]
  end

  defp ffmpeg_args(path, index) do
    [
      "-nostdin",
      "-v",
      "error",
      "-i",
      path,
      "-map",
      "0:#{index}",
      "-c:s",
      "srt",
      "-f",
      "srt",
      "pipe:1"
    ]
  end

  defp subtitle_language(%{"tags" => %{"language" => language}}) when is_binary(language) do
    @aliases[language |> String.trim() |> String.downcase()] || "und"
  end

  defp subtitle_language(_), do: "und"

  defp disposition?(%{"disposition" => disposition}, key) when is_map(disposition) do
    Map.get(disposition, key, 0) == 1
  end

  defp disposition?(_, _), do: false

  defp bin, do: Application.get_env(:cinder, :ffprobe_bin, "ffprobe")
  defp ffmpeg_bin, do: Application.get_env(:cinder, :ffmpeg_bin, "ffmpeg")

  defp ffmpeg_executable! do
    case System.find_executable(ffmpeg_bin()) do
      nil ->
        System.cmd(ffmpeg_bin(), [])
        ffmpeg_bin()

      executable ->
        executable
    end
  end

  defp read_stderr(path) do
    case File.read(path) do
      {:ok, stderr} -> String.trim(stderr)
      {:error, _} -> ""
    end
  end
end
