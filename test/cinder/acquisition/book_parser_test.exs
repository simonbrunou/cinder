defmodule Cinder.Acquisition.BookParserTest do
  # The tag-region parser's shared behaviour, run once per book kind. What only one kind
  # recognizes (its containers, the narrator credit) lives in `book_parser_kind_test.exs`.
  use ExUnit.Case,
    async: true,
    parameterize: [%{kind: :ebook}, %{kind: :audiobook}]

  alias Cinder.Acquisition.BookParser

  # Per kind: the preferred and the second accepted format, a format the kind recognizes but
  # refuses, and the kind's own word for itself in a release name.
  @kinds %{
    ebook: %{fmt: "epub", alt: "mobi", refused: "pdf", word: "eBook"},
    audiobook: %{fmt: "m4b", alt: "mp3", refused: "m4a", word: "Audiobook"}
  }

  # Parses `name` as the kind under test, with `{fmt}`, `{alt}`, `{refused}` and `{word}`
  # replaced by the kind's own tokens.
  defp parse(%{kind: kind}, name) do
    name =
      Enum.reduce([:fmt, :alt, :refused, :word], name, fn key, acc ->
        String.replace(acc, "{#{key}}", @kinds[kind][key])
      end)

    BookParser.parse(name, kind)
  end

  defp format(%{kind: kind}, key), do: String.to_existing_atom(@kinds[kind][key])

  describe "formats" do
    test "extracts a single format from a parenthesised tag", ctx do
      assert parse(ctx, "Ursula K. Le Guin - The Dispossessed ({fmt})").formats ==
               [format(ctx, :fmt)]
    end

    test "extracts a format written as a bare extension", ctx do
      assert parse(ctx, "Toni Morrison - Beloved.{fmt}").formats == [format(ctx, :fmt)]
    end

    test "extracts every format of a multi-format release rather than picking one", ctx do
      %{formats: formats} = parse(ctx, "Frank Herbert - Dune ({fmt}, {alt}) [retail]")

      assert Enum.sort(formats) == Enum.sort([format(ctx, :fmt), format(ctx, :alt)])
    end

    test "recognizes a format the kind refuses so the scorer can name what it refuses", ctx do
      assert parse(ctx, "Toni Morrison - Beloved ({refused})").formats == [format(ctx, :refused)]
    end

    test "a name with no format token parses to an empty set, not a guess", ctx do
      assert %{formats: []} = parse(ctx, "Toni Morrison - Beloved")
    end

    test "a non-binary name parses to the empty result rather than raising", %{kind: kind} do
      assert %{formats: [], language: nil, retail?: false, collection?: false} =
               BookParser.parse(nil, kind)
    end
  end

  describe "a format word in the TITLE is not a format tag" do
    # A book about a format carries the word in its own title. Reading it as a tag invents a
    # format the release never claimed AND makes the book unmatchable, because the scorer
    # discounts format words as metadata in the title remainder.
    test "a title naming a format claims no format", ctx do
      assert %{formats: []} = parse(ctx, "Matt Garrish - {fmt} 3 Best Practices")
    end

    test "the same book WITH a real tag still parses the tag", ctx do
      assert parse(ctx, "Matt Garrish - {fmt} 3 Best Practices ({fmt})").formats ==
               [format(ctx, :fmt)]
    end

    test "a real trailing tag run is still a tag region", ctx do
      assert parse(ctx, "Frank.Herbert-Dune.2019.Retail.{fmt}.{word}-BitBook").formats ==
               [format(ctx, :fmt)]

      assert parse(ctx, "Toni Morrison - Beloved.{fmt}").formats == [format(ctx, :fmt)]
    end
  end

  describe "format-first names (the tag region must not swallow the title)" do
    # A name that leads with its format tag used to make the whole release name the "tag region",
    # so an ordinary title word that is also a language became the parsed audio language and the
    # scorer invented a `:language_mismatch` against it.
    test "a bracketed leading format tag does not turn title words into languages", ctx do
      for name <- [
            "[{fmt}] Michael Ondaatje - The English Patient",
            "({fmt}) Isabel Allende - The Japanese Lover",
            "[{alt}] Mary Renault - The Persian Boy",
            "[{fmt}] Donald E. Westlake - The Italian Job"
          ] do
        assert %{language: nil} = parse(ctx, name), "leaked a language from #{name}"
      end
    end

    test "an unbracketed leading format tag does not either", ctx do
      assert %{language: nil} = parse(ctx, "{fmt} - Alan Furst - The Polish Officer")
    end

    test "a short format-first title does not become its own language", ctx do
      # A word-count bound let three title words through: "[EPUB] The Japanese Lover" was tagged
      # JAPANESE. Whether the words ARE tags is the question, not how many there are.
      for name <- [
            "[{fmt}] The Japanese Lover",
            "[{fmt}] The English Patient",
            "({alt}) The Persian Boy"
          ] do
        assert %{language: nil} = parse(ctx, name), "leaked a language from #{name}"
      end
    end

    test "a bare MULTI tag reads the same as a bracketed one", ctx do
      for name <- [
            "Toni Morrison - Beloved ({fmt}) MULTI",
            "Toni Morrison - Beloved ({fmt}) MULTILINGUAL",
            "Toni Morrison - Beloved ({fmt}) [MULTI]"
          ] do
        assert %{language: "MULTI"} = parse(ctx, name), "missed MULTI in #{name}"
      end
    end

    test "a bare language tag BETWEEN two bracket groups is read", ctx do
      assert %{language: "FRENCH"} =
               parse(ctx, "Victor Hugo - Les Miserables ({fmt}) FRENCH [retail]")
    end

    test "a bare language tag after a bracketed format is still read", ctx do
      # Skipping the post-bracket tail entirely turned a correctly-tagged French release into a
      # language mismatch.
      assert %{language: "FRENCH"} = parse(ctx, "Victor Hugo - Les Miserables ({fmt}) FRENCH")
    end

    test "a genuine trailing language tag is still read", ctx do
      assert %{language: "FRENCH"} = parse(ctx, "Victor Hugo - Les Miserables ({fmt}) [FRENCH]")
    end
  end

  describe "language" do
    test "reads a language marker from a bracketed tag", ctx do
      assert %{language: "FRENCH"} = parse(ctx, "Albert Camus - L'Etranger [FRENCH] ({fmt})")
    end

    test "reads a language marker written after the format token", ctx do
      assert %{language: "GERMAN"} = parse(ctx, "Kafka - Der Process {fmt} GERMAN")
    end

    test "a language word inside the title is NOT read as the release language", ctx do
      assert %{language: nil} = parse(ctx, "Michael Ondaatje - The English Patient ({fmt})")
      assert %{language: nil} = parse(ctx, "Donald E. Westlake - The Italian Job ({fmt})")
    end

    test "a title-only name with no tag region is never language-tagged", ctx do
      assert %{language: nil} = parse(ctx, "Some Author - The French Lieutenant's Woman")
    end

    test "an untagged release has no language", ctx do
      assert %{language: nil} = parse(ctx, "Frank Herbert - Dune ({fmt})")
    end

    test "MULTI marks a multi-language release", ctx do
      assert %{language: "MULTI"} = parse(ctx, "Frank Herbert - Dune ({fmt}) [MULTI]")
    end

    test "a foreign language wins over English when both appear in the tag region", ctx do
      assert %{language: "SPANISH"} =
               parse(ctx, "Gabriel Garcia Marquez - Cien Anos [SPANISH English] ({fmt})")
    end
  end

  describe "retail, collection and abridged markers" do
    test "flags a retail release", ctx do
      assert %{retail?: true} = parse(ctx, "Frank Herbert - Dune ({fmt}) [retail]")
      assert %{retail?: false} = parse(ctx, "Frank Herbert - Dune ({fmt})")
    end

    test "flags an omnibus, a boxset, and an anthology", ctx do
      assert %{collection?: true} = parse(ctx, "Tolkien - LOTR Omnibus ({fmt})")
      assert %{collection?: true} = parse(ctx, "Sanderson - Stormlight Boxset ({fmt})")
      assert %{collection?: true} = parse(ctx, "Various - Best SF Anthology ({fmt})")
    end

    test "flags a numbered book range", ctx do
      assert %{collection?: true} =
               parse(ctx, "Brandon Sanderson - Stormlight Archive Books 1-3 ({fmt})")

      assert %{collection?: true} = parse(ctx, "Author - Series #1-5 ({fmt})")
      assert %{collection?: true} = parse(ctx, "Author - Complete Works ({fmt})")
    end

    test "spaced and hyphenated box-set spellings are collections too", ctx do
      assert %{collection?: true} = parse(ctx, "Sanderson - Stormlight Box Set ({fmt})")
      assert %{collection?: true} = parse(ctx, "Sanderson - Stormlight Box-Set ({fmt})")
    end

    test "a bare numeric range with no book/volume word is still a collection", ctx do
      assert %{collection?: true} = parse(ctx, "Sanderson - The Stormlight Archive 1-3 ({fmt})")
    end

    test "a single numbered volume is not a collection", ctx do
      assert %{collection?: false} =
               parse(ctx, "Brandon Sanderson - The Way of Kings Book 1 ({fmt})")
    end

    test "a bare numeric range records its digits so the scorer can tell a title from a span",
         ctx do
      assert %{collection?: true, collection_numbers: ["11", "22"]} =
               parse(ctx, "Stephen King - 11-22-63 ({fmt})")
    end

    test "a keyword-marked range records no digits — it needs no extra corroboration", ctx do
      assert %{collection?: true, collection_numbers: nil} =
               parse(ctx, "Brandon Sanderson - Stormlight Archive Books 1-3 ({fmt})")
    end

    test "a hash-prefixed range records no digits either — '#' is its own unconditional evidence",
         ctx do
      # Codex review: a bare-range digit match was being captured even for "#1-3", so a numeric
      # title sharing those same digits could forgive an explicit "#1-3" pack claim. "#" is
      # explicit volume/issue notation on its own, so it must never be forgivable.
      assert %{collection?: true, collection_numbers: nil} =
               parse(ctx, "Author - Series #1-3 ({fmt})")
    end

    test "flags an abridged text, but not an unabridged one", ctx do
      assert %{abridged?: true} = parse(ctx, "Frank Herbert - Dune (Abridged) ({fmt})")
      assert %{abridged?: false} = parse(ctx, "Frank Herbert - Dune (Unabridged) ({fmt})")
    end
  end
end
