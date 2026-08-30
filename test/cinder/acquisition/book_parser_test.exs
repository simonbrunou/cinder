defmodule Cinder.Acquisition.BookParserTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.BookParser

  describe "formats" do
    test "extracts a single format from a parenthesised tag" do
      assert %{formats: [:epub]} =
               BookParser.parse("Ursula K. Le Guin - The Dispossessed (epub)")
    end

    test "extracts a format written as a bare extension" do
      assert %{formats: [:epub]} = BookParser.parse("Toni Morrison - Beloved.epub")
    end

    test "extracts every format of a multi-format release rather than picking one" do
      assert %{formats: formats} =
               BookParser.parse("Frank Herbert - Dune (EPUB, MOBI, AZW3) [retail]")

      assert Enum.sort(formats) == [:azw3, :epub, :mobi]
    end

    test "azw3 is not swallowed by the azw token" do
      assert %{formats: [:azw3]} = BookParser.parse("Andy Weir - Project Hail Mary [AZW3]")
    end

    test "recognizes formats outside the profile so the scorer can name what it refuses" do
      assert %{formats: [:pdf]} = BookParser.parse("Some Textbook - Author (PDF)")
      assert %{formats: [:djvu]} = BookParser.parse("Some Scan - Author (DJVU)")
      assert %{formats: [:cbz]} = BookParser.parse("Some Comic - Author (CBZ)")
    end

    test "a name with no format token parses to an empty set, not a guess" do
      assert %{formats: []} = BookParser.parse("Toni Morrison - Beloved")
    end

    test "a non-binary name parses to the empty result rather than raising" do
      assert %{formats: [], language: nil, retail?: false, collection?: false} =
               BookParser.parse(nil)
    end
  end

  describe "language" do
    test "reads a language marker from a bracketed tag" do
      assert %{language: "FRENCH"} =
               BookParser.parse("Albert Camus - L'Etranger [FRENCH] (epub)")
    end

    test "reads a language marker written after the format token" do
      assert %{language: "GERMAN"} = BookParser.parse("Kafka - Der Process epub GERMAN")
    end

    test "a language word inside the title is NOT read as the release language" do
      assert %{language: nil} = BookParser.parse("Michael Ondaatje - The English Patient (epub)")
      assert %{language: nil} = BookParser.parse("Donald E. Westlake - The Italian Job (epub)")
    end

    test "a title-only name with no tag region is never language-tagged" do
      assert %{language: nil} = BookParser.parse("Some Author - The French Lieutenant's Woman")
    end

    test "MULTI marks a multi-language release" do
      assert %{language: "MULTI"} = BookParser.parse("Frank Herbert - Dune (epub) [MULTI]")
    end

    test "a foreign language wins over English when both appear in the tag region" do
      assert %{language: "SPANISH"} =
               BookParser.parse("Gabriel Garcia Marquez - Cien Anos [SPANISH English] (epub)")
    end
  end

  describe "retail and collection markers" do
    test "flags a retail release" do
      assert %{retail?: true} = BookParser.parse("Frank Herbert - Dune (epub) [retail]")
      assert %{retail?: false} = BookParser.parse("Frank Herbert - Dune (epub)")
    end

    test "flags an omnibus, a boxset, and an anthology" do
      assert %{collection?: true} = BookParser.parse("Tolkien - LOTR Omnibus (epub)")
      assert %{collection?: true} = BookParser.parse("Sanderson - Stormlight Boxset (epub)")
      assert %{collection?: true} = BookParser.parse("Various - Best SF Anthology (epub)")
    end

    test "flags a numbered book range" do
      assert %{collection?: true} =
               BookParser.parse("Brandon Sanderson - Stormlight Archive Books 1-3 (epub)")

      assert %{collection?: true} = BookParser.parse("Author - Series #1-5 (epub)")
      assert %{collection?: true} = BookParser.parse("Author - Complete Works (epub)")
    end

    test "a single numbered volume is not a collection" do
      assert %{collection?: false} =
               BookParser.parse("Brandon Sanderson - The Way of Kings Book 1 (epub)")
    end
  end

  test "known_formats/0 lists the recognizer's vocabulary" do
    formats = BookParser.known_formats()

    assert :epub in formats
    assert :pdf in formats
    assert formats == Enum.uniq(formats)
  end
end
