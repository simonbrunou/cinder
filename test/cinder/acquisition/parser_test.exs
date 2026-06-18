defmodule Cinder.Acquisition.ParserTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Parser

  test "parses a standard p2p release name" do
    assert Parser.parse("Inception.2010.1080p.BluRay.x264-RARBG") ==
             %{resolution: "1080p", codec: "x264", group: "RARBG", language: nil}
  end

  test "parses 2160p x265 with a language tag" do
    assert Parser.parse("Dune.2021.MULTI.2160p.UHD.BluRay.x265-TERMiNAL") ==
             %{resolution: "2160p", codec: "x265", group: "TERMiNAL", language: "MULTI"}
  end

  test "a hyphen in the title is not mistaken for a group" do
    assert %{group: nil, resolution: "1080p", codec: "x264"} =
             Parser.parse("Spider-Man.2002.1080p.BluRay.x264")
  end

  test "a source-hyphen token with a trailing field is not a group" do
    # Note: ends on `.H264`, not on `WEB-DL` — a name ending exactly on `WEB-DL` would give "DL".
    assert %{group: nil, codec: "h264", resolution: "1080p"} =
             Parser.parse("Movie.2010.1080p.WEB-DL.H264")
  end

  test "a groupless scene name yields a nil group" do
    assert %{group: nil} = Parser.parse("Some.Movie.2015.720p.HDTV.x264")
  end

  test "unknown fields are nil" do
    assert Parser.parse("Just A Title") ==
             %{resolution: nil, codec: nil, group: nil, language: nil}
  end

  test "matching is case-insensitive" do
    assert %{codec: "x265", resolution: "1080p", group: "grp"} =
             Parser.parse("movie.2020.1080P.bluray.X265-grp")
  end
end
