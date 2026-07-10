defmodule Cinder.Subtitles.SrtTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Srt

  test "parse extracts dialogue and render rebuilds it with translated dialogue" do
    assert {:ok, srt} = Srt.parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i>\n\n")
    assert Srt.dialogue(srt) == ["<i>Hello</i>"]

    assert Srt.render(srt, ["<i>Bonjour</i>"]) ==
             "1\n00:00:01,000 --> 00:00:02,000\n<i>Bonjour</i>\n\n"
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
