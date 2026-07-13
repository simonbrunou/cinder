defmodule Cinder.Acquisition.ParserTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Parser

  @preferences_fixture "test/support/fixtures/anime/preferences-v1.json"

  test "parses a standard p2p release name" do
    assert Parser.parse("Inception.2010.1080p.BluRay.x264-RARBG") ==
             %{
               resolution: "1080p",
               source: "bluray",
               codec: "x264",
               group: "RARBG",
               language: nil,
               audio_languages: [],
               audio_claim_complete?: false,
               embedded_subtitle_languages: [],
               embedded_subtitle_claim: :unknown,
               season: nil,
               episodes: nil
             }
  end

  test "parses 2160p x265 with a language tag" do
    assert Parser.parse("Dune.2021.MULTI.2160p.UHD.BluRay.x265-TERMiNAL") ==
             %{
               resolution: "2160p",
               source: "bluray",
               codec: "x265",
               group: "TERMiNAL",
               language: "MULTI",
               audio_languages: [],
               audio_claim_complete?: false,
               embedded_subtitle_languages: [],
               embedded_subtitle_claim: :unknown,
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
               source: nil,
               codec: nil,
               group: nil,
               language: nil,
               audio_languages: [],
               audio_claim_complete?: false,
               embedded_subtitle_languages: [],
               embedded_subtitle_claim: :unknown,
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
               source: nil,
               codec: nil,
               group: nil,
               language: nil,
               audio_languages: [],
               audio_claim_complete?: false,
               embedded_subtitle_languages: [],
               embedded_subtitle_claim: :unknown,
               season: nil,
               episodes: nil
             }
  end

  describe "source parsing" do
    test "BluRay and its rip variants map to bluray" do
      for name <- ["M.2020.1080p.BluRay.x264", "M.2020.720p.BRRip", "M.2020.BDRip.x264"] do
        assert %{source: "bluray"} = Parser.parse(name)
      end
    end

    test "remux wins over bluray" do
      assert %{source: "remux"} = Parser.parse("M.2020.2160p.BluRay.REMUX.x265")
    end

    test "webrip is distinguished from webdl, and bare WEB is webdl" do
      assert %{source: "webrip"} = Parser.parse("M.2020.1080p.WEBRip.x264")
      assert %{source: "webdl"} = Parser.parse("M.2020.1080p.WEB-DL.x264")
      assert %{source: "webdl"} = Parser.parse("M.2020.1080p.WEB.x264")
    end

    test "hdtv, dvd, and cam tokens" do
      assert %{source: "hdtv"} = Parser.parse("M.2020.720p.HDTV.x264")
      assert %{source: "dvd"} = Parser.parse("M.2019.DVDRip.x264")
      assert %{source: "cam"} = Parser.parse("M.2021.CAM.x264")
    end

    test "an untagged source is nil" do
      assert %{source: nil} = Parser.parse("Inception.2010.x264-GRP")
    end

    test "BDRemux is tagged remux, not bluray" do
      assert %{source: "remux"} = Parser.parse("M.2020.2160p.BDRemux.x265")
    end

    test "a source word in the TITLE does not produce a false source (scan is scoped past the year)" do
      # The films "Cam" and "Charlotte's Web": an untagged release must stay nil so the scorer's
      # nil-passes valve isn't defeated by a recognized-but-unlisted false source.
      assert %{source: nil} = Parser.parse("Cam.2018.1080p.x264-GRP")
      assert %{source: nil} = Parser.parse("Charlottes.Web.2006.1080p.x264-GRP")
      # ...but a real source tag after the year still matches.
      assert %{source: "webdl"} = Parser.parse("Cam.2018.1080p.WEB-DL.x264-GRP")
    end

    test "a yearless name still tags a real source that precedes the resolution" do
      # A compound source tag is unambiguous, so it matches anywhere — a yearless name with the
      # source before the resolution must not drop it. (Regression guard.)
      assert %{source: "dvd"} = Parser.parse("Show.Name.S01.DVDRip.480p.x264-GRP")
      assert %{source: "bluray"} = Parser.parse("Movie.BDRip.1080p.x264")
    end

    test "a compound source is read even when it precedes the year or trails it" do
      # Compound tokens match anywhere, so these unusual orderings (source before the year, or a
      # trailing year) keep their real source instead of dropping to nil. (Regression guards.)
      assert %{source: "webdl"} = Parser.parse("Title.1080p.WEB-DL.2020.x264")
      assert %{source: "dvd"} = Parser.parse("Movie.Title.DVDRip.XviD.2009")
    end

    test "a real compound source outranks a title source-word in a yearless name" do
      # "Web" in the title must not override a real HDTV tag; the compound match wins.
      assert %{source: "hdtv"} = Parser.parse("Charlottes.Web.S01.1080p.HDTV.x264-GRP")
    end

    test "cam-family title words do not produce a false source; a real tag still wins" do
      # "Telecine"/"Screener" are ordinary words that can be a TITLE; the cam family is scoped to
      # the tag region, so an untagged release stays nil and a real source after it wins.
      assert %{source: nil} = Parser.parse("Telecine.2019.1080p.x264-GRP")
      assert %{source: "webdl"} = Parser.parse("Screener.2019.1080p.WEB.x264")
      # ...but a genuine screener tag in the tag region is read.
      assert %{source: "cam"} = Parser.parse("Movie.2024.SCREENER.x264")
    end

    test "a yearless, resolutionless name does not read a title source-word" do
      # No tag-region anchor ⇒ the bare scan must not run over the title (no false source).
      assert %{source: nil} = Parser.parse("Charlottes.Web.XviD-GRP")
      assert %{source: nil} = Parser.parse("Cam.XviD-GRP")
    end
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

    test "a dash-separated episode (Sxx-Eyy) is a single episode, not a season pack" do
      # Regression: the separator class once omitted "-", so this fell through to
      # @bare_season and out-scored genuine season packs as a fake full-season cover.
      assert %{season: 1, episodes: [2]} = Parser.parse("Show.Name.S01-E02.1080p.WEB.H264-GRP")
    end

    test "a spaced-dash separator run (Sxx - Eyy) is a single episode, not a season pack" do
      assert %{season: 1, episodes: [2]} = Parser.parse("Show - S01 - E02 - 1080p")
      assert %{season: 1, episodes: [2]} = Parser.parse("Show.S01- E02.1080p")
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

    test "a group fragment like -S1CK on a season-less name is not a bare season pack" do
      # No real season token anywhere: reading "-S1CK" as season 1 would let a
      # title-matching movie release masquerade as a whole-season pack in set-cover.
      assert %{season: nil, episodes: nil} = Parser.parse("Show.2020.1080p.WEB-S1CK")
    end

    test "unusual non-alphanumeric separators after a season token still read as a pack" do
      assert %{season: 1, episodes: nil} = Parser.parse("Show.S01[1080p].WEB")
      assert %{season: 2, episodes: nil} = Parser.parse("Show S02+Extras 720p")
    end

    test "split-season halves (S05A/S05B) read as packs of that season" do
      assert %{season: 5, episodes: nil} = Parser.parse("Show.S05A.1080p.WEB-GRP")
      assert %{season: 5, episodes: nil} = Parser.parse("Show.S05B.720p.WEB")
    end

    test "word-form multi-season ranges are rejected rather than read as one season" do
      assert %{season: nil, episodes: nil} = Parser.parse("Show.Season.1-5.Complete.1080p")
      assert %{season: nil, episodes: nil} = Parser.parse("Show.Season 1-3.720p.WEB")
      assert %{season: nil, episodes: nil} = Parser.parse("Show.Seasons.1-5.COMPLETE.1080p")
    end

    test "a hyphen-glued resolution after a word-form season is not a multi-season range" do
      assert %{season: 1, episodes: nil} = Parser.parse("Show.Season.1-1080p.WEB")
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

  describe "conservative Anime release claims" do
    test "parses every versioned preference fixture case" do
      fixture = @preferences_fixture |> File.read!() |> Jason.decode!()
      assert fixture["version"] == 1

      for fixture_case <- fixture["cases"] do
        expected = fixture_case["expected"]
        parsed = Parser.parse(fixture_case["title"])

        assert Map.take(parsed, [
                 :group,
                 :audio_languages,
                 :audio_claim_complete?,
                 :embedded_subtitle_languages,
                 :embedded_subtitle_claim
               ]) == %{
                 group: expected["group"],
                 audio_languages: expected["audio"],
                 audio_claim_complete?: expected["audio_complete"],
                 embedded_subtitle_languages: expected["subtitles"],
                 embedded_subtitle_claim: subtitle_claim(expected["subtitle_claim"])
               },
               fixture_case["id"]
      end
    end

    test "keeps trailing Standard group precedence over a leading Anime token" do
      assert Parser.parse("[Fansub] Show.2020.1080p.WEB-Scene").group == "Scene"
    end

    test "bare multiplicity and title-word collisions stay unknown" do
      assert %{audio_languages: [], audio_claim_complete?: false} =
               Parser.parse("[Group] Show - 1 [1080p] Dual Audio")

      assert %{audio_languages: [], audio_claim_complete?: false} =
               Parser.parse("[Group] Show - 1 [1080p] MULTI")

      assert %{embedded_subtitle_claim: :unknown} = Parser.parse("Raw Deal 1986 [1080p]")
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

    test "a subtitle marker with a separator before the language word also stays nil" do
      # The pre-strip removes "<word> SUB(S/BED/TITLE...)" so a subtitle annotation never reads as
      # audio, including the endonym/abbrev forms the old per-token guard missed.
      for name <- [
            "Pelicula.2018.LATINO.SUBS.1080p.WEB-DL",
            "Foreign.Film.2019.ENGLISH.SUBTITLES.1080p.WEB-DL",
            "Series.2020.GREEK.SUBS.720p.WEB"
          ] do
        assert Parser.parse(name).language == nil, "expected nil (subtitle marker) from #{name}"
      end
    end

    test "MULTI is kept even when glued to a subtitle token, and a SUBBED audio tag survives" do
      # MULTI is matched on the raw name, so the subtitle strip can't eat it.
      assert Parser.parse("Movie.2021.MULTI.SUBS.1080p.BluRay.x264").language == "MULTI"
      # "SUBBED" = "has subtitles"; the named language is the AUDIO, so it must not be stripped.
      assert Parser.parse("Movie.2019.KOREAN.SUBBED.1080p.BluRay.x264").language == "KOREAN"
      assert Parser.parse("Film.2018.TRUEFRENCH.SUBBED.1080p.WEB").language == "FRENCH"
    end

    test "a real audio tag wins over a title-word language (registry order)" do
      # "Greek" in the title also matches, but the real FRENCH tag is earlier in the registry, so
      # first_match returns FRENCH. (A bare title-word collision with no real tag is left to the
      # Original/Any soft fallback in Cinder.Acquisition.)
      assert Parser.parse("The.Greek.Tycoon.1978.FRENCH.1080p.BluRay.x264").language == "FRENCH"
    end

    test "every registry language has ISO 639-2 audio codes (no drift)" do
      # Map.fetch! in @audio_codes already fails the build on a missing entry; this also asserts
      # each language carries its 639-1 code plus at least one 639-2 form for the MediaInfo check.
      assert Enum.all?(Parser.audio_codes(), fn {code, forms} ->
               code in forms and length(forms) >= 2
             end)
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

  defp subtitle_claim("present"), do: :present
  defp subtitle_claim("absent"), do: :absent
  defp subtitle_claim("unknown"), do: :unknown
end
