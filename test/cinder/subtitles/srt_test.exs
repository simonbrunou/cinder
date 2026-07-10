defmodule Cinder.Subtitles.SrtTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Srt

  test "parse extracts dialogue and render rebuilds it with translated dialogue" do
    assert {:ok, srt} = Srt.parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i>\n\n")
    assert Srt.dialogue(srt) == ["<i>Hello</i>"]

    assert Srt.render(srt, ["<i>Bonjour</i>"]) ==
             "1\n00:00:01,000 --> 00:00:02,000\n<i>Bonjour</i>\n\n"
  end

  test "parse accepts a BOM and render preserves multi-cue CRLF markup and separators" do
    source =
      <<0xEF, 0xBB, 0xBF>> <>
        "1\r\n00:00:01,000 --> 00:00:02,000\r\n<i>Hello</i>\r\n\r\n\r\n" <>
        "2\r\n00:00:03,000 --> 00:00:04,000\r\n<b>Goodbye</b>\r\nAgain\r\n\r\n"

    assert {:ok, srt} = Srt.parse(source)
    assert Srt.dialogue(srt) == ["<i>Hello</i>", "<b>Goodbye</b>\r\nAgain"]

    assert Srt.render(srt, ["<i>Bonjour</i>", "<b>Au revoir</b>\r\nEncore"]) ==
             <<0xEF, 0xBB, 0xBF>> <>
               "1\r\n00:00:01,000 --> 00:00:02,000\r\n<i>Bonjour</i>\r\n\r\n\r\n" <>
               "2\r\n00:00:03,000 --> 00:00:04,000\r\n<b>Au revoir</b>\r\nEncore\r\n\r\n"
  end

  test "parse rejects non-cues" do
    assert {:error, :invalid_srt} = Srt.parse("not a cue")
  end

  test "parse accepts a timing line containing an arrow without surrounding spaces" do
    assert {:ok, _srt} = Srt.parse("1\n00:00:01,000-->00:00:02,000\nHello\n\n")
  end

  test "render rejects a translated-cue count mismatch" do
    assert {:ok, srt} = Srt.parse("1\n00:00:01,000 --> 00:00:02,000\nHello\n\n")
    assert {:error, :cue_count_mismatch} = Srt.render(srt, [])
  end
end
