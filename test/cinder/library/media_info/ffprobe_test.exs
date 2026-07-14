defmodule Cinder.Library.MediaInfo.FfprobeTest do
  use ExUnit.Case, async: false

  alias Cinder.Library.{MediaInfo.Ffprobe, PolicyVerifier}

  setup do
    ffmpeg_bin = Application.get_env(:cinder, :ffmpeg_bin)
    ffprobe_bin = Application.get_env(:cinder, :ffprobe_bin)

    on_exit(fn ->
      restore_bin(:ffmpeg_bin, ffmpeg_bin)
      restore_bin(:ffprobe_bin, ffprobe_bin)
    end)
  end

  @tag :tmp_dir
  test "health/0 is :ok when the binary runs and exits zero", %{tmp_dir: tmp} do
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)

    assert Ffprobe.health() == :ok
  end

  @tag :tmp_dir
  test "health/0 surfaces a non-zero exit", %{tmp_dir: tmp} do
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\nprintf 'boom' >&2\nexit 3\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)

    assert Ffprobe.health() == {:error, {:ffprobe_exit, 3, "boom"}}
  end

  test "health/0 surfaces a missing binary as an error instead of crashing" do
    Application.put_env(:cinder, :ffprobe_bin, "definitely-not-a-real-binary")

    assert {:error, %ErlangError{original: :enoent}} = Ffprobe.health()
  end

  @tag :tmp_dir
  test "Health.check_service(:media_info) delegates to the configured impl's health/0", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)

    media_info = Application.get_env(:cinder, :media_info)
    Application.put_env(:cinder, :media_info, Ffprobe)
    on_exit(fn -> restore_bin(:media_info, media_info) end)

    assert Cinder.Health.check_service(:media_info) == :ok
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

  @tag :tmp_dir
  test "policy failure evidence strips ffprobe stderr while Standard probe keeps diagnostics", %{
    tmp_dir: tmp
  } do
    source = "/downloads/private/anime.mkv"
    stderr = "#{source}: token=secret: invalid data"
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\nprintf '#{stderr}\\n' >&2\nexit 7\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)

    assert Ffprobe.probe(source) == {:error, {:ffprobe_exit, 7, stderr}}

    assert {:unavailable, {:probe_failed, "anime.mkv", {:ffprobe_exit, 7}}} =
             result = PolicyVerifier.verify_sources([source], policy_snapshot(), Ffprobe)

    refute inspect(result) =~ source
    refute inspect(result) =~ stderr
    refute inspect(result) =~ "secret"
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

  defp policy_snapshot do
    %{
      "required_audio_languages" => ["ja"],
      "required_embedded_subtitle_languages" => []
    }
  end

  defp restore_bin(key, nil), do: Application.delete_env(:cinder, key)
  defp restore_bin(key, value), do: Application.put_env(:cinder, key, value)
end
