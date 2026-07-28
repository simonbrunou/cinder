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
    out = "video,0,\naudio,1,eng\naudio,0,fre\nsubtitle,0,eng\nsubtitle,0,und\naudio,0,\n"
    assert Ffprobe.parse(out) == %{audio: ["eng", "fre"], subtitles: ["eng"]}
  end

  test "parse dedups repeated audio/subtitle languages, preserving first-seen order" do
    out = "audio,1,eng\naudio,0,eng\naudio,0,fre\nsubtitle,0,eng\nsubtitle,0,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["eng", "fre"], subtitles: ["eng"]}
  end

  # Issue #197: a MULTi file with the dub flagged default plays as the dub. Downstream reads the
  # head of :audio as "what plays", so the default track has to sort first regardless of index.
  test "parse puts the default-disposition audio track first, keeping stream order otherwise" do
    out = "video,0,\naudio,0,fre\naudio,1,tur\naudio,0,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["tur", "fre", "eng"], subtitles: []}

    assert %{audio: ["tur", "fre", "eng"]} = Ffprobe.parse_policy(out)
  end

  # The two cases where the head is NOT a proven default track, which is why the movie-page hint
  # phrases it as the *leading* track. Both must still be plain stream order, not a guess.
  test "parse keeps stream order when no audio track carries the default disposition" do
    out = "audio,0,fre\naudio,0,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["fre", "eng"], subtitles: []}
  end

  test "parse drops an untagged default track rather than promoting it, leaving stream order" do
    out = "video,0,\naudio,1,und\naudio,0,fre\naudio,0,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["fre", "eng"], subtitles: []}

    assert %{audio: ["fre", "eng"], audio_unknown?: true} = Ffprobe.parse_policy(out)
  end

  # Real ffprobe omits the trailing field entirely for a stream with no language tag rather than
  # emitting an empty one, so the two-field row is the shape production actually hits — verified
  # against ffprobe 8.1.2 on a Matroska file whose default audio track carries only a title.
  # Without this, parse_row/1's [type, default] clause is unexercised, and a language could be
  # silently read as a disposition flag if args/1 and parse_row/1 ever drift.
  test "parse handles the two-field row real ffprobe emits for an untagged stream" do
    out = "video,0\naudio,1\naudio,0,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["eng"], subtitles: []}

    assert %{audio: ["eng"], audio_unknown?: true, subtitle_unknown?: false} =
             Ffprobe.parse_policy(out)
  end

  @tag :tmp_dir
  test "probe asks ffprobe for the default disposition, not just codec_type + language", %{
    tmp_dir: tmp
  } do
    argv = Path.join(tmp, "argv")
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" > #{argv}\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)

    assert {:ok, _} = Ffprobe.probe("/media/m.mkv")

    # Pins the arity contract parse_row/1's three-field split depends on.
    assert File.read!(argv) =~
             "stream=codec_type:stream_disposition=default:stream_tags=language"
  end

  test "parse_policy preserves whether audio and subtitle streams have unknown tags" do
    out = "video,0,\naudio,1,eng\naudio,0,und\nsubtitle,0,fre\nsubtitle,0,\n"

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
    File.write!(path, "#!/bin/sh\nprintf 'audio,1,jpn\\naudio,0,und\\nsubtitle,0,fre\\n'\n")
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
