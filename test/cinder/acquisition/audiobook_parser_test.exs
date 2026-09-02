defmodule Cinder.Acquisition.AudiobookParserTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{AudiobookParser, AudiobookScorer}

  describe "formats" do
    test "extracts a single format from a parenthesised tag" do
      assert %{formats: [:m4b]} =
               AudiobookParser.parse("Frank Herbert - Dune (M4B)")
    end

    test "extracts a format written as a bare extension" do
      assert %{formats: [:mp3]} = AudiobookParser.parse("Toni Morrison - Beloved.mp3")
    end

    test "extracts every format of a multi-format release rather than picking one" do
      assert %{formats: formats} =
               AudiobookParser.parse("Frank Herbert - Dune (M4B, MP3)")

      assert Enum.sort(formats) == [:m4b, :mp3]
    end

    test "recognizes formats outside the profile so the scorer can name what it refuses" do
      assert %{formats: [:m4a]} = AudiobookParser.parse("Toni Morrison - Beloved (M4A)")
      assert %{formats: [:flac]} = AudiobookParser.parse("Toni Morrison - Beloved (FLAC)")
    end

    test "a name with no format token parses to an empty set, not a guess" do
      assert %{formats: []} = AudiobookParser.parse("Toni Morrison - Beloved")
    end

    test "a non-binary name parses to the empty result rather than raising" do
      assert %{formats: [], language: nil, narrator: nil} = AudiobookParser.parse(nil)
    end

    test "e-book containers are recognized (so the scorer can say wrong-family, not unknown)" do
      assert %{formats: [:epub]} =
               AudiobookParser.parse("Ursula K. Le Guin - The Dispossessed (epub)")

      assert %{formats: [:azw3]} = AudiobookParser.parse("Frank Herbert - Dune (AZW3)")
    end
  end

  describe "a format word in the TITLE is not a format tag" do
    test "a title naming a format claims no format" do
      assert %{formats: []} =
               AudiobookParser.parse("Matt Garrish - The MP3 Encoding Handbook")
    end

    test "the same book WITH a real tag still parses the tag" do
      assert %{formats: [:m4b]} =
               AudiobookParser.parse("Matt Garrish - The MP3 Encoding Handbook (m4b)")
    end
  end

  describe "narrator" do
    test "extracts a narrated-by credit from a parenthesised group" do
      assert %{narrator: "Ray Porter"} =
               AudiobookParser.parse(
                 "Andy Weir - Project Hail Mary (Narrated by Ray Porter) [M4B]"
               )
    end

    test "extracts a read-by credit from a bracketed group" do
      assert %{narrator: "Scott Brick"} =
               AudiobookParser.parse("Frank Herbert - Dune [Read by Scott Brick] (M4B)")
    end

    test "a title mentioning \"read by\" in prose is not a narrator credit" do
      assert %{narrator: nil} =
               AudiobookParser.parse("A Story Read by Firelight (M4B)")
    end

    test "no narrator credit parses to nil, not a guess" do
      assert %{narrator: nil} = AudiobookParser.parse("Frank Herbert - Dune (M4B)")
    end
  end

  describe "language" do
    test "reads a language tag from the bracketed region" do
      assert %{language: "FRENCH"} =
               AudiobookParser.parse("Frank Herbert - Dune [FRENCH] (M4B)")
    end

    test "an untagged release has no language" do
      assert %{language: nil} = AudiobookParser.parse("Frank Herbert - Dune (M4B)")
    end

    test "MULTI is recognized" do
      assert %{language: "MULTI"} = AudiobookParser.parse("Frank Herbert - Dune (M4B) MULTI")
    end
  end

  describe "retail, collection, and abridged markers" do
    test "retail" do
      assert %{retail?: true} = AudiobookParser.parse("Frank Herbert - Dune (M4B) [retail]")
    end

    test "collection" do
      assert %{collection?: true} =
               AudiobookParser.parse("Frank Herbert - Dune Anthology (M4B)")
    end

    test "abridged, but not unabridged" do
      assert %{abridged?: true} = AudiobookParser.parse("Frank Herbert - Dune (Abridged) (M4B)")

      assert %{abridged?: false} =
               AudiobookParser.parse("Frank Herbert - Dune (Unabridged) (M4B)")
    end
  end

  test "known_formats/0 lists the recognizer's vocabulary" do
    assert Enum.sort(AudiobookParser.known_formats()) ==
             Enum.sort([:m4b, :mp3, :m4a, :aac, :flac, :ogg, :wma, :epub, :azw3, :mobi])
  end

  test "AudiobookScorer.accepted_formats/0 is a subset of known_formats/0" do
    assert Enum.all?(AudiobookScorer.accepted_formats(), &(&1 in AudiobookParser.known_formats()))
  end
end
