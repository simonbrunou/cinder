defmodule Cinder.Acquisition.TitleNoiseTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.TitleNoise

  # Each test here pins one specific regex/conditional branch in TitleNoise directly, so a
  # regression in one branch fails a named test rather than hiding behind the many indirect paths
  # through BookScorer/AudiobookScorer's evaluate/3. The scorer-level tests (book_scorer_test.exs,
  # audiobook_scorer_test.exs) additionally prove the mechanism integrates correctly end to end —
  # both kinds of coverage are kept; see "a series ordinal that coincidentally equals the wanted
  # number is not title evidence" in those files for the single most important end-to-end
  # negative-direction case (an unrelated book in a shared series, whose ordinal numerically
  # coincides with the wanted title's own number, is still rejected).

  describe "series_name/1" do
    test "extracts :name from a structured series entry" do
      # Pins: Cinder.Books.Metadata.work/0's documented %{name:, position:} shape.
      assert TitleNoise.series_name(%{name: "Foo", position: "1"}) == "Foo"
    end

    test "returns a plain string series entry unchanged" do
      # Pins: every existing caller/fixture that passes series as plain strings.
      assert TitleNoise.series_name("Foo") == "Foo"
    end

    test "returns nil for an entry with neither shape, rather than raising" do
      # Pins: the catch-all clause. Without it, a malformed series entry (an integer, a map with
      # no :name) crashes Regex.escape/1 deep inside strip/2 instead of being skipped.
      assert TitleNoise.series_name(123) == nil
      assert TitleNoise.series_name(%{other: "x"}) == nil
    end
  end

  describe "strip/2 — wanted title's own bare number" do
    test "keeps a bare digit that is the wanted title's own number" do
      # Pins: strip_series_number/2's preservation branch (#517's core fix).
      assert TitleNoise.strip("Ray Bradbury - Fahrenheit 451 ", %{title: "Fahrenheit 451"}) =~
               "451"
    end

    test "strips a bare digit unrelated to the wanted title" do
      # Pins: strip_series_number/2's noise branch.
      refute TitleNoise.strip("Brandon Sanderson - The Way of Kings 07 ", %{
               title: "The Way of Kings"
             }) =~ ~r/\b07\b/
    end
  end

  describe "strip/2 — series ordinal, adjacency and separators" do
    test "strips an ordinal that follows a series name over a tight separator" do
      # Pins: strip_ordinal_after/4's [ .#_]* tight-separator match and its strip branch.
      result =
        TitleNoise.strip("Brandon Sanderson - The Stormlight Archive 02 - Words of Radiance ", %{
          title: "The Way of Kings",
          series: ["The Stormlight Archive"]
        })

      assert result =~ "Stormlight Archive"
      refute result =~ ~r/\b02\b/
    end

    test "strips an ordinal that precedes a series name" do
      # Pins: strip_ordinal_before/4's strip branch (the mirror of strip_ordinal_after/4).
      refute TitleNoise.strip("X - 13 Foo - Room ", %{title: "Room 13", series: ["Foo"]}) =~
               ~r/\b13\b.*Foo/
    end

    test "keeps a wanted-title-own number that precedes its series name" do
      # Pins: strip_ordinal_before/4's KEEP branch (belongs_to_wanted_title?/2 true) -- distinct
      # from the after-form's keep branch below, since it is a separate function/regex.
      assert TitleNoise.strip("X - 13 Room ", %{title: "13 Room", series: ["Room"]}) =~ "13"
    end

    test "keeps a wanted-title-own number that follows its series name" do
      # Pins: strip_ordinal_after/4's KEEP branch -- the wanted title itself IS "series + number".
      assert TitleNoise.strip("X - Room 13 ", %{title: "Room 13", series: ["Room"]}) =~ "13"
    end

    test "recognizes the series name across a normalized (dot) separator, not just a space" do
      # Pins: word_pattern/1's [^A-Za-z0-9]+ inter-word join, matched against scene-style naming.
      refute TitleNoise.strip("X - Foo.Bar.13 - Room ", %{
               title: "Room 13",
               series: ["Foo Bar"]
             }) =~ ~r/\b13\b.*Room/
    end

    test "does not attach a proper field delimiter's next field as an ordinal" do
      # Pins: the [ .#_]* class excluding a spaced hyphen -- "Author - Series - Title" must not
      # read the TITLE field's own leading number as the SERIES field's ordinal. Constructed so
      # the wanted title's own number ("13") only survives if strip_ordinal_after/4 did NOT
      # consume it as "Foo"'s ordinal (a bug would strip it here and never re-offer it).
      assert TitleNoise.strip("X - Foo - 13 Ways ", %{
               title: "13 Ways",
               series: [%{name: "Foo", position: "1"}]
             }) =~ "13"
    end

    test "consumes a fractional ordinal atomically, not just its integer prefix" do
      # Pins: \d{1,3}(?:\.\d{1,3})? -- a decimal series position ("1.5", a novella between books
      # 1 and 2) must not leave its fractional remainder exposed as a bare, coincidentally-
      # matching digit.
      refute TitleNoise.strip("X.Foo.1.5.Room.", %{
               title: "Room 5",
               series: [%{name: "Foo", position: "1.5"}]
             }) =~ ~r/\b5\b/
    end
  end

  describe "strip/2 — series ordinal, text normalization" do
    test "recognizes a series ordinal despite a diacritic the release keeps" do
      # Pins: word_pattern/1's \p{Mn}* combining-mark tolerance plus nfd/1's NFD normalization --
      # the series name is ASCII-folded ("cafe") but the release keeps "Café".
      refute TitleNoise.strip("X - Café.13 - Room ", %{title: "Room 13", series: ["Café"]}) =~
               ~r/\b13\b.*Room/
    end

    test "recognizes a series ordinal despite an apostrophe the release keeps" do
      # Pins: word_pattern/1's apostrophe tolerance -- tokens/1 DROPS apostrophes ("Dragon's"
      # folds to "dragons"), but the release keeps the literal apostrophe between "n" and "s".
      refute TitleNoise.strip("X - Dragon's Foo 13 - Room ", %{
               title: "Room 13",
               series: ["Dragon's Foo"]
             }) =~ ~r/\b13\b.*Room/
    end

    test "malformed UTF-8 does not raise" do
      # Pins: nfd/1's {:error, ok_part, rest} fallback, the same discipline
      # Cinder.Books.TitleFold.nfd/1 documents for a garbled indexer/provider title.
      assert is_binary(
               TitleNoise.strip(<<0xFF, 0xFE>> <> "Foo 13 - Room", %{
                 title: "Room",
                 series: ["Foo"]
               })
             )
    end
  end

  describe "strip/2 — series name embedding its own digit" do
    test "removes a digit embedded in an unrelated series name" do
      # Pins: strip_embedded_series_number/4's strip branch -- "Foo 13" as the SERIES NAME
      # itself (not an adjacent ordinal) coincidentally shares its digit with an unrelated
      # wanted title.
      refute TitleNoise.strip("X - Foo 13 - Room ", %{title: "Room 13", series: ["Foo 13"]}) =~
               ~r/\b13\b.*Room/
    end

    test "keeps a series name's embedded digit when it IS the wanted title's own number" do
      # Pins: strip_embedded_series_number/4's KEEP branch.
      assert TitleNoise.strip("X - Room 13 ", %{title: "Room 13", series: ["Room 13"]}) =~ "13"
    end
  end

  describe "strip/2 — keyword-prefixed number (book/vol/edition/etc)" do
    test "strips a keyword-prefixed number unrelated to the wanted title" do
      # Pins: strip_keyword_number/2's keyword_regex strip branch.
      refute TitleNoise.strip("X - Room - Edition 13 ", %{title: "Room 13"}) =~
               ~r/Edition\s*13/i
    end

    test "keeps a keyword-prefixed number that IS the wanted title's own phrase" do
      # Pins: strip_keyword_number/2's keyword_regex KEEP branch (eponymous keyword phrase).
      assert TitleNoise.strip("X - Edition 13 ", %{title: "Edition 13"}) =~ ~r/Edition\s*13/i
    end
  end

  describe "strip/2 — the 'ed' abbreviation vs. an author literally named Ed" do
    test "does not treat 'Ed' at the very start of the string as an edition marker" do
      # Pins: the (?<=.) lookbehind excluding position 0, where an author byline sits but a
      # genuine edition marker essentially never does.
      assert TitleNoise.strip("Ed.13.", %{title: "13"}) =~ "Ed"
      assert TitleNoise.strip("Ed.13.", %{title: "13"}) =~ "13"
    end

    test "strips a genuine mid-release 'ed N' edition marker unrelated to the wanted title" do
      # Pins: the ed-regex strip branch, for "ed" NOT at position 0.
      refute TitleNoise.strip("X - Room - Ed 13 ", %{title: "Room 13"}) =~ ~r/[Ee]d\s*13/
    end

    test "keeps a mid-release 'ed N' that IS the wanted title's own phrase" do
      # Pins: the ed-regex KEEP branch (belongs_to_wanted_title?/2 true) -- distinct from the
      # position-0 exemption above, which never reaches this branch at all.
      assert TitleNoise.strip("X - Something - Ed 13 ", %{title: "Ed 13"}) =~ ~r/[Ee]d\s*13/
    end
  end
end
