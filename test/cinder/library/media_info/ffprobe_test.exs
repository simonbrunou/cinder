defmodule Cinder.Library.MediaInfo.FfprobeTest do
  use ExUnit.Case, async: false

  alias Cinder.Library.MediaInfo.Ffprobe

  setup do
    ffmpeg_bin = Application.get_env(:cinder, :ffmpeg_bin)
    ffprobe_bin = Application.get_env(:cinder, :ffprobe_bin)

    on_exit(fn ->
      restore_bin(:ffmpeg_bin, ffmpeg_bin)
      restore_bin(:ffprobe_bin, ffprobe_bin)
    end)
  end

  test "parse buckets audio + subtitle streams by codec_type, dropping und/empty" do
    out = "video,\naudio,eng\naudio,fre\nsubtitle,eng\nsubtitle,und\naudio,\n"
    assert Ffprobe.parse(out) == %{audio: ["eng", "fre"], subtitles: ["eng"]}
  end

  test "parse dedups repeated audio/subtitle languages, preserving first-seen order" do
    out = "audio,eng\naudio,eng\naudio,fre\nsubtitle,eng\nsubtitle,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["eng", "fre"], subtitles: ["eng"]}
  end

  test "parse_policy preserves whether audio and subtitle streams have unknown tags" do
    out = "video,\naudio,eng\naudio,und\nsubtitle,fre\nsubtitle,\n"

    assert Ffprobe.parse_policy(out) == %{
             audio: ["eng"],
             subtitles: ["fre"],
             audio_unknown?: true,
             subtitle_unknown?: true
           }

    assert Ffprobe.parse(out) == %{audio: ["eng"], subtitles: ["fre"]}
  end

  @tag :tmp_dir
  test "probe_policy returns the detailed report from one ffprobe invocation", %{tmp_dir: tmp} do
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\nprintf 'audio,jpn\\naudio,und\\nsubtitle,fre\\n'\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)

    assert Ffprobe.probe_policy("/media/anime.mkv") ==
             {:ok,
              %{
                audio: ["jpn"],
                subtitles: ["fre"],
                audio_unknown?: true,
                subtitle_unknown?: false
              }}
  end

  test "parse_subtitle_tracks/1 keeps supported text tracks in ffprobe order" do
    assert Ffprobe.parse_subtitle_tracks(%{
             "streams" => [
               %{
                 "index" => 2,
                 "codec_name" => "subrip",
                 "tags" => %{"language" => "eng"},
                 "disposition" => %{"default" => 1, "forced" => 0}
               },
               %{
                 "index" => 3,
                 "codec_name" => "hdmv_pgs_subtitle",
                 "tags" => %{"language" => "fra"},
                 "disposition" => %{"default" => 0, "forced" => 0}
               }
             ]
           }) == [%{index: 2, language: "en", default?: true, forced?: false}]
  end

  @tag :tmp_dir
  test "extract_subtitle/2 returns stdout without successful-process stderr", %{tmp_dir: tmp} do
    use_ffmpeg_bin(tmp, "printf 'subtitle bytes'; printf 'diagnostic' >&2")

    assert Ffprobe.extract_subtitle("/media/movie.mkv", 2) == {:ok, "subtitle bytes"}
  end

  @tag :tmp_dir
  test "extract_subtitle/2 returns trimmed stderr on a failed process", %{tmp_dir: tmp} do
    use_ffmpeg_bin(tmp, "printf 'partial output'; printf 'cannot decode\\n' >&2; exit 7")

    assert Ffprobe.extract_subtitle("/media/movie.mkv", 2) ==
             {:error, {:ffmpeg_exit, 7, "cannot decode"}}
  end

  defp use_ffmpeg_bin(tmp, script) do
    path = Path.join(tmp, "ffmpeg")
    File.write!(path, "#!/bin/sh\n#{script}\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffmpeg_bin, path)
  end

  defp restore_bin(key, nil), do: Application.delete_env(:cinder, key)
  defp restore_bin(key, value), do: Application.put_env(:cinder, key, value)
end
