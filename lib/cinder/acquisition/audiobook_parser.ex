defmodule Cinder.Acquisition.AudiobookParser do
  @moduledoc """
  Extracts audiobook-release attributes (`formats`, `language`, `retail?`, `collection?`,
  `abridged?`, `narrator`) from a release name. Pure and best-effort — an unrecognized field is
  `nil`/`false`/`[]`.

  Copies `Cinder.Acquisition.BookParser`'s structure (tag-region discipline, bracket handling)
  verbatim rather than sharing it, per the B7a plan's "new sibling modules, not widened e-book
  ones" decision (the direct B4c-§4 forced-reuse case): the two domains diverge enough — audio
  containers instead of e-book containers, a narrator credit e-books never have — that a shared
  abstraction would force every future e-book-only tweak to carry an audiobook conditional it
  does not need, and vice versa. What genuinely is shared is drawn from the existing registries:
  `Cinder.Acquisition.Parser.language_tags/0` (the language-tag table every family already draws
  from) rather than a second hand-kept copy.

  ## Formats

  `Cinder.Acquisition.AudiobookScorer.accepted_formats/0` is `[:m4b, :mp3]` — the B7a plan's own
  judgment call (§0.1 of the audiobook plan), not contract-derived; the contract only names M4B
  as preferred and gestures at "common multipart audio containers" without enumerating them.
  `m4a`/`aac`/`flac`/`ogg`/`wma` are recognized but rejected, for the same reason `BookParser`
  recognizes PDF/CBZ/DJVU: the scorer needs to tell "this is an unsupported container, refused"
  from "no format stated at all", which it can only do if the parser names the format it refuses.
  `epub`/`azw3`/`mobi` are recognized here too, for the identical reason: a release miscategorized
  into (or bundled with) an e-book file must read as "wrong family, refused" rather than "no
  format stated at all".

  ## Narrator is informational only

  `narrator/1` matches `"(Narrated by Ray Porter)"` / `"[Read by ...]"`-shaped groups in the tag
  region only — the same discipline `language/1` uses and for the same reason: an audiobook's own
  title can legitimately contain "narrated by" as prose, but the parenthesized/bracketed form does
  not. Never a scorer gate — see `Cinder.Acquisition.AudiobookScorer`'s moduledoc.
  """

  alias Cinder.Acquisition.Parser

  # Extension-style format tokens. Ordered most-specific-first so a longer token is not swallowed
  # by a shorter one sharing a prefix. The value is the canonical atom the scorer's allow-list is
  # written in.
  @formats [
    {~r/\bm4b\b/i, :m4b},
    {~r/\bmp3\b/i, :mp3},
    {~r/\bm4a\b/i, :m4a},
    {~r/\baac\b/i, :aac},
    {~r/\bflac\b/i, :flac},
    {~r/\bogg\b/i, :ogg},
    {~r/\bwma\b/i, :wma},
    # E-book containers are recognized-but-rejected here too, the same reason `BookParser`
    # recognizes PDF/DJVU/CBZ outside its own accepted set: the scorer needs to tell "this is an
    # EPUB, wrong family" from "no format stated at all", and it can only do that if the parser
    # names the format it refuses.
    {~r/\bepub\b/i, :epub},
    {~r/\bazw3\b/i, :azw3},
    {~r/\bmobi\b/i, :mobi}
  ]

  @format_anchor ~r/\b(?:m4b|mp3|m4a|aac|flac|ogg|wma|epub|azw3|mobi)\b/i

  # A retail release came from the publisher's own file rather than a rip or a conversion.
  @retail ~r/\bretail\b/i

  # An abridged audiobook is a DIFFERENT text, not a worse copy of the same one. "unabridged" is
  # checked first because it contains "abridged" as a substring — the `\b` alone would match it.
  @abridged ~r/(?<!un)\babridged\b/i

  # Markers that say the release is more than the one work asked for — the same rationale
  # `BookParser`'s own `@collection_markers` documents, copied verbatim for audio releases.
  @collection_markers [
    ~r/\bomnibus\b/i,
    ~r/\banthology\b/i,
    ~r/\bcollection\b/i,
    ~r/\bbox[\s._-]?sets?\b/i,
    ~r/\bcomplete\s+(?:series|works|collection|trilogy|saga)\b/i,
    ~r/\b(?:books?|vols?|volumes?)[\s._#-]*\d+\s*(?:-|–|to|thru|through)\s*\d+\b/i,
    # A hash-prefixed range ("#1-3") is `#` PLUS a range and is unconditional evidence exactly
    # like the keyword-prefixed range above — see `BookParser`'s own list (Codex review, #518).
    ~r/#\s*\d+\s*(?:-|–)\s*\d+\b/
  ]

  # See `BookParser`'s own `@collection_numeric_ranges` for why this is kept separate: no keyword
  # and no "#", so genuinely ambiguous between a real pack span and a numeric title's own number
  # (#518).
  @collection_numeric_ranges [
    ~r/\s(\d{1,2})\s*(?:-|–)\s*(\d{1,2})\b/
  ]

  # `{regex, tag}` for each language, derived from the shared registry so book/audiobook/video
  # cannot drift on what a tag means.
  @languages Parser.language_tags()
             |> Enum.map(fn {_code, tag} -> {Regex.compile!("\\b#{tag}\\b", "i"), tag} end)
             |> Enum.sort_by(fn {_regex, tag} -> {tag == "ENGLISH", tag} end)

  @multi ~r/\bmulti(?:lingual)?\b/i

  # "(Narrated by Ray Porter)" / "[Read by Ray Porter]" — parenthesized/bracketed only, so a
  # title's own prose ("A Story Read by Firelight") is never mistaken for a narrator credit.
  @narrator ~r/[\[\(](?:narrated|read)\s+by\s+([^\]\)]+)[\]\)]/i

  @doc """
  Parses an audiobook release name into the `Cinder.Acquisition.AudiobookRelease` name-derived
  fields.
  """
  @spec parse(String.t() | any()) :: %{
          formats: [atom()],
          language: String.t() | nil,
          retail?: boolean(),
          collection?: boolean(),
          collection_numbers: [String.t()] | nil,
          abridged?: boolean(),
          narrator: String.t() | nil
        }
  def parse(name) when is_binary(name) do
    {collection?, collection_numbers} = collection_evidence(name)

    %{
      formats: formats(name),
      language: language(name),
      retail?: Regex.match?(@retail, name),
      collection?: collection?,
      collection_numbers: collection_numbers,
      abridged?: Regex.match?(@abridged, name),
      narrator: narrator(name)
    }
  end

  def parse(_name),
    do: %{
      formats: [],
      language: nil,
      retail?: false,
      collection?: false,
      collection_numbers: nil,
      abridged?: false,
      narrator: nil
    }

  @doc "Every format token the parser recognizes, in preference-neutral recognizer order."
  @spec known_formats() :: [atom()]
  def known_formats, do: Enum.map(@formats, fn {_regex, format} -> format end) |> Enum.uniq()

  # See `BookParser.collection_evidence/1` for the reasoning.
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

  defp narrator(name) do
    case Regex.run(@narrator, name, capture: :all_but_first) do
      [captured] -> captured |> String.trim() |> presence()
      nil -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  # Formats are read from the TAG REGION, not the whole name, for the same reason
  # `BookParser.formats/1` documents: a title ABOUT a format ("The AAC Encoding Handbook") must
  # not read as claiming that format.
  defp formats(name) do
    region = format_region(name)

    @formats
    |> Enum.flat_map(fn {regex, format} ->
      if Regex.match?(regex, region), do: [format], else: []
    end)
    |> Enum.uniq()
  end

  defp format_region(name) do
    bracketed = bracketed_region(name)

    bracketed <> " " <> anchored_region(name)
  end

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

  defp tag_tail?(tail) do
    tail
    |> String.replace(~r/-[A-Za-z0-9]+\s*$/, " ")
    |> String.split(~r/[^A-Za-z]+/, trim: true)
    |> Enum.all?(&tag_word?/1)
  end

  defp tag_word?(word) do
    Regex.match?(@format_anchor, word) or Regex.match?(@retail, word) or
      Regex.match?(@abridged, word) or String.match?(word, ~r/^(?:un)?abridged$/i) or
      word =~ ~r/^(?:audiobook|book|retail|rip|v\d+|narrated|read|by)$/i or
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

  defp tag_region(name) do
    bracketed = bracketed_region(name)

    bracketed <> " " <> trailing_region(name, bracketed)
  end

  defp bracketed_region(name) do
    ~r/[\[\(\{]([^\]\)\}]*)[\]\)\}]/
    |> Regex.scan(name, capture: :all_but_first)
    |> Enum.map_join(" ", &hd/1)
  end

  defp trailing_region(name, bracketed) do
    if Regex.match?(@format_anchor, bracketed) do
      after_last_bracket(name)
    else
      Regex.split(@format_anchor, name, parts: 2) |> after_anchor(name)
    end
  end

  defp after_anchor([head, tail], name),
    do: if(String.length(head) * 3 >= String.length(name), do: tail, else: "")

  defp after_anchor([_no_anchor], _name), do: ""

  defp after_last_bracket(name) do
    ~r/[\[\(\{][^\]\)\}]*[\]\)\}]/
    |> Regex.split(name, trim: true)
    |> Enum.filter(&bare_tag_run?/1)
    |> Enum.join(" ")
  end

  defp bare_tag_run?(run) do
    words = String.split(run, ~r/[^A-Za-z]+/, trim: true)

    words != [] and Enum.all?(words, &tag_word?/1)
  end
end
