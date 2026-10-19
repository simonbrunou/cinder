defmodule Cinder.Acquisition.BookParserKindTest do
  # What only one book kind's parse does. The shared tag-region behaviour runs for both kinds in
  # `book_parser_test.exs`.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.BookParser

  defp ebook(name), do: BookParser.parse(name, :ebook)
  defp audiobook(name), do: BookParser.parse(name, :audiobook)

  describe "e-book" do
    test "azw3 is not swallowed by the azw token" do
      assert %{formats: [:azw3]} = ebook("Andy Weir - Project Hail Mary [AZW3]")
    end

    test "recognizes scan and comic formats it refuses" do
      assert %{formats: [:djvu]} = ebook("Some Scan - Author (DJVU)")
      assert %{formats: [:cbr]} = ebook("Author - Title (cbr)")
      assert %{formats: [:cbz]} = ebook("Author - Title (cbz)")
    end

    test "a title naming a refused format claims no format" do
      assert %{formats: []} = ebook("Jane Doe - PDF Forms Explained")
    end

    test "the result names no narrator, a field the e-book release does not have" do
      refute Map.has_key?(
               ebook("Andy Weir - Project Hail Mary (Narrated by Ray Porter) (epub)"),
               :narrator
             )

      refute Map.has_key?(ebook(nil), :narrator)
    end
  end

  describe "audiobook" do
    test "e-book containers are recognized (so the scorer can say wrong-family, not unknown)" do
      assert %{formats: [:epub]} = audiobook("Ursula K. Le Guin - The Dispossessed (epub)")
      assert %{formats: [:azw3]} = audiobook("Frank Herbert - Dune (AZW3)")
    end

    test "recognizes an unsupported audio container by name" do
      assert %{formats: [:flac]} = audiobook("Toni Morrison - Beloved (FLAC)")
    end

    test "a non-binary name has no narrator rather than raising" do
      assert %{narrator: nil} = audiobook(nil)
    end
  end

  describe "each kind's own tag words" do
    # A word after the format token counts as a tag only when it is the kind's own vocabulary;
    # otherwise the format word is read as part of the title and claims nothing.
    test "a scan marker is an e-book tag, not an audiobook one" do
      assert %{formats: [:epub]} = ebook("Toni Morrison - Beloved.epub.Scan")
      assert %{formats: []} = audiobook("Toni Morrison - Beloved.m4b.Scan")
    end

    test "a rip marker is an audiobook tag, not an e-book one" do
      assert %{formats: [:m4b]} = audiobook("Toni Morrison - Beloved.m4b.Rip")
      assert %{formats: []} = ebook("Toni Morrison - Beloved.epub.Rip")
    end
  end

  describe "audiobook narrator" do
    test "extracts a narrated-by credit from a parenthesised group" do
      assert %{narrator: "Ray Porter"} =
               audiobook("Andy Weir - Project Hail Mary (Narrated by Ray Porter) [M4B]")
    end

    test "extracts a read-by credit from a bracketed group" do
      assert %{narrator: "Scott Brick"} =
               audiobook("Frank Herbert - Dune [Read by Scott Brick] (M4B)")
    end

    test "a title mentioning \"read by\" in prose is not a narrator credit" do
      assert %{narrator: nil} = audiobook("A Story Read by Firelight (M4B)")
    end

    test "no narrator credit parses to nil, not a guess" do
      assert %{narrator: nil} = audiobook("Frank Herbert - Dune (M4B)")
    end
  end
end
