defmodule Cinder.Library.MediaInfo.FfprobeTest do
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.Language
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

  # #510: `health/0` used the lighter `Task.async/yield/shutdown(:brutal_kill)` idiom — the
  # exact defect `probe/1`/`probe_policy/1`/`subtitle_tracks/1`/`extract_subtitle/2` already fixed
  # for issue #447: killing the Elixir task does not kill a child that never reads stdin.
  @tag :tmp_dir
  test "health/0 kills the underlying ffprobe process on timeout, not just the Elixir task", %{
    tmp_dir: tmp
  } do
    pidfile = Path.join(tmp, "ffprobe.pid")
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\necho $$ > #{pidfile}\nexec sleep 30\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)
    with_short_timeout(:ffprobe_health_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)
    assert Ffprobe.health() == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - t0 < 3000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)
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
    assert %{audio: ["eng", "fre"], subtitles: ["eng"], default_audio: "eng"} = Ffprobe.parse(out)
  end

  test "parse dedups repeated audio/subtitle languages, preserving first-seen order" do
    out = "audio,1,eng\naudio,0,eng\naudio,0,fre\nsubtitle,0,eng\nsubtitle,0,eng\n"
    assert %{audio: ["eng", "fre"], subtitles: ["eng"]} = Ffprobe.parse(out)
  end

  # Issue #197: a MULTi file with the dub flagged default plays as the dub, and as a *set* of
  # languages it is identical to one with the original flagged default. Hence a separate field.
  test "parse reports the default-disposition audio track's language, leaving :audio in stream order" do
    out = "video,0,\naudio,0,fre\naudio,1,tur\naudio,0,eng\n"

    assert Ffprobe.parse(out) == %{
             audio: ["fre", "tur", "eng"],
             subtitles: [],
             default_audio: "tur"
           }

    assert %{audio: ["fre", "tur", "eng"], default_audio: "tur"} = Ffprobe.parse_policy(out)
  end

  # The three cases where the default track's language is NOT established — no flag, an untagged
  # flag, and flags that disagree. All must report nil rather than infer one.
  test "parse reports no default language when no audio track carries the disposition" do
    out = "audio,0,fre\naudio,0,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["fre", "eng"], subtitles: [], default_audio: nil}
  end

  test "parse reports no default language when the default track is untagged" do
    out = "video,0,\naudio,1,und\naudio,0,fre\naudio,0,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["fre", "eng"], subtitles: [], default_audio: nil}

    assert %{audio: ["fre", "eng"], audio_unknown?: true, default_audio: nil} =
             Ffprobe.parse_policy(out)
  end

  # Matroska's FlagDefault means "eligible for automatic selection", not "this one plays": with
  # several flagged the player picks by the viewer's language preference, so a file offering both
  # fre and eng is correct and naming either as what plays would be a false warning. Stream order
  # is no proxy for that choice.
  test "parse establishes no default language when the flagged tracks disagree" do
    assert %{default_audio: nil} = Ffprobe.parse("audio,1,fre\naudio,1,eng\n")
    assert %{default_audio: nil} = Ffprobe.parse("audio,1,und\naudio,1,eng\n")

    # ...but exactly one flagged track still establishes it — issue #197's own shape.
    assert %{default_audio: "tur"} = Ffprobe.parse("audio,1,tur\naudio,0,eng\n")
  end

  # Several flagged tracks that AGREE are unambiguous, and this is the common MULTi shape (one dub
  # in 5.1 + the same dub in 2.0, both flagged, original unflagged). Deciding "several" on track
  # count rather than distinct languages would silence issue #197's own failure mode.
  test "parse establishes the default language when every flagged track agrees" do
    assert %{default_audio: "fre"} = Ffprobe.parse("audio,1,fre\naudio,1,fre\naudio,0,eng\n")

    # Two untagged flags still establish nothing.
    assert %{default_audio: nil} = Ffprobe.parse("audio,1,und\naudio,1,und\naudio,0,eng\n")
  end

  # An `und` entry in :audio would trip Language.audio_satisfies?/2's unrecognised-code escape and
  # silently disable wrong-language parks for the whole file, so it stays out.
  test "an untagged default track never leaks into :audio" do
    out = "audio,1,und\naudio,0,tur\n"
    assert %{audio: ["tur"]} = Ffprobe.parse(out)
    refute Language.audio_satisfies?("en", ["tur"])
  end

  # Real ffprobe omits the trailing field entirely for a stream with no language tag rather than
  # emitting an empty one, so the two-field row is the shape production actually hits — verified
  # against ffprobe 8.1.2 on a Matroska file whose default audio track carries only a title.
  # Without this, parse_row/1's [type, default] clause is unexercised, and a language could be
  # silently read as a disposition flag if args/1 and parse_row/1 ever drift.
  test "parse handles the two-field row real ffprobe emits for an untagged stream" do
    out = "video,0\naudio,1\naudio,0,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["eng"], subtitles: [], default_audio: nil}

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
             subtitle_unknown?: true,
             default_audio: "eng"
           }

    assert %{audio: ["eng"], subtitles: ["fre"]} = Ffprobe.parse(out)
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
                subtitle_unknown?: false,
                default_audio: "jpn"
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
           }) == [
             %{index: 2, language: "eng", default?: true, forced?: false, packet_count: 0}
           ]
  end

  test "parse_subtitle_tracks/1 reports chi/zho/yue as their raw ffprobe codes, not zh/cn (#573)" do
    # #519 previously canonicalized this value through Language.normalize/1 so "chi"/"zho"/"yue"
    # all read as "zh"/"cn". That collapsed the very distinction a Cantonese "cn" reference/local
    # source selector needs to tell a generic Chinese track ("chi"/"zho", forward-tolerant) apart
    # from an explicitly Mandarin one ("cmn", never tolerant) - see Language.raw_track_satisfies?/2.
    assert Ffprobe.parse_subtitle_tracks(%{
             "streams" => [
               %{
                 "index" => 2,
                 "codec_name" => "subrip",
                 "tags" => %{"language" => "chi"},
                 "disposition" => %{"default" => 0, "forced" => 0}
               },
               %{
                 "index" => 3,
                 "codec_name" => "subrip",
                 "tags" => %{"language" => "zho"},
                 "disposition" => %{"default" => 0, "forced" => 0}
               },
               %{
                 "index" => 4,
                 "codec_name" => "subrip",
                 "tags" => %{"language" => "yue"},
                 "disposition" => %{"default" => 0, "forced" => 0}
               }
             ]
           }) == [
             %{index: 2, language: "chi", default?: false, forced?: false, packet_count: 0},
             %{index: 3, language: "zho", default?: false, forced?: false, packet_count: 0},
             %{index: 4, language: "yue", default?: false, forced?: false, packet_count: 0}
           ]
  end

  test "parse_subtitle_tracks/1 exposes packet counts for broadest-reference selection" do
    assert Ffprobe.parse_subtitle_tracks(%{
             "streams" => [
               %{
                 "index" => 2,
                 "codec_name" => "subrip",
                 "nb_read_packets" => "18",
                 "disposition" => %{"forced" => 0}
               },
               %{
                 "index" => 4,
                 "codec_name" => "ass",
                 "nb_read_packets" => "N/A",
                 "disposition" => %{"forced" => 0}
               }
             ]
           }) == [
             %{index: 2, language: "und", default?: false, forced?: false, packet_count: 18},
             %{index: 4, language: "und", default?: false, forced?: false, packet_count: 0}
           ]
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

  @tag :tmp_dir
  test "probe/1 kills a hung ffprobe process and returns {:error, :timeout} within its bound", %{
    tmp_dir: tmp
  } do
    use_hanging_ffprobe(tmp)
    with_short_timeout(:ffprobe_probe_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)
    assert Ffprobe.probe("/media/movie.mkv") == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - t0 < 3000
  end

  @tag :tmp_dir
  test "probe_policy/1 kills a hung ffprobe process and returns {:error, :timeout} within its bound",
       %{tmp_dir: tmp} do
    use_hanging_ffprobe(tmp)
    with_short_timeout(:ffprobe_probe_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)
    assert Ffprobe.probe_policy("/media/movie.mkv") == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - t0 < 3000
  end

  @tag :tmp_dir
  test "subtitle_tracks/1 kills a hung ffprobe process and returns {:error, :timeout} within its bound",
       %{tmp_dir: tmp} do
    use_hanging_ffprobe(tmp)
    with_short_timeout(:ffprobe_subtitle_tracks_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)
    assert Ffprobe.subtitle_tracks("/media/movie.mkv") == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - t0 < 3000
  end

  # Proves the deadline is an ABSOLUTE bound, not a per-message poll tick that a chatty process
  # can keep resetting: this stub emits `:data` continuously, as fast as the shell can write, so
  # a loop that only re-checks the deadline in its `after` branch — the module's actual shape
  # before this test was added, with a fixed 100ms poll interval — would have that timer's clock
  # perpetually reset by a message already waiting in the mailbox by the time each `receive` is
  # re-entered, and would never time out at all: confirmed directly against the pre-fix
  # `supervise/4` (calling `Ffprobe.extract_subtitle/2` outside ExUnit, with this exact stub) —
  # it hung indefinitely rather than returning `{:error, :timeout}`. A slower, sleep-throttled
  # version of this same stub was tried first and did not reliably fail under `mix test`'s own
  # scheduler load (many concurrent test processes introduce enough incidental scheduling gaps
  # to occasionally let a 100ms `after` fire "by accident"); this max-speed, no-sleep version
  # leaves no such gap and fails deterministically instead. `extract_subtitle/2` (ffmpeg piping
  # SRT to stdout) is the real-world path most exposed to this: a corrupt/pathological stream can
  # make ffmpeg emit output continuously.
  @tag :tmp_dir
  @tag timeout: 5_000
  test "extract_subtitle/2 still times out when the process emits data faster than any poll tick",
       %{tmp_dir: tmp} do
    pidfile = Path.join(tmp, "ffmpeg.pid")
    use_ffmpeg_bin(tmp, "echo $$ > #{pidfile}\nwhile :; do printf spam; done")
    with_short_timeout(:ffmpeg_extract_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)
    assert Ffprobe.extract_subtitle("/media/movie.mkv", 2) == {:error, :timeout}
    elapsed = System.monotonic_time(:millisecond) - t0

    # Close to the configured bound (not merely "eventually finite") — proves the deadline fired
    # on schedule rather than being starved indefinitely by the continuous stream of data.
    assert elapsed >= 150
    assert elapsed < 1000

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)
  end

  @tag :tmp_dir
  test "extract_subtitle/2 kills a hung ffmpeg process and returns {:error, :timeout} within its bound",
       %{tmp_dir: tmp} do
    use_ffmpeg_bin(tmp, "exec sleep 30")
    with_short_timeout(:ffmpeg_extract_timeout_ms, 150)

    t0 = System.monotonic_time(:millisecond)
    assert Ffprobe.extract_subtitle("/media/movie.mkv", 2) == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - t0 < 3000
  end

  # The whole point of the heavier Port+SIGKILL pattern over `Task.shutdown(:brutal_kill)` is
  # that the real OS process dies, not just Cinder's side of the port — otherwise every poller
  # tick against a hung file would leak one more orphaned ffmpeg holding a staging-file fd.
  # Exercises the trickiest chain: `/bin/sh -c 'exec "$@" ...'` -> `exec`'d ffmpeg stub ->
  # `exec`'d `sleep`, all sharing one pid via POSIX `exec`'s "replace, don't fork" semantics, so
  # the pid our stub records is exactly the pid `kill/1` targets.
  @tag :tmp_dir
  test "extract_subtitle/2 timeout kills the underlying OS process, not just the Elixir call",
       %{tmp_dir: tmp} do
    pidfile = Path.join(tmp, "ffmpeg.pid")
    use_ffmpeg_bin(tmp, "echo $$ > #{pidfile}\nexec sleep 30")
    with_short_timeout(:ffmpeg_extract_timeout_ms, 150)

    assert Ffprobe.extract_subtitle("/media/movie.mkv", 2) == {:error, :timeout}

    pid = wait_for_pidfile(pidfile)
    assert process_gone?(pid)
  end

  # Neither poller GenServer (`Cinder.Download.Poller`/`TvPoller`) traps exits or has a
  # catch-all `handle_info/2` — a stray `{port, {:data, _}}`/`{port, {:exit_status, _}}` message
  # surviving past this call's return would crash it with `FunctionClauseError`. Proves the
  # killed port's messages are fully drained before `probe/1` returns, from the caller's own
  # mailbox (this test process IS the port owner, exactly like the poller would be).
  @tag :tmp_dir
  test "probe/1's timeout leaves no port messages behind in the caller's mailbox", %{
    tmp_dir: tmp
  } do
    use_hanging_ffprobe(tmp)
    with_short_timeout(:ffprobe_probe_timeout_ms, 150)

    assert Ffprobe.probe("/media/movie.mkv") == {:error, :timeout}

    refute_receive {_port, {:data, _data}}, 300
    refute_receive {_port, {:exit_status, _status}}, 50
  end

  test "probe/1 surfaces a missing binary as an error instead of crashing" do
    Application.put_env(:cinder, :ffprobe_bin, "definitely-not-a-real-binary")
    assert {:error, %ErlangError{original: :enoent}} = Ffprobe.probe("/media/movie.mkv")
  end

  test "probe_policy/1 surfaces a missing binary as an error instead of crashing" do
    Application.put_env(:cinder, :ffprobe_bin, "definitely-not-a-real-binary")
    assert {:error, %ErlangError{original: :enoent}} = Ffprobe.probe_policy("/media/movie.mkv")
  end

  test "subtitle_tracks/1 surfaces a missing binary as an error instead of crashing" do
    Application.put_env(:cinder, :ffprobe_bin, "definitely-not-a-real-binary")
    assert {:error, %ErlangError{original: :enoent}} = Ffprobe.subtitle_tracks("/media/movie.mkv")
  end

  test "extract_subtitle/2 surfaces a missing ffmpeg binary as an error instead of crashing" do
    Application.put_env(:cinder, :ffmpeg_bin, "definitely-not-a-real-binary")

    assert {:error, %ErlangError{original: :enoent}} =
             Ffprobe.extract_subtitle("/media/movie.mkv", 2)
  end

  defp use_ffmpeg_bin(tmp, script) do
    path = Path.join(tmp, "ffmpeg")
    File.write!(path, "#!/bin/sh\n#{script}\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffmpeg_bin, path)
  end

  defp use_hanging_ffprobe(tmp) do
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)
  end

  defp with_short_timeout(key, ms) do
    previous = Application.get_env(:cinder, key)
    Application.put_env(:cinder, key, ms)
    on_exit(fn -> restore_bin(key, previous) end)
  end

  # Bounded poll for the stub's own pid file — it is written before the stub `exec`s into the
  # long sleep, so this only waits for the process to have actually started.
  defp wait_for_pidfile(pidfile, attempts \\ 50)

  defp wait_for_pidfile(_pidfile, 0), do: flunk("stub process never wrote its pid file")

  defp wait_for_pidfile(pidfile, attempts) do
    case File.read(pidfile) do
      {:ok, content} ->
        content |> String.trim() |> String.to_integer()

      {:error, :enoent} ->
        Process.sleep(20)
        wait_for_pidfile(pidfile, attempts - 1)
    end
  end

  # `kill -0` sends no signal, just checks the pid is reachable; a real OS SIGKILL is not
  # instantaneous from the caller's point of view, so this polls a short bounded window rather
  # than asserting on the very first check.
  defp process_gone?(pid, attempts \\ 50)
  defp process_gone?(_pid, 0), do: false

  defp process_gone?(pid, attempts) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} ->
        Process.sleep(20)
        process_gone?(pid, attempts - 1)

      {_out, _nonzero} ->
        true
    end
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
