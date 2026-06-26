defmodule Cinder.Acquisition.ParserTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Parser

  test "parses a standard p2p release name" do
    assert Parser.parse("Inception.2010.1080p.BluRay.x264-RARBG") ==
             %{
               resolution: "1080p",
               codec: "x264",
               group: "RARBG",
               language: nil,
               season: nil,
               episodes: nil
             }
  end

  test "parses 2160p x265 with a language tag" do
    assert Parser.parse("Dune.2021.MULTI.2160p.UHD.BluRay.x265-TERMiNAL") ==
             %{
               resolution: "2160p",
               codec: "x265",
               group: "TERMiNAL",
               language: "MULTI",
               season: nil,
               episodes: nil
             }
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
             %{
               resolution: nil,
               codec: nil,
               group: nil,
               language: nil,
               season: nil,
               episodes: nil
             }
  end

  test "matching is case-insensitive" do
    assert %{codec: "x265", resolution: "1080p", group: "grp"} =
             Parser.parse("movie.2020.1080P.bluray.X265-grp")
  end

  test "a non-string title yields all-nil attrs instead of raising" do
    # An indexer result with a missing/null title must not crash best_release/2;
    # the parser stays total so the {:ok | :no_match | {:error, _}} contract holds.
    assert Parser.parse(nil) ==
             %{
               resolution: nil,
               codec: nil,
               group: nil,
               language: nil,
               season: nil,
               episodes: nil
             }
  end

  describe "TV season/episode parsing" do
    test "a single episode (SxxEyy) sets season and a one-element episode list" do
      assert %{season: 1, episodes: [2], resolution: "1080p", codec: "x265", group: "GRP"} =
               Parser.parse("Show.S01E02.1080p.WEB-DL.x265-GRP")
    end

    test "the 1x02 form is read as a single episode" do
      assert %{season: 1, episodes: [2], resolution: "720p", codec: "x264", group: "GRP"} =
               Parser.parse("Show.Name.1x02.720p.HDTV.x264-GRP")
    end

    test "a range (SxxEyy-Ezz) expands to the inclusive episode list" do
      assert %{season: 1, episodes: [1, 2, 3], group: "GRP"} =
               Parser.parse("Show.S01E01-E03.1080p-GRP")
    end

    test "a double episode without a dash lists both" do
      assert %{season: 1, episodes: [1, 2]} = Parser.parse("Show.S01E01E02.1080p")
    end

    test "a numbered season pack sets season with no episode list" do
      assert %{season: 1, episodes: nil, group: "GRP"} =
               Parser.parse("Show.S01.1080p.BluRay.x264-GRP")
    end

    test "the 'Season NN' word form is a season pack" do
      assert %{season: 5, episodes: nil} = Parser.parse("Show.Season.05.720p")
    end

    test "a movie name has nil season and episodes" do
      assert %{season: nil, episodes: nil} =
               Parser.parse("Inception.2010.1080p.BluRay.x264-RARBG")
    end
  end

  describe "TV parsing guards (deferred or junk → nil/nil)" do
    test "a multi-season pack is rejected rather than read as season 1" do
      # Any separator between two season tokens strands the others if mis-read as season 1.
      assert %{season: nil, episodes: nil} = Parser.parse("Show.S01S02.COMPLETE.720p")
      assert %{season: nil, episodes: nil} = Parser.parse("Show.Complete.S01-S03.1080p")
      assert %{season: nil, episodes: nil} = Parser.parse("Show.S01.S02.COMPLETE.1080p")
      assert %{season: nil, episodes: nil} = Parser.parse("Show.S01 S02.1080p")
    end

    test "two SxxEyy tokens (a multi-season release) are rejected, not read as the first" do
      assert %{season: nil, episodes: nil} = Parser.parse("Show.S01E01.S02E02.GROUP")
    end

    test "a release group beginning S<digit> is not counted as a second season" do
      # "S1CK"/"S5RT" are group fragments, not seasons — the pack stays season 1.
      assert %{season: 1, episodes: nil} = Parser.parse("Show.S01.1080p.x265-S1CK")
      assert %{season: 1, episodes: nil} = Parser.parse("Show.S01.1080p-S5RT")
    end

    test "S00 specials park (specials are M6 scope)" do
      assert %{season: nil, episodes: nil} = Parser.parse("Show.S00E01.1080p")
    end

    test "the 1x00 form parks rather than yielding episode 0" do
      assert %{season: nil, episodes: nil} = Parser.parse("Show.1x00.1080p")
    end

    test "year-as-season is not mistaken for a season" do
      assert %{season: nil, episodes: nil} = Parser.parse("Show.S2009E12.720p")
    end
  end

  describe "language: French dub markers (M-language)" do
    test "TRUEFRENCH tags FRENCH" do
      assert Parser.parse("Movie.2021.TRUEFRENCH.1080p.BluRay.x264-GRP").language == "FRENCH"
    end

    test "VFF / VFQ / VFI / VF tag FRENCH" do
      for marker <- ~w(VFF VFQ VFI VF) do
        assert Parser.parse("Movie.2021.#{marker}.1080p.WEB-DL.x264-GRP").language == "FRENCH",
               "expected #{marker} to tag FRENCH"
      end
    end

    test "MULTI still wins over a French dub marker" do
      assert Parser.parse("Movie.2021.MULTI.VFF.1080p.BluRay.x264-GRP").language == "MULTI"
    end

    test "VOSTFR and SUBFRENCH stay nil (subtitles = original audio, not a French audio tag)" do
      assert Parser.parse("Movie.2021.VOSTFR.1080p.BluRay.x264-GRP").language == nil
      assert Parser.parse("Movie.2021.SUBFRENCH.1080p.BluRay.x264-GRP").language == nil
    end
  end

  describe "language: foreign audio tags (registry)" do
    test "Hungarian — full word, native 'magyar', and HUN abbreviation all tag HUNGARIAN" do
      for name <- [
            "Movie.2019.HUNGARIAN.1080p.BluRay.x264-GRP",
            "Valami.2020.magyar.szinkron.720p",
            "Some.Movie.2019.HUN.1080p.WEB-DL.H264"
          ] do
        assert Parser.parse(name).language == "HUNGARIAN", "expected HUNGARIAN from #{name}"
      end
    end

    test "a spread of languages tag correctly" do
      cases = [
        {"Movie.2018.RUS.1080p.BluRay-RUS", "RUSSIAN"},
        {"Pelicula.2016.SPANISH.Castellano.1080p", "SPANISH"},
        {"Pelicula.2016.LATINO.1080p.WEB-DL.x264", "SPANISH"},
        {"Filme.2019.PT-BR.Dublado.1080p.WEB-DL", "PORTUGUESE"},
        {"Film.2017.PL.Lektor.1080p.WEB-DL", "POLISH"},
        {"Anime.2020.JPN.1080p.BluRay", "JAPANESE"},
        {"Movie.2018.MANDARIN.1080p.WEB-DL", "CHINESE"},
        {"Movie.2018.CANTONESE.1080p.BluRay", "CANTONESE"}
      ]

      for {name, tag} <- cases do
        assert Parser.parse(name).language == tag, "expected #{tag} from #{name}"
      end
    end

    test "a subtitle marker is not read as an audio tag (sub-guard)" do
      for name <- [
            "Movie.2018.1080p.WEB-DL.ENG.SUBS-GRP",
            "Film.2017.NL.SUBS.1080p.BluRay",
            "Some.Movie.2018.PL.SUB.1080p.WEB-DL",
            "Movie.2019.Nordic.SWE.SUBS.720p.WEB-DL",
            "Doc.2021.1080p.WEB.x265.HUN.SUBS"
          ] do
        assert Parser.parse(name).language == nil, "expected nil (subtitle marker) from #{name}"
      end
    end

    test "the audio tag wins when subtitles are also named" do
      # Hungarian audio + English subs → HUNGARIAN, not ENGLISH.
      assert Parser.parse("Valami.2018.HUN.ENG.SUBS.1080p.WEB-DL").language == "HUNGARIAN"
      assert Parser.parse("Le.Film.2019.FRENCH.English.Subs.1080p.WEB-DL").language == "FRENCH"
    end

    test "codec/source tokens are never mistaken for a language" do
      name = "Movie.2020.2160p.UHD.BluRay.REMUX.HDR.DV.HEVC.DTS-HD.MA-FraMeSToR"
      assert Parser.parse(name).language == nil
    end

    test "a language word in the title is not read as an audio tag (post-year scoping)" do
      # Language matching is scoped to the technical tags after the release year, so these
      # title words stay nil even though the registry contains their language.
      for name <- [
            "The.Italian.Job.2003.1080p.BluRay.x264-GRP",
            "My.Big.Fat.Greek.Wedding.2002.1080p.BluRay.x264",
            "Russian.Doll.2019.1080p.NF.WEB-DL.DDP5.1.x264",
            "The.English.Patient.1996.1080p.BluRay.x264"
          ] do
        assert Parser.parse(name).language == nil, "expected nil (title word) from #{name}"
      end
    end

    test "the title is ignored but a real post-year tag is still found" do
      # "Greek" in the title is skipped; the FRENCH tag after the year wins.
      assert Parser.parse("The.Greek.Tycoon.1978.FRENCH.1080p.BluRay.x264").language == "FRENCH"
    end

    test "every registry language has both a release tag and ISO 639-2 audio codes (no drift)" do
      tag_codes = Parser.language_tags() |> Map.keys() |> MapSet.new()
      audio_codes = Parser.audio_codes() |> Map.keys() |> MapSet.new()
      assert tag_codes == audio_codes
      # Each audio entry includes the 639-1 code itself plus at least one form.
      assert Enum.all?(Parser.audio_codes(), fn {code, forms} -> code in forms and forms != [] end)
    end
  end

  describe "TV tail edge cases (keep the leading episode, drop trailing junk)" do
    test "a hyphen-glued resolution keeps the episode instead of dropping the release" do
      assert %{season: 1, episodes: [2], resolution: "720p"} =
               Parser.parse("Show.S01E02-720p.WEB")
    end

    test "a descending range keeps the valid leading episode" do
      assert %{season: 1, episodes: [3]} = Parser.parse("Show.S01E03-E01.1080p")
    end

    test "a dot- or space-separated single episode is not mistaken for a season pack" do
      assert %{season: 1, episodes: [2]} = Parser.parse("Show.S01.E02.1080p.x265-GRP")
      assert %{season: 1, episodes: [2]} = Parser.parse("Show S01 E02 1080p")
    end
  end
end
