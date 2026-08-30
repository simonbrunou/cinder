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
    {~r/\bcb[rz]\b/i, :cbz},
    {~r/\brtf\b/i, :rtf}
  ]

  @format_anchor ~r/\b(?:epub|azw3|azw|mobi|pdf|djvu|fb2|lit|cbr|cbz|rtf)\b/i

  # A retail release came from the publisher's own file rather than a scan or a conversion.
  @retail ~r/\bretail\b/i

  # Markers that say the release is more than the one work asked for. The contract requires
  # omnibus/anthology ambiguity to produce an explained rejection rather than a silent fallback,
  # and a bare token-containment test cannot see the difference on its own: every token of
  # "The Way of Kings" really is present in "The Stormlight Archive Books 1-3 (The Way of Kings,
  # Words of Radiance, Oathbringer)".
  #
  # `books 1-3` / `#1-5` / `vol 1-3` are ranges, not single volumes. A bare "collection" or
  # "anthology" is enough on its own; those words are near-never part of a novel's own title, and
  # when they are, the cost is a manual search rather than a wrong import.
  @collection [
    ~r/\bomnibus\b/i,
    ~r/\banthology\b/i,
    ~r/\bcollection\b/i,
    ~r/\bboxs?et\b/i,
    ~r/\bcomplete\s+(?:series|works|collection|trilogy|saga)\b/i,
    ~r/\b(?:books?|vols?|volumes?)[\s._#-]*\d+\s*(?:-|–|to|thru|through)\s*\d+\b/i,
    ~r/#\s*\d+\s*(?:-|–)\s*\d+\b/
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
          collection?: boolean()
        }
  def parse(name) when is_binary(name) do
    %{
      formats: formats(name),
      language: language(name),
      retail?: Regex.match?(@retail, name),
      collection?: Enum.any?(@collection, &Regex.match?(&1, name))
    }
  end

  def parse(_name), do: %{formats: [], language: nil, retail?: false, collection?: false}

  @doc "Every format token the parser recognizes, in preference-neutral recognizer order."
  @spec known_formats() :: [atom()]
  def known_formats, do: Enum.map(@formats, fn {_regex, format} -> format end) |> Enum.uniq()

  defp formats(name) do
    @formats
    |> Enum.flat_map(fn {regex, format} ->
      if Regex.match?(regex, name), do: [format], else: []
    end)
    |> Enum.uniq()
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
    bracketed =
      ~r/[\[\(\{]([^\]\)\}]*)[\]\)\}]/
      |> Regex.scan(name, capture: :all_but_first)
      |> Enum.map_join(" ", &hd/1)

    trailing =
      case Regex.split(@format_anchor, name, parts: 2) do
        [_head, tail] -> tail
        [_no_anchor] -> ""
      end

    bracketed <> " " <> trailing
  end
end
