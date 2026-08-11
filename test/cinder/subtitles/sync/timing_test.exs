defmodule Cinder.Subtitles.Sync.TimingTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Sync.Timing

  test "retimes SRT with an offset and progressive rate" do
    source = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n"

    assert {:ok, output} = Timing.retime(source, ".srt", 1_000, 2.0)
    assert output =~ "00:00:03,000 --> 00:00:05,000"
    assert output =~ "00:00:07,000 --> 00:00:09,000"
  end

  test "retimes VTT while preserving its millisecond timestamp spelling" do
    source = "WEBVTT\n\n00:01.000 --> 00:02.000\nOne\n\n00:03.000 --> 00:04.000\nTwo\n"

    assert {:ok, output} = Timing.retime(source, ".vtt", 1_000, 2.0)
    assert output =~ "00:03.000 --> 00:05.000"
    assert output =~ "00:07.000 --> 00:09.000"
  end

  for extension <- [".ass", ".ssa"] do
    test "retimes #{extension} Dialogue rows without changing headers" do
      source =
        "[Script Info]\nTitle: Test\n[Events]\n" <>
          "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,One\n" <>
          "Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,Two\n"

      assert {:ok, output} = Timing.retime(source, unquote(extension), 1_000, 2.0)
      assert output =~ "Title: Test"
      assert output =~ "Dialogue: 0,0:00:03.00,0:00:05.00"
      assert output =~ "Dialogue: 0,0:00:07.00,0:00:09.00"
    end
  end

  test "retimes both timestamped and MicroDVD SUB files" do
    assert {:ok, timestamped} =
             Timing.retime("[00:00:01.00][00:00:02.00]One\n", ".sub", 1_000, 2.0)

    assert timestamped == "[00:00:03.00][00:00:05.00]One\n"

    source = "{1}{1}25.000\n{25}{50}One\n"
    assert {:ok, microdvd} = Timing.retime(source, ".sub", 1_000, 2.0)
    assert microdvd == "{1}{1}25.000\n{75}{125}One\n"
  end

  test "anchors derive the same affine map used by direct controls" do
    assert Timing.from_anchors([{1_000, 2_000}]) == {:ok, {1_000, 1.0}}
    assert Timing.from_anchors([{1_000, 2_000}, {3_000, 6_000}]) == {:ok, {0, 2.0}}
    assert Timing.from_anchors([{1_000, 2_000}, {1_000, 3_000}]) == {:error, :invalid_anchors}
  end

  test "retimes cue fields without changing timestamp-shaped dialogue text" do
    srt = "1\n00:00:01,000 --> 00:00:02,000\nMeet at 12:34:56,789\n\n"
    assert {:ok, output} = Timing.retime(srt, ".srt", 1_000, 1.0)
    assert output =~ "00:00:02,000 --> 00:00:03,000"
    assert output =~ "Meet at 12:34:56,789"

    vtt = "WEBVTT\n\n00:01.000 --> 00:02.000\nAt 12:34.567\n"
    assert {:ok, output} = Timing.retime(vtt, ".vtt", 1_000, 1.0)
    assert output =~ "00:02.000 --> 00:03.000"
    assert output =~ "At 12:34.567"

    ass =
      "[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,At 1:23:45.67\n"

    assert {:ok, output} = Timing.retime(ass, ".ass", 1_000, 1.0)
    assert output =~ "Dialogue: 0,0:00:02.00,0:00:03.00"
    assert output =~ "At 1:23:45.67"

    sub = "[00:00:01.00][00:00:02.00]At 12:34:56.78\n"
    assert {:ok, output} = Timing.retime(sub, ".sub", 1_000, 1.0)
    assert output == "[00:00:02.00][00:00:03.00]At 12:34:56.78\n"
  end

  test "clamping a negative correction keeps a positive cue duration" do
    source = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    assert {:ok, output} = Timing.retime(source, ".srt", -5_000, 1.0)
    assert output =~ "00:00:00,000 --> 00:00:00,001"
  end

  test "rejects documents without a structural cue in the selected format" do
    for {extension, source} <- [
          {".srt", "plain text 00:00:01,000"},
          {".vtt", "WEBVTT\nplain text"},
          {".ass", "[Events]\nComment: 0,0:00:01.00,0:00:02.00,No dialogue"},
          {".ssa", "[Events]\nFormat: Marked, Start, End, Style, Text"},
          {".sub", "{1}{1}25.000\nplain text"}
        ] do
      assert Timing.retime(source, extension, 1_000, 1.0) == {:error, :invalid_subtitle}
    end
  end
end
