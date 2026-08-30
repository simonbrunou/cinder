defmodule Cinder.Acquisition.BookParserTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.{BookParser, BookScorer}

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

  describe "a format word in the TITLE is not a format tag" do
    # A book about a format carries the word in its own title. Reading it as a tag invents a
    # format the release never claimed AND makes the book unmatchable, because the scorer
    # discounts format words as metadata in the title remainder.
    test "a title naming a format claims no format" do
      assert %{formats: []} = BookParser.parse("Matt Garrish - EPUB 3 Best Practices")
      assert %{formats: []} = BookParser.parse("Jane Doe - PDF Forms Explained")
    end

    test "the same book WITH a real tag still parses the tag" do
      assert %{formats: [:epub]} = BookParser.parse("Matt Garrish - EPUB 3 Best Practices (epub)")
    end

    test "a real trailing tag run is still a tag region" do
      assert %{formats: [:epub]} =
               BookParser.parse("Frank.Herbert-Dune.2019.Retail.EPUB.eBook-BitBook")

      assert %{formats: [:epub]} = BookParser.parse("Toni Morrison - Beloved.epub")
    end
  end

  describe "comic containers" do
    test "CBR and CBZ are distinct formats" do
      assert %{formats: [:cbr]} = BookParser.parse("Author - Title (cbr)")
      assert %{formats: [:cbz]} = BookParser.parse("Author - Title (cbz)")
    end

    test "both are outside the e-book profile" do
      refute :cbr in BookScorer.accepted_formats()
      refute :cbz in BookScorer.accepted_formats()
    end
  end

  describe "format-first names (the tag region must not swallow the title)" do
    # A name that leads with its format tag used to make the whole release name the "tag region",
    # so an ordinary title word that is also a language became the parsed audio language and the
    # scorer invented a `:language_mismatch` against it.
    test "a bracketed leading format tag does not turn title words into languages" do
      for name <- [
            "[EPUB] Michael Ondaatje - The English Patient",
            "(EPUB) Isabel Allende - The Japanese Lover",
            "[MOBI] Mary Renault - The Persian Boy",
            "[EPUB] Donald E. Westlake - The Italian Job"
          ] do
        assert %{language: nil} = BookParser.parse(name), "leaked a language from #{name}"
      end
    end

    test "an unbracketed leading format tag does not either" do
      assert %{language: nil} = BookParser.parse("EPUB - Alan Furst - The Polish Officer")
    end

    test "a short format-first title does not become its own language" do
      # A word-count bound let three title words through: "[EPUB] The Japanese Lover" was tagged
      # JAPANESE. Whether the words ARE tags is the question, not how many there are.
      for name <- [
            "[EPUB] The Japanese Lover",
            "[EPUB] The English Patient",
            "(MOBI) The Persian Boy"
          ] do
        assert %{language: nil} = BookParser.parse(name), "leaked a language from #{name}"
      end
    end

    test "a bare language tag BETWEEN two bracket groups is read" do
      assert %{language: "FRENCH"} =
               BookParser.parse("Victor Hugo - Les Miserables (epub) FRENCH [retail]")
    end

    test "a bare language tag after a bracketed format is still read" do
      # Skipping the post-bracket tail entirely turned a correctly-tagged French release into a
      # language mismatch.
      assert %{language: "FRENCH"} =
               BookParser.parse("Victor Hugo - Les Miserables (epub) FRENCH")
    end

    test "a genuine trailing language tag is still read" do
      assert %{language: "FRENCH"} =
               BookParser.parse("Victor Hugo - Les Miserables (epub) [FRENCH]")
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

    test "spaced and hyphenated box-set spellings are collections too" do
      assert %{collection?: true} = BookParser.parse("Sanderson - Stormlight Box Set (epub)")
      assert %{collection?: true} = BookParser.parse("Sanderson - Stormlight Box-Set (epub)")
    end

    test "a bare numeric range with no book/volume word is still a collection" do
      assert %{collection?: true} =
               BookParser.parse("Sanderson - The Stormlight Archive 1-3 (epub)")
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
