defmodule Cinder.Subtitles.Sync.TimingTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Sync.Timing

  test "retimes SRT with an offset and progressive rate" do
    source = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n\n"

    assert {:ok, output} = Timing.retime(source, ".srt", 1_000, 2.0)
    assert output =~ "00:00:03,000 --> 00:00:05,000"
    assert output =~ "00:00:07,000 --> 00:00:09,000"
  end

  test "preserves a UTF-8 BOM while retiming" do
    source = <<0xEF, 0xBB, 0xBF, "1\n00:00:01,000 --> 00:00:02,000\nOne\n">>
    assert {:ok, <<0xEF, 0xBB, 0xBF, output::binary>>} = Timing.retime(source, ".srt", 1_000, 1.0)
    assert output =~ "00:00:02,000 --> 00:00:03,000"
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
          "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" <>
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

  test "MicroDVD requires a finite positive FPS header" do
    for source <- [
          "{25}{50}Headerless\n",
          "{1}{1}0\n{25}{50}Zero\n",
          "{1}{1}-25\n{25}{50}Negative\n",
          "{1}{1}not-fps\n{25}{50}Invalid\n",
          "{1}{1}1e999\n{25}{50}Infinite\n"
        ] do
      assert Timing.retime(source, ".sub", 1_000, 1.0) == {:error, :invalid_subtitle}
    end

    assert {:ok, "{1}{1}23.976\n{48}{72}Valid\n"} =
             Timing.retime("{1}{1}23.976\n{24}{48}Valid\n", ".sub", 1_000, 1.0)
  end

  test "MicroDVD accepts CRLF after the positive FPS header" do
    source = "{1}{1}25.000\r\n{25}{50}One\r\n"
    assert {:ok, "{1}{1}25.000\r\n{50}{75}One\r\n"} = Timing.retime(source, ".sub", 1_000, 1.0)
  end

  test "rejects transforms and anchors outside bounded finite operating ranges" do
    srt = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"

    assert {:error, :invalid_adjustment} = Timing.retime(srt, ".srt", 0, 1.0e307)
    assert {:error, :invalid_adjustment} = Timing.retime(srt, ".srt", 100_000_000, 1.0)

    assert {:error, :invalid_anchors} =
             Timing.from_anchors([{0, 0}, {1, 100_000_000}])
  end

  test "extreme MicroDVD values fail closed instead of overflowing" do
    frame = String.duplicate("9", 400)
    source = "{1}{1}25.0\n{#{frame}}{#{frame}}Cue\n"
    assert {:error, :invalid_subtitle} = Timing.retime(source, ".sub", 0, 1.0)
  end

  test "anchors derive the same affine map used by direct controls" do
    assert Timing.from_anchors([{1_000, 2_000}]) == {:ok, {1_000, 1.0}}
    assert Timing.from_anchors([{1_000, 2_000}, {3_000, 6_000}]) == {:ok, {0, 2.0}}
    assert Timing.from_anchors([{1_000, 2_000}, {1_000, 3_000}]) == {:error, :invalid_anchors}
  end

  test "retimes cue fields without changing timestamp-shaped dialogue text" do
    srt =
      "1\n00:00:01,000 --> 00:00:02,000\nDisplay 00:00:03,000 --> 00:00:04,000 here\n\n"

    assert {:ok, output} = Timing.retime(srt, ".srt", 1_000, 1.0)
    assert output =~ "00:00:02,000 --> 00:00:03,000"
    assert output =~ "Display 00:00:03,000 --> 00:00:04,000 here"

    vtt = "WEBVTT\n\n00:01.000 --> 00:02.000\nDisplay 00:03.000 --> 00:04.000 here\n"
    assert {:ok, output} = Timing.retime(vtt, ".vtt", 1_000, 1.0)
    assert output =~ "00:02.000 --> 00:03.000"
    assert output =~ "Display 00:03.000 --> 00:04.000 here"

    ass =
      "[Events]\n" <>
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" <>
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,At 1:23:45.67\n"

    assert {:ok, output} = Timing.retime(ass, ".ass", 1_000, 1.0)
    assert output =~ "Dialogue: 0,0:00:02.00,0:00:03.00"
    assert output =~ "At 1:23:45.67"

    sub = "[00:00:01.00][00:00:02.00]At 12:34:56.78\n"
    assert {:ok, output} = Timing.retime(sub, ".sub", 1_000, 1.0)
    assert output == "[00:00:02.00][00:00:03.00]At 12:34:56.78\n"
  end

  test "adds VTT hours when an adjustment crosses one hour" do
    source = "WEBVTT\n\n59:59.000 --> 59:59.500\nOne\n"
    assert {:ok, output} = Timing.retime(source, ".vtt", 2_000, 1.0)
    assert output =~ "01:00:01.000 --> 01:00:01.500"
  end

  test "clamping a negative correction keeps a positive cue duration" do
    source = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n"
    assert {:ok, output} = Timing.retime(source, ".srt", -5_000, 1.0)
    assert output =~ "00:00:00,000 --> 00:00:00,001"
  end

  test "rejects out-of-range timestamp fields and MicroDVD bounds" do
    invalid = [
      {".srt", "1\n00:60:01,000 --> 00:60:02,000\nOne\n"},
      {".vtt", "WEBVTT\n\n00:01.000 --> 00:60.000\nOne\n"},
      {".ass", "[Events]\nDialogue: 0,169:00:00.00,169:00:01.00,Default,,One\n"},
      {".ssa", "[Events]\nDialogue: 0,0:00:60.00,0:01:01.00,Default,,One\n"},
      {".sub", "[00:00:01.00][00:99:02.00]One\n"},
      {".sub", "{1}{1}1001.0\n{25}{50}One\n"},
      {".sub", "{1}{1}1.0\n{604800001}{604800002}One\n"}
    ]

    for {extension, source} <- invalid do
      assert {:error, :invalid_subtitle} = Timing.retime(source, extension, 0, 1.0)
    end
  end

  test "rejects reversed or equal cue intervals and conflicting MicroDVD headers" do
    invalid = [
      {".srt", "1\n00:00:02,000 --> 00:00:01,000\nOne\n"},
      {".vtt", "WEBVTT\n\n00:01.000 --> 00:01.000\nOne\n"},
      {".ass", ass_source("0:00:02.00", "0:00:01.00")},
      {".sub", "[00:00:02.00][00:00:01.00]One\n"},
      {".sub", "{1}{1}25.0\n{50}{25}One\n"},
      {".sub", "{1}{1}25.0\n{25}{25}Equal\n"},
      {".sub", "{1}{1}25.0\n{1}{1}23.976\n{25}{50}One\n"}
    ]

    for {extension, source} <- invalid do
      assert {:error, :invalid_subtitle} = Timing.retime(source, extension, 0, 1.0)
    end
  end

  test "rejects adjustments whose generated timestamps exceed format bounds" do
    invalid = [
      {".srt", "1\n99:59:58,000 --> 99:59:59,000\nOne\n", 86_400_000, 1.0},
      {".ass", ass_source("167:59:58.00", "167:59:59.00"), 86_400_000, 1.0},
      {".sub", "{1}{1}1000\n{604799999}{604800000}One\n", 0, 10.0}
    ]

    for {extension, source, offset, rate} <- invalid do
      assert {:error, :invalid_subtitle} = Timing.retime(source, extension, offset, rate)
    end
  end

  test "rejects a document containing any malformed structural cue row" do
    malformed = [
      {".srt", "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\nbad --> 00:00:04,000\nTwo\n"},
      {".vtt", "WEBVTT\n\n00:01.000 --> 00:02.000\nOne\n\nbad --> 00:04.000\nTwo\n"},
      {".ass", ass_source("0:00:01.00", "0:00:02.00") <> "Dialogue: bad,row\n"},
      {".sub", "[00:00:01.00][00:00:02.00]One\n[bad][00:00:04.00]Two\n"},
      {".sub", "{1}{1}25.0\n{25}{50}One\n{bad}{75}Two\n"}
    ]

    for {extension, source} <- malformed do
      assert {:error, :invalid_subtitle} = Timing.retime(source, extension, 1_000, 1.0)
    end
  end

  test "rejects otherwise valid documents containing out-of-grammar rows or blocks" do
    malformed = [
      {".srt", "1\n00:00:01,000 --> 00:00:02,000\nOne\n\nGARBAGE\n"},
      {".vtt", "WEBVTT\n\n00:01.000 --> 00:02.000\nOne\n\nGARBAGE\n"},
      {".ass", ass_source("0:00:01.00", "0:00:02.00") <> "GARBAGE\n"},
      {".sub", "GARBAGE\n[00:00:01.00][00:00:02.00]One\n"},
      {".sub", "{1}{1}25.0\n{25}{50}One\nGARBAGE\n"}
    ]

    for {extension, source} <- malformed do
      assert {:error, :invalid_subtitle} = Timing.retime(source, extension, 0, 1.0)
    end
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

  defp ass_source(start_time, end_time) do
    "[Events]\n" <>
      "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" <>
      "Dialogue: 0,#{start_time},#{end_time},Default,,0,0,0,,One\n"
  end
end
