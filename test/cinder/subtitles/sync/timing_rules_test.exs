defmodule Cinder.Subtitles.Sync.TimingRulesTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Sync.TimingRules

  # 24000/1001 fps: one frame is 41.7 ms, two frames 83 ms, half a second (12 frames) 500 ms,
  # 20 frames 834 ms.
  @fps 24_000 / 1001

  defp srt(cues) do
    cues
    |> Enum.with_index(1)
    |> Enum.map_join(fn {{start_ms, finish_ms, text}, n} ->
      "#{n}\n#{ts(start_ms)} --> #{ts(finish_ms)}\n#{text}\n\n"
    end)
  end

  defp ts(ms),
    do:
      :io_lib.format("~2..0B:~2..0B:~2..0B,~3..0B", [
        div(ms, 3_600_000),
        rem(div(ms, 60_000), 60),
        rem(div(ms, 1000), 60),
        rem(ms, 1000)
      ])
      |> IO.iodata_to_binary()

  test "a gap under half a second is closed to two frames; a longer one is left alone" do
    cues = [{1_000, 2_000}, {2_200, 3_100}, {4_000, 5_000}]

    assert TimingRules.times(cues, @fps) == [{1_000, 2_117}, {2_200, 3_100}, {4_000, 5_000}]
  end

  test "an overlap or a gap under two frames is opened to two frames" do
    cues = [{1_000, 2_300}, {2_200, 3_200}, {3_220, 4_400}]

    assert TimingRules.times(cues, @fps) == [{1_000, 2_117}, {2_200, 3_137}, {3_220, 4_400}]
  end

  test "a line shorter than 20 frames grows into the gap after it, up to two frames before the next" do
    cues = [{1_000, 1_300}, {3_000, 3_200}, {3_500, 4_500}]

    assert TimingRules.times(cues, @fps) == [{1_000, 1_834}, {3_000, 3_417}, {3_500, 4_500}]
  end

  test "a line that could only lose its overlap by dropping under 20 frames keeps it" do
    cues = [{1_000, 2_000}, {1_400, 2_500}]

    assert TimingRules.times(cues, @fps) == [{1_000, 2_000}, {1_400, 2_500}]
  end

  test "lines relate in in-time order whatever order the file lists them in" do
    cues = [{2_200, 3_100}, {1_000, 2_000}]

    assert TimingRules.times(cues, @fps) == [{2_200, 3_100}, {1_000, 2_117}]
  end

  test "two frames and half a second follow the video's frame rate" do
    # At 25 fps two frames are 80 ms and half a second is 13 frames (520 ms).
    assert TimingRules.times([{1_000, 2_000}, {2_510, 3_400}], 25) == [
             {1_000, 2_430},
             {2_510, 3_400}
           ]

    assert TimingRules.times([{1_000, 2_000}, {2_510, 3_400}], @fps) == [
             {1_000, 2_000},
             {2_510, 3_400}
           ]
  end

  test "rewrite/3 changes only cue timings, keeping a BOM, CRLF and the text" do
    crlf = &String.replace(&1, "\n", "\r\n")

    source =
      <<0xEF, 0xBB, 0xBF>> <>
        crlf.(srt([{1_000, 2_000, "One"}, {2_200, 3_100, "At 00:00:09,000"}]))

    assert TimingRules.rewrite(source, ".srt", frame_rate: @fps) ==
             {:ok,
              <<0xEF, 0xBB, 0xBF>> <>
                crlf.(srt([{1_000, 2_117, "One"}, {2_200, 3_100, "At 00:00:09,000"}]))}
  end

  test "rewrite/3 returns a file that already follows the rules byte for byte" do
    source = srt([{1_000, 2_000, "One"}, {2_600, 3_600, "Two"}])

    assert TimingRules.rewrite(source, ".srt", frame_rate: @fps) == {:ok, source}
  end

  test "rewrite/3 handles WebVTT and leaves styled formats alone" do
    vtt = "WEBVTT\n\n00:01.000 --> 00:02.000\nOne\n\n00:02.200 --> 00:03.100\nTwo\n"

    assert {:ok, "WEBVTT\n\n00:01.000 --> 00:02.117\nOne\n\n00:02.200 --> 00:03.100\nTwo\n"} =
             TimingRules.rewrite(vtt, ".vtt", frame_rate: @fps)

    ass =
      "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" <>
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,One\n" <>
        "Dialogue: 0,0:00:01.50,0:00:03.00,Sign,,0,0,0,,Sign\n"

    assert TimingRules.rewrite(ass, ".ass", frame_rate: @fps) == {:ok, ass}
  end

  describe "with shot changes" do
    # Half a second is 12 frames (500 ms), three quarters of it 9 frames (375 ms).
    defp cut(cues, cuts, texts \\ nil),
      do: TimingRules.times(cues, @fps, shot_changes: cuts, texts: texts)

    test "a line starting within half a second after a cut starts on it" do
      assert cut([{10_200, 11_500}], [10_000]) == [{10_000, 11_500}]
      assert cut([{10_600, 11_500}], [10_000]) == [{10_600, 11_500}]
    end

    test "a line running across a cut it starts just before moves to the cut or half a second before it" do
      assert cut([{9_900, 11_500}], [10_000]) == [{10_000, 11_500}]
      assert cut([{9_600, 11_500}], [10_000]) == [{9_500, 11_500}]
      # A line that ends before the cut is not dialogue running across it.
      assert cut([{9_900, 9_990}], [10_000]) == [{9_900, 10_734}]
    end

    test "an in-time does not move earlier when the line before could not keep 20 frames" do
      assert cut([{9_400, 9_900}, {10_200, 11_500}], [10_000]) == [
               {9_400, 10_117},
               {10_200, 11_500}
             ]
    end

    test "a line ending just before a cut ends 2 frames before it, with the next line on the cut" do
      assert cut([{1_000, 3_000}, {3_400, 5_000}], [3_300]) == [{1_000, 3_217}, {3_300, 5_000}]
    end

    test "a line ending just after a cut ends 2 frames before it when it stays readable" do
      assert cut([{1_000, 3_100}], [3_000], ["Hi."]) == [{1_000, 2_917}]

      long = String.duplicate("Too many words. ", 4)
      assert cut([{1_000, 3_100}], [3_000], [long]) == [{1_000, 3_500}]
    end

    # A sound cue beside dialogue starting at the same time: ending it before the cut would leave
    # it under 20 frames, and the fallback must not cap it at the next line's in-time either.
    test "simultaneous lines crossing a cut keep their length" do
      assert cut([{1_000, 2_000}, {1_000, 2_500}], [1_800]) == [{1_000, 2_000}, {1_000, 2_500}]
    end

    test "rewrite/3 reads each line's text for its reading speed" do
      source =
        srt([{1_000, 3_100, String.duplicate("Too many words. ", 4)}, {5_000, 6_000, "Hi."}])

      assert TimingRules.rewrite(source, ".srt", frame_rate: @fps, shot_changes: [3_000, 6_050]) ==
               {:ok,
                srt([
                  {1_000, 3_500, String.duplicate("Too many words. ", 4)},
                  {5_000, 5_967, "Hi."}
                ])}
    end
  end
end
