defmodule Cinder.Library.MediaInfo.FfprobeTest do
  use ExUnit.Case, async: true
  alias Cinder.Library.MediaInfo.Ffprobe

  test "parse buckets audio + subtitle streams by codec_type, dropping und/empty" do
    out = "video,\naudio,eng\naudio,fre\nsubtitle,eng\nsubtitle,und\naudio,\n"
    assert Ffprobe.parse(out) == %{audio: ["eng", "fre"], subtitles: ["eng"]}
  end

  test "parse dedups repeated audio/subtitle languages, preserving first-seen order" do
    out = "audio,eng\naudio,eng\naudio,fre\nsubtitle,eng\nsubtitle,eng\n"
    assert Ffprobe.parse(out) == %{audio: ["eng", "fre"], subtitles: ["eng"]}
  end
end
