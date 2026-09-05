defmodule Cinder.Library.AudioProbe.FfprobeTest do
  use ExUnit.Case, async: false

  alias Cinder.Library.AudioProbe.Ffprobe

  setup do
    ffprobe_bin = Application.get_env(:cinder, :ffprobe_bin)
    timeout_ms = Application.get_env(:cinder, :audiobook_probe_timeout_ms)
    health_timeout_ms = Application.get_env(:cinder, :audiobook_health_timeout_ms)

    on_exit(fn ->
      restore_bin(ffprobe_bin)
      restore_timeout(timeout_ms)
      restore_health_timeout(health_timeout_ms)
    end)
  end

  @tag :tmp_dir
  test "health/0 is :ok when the binary runs and exits zero", %{tmp_dir: tmp} do
    use_ffprobe(tmp, "exit 0")
    assert Ffprobe.health() == :ok
  end

  @tag :tmp_dir
  test "health/0 surfaces a non-zero exit", %{tmp_dir: tmp} do
    use_ffprobe(tmp, "printf 'boom' >&2\nexit 3")
    assert Ffprobe.health() == {:error, {:ffprobe_exit, 3, "boom"}}
  end

  test "health/0 surfaces a missing binary as an error instead of crashing" do
    Application.put_env(:cinder, :ffprobe_bin, "definitely-not-a-real-binary")
    assert {:error, %ErlangError{original: :enoent}} = Ffprobe.health()
  end

  # #510: a hung `-version` call timing out its Elixir-side Task used to leave the underlying
  # `ffprobe` process running, the same defect `probe/1` had — proven the same way: a fake
  # ffprobe that outlives the configured timeout and then writes a marker must never get to.
  @tag :tmp_dir
  test "health/0 kills the underlying ffprobe process on timeout, not merely abandons it", %{
    tmp_dir: tmp
  } do
    marker = Path.join(tmp, "health_survived")
    use_ffprobe(tmp, "sleep 1\ntouch #{marker}\nexit 0")
    Application.put_env(:cinder, :audiobook_health_timeout_ms, 100)

    assert Ffprobe.health() == {:error, :timeout}

    Process.sleep(1200)
    refute File.exists?(marker)
  end

  @tag :tmp_dir
  test "probe/1 asks ffprobe for the narrow, bounded projection", %{tmp_dir: tmp} do
    argv = Path.join(tmp, "argv")
    use_ffprobe(tmp, "printf '%s\\n' \"$@\" > #{argv}\nprintf '{}'")

    assert {:ok, _report} = Ffprobe.probe("/media/book.mp3")

    written = File.read!(argv)
    assert written =~ "format=format_name,duration:format_tags=album,title,track,disc:chapter=id"
    assert written =~ "-of\njson"
    assert written =~ "/media/book.mp3"
  end

  @tag :tmp_dir
  test "probe/1 parses container/duration/chapter/tag facts from a real ffprobe MP3 shape", %{
    tmp_dir: tmp
  } do
    json = ~s({
      "format": {
        "format_name": "mp3",
        "duration": "3661.234000",
        "tags": {"album": "The Dispossessed", "title": "Chapter 3", "track": "3/12", "disc": "1"}
      },
      "chapters": [{"id": 0}, {"id": 1}]
    })

    use_ffprobe(tmp, "printf '%s' '#{json}'")

    assert Ffprobe.probe("/media/03.mp3") ==
             {:ok,
              %{
                container: :mp3,
                duration_seconds: 3661,
                chapter_count: 2,
                track_tag: 3,
                disc_tag: 1,
                album_tag: "The Dispossessed",
                title_tag: "Chapter 3"
              }}
  end

  # ffprobe reports every MP4-family container (M4B included — there is no format name distinct
  # from M4A/MP4) under the same `format_name`; the resolver's own extension + magic-byte check is
  # the real format gate, not this field.
  @tag :tmp_dir
  test "probe/1 reports the M4B/M4A-family format_name as :m4b", %{tmp_dir: tmp} do
    json = ~s({"format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "120.0"}})
    use_ffprobe(tmp, "printf '%s' '#{json}'")

    assert {:ok, %{container: :m4b, duration_seconds: 120}} = Ffprobe.probe("/media/book.m4b")
  end

  @tag :tmp_dir
  test "probe/1 reports :unknown for an unrecognized container and nil for absent tags", %{
    tmp_dir: tmp
  } do
    json = ~s({"format": {"format_name": "ogg"}})
    use_ffprobe(tmp, "printf '%s' '#{json}'")

    assert Ffprobe.probe("/media/book.ogg") ==
             {:ok,
              %{
                container: :unknown,
                duration_seconds: nil,
                chapter_count: 0,
                track_tag: nil,
                disc_tag: nil,
                album_tag: nil,
                title_tag: nil
              }}
  end

  @tag :tmp_dir
  test "probe/1 surfaces a non-zero ffprobe exit without raising", %{tmp_dir: tmp} do
    use_ffprobe(tmp, "printf 'no such file' >&2\nexit 1")
    assert Ffprobe.probe("/media/missing.mp3") == {:error, {:ffprobe_exit, 1, "no such file"}}
  end

  @tag :tmp_dir
  test "probe/1 degrades on malformed JSON rather than raising", %{tmp_dir: tmp} do
    use_ffprobe(tmp, "printf 'not json'")
    assert Ffprobe.probe("/media/book.mp3") == {:error, :invalid_probe_output}
  end

  test "probe/1 surfaces a missing binary as an error instead of crashing" do
    Application.put_env(:cinder, :ffprobe_bin, "definitely-not-a-real-binary")
    assert {:error, %ErlangError{original: :enoent}} = Ffprobe.probe("/media/book.mp3")
  end

  # #510: a hung probe timing out its Elixir-side Task used to leave the underlying `ffprobe`
  # process running — closing a port does nothing to a child that never reads stdin. Proven here
  # by a fake ffprobe that outlives the configured timeout and then writes a marker: the marker
  # must never appear, meaning the real process was killed, not merely abandoned.
  @tag :tmp_dir
  test "probe/1 kills the underlying ffprobe process on timeout, not merely abandons it", %{
    tmp_dir: tmp
  } do
    marker = Path.join(tmp, "probe_survived")
    use_ffprobe(tmp, "sleep 1\ntouch #{marker}\nexit 0")
    Application.put_env(:cinder, :audiobook_probe_timeout_ms, 100)

    assert Ffprobe.probe("/media/book.mp3") == {:error, :timeout}

    Process.sleep(1200)
    refute File.exists?(marker)
  end

  defp use_ffprobe(tmp, script) do
    path = Path.join(tmp, "ffprobe")
    File.write!(path, "#!/bin/sh\n#{script}\n")
    File.chmod!(path, 0o755)
    Application.put_env(:cinder, :ffprobe_bin, path)
  end

  defp restore_bin(nil), do: Application.delete_env(:cinder, :ffprobe_bin)
  defp restore_bin(value), do: Application.put_env(:cinder, :ffprobe_bin, value)

  defp restore_timeout(nil), do: Application.delete_env(:cinder, :audiobook_probe_timeout_ms)

  defp restore_timeout(value),
    do: Application.put_env(:cinder, :audiobook_probe_timeout_ms, value)

  defp restore_health_timeout(nil),
    do: Application.delete_env(:cinder, :audiobook_health_timeout_ms)

  defp restore_health_timeout(value),
    do: Application.put_env(:cinder, :audiobook_health_timeout_ms, value)
end
