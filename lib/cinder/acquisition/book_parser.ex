defmodule Cinder.Acquisition.BookParser do
  @moduledoc """
  Extracts book-release attributes (`formats`, `language`, `retail?`, `collection?`) from a
  release name. Pure and best-effort — an unrecognized field is `nil`/`false`/`[]`.

  ## Why this is not `Cinder.Acquisition.Parser`

  A video release name is *title, then tags*: `Inception.2010.1080p.BluRay.x264-RARBG`. The parser
  can anchor on the year/resolution marker and treat everything past it as the tag region. A book
  release name has no such anchor — `Ursula K. Le Guin - The Dispossessed (epub)` carries no year,
  no resolution, and its "tags" are one parenthesised word. So the region rules differ, and the
  tokens differ (there is no book codec, and no video format is an e-book format).

  What the two **do** share is the language vocabulary, which is derived from
  `Cinder.Acquisition.Parser.language_tags/0` rather than restated here — two hand-synced language
  tables is exactly the drift that module's own registry note warns about.

  ## Formats are a set

  `Author - Title (EPUB, MOBI, AZW3)` is one release carrying three formats. Parsing it to a
  single value would either drop an acceptable format or invent a preference the release never
  stated, so `formats` is a list, ordered as the recognizer lists them (stable, not
  release-order).

  Formats outside the e-book profile — PDF, CBZ, DJVU — are recognized *on purpose*. The scorer
  needs to tell "this is a PDF scan, refused" from "no format stated at all", and it can only do
  that if the parser names the format it refuses. A recognizer that only knew the accepted
  formats would collapse both into one silent miss.

  ## Language is only read from the tag region

  A book release name is mostly title, and titles contain language words: *The English Patient*,
  *The Italian Job*, *Dutch Courage*. Matching a language token anywhere in the name would tag
  those with a language they do not have, and the scorer would then reject the correct release for
  a language mismatch it invented. So a language token counts only when it appears in the tag
  region — the bracketed/parenthesised groups, plus anything after the first format token — which
  is where a real language marker is actually written. `Cinder.Acquisition.Parser` restricts its
  own collision-prone `@bare_sources` scan the same way and for the same reason.

  Only the full English language name is matched (`FRENCH`, `GERMAN`), not the endonyms and
  two-to-three-letter abbreviations the video registry also carries. Those exist for scene video
  naming; `\\bita\\b` and `\\bvf\\b` in a book title are far likelier to be a fragment of a name
  than an Italian or French marker, and an untagged release is handled gracefully downstream while
  a wrongly-tagged one is rejected.
  """

  alias Cinder.Acquisition.Parser

  # Extension-style format tokens. Ordered most-specific-first so `azw3` is not swallowed by
  # `azw`. The value is the canonical atom the scorer's allow-list is written in.
  @formats [
    {~r/\bepub\b/i, :epub},
    {~r/\bazw3\b/i, :azw3},
    {~r/\bazw\b/i, :azw},
    {~r/\bmobi\b/i, :mobi},
    {~r/\bpdf\b/i, :pdf},
    {~r/\bdjvu\b/i, :djvu},
    {~r/\bfb2\b/i, :fb2},
    {~r/\blit\b/i, :lit},
    {~r/\bcbz\b/i, :cbz},
    {~r/\bcbr\b/i, :cbr},
    {~r/\brtf\b/i, :rtf}
  ]

  @format_anchor ~r/\b(?:epub|azw3|azw|mobi|pdf|djvu|fb2|lit|cbr|cbz|rtf)\b/i

  # A retail release came from the publisher's own file rather than a scan or a conversion.
  @retail ~r/\bretail\b/i

  # An abridged text is a DIFFERENT text, not a worse copy of the same one. "unabridged" is
  # checked first because it contains "abridged" as a substring — the `\b` alone would match it.
  @abridged ~r/(?<!un)\babridged\b/i

  # Markers that say the release is more than the one work asked for. The contract requires
  # omnibus/anthology ambiguity to produce an explained rejection rather than a silent fallback,
  # and a bare token-containment test cannot see the difference on its own: every token of
  # "The Way of Kings" really is present in "The Stormlight Archive Books 1-3 (The Way of Kings,
  # Words of Radiance, Oathbringer)".
  #
  # `books 1-3` / `#1-5` / `vol 1-3` are ranges, not single volumes. A bare "collection" or
  # "anthology" is enough on its own; those words are near-never part of a novel's own title, and
  # when they are, the cost is a manual search rather than a wrong import.
  @collection_markers [
    ~r/\bomnibus\b/i,
    ~r/\banthology\b/i,
    ~r/\bcollection\b/i,
    # "box set" and "box-set" are the dominant WRITTEN forms; `\bboxs?et\b` alone matched only the
    # closed-up spelling.
    ~r/\bbox[\s._-]?sets?\b/i,
    ~r/\bcomplete\s+(?:series|works|collection|trilogy|saga)\b/i,
    # A keyword-prefixed range ("Books 1-3", "Vols 1-3") carries its own word, so unlike the bare
    # range below it needs no further corroboration to count as a collection claim.
    ~r/\b(?:books?|vols?|volumes?)[\s._#-]*\d+\s*(?:-|–|to|thru|through)\s*\d+\b/i,
    # A hash-prefixed range ("#1-3", "#1-5") is `#` PLUS a range — that "#" is itself explicit
    # volume/issue notation, not punctuation a title incidentally carries, so this is unconditional
    # evidence exactly like the keyword-prefixed range above (Codex review, #518): a numeric title
    # that also happens to contain the same digits ("Numeric Work 1/3" against a release naming
    # itself "... 1/3 #1-3") must not forgive an explicit "#1-3" pack claim just because its own
    # title coincidentally shares those digits.
    ~r/#\s*\d+\s*(?:-|–)\s*\d+\b/
  ]

  # A bare numeric range with no "books"/"vols" prefix and no leading "#" — "The Stormlight
  # Archive 1-3" — is the same pack, written the way most uploaders actually write it, and is
  # bounded to 1-2 digits per side so a year range or an ISBN fragment cannot read as a volume
  # span. But with no keyword and no "#" it is genuinely ambiguous: a work whose own title IS a
  # number written as a range ("11/22/63", punctuation-normalized to "11-22-63") matches the
  # identical shape (#518). The digits are captured so `BookScorer.check_collection/2` can tell
  # the two apart by comparing them against the wanted title's own numeric tokens — a real pack's
  # span shares no such run with an unrelated wanted title.
  @collection_numeric_ranges [
    ~r/\s(\d{1,2})\s*(?:-|–)\s*(\d{1,2})\b/
  ]

  # `{regex, tag}` for each language, derived from the shared registry so the two families cannot
  # drift on what a tag means. Full English name only — see the moduledoc.
  @languages Parser.language_tags()
             |> Enum.map(fn {_code, tag} -> {Regex.compile!("\\b#{tag}\\b", "i"), tag} end)
             |> Enum.sort_by(fn {_regex, tag} -> {tag == "ENGLISH", tag} end)

  @multi ~r/\bmulti(?:lingual)?\b/i

  @doc """
  Parses a book release name into the `Cinder.Acquisition.BookRelease` name-derived fields.
  """
  @spec parse(String.t() | any()) :: %{
          formats: [atom()],
          language: String.t() | nil,
          retail?: boolean(),
          collection?: boolean(),
          collection_numbers: [String.t()] | nil,
          abridged?: boolean()
        }
  def parse(name) when is_binary(name) do
    {collection?, collection_numbers} = collection_evidence(name)

    %{
      formats: formats(name),
      language: language(name),
      retail?: Regex.match?(@retail, name),
      collection?: collection?,
      collection_numbers: collection_numbers,
      abridged?: Regex.match?(@abridged, name)
    }
  end

  def parse(_name),
    do: %{
      formats: [],
      language: nil,
      retail?: false,
      collection?: false,
      collection_numbers: nil,
      abridged?: false
    }

  @doc "Every format token the parser recognizes, in preference-neutral recognizer order."
  @spec known_formats() :: [atom()]
  def known_formats, do: Enum.map(@formats, fn {_regex, format} -> format end) |> Enum.uniq()

  # A keyword marker is unambiguous evidence on its own. A bare numeric range gets no benefit of
  # the doubt when a keyword marker ALSO matched — that is real additional evidence of a pack, not
  # a coincidental digit overlap with the wanted title — so its digits are only captured when the
  # numeric range is the ENTIRE collection evidence for this release.
  defp collection_evidence(name) do
    if Enum.any?(@collection_markers, &Regex.match?(&1, name)) do
      {true, nil}
    else
      case numeric_range(name) do
        nil -> {false, nil}
        numbers -> {true, numbers}
      end
    end
  end

  defp numeric_range(name) do
    Enum.find_value(@collection_numeric_ranges, fn regex ->
      case Regex.run(regex, name) do
        [_whole, a, b] -> [a, b]
        nil -> nil
      end
    end)
  end

  # Formats are read from the TAG REGION, not the whole name — the same discipline `language/1`
  # follows, and for the same reason. A book ABOUT a format carries the word in its title:
  # "Matt Garrish - EPUB 3 Best Practices" was parsed `formats: [:epub]` on the strength of its
  # own title, so an untagged release of it claimed to be an EPUB. Worse, `@edition_annotations`
  # then discounted "epub" as metadata in the title remainder, so the book could not be matched
  # even when the request named it exactly.
  #
  # A bare extension suffix ("Author - Title.epub") has no bracket to sit in, so the trailing
  # region covers it; `tag_region/1` treats an anchor in the leading third as a prefix, which is
  # what keeps "[EPUB] Author - Title" working.
  defp formats(name) do
    region = format_region(name)

    @formats
    |> Enum.flat_map(fn {regex, format} ->
      if Regex.match?(regex, region), do: [format], else: []
    end)
    |> Enum.uniq()
  end

  # `tag_region/1` starts AFTER the format anchor, because for a language the format word itself
  # carries nothing. Formats need the anchor included, so this is the tag region plus the anchored
  # token: bracketed groups, and the tail from the first format token onwards ("Beloved.epub",
  # "... EPUB-GROUP"). A leading format prefix ("[EPUB] Author - Title") is already covered by the
  # bracketed half, so it is not scanned twice.
  defp format_region(name) do
    bracketed = bracketed_region(name)

    bracketed <> " " <> anchored_region(name)
  end

  # From the first format token to the end — but ONLY when everything following it is itself
  # metadata. A format tag is the last thing a release name says, or is followed by other tags
  # ("Beloved.epub", "...Retail.EPUB.eBook-BitBook"). A format word trailed by ordinary words is
  # the TITLE talking about a format — "Matt Garrish - EPUB 3 Best Practices" — and reading it as
  # a tag both invents a format the release never claimed and makes the book unmatchable, since
  # the scorer discounts format words as metadata in the title remainder.
  defp anchored_region(name) do
    case Regex.run(@format_anchor, name, return: :index) do
      [{start, length} | _rest] ->
        region = binary_part(name, start, byte_size(name) - start)
        tail = binary_part(name, start + length, byte_size(name) - start - length)

        if tag_tail?(tail), do: region, else: ""

      nil ->
        ""
    end
  end

  # Every word after the format token is a tag, a group/tracker name, or punctuation — never
  # ordinary prose. Numbers count as tags ("EPUB 3" is the exception this exists to catch, but a
  # bare year or volume number after a tag is normal), so the discriminator is alphabetic words
  # that are not themselves recognized metadata.
  defp tag_tail?(tail) do
    # A trailing scene group ("-BitBook", "-GRP") is an arbitrary name by definition, so it can
    # never be on a known-word list. It is recognized by POSITION instead — last, after a
    # hyphen — and dropped before the remaining words are checked.
    tail
    |> String.replace(~r/-[A-Za-z0-9]+\s*$/, " ")
    |> String.split(~r/[^A-Za-z]+/, trim: true)
    |> Enum.all?(&tag_word?/1)
  end

  defp tag_word?(word) do
    Regex.match?(@format_anchor, word) or Regex.match?(@retail, word) or
      Regex.match?(@abridged, word) or String.match?(word, ~r/^(?:un)?abridged$/i) or
      word =~ ~r/^(?:ebook|book|retail|scan|ocr|v\d+)$/i or
      Regex.match?(@multi, word) or word =~ ~r/^multilingual$/i or
      Enum.any?(@languages, fn {regex, _tag} -> Regex.match?(regex, word) end) or
      String.length(word) <= 2
  end

  defp language(name) do
    region = tag_region(name)

    if Regex.match?(@multi, region),
      do: "MULTI",
      else: find_language(region)
  end

  defp find_language(region) do
    Enum.find_value(@languages, fn {regex, tag} ->
      if Regex.match?(regex, region), do: tag
    end)
  end

  # The region a marker may legitimately appear in: every bracketed/parenthesised group, plus
  # everything after the first format token. Both, not either — `Dune [FRENCH] epub` puts the
  # marker before the format, and `Dune epub FRENCH` puts it after, and both are real.
  #
  # No brackets and no format token ⇒ `""`, so nothing is tagged. That is the deliberate outcome:
  # a name with no tag region at all is all title, and reading a language out of a title is the
  # failure this whole split exists to prevent.
  defp tag_region(name) do
    bracketed = bracketed_region(name)

    bracketed <> " " <> trailing_region(name, bracketed)
  end

  defp bracketed_region(name) do
    ~r/[\[\(\{]([^\]\)\}]*)[\]\)\}]/
    |> Regex.scan(name, capture: :all_but_first)
    |> Enum.map_join(" ", &hd/1)
  end

  # Everything after the first format token — the region where a bare (unbracketed) tag like
  # "... EPUB FRENCH" lives.
  #
  # Skipped entirely when the format was already written as a bracketed tag, because a
  # format-FIRST name ("[EPUB] Michael Ondaatje - The English Patient") would otherwise put the
  # whole title in the tag region and read its words as language tags:
  #
  #     "[EPUB] ... The English Patient"  -> ENGLISH
  #     "(EPUB) ... The Japanese Lover"   -> JAPANESE
  #     "[MOBI] ... The Persian Boy"      -> PERSIAN
  #
  # which is exactly the invented `:language_mismatch` this module's `@moduledoc` says the tag
  # region exists to prevent. If the format is bracketed, `bracketed` already covers the tag
  # region and the trailing scan has nothing left to contribute.
  defp trailing_region(name, bracketed) do
    if Regex.match?(@format_anchor, bracketed) do
      # The format was a bracketed tag, so the anchor scan would put the whole TITLE in the tag
      # region ("[EPUB] ... The English Patient" -> ENGLISH). But text after the LAST bracket is
      # still tag territory — "Les Miserables (epub) FRENCH" is a real shape, and skipping it
      # turned a correctly-tagged French release into a language mismatch.
      after_last_bracket(name)
    else
      Regex.split(@format_anchor, name, parts: 2) |> after_anchor(name)
    end
  end

  # An anchor in the leading third of the name is a format PREFIX ("EPUB - Author - Title"), not a
  # tag terminating the title, so the "tail" is the title itself. Only a late anchor really marks
  # where the tags begin.
  defp after_anchor([head, tail], name),
    do: if(String.length(head) * 3 >= String.length(name), do: tail, else: "")

  defp after_anchor([_no_anchor], _name), do: ""

  # The bare (unbracketed) runs BETWEEN and AFTER bracket groups — "Les Miserables (epub) FRENCH",
  # "... (epub) FRENCH [retail]". Each run is kept only when every word in it is a recognized tag.
  #
  # Word COUNT was the wrong test: it let "[EPUB] The Japanese Lover" through (three title words
  # after a leading format tag, read as JAPANESE), and it dropped a real tag sitting between two
  # bracket groups. Whether the words ARE tags is the question, and `tag_word?/1` already answers
  # it for the format scan. A title word is not a tag, so a title never enters the region — which
  # is the whole point of the split.
  defp after_last_bracket(name) do
    ~r/[\[\(\{][^\]\)\}]*[\]\)\}]/
    |> Regex.split(name, trim: true)
    |> Enum.filter(&bare_tag_run?/1)
    |> Enum.join(" ")
  end

  # Every alphabetic word in the run is a known tag word. An empty run (pure punctuation) carries
  # nothing and is harmless either way.
  defp bare_tag_run?(run) do
    words = String.split(run, ~r/[^A-Za-z]+/, trim: true)

    words != [] and Enum.all?(words, &tag_word?/1)
  end
end
