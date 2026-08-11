defmodule Cinder.Library.MediaInfo.Ffprobe do
  @moduledoc """
  `Cinder.Library.MediaInfo` via the `ffprobe` CLI (FFmpeg). Reads every stream's `codec_type`,
  `default` disposition and `language` tag in one call, buckets audio vs subtitle streams, and
  drops untagged/`und` streams. `default_audio` reports the default audio track's language
  separately — `nil` unless every default-flagged track names the same language, since Matroska's
  FlagDefault means "eligible for automatic selection", not "this one plays" (issue #197).

  Returns `{:ok, %{audio: codes, subtitles: codes, default_audio: code | nil}}` or
  `{:error, reason}` when `ffprobe` is missing or exits non-zero — the importer treats an error
  (or empty lists) as "can't verify" and imports anyway, so a host without `ffprobe` degrades
  rather than blocking imports.

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
      {:exit, reason} -> {:error, {:ffprobe_exit, reason}}
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

  # One line per stream: "codec_type,default,language" — `default` is the disposition flag (1/0),
  # `language` empty (or the field absent) when the stream has no tag.
  defp args(path),
    do: ~w(-v error
        -show_entries stream=codec_type:stream_disposition=default:stream_tags=language
        -of csv=p=0) ++ [path]

  @doc false
  def parse(out) do
    rows = parse_rows(out)

    %{
      audio: Enum.uniq(for({"audio", _default?, lang} <- rows, lang != nil, do: lang)),
      subtitles: Enum.uniq(for({"subtitle", _default?, lang} <- rows, lang != nil, do: lang)),
      default_audio: default_audio(rows)
    }
  end

  @doc false
  def parse_policy(out) do
    rows = parse_rows(out)

    %{
      audio: Enum.uniq(for({"audio", _default?, lang} <- rows, is_binary(lang), do: lang)),
      subtitles: Enum.uniq(for({"subtitle", _default?, lang} <- rows, is_binary(lang), do: lang)),
      audio_unknown?: Enum.any?(rows, &match?({"audio", _default?, nil}, &1)),
      subtitle_unknown?: Enum.any?(rows, &match?({"subtitle", _default?, nil}, &1)),
      default_audio: default_audio(rows)
    }
  end

  # The language of the default audio track: what a player selects absent a viewer preference, and
  # the one fact `:audio` cannot express — a MULTi release with the dub flagged default is, as a set
  # of languages, identical to one with the original flagged default (issue #197).
  #
  # Established ONLY when the default-flagged audio tracks all name one language. Everything else is
  # nil, and the caller must not warn on nil:
  #
  #   * nothing flagged — no evidence at all;
  #   * the lone flagged track untagged — it may well BE the wanted language, so naming any other
  #     track as what plays would state the opposite of the fact;
  #   * several flagged tracks DISAGREEING — Matroska's FlagDefault marks a track "eligible for
  #     automatic selection", not "this one plays" (RFC 9559 §5.1.4.1.5; §19.1's own example flags
  #     three audio tracks). The player chooses among the eligible ones by the viewer's language
  #     preference, so a file flagging both fre and eng is correct and must not be warned about,
  #     and stream order is no proxy for that choice.
  #
  # Enum.uniq is what makes that last rule about *languages* rather than track count: the common
  # MULTi shape of one dub in 5.1 plus the same dub in 2.0, both flagged, is unambiguous — every
  # eligible track is French — and is exactly issue #197's failure mode, so it must still warn.
  #
  # Kept out of `:audio` deliberately — an `und` entry there would trip
  # `Language.audio_satisfies?/2`'s unrecognised-code escape and silently disable wrong-language
  # parks for the whole file.
  defp default_audio(rows) do
    case Enum.uniq(for {"audio", true, lang} <- rows, do: lang) do
      [lang] -> lang
      _none_or_disagreeing -> nil
    end
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
        forced?: disposition?(stream, "forced"),
        packet_count: packet_count(stream)
      }
    end
  end

  def parse_subtitle_tracks(_), do: []

  # "audio,1,eng" -> {"audio", true, "eng"}; "video,0" / "audio,0,und" -> {_, _, nil}
  # (dropped downstream).
  defp parse_rows(out) do
    out
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&parse_row/1)
  end

  defp parse_row(line) do
    case String.split(line, ",", parts: 3) do
      [type, default, lang] -> {String.trim(type), default?(default), normalize(lang)}
      [type, default] -> {String.trim(type), default?(default), nil}
      [type] -> {String.trim(type), false, nil}
    end
  end

  defp default?(flag), do: String.trim(flag) == "1"

  defp normalize(lang) do
    code = lang |> String.trim() |> String.downcase()
    if code == "" or code in @ignored, do: nil, else: code
  end

  defp subtitle_track_args(path) do
    ~w(-v error -count_packets -select_streams s
      -show_entries stream=index,codec_name,nb_read_packets:stream_disposition=default,forced:stream_tags=language
      -of json) ++ [path]
  end

  defp packet_count(%{"nb_read_packets" => count}) when is_binary(count) do
    case Integer.parse(count) do
      {value, ""} when value >= 0 -> value
      _ -> 0
    end
  end

  defp packet_count(_stream), do: 0

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
