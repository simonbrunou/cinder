defmodule Cinder.Acquisition.TitleNoise do
  @moduledoc """
  Strips release-name noise that could be mistaken for a wanted title's own number, shared
  between `Cinder.Acquisition.BookScorer` and `Cinder.Acquisition.AudiobookScorer`.

  This is pure text normalization with no format-specific policy: it takes a release title that
  has already had its bracketed groups and trailing scene tag resolved (each scorer's own job,
  since the e-book and audiobook profiles disagree on what a bracket may legitimately contain —
  a narrator credit is audiobook-only evidence, for one), plus the `work` being scored against,
  and decides which bare digits are release-side series/edition-position noise versus which
  belong to the wanted title itself. The two scorers called an identical copy of this mechanism
  before this module existed; a subtlety fixed in one copy and not the other is exactly the class
  of bug two copies of an algorithm this fiddly will eventually produce (and did, once, before
  this extraction — an inconsistent digit-value check on one branch that the other branches had
  already been upgraded past).

  ## Why any of this exists

  A bare 1-3 digit token between separators is ambiguous: overwhelmingly it is release-side
  series-position noise ("Sanderson - The Stormlight Archive **01** - The Way of Kings"), but a
  work whose own title carries a number writes it the exact same way ("Fahrenheit **451**",
  "Catch-**22**", "The **39** Steps"). Stripping every bare digit unconditionally erased the
  wanted title's own number and rejected the exact requested book (#517); keeping every bare
  digit re-admitted a release naming a *different* book in a shared series whose ordinal happens
  to numerically coincide with the wanted digit — the "loosened title guard admits the wrong
  book" failure the fix must not produce in the process of correcting the first one.

  The distinguishing evidence, applied everywhere a digit is conditionally kept, is
  `belongs_to_wanted_title?/2`: a digit (or a keyword/series-name-plus-digit phrase) is preserved
  only when it forms a contiguous run of the *wanted title's own tokens* — not merely when its
  numeric value happens to appear somewhere in them. A release-side ordinal attached to an
  unrelated series or edition marker shares no such run with an unrelated wanted title and is
  still stripped; a wanted title that itself *is* "series name + number" or "keyword + number"
  keeps its own number, because that exact sequence — not just its value — is what the request
  asked for.
  """

  alias Cinder.Books.TitleFold

  @doc """
  Strips series-ordinal, keyword-prefixed, hash-prefixed, and bare wanted-number noise from a
  release title.

  `title` must already have had bracketed groups and a trailing scene `-GROUP` tag resolved by
  the caller (each scorer's own `drop_bracketed_groups/2`) and must be the caller's `String.trim/1`'d
  title, so the position-based "ed" guard below anchors on the release's actual content start.
  """
  @spec strip(String.t(), map()) :: String.t()
  def strip(title, work) do
    wanted_tokens = work |> Map.fetch!(:title) |> tokens()

    title
    |> strip_series_ordinal(work)
    |> String.replace(~r/-[A-Za-z0-9]+$/, " ")
    |> strip_keyword_number(wanted_tokens)
    |> String.replace(~r/#\d{1,3}\b/, " ")
    |> strip_series_number(wanted_numeric_tokens(work))
  end

  @doc """
  `work.series` entries are the plain strings every existing caller and fixture uses, but
  `Cinder.Books.Metadata.work/0`'s documented shape is a list of `%{name:, position:}` maps.
  Returns `nil` for anything else so a caller building a series-name pattern skips the entry
  gracefully rather than crashing on the real shape.

  Exported so `BookScorer.series_tokens/1` and `AudiobookScorer.series_tokens/1` — which forgive
  a leftover title word that names a series this work belongs to, a separate, older mechanism
  this module does not otherwise touch — can read the same series-name text this module resolves
  ordinals against, rather than keeping a second, potentially-diverging copy of this one-line
  extraction.
  """
  @spec series_name(String.t() | map() | any()) :: String.t() | nil
  def series_name(%{name: name}) when is_binary(name), do: name
  def series_name(name) when is_binary(name), do: name
  def series_name(_other), do: nil

  # "book"/"vol"/"edition"/etc + a number is release-side series/edition-position noise in the
  # overwhelming case ("Edition 13"), but the wanted title itself can BE that phrase ("Edition
  # 13" as the work's own name) — unconditionally stripping erased required title evidence. The
  # keyword and its digit are kept only when they form a contiguous run of the wanted title's own
  # tokens, the same test `strip_ordinal_after/4` applies to a series name's own ordinal.
  defp strip_keyword_number(title, wanted_tokens) do
    keyword_regex = ~r/\b(book|bk|vol|volume|part|pt|no|nr|edition)\b[ .#]*(\d{1,3})\b/i

    stripped =
      Regex.replace(keyword_regex, title, fn _whole, word, digits ->
        keyword_replacement(word, digits, wanted_tokens)
      end)

    # "ed" alone is the SAME abbreviation, but it is also a real first name — "Ed.13.epub" for
    # author "Ed" and title "13" must not read "Ed" as an edition marker and strip both it and
    # the wanted title's own number. Author names lead a release ("Author - Title" convention),
    # so a lookbehind requiring at least one preceding character excludes "ed" at the very start
    # of the (already-trimmed) string, where a genuine edition marker essentially never sits.
    Regex.replace(~r/(?<=.)\bed\b[ .#]*(\d{1,3})\b/i, stripped, fn _whole, digits ->
      if belongs_to_wanted_title?(["ed", digits], wanted_tokens),
        do: "ed " <> digits,
        else: " "
    end)
  end

  defp keyword_replacement(word, digits, wanted_tokens) do
    if belongs_to_wanted_title?([String.downcase(word), digits], wanted_tokens),
      do: word <> " " <> digits,
      else: " "
  end

  # A bare digit right after a series name THIS WORK belongs to is a series-position ordinal
  # ("The Stormlight Archive 01"), not part of the title — regardless of whether that digit
  # happens to numerically coincide with the wanted title's own number. Without this, a release
  # for a DIFFERENT book sharing a series ("X - Foo 13 - Room" for a wanted "Room 13" in series
  # "Foo") had its ordinal misread as supplying the wanted title's missing "13". Stripped
  # unconditionally, ahead of the wanted-number preservation step, so the coincidence never
  # reaches it.
  defp strip_series_ordinal(title, work) do
    normalized = nfd(title)
    wanted_tokens = work |> Map.fetch!(:title) |> tokens()

    work
    |> Map.get(:series)
    |> List.wrap()
    |> Enum.reduce(normalized, &apply_series_ordinal_strip(&1, &2, wanted_tokens))
  end

  defp apply_series_ordinal_strip(series_entry, title, wanted_tokens) do
    with name when is_binary(name) <- series_name(series_entry),
         [_ | _] = words <- tokens(name) do
      pattern = Enum.map_join(words, "[^A-Za-z0-9]+", &word_pattern/1)

      title
      |> strip_ordinal_after(pattern, words, wanted_tokens)
      |> strip_ordinal_before(pattern, words, wanted_tokens)
      |> strip_embedded_series_number(pattern, words, wanted_tokens)
    else
      _ -> title
    end
  end

  # Matched on the series name's own TOKENS, joined by "any run of non-alphanumeric characters",
  # not its literal metadata spelling — an indexer writing scene-style "Foo.Bar.13" for a series
  # named "Foo Bar" is the identical separator normalization `tokens/1` already applies
  # everywhere else, and a literal-space match missed it, readmitting the coincidence this
  # function exists to close.
  #
  # The series-name portion is CAPTURED and kept in the replacement always; the DIGIT is kept
  # only when "series words ++ digit" (or "digit ++ series words", for the before-form) forms a
  # contiguous run of the WANTED title's own tokens — i.e. the wanted title itself is the series
  # name followed by its own number ("Room 13", series `["Room"]`), not just any release whose
  # ordinal happens to numerically coincide with the wanted title's digit while naming an
  # unrelated series ("Foo 13 - Room" for a wanted "Room 13" in series "Foo" is a DIFFERENT book,
  # and must still lose its ordinal). Checked in both orders — "Foo 13" and "13 Foo" are both
  # real placements an indexer writes an ordinal in.
  #
  # The separator between a series name and its adjacent ordinal is TIGHT — a single space, dot,
  # hash, or underscore, matching the same class the keyword-prefixed regex above uses — not any
  # punctuation run. A proper field delimiter (" - ", with spaces around the hyphen) separates
  # DISTINCT release fields ("Author - Series - Title"), so "X - Foo - 13 Ways" must not read the
  # next field's leading number as "Foo"'s ordinal just because a hyphen sits loosely between
  # them. The digit itself may be a decimal ("1.5", a novella between books 1 and 2 in a series)
  # and is consumed atomically rather than leaving its fractional remainder exposed.
  defp strip_ordinal_after(title, pattern, words, wanted_tokens) do
    regex = Regex.compile!("\\b(" <> pattern <> ")[ .#_]*(\\d{1,3}(?:\\.\\d{1,3})?)\\b", "iu")

    Regex.replace(regex, title, fn _whole, name, digits ->
      if belongs_to_wanted_title?(words ++ [digits], wanted_tokens),
        do: name <> " " <> digits,
        else: name <> " "
    end)
  end

  defp strip_ordinal_before(title, pattern, words, wanted_tokens) do
    regex = Regex.compile!("\\b(\\d{1,3}(?:\\.\\d{1,3})?)[ .#_]*(" <> pattern <> ")\\b", "iu")

    Regex.replace(regex, title, fn _whole, digits, name ->
      if belongs_to_wanted_title?([digits | words], wanted_tokens),
        do: digits <> " " <> name,
        else: " " <> name
    end)
  end

  # A digit EMBEDDED in the series name's own tokens ("Foo 13") has no adjacent-ordinal strip to
  # catch it — the whole "Foo 13" already IS the series pattern, not "Foo" plus a stray extra
  # ordinal — so it fell through to `strip_series_number/2`'s pure value-based preservation and
  # satisfied an unrelated wanted title's coincidentally-equal number. Kept only when the whole
  # series name, embedded digit included, is itself a contiguous run of the wanted title's own
  # tokens; otherwise removed along with the rest of the series name.
  defp strip_embedded_series_number(title, pattern, words, wanted_tokens) do
    if Enum.any?(words, &Regex.match?(~r/^\d+$/, &1)),
      do: replace_embedded_series(title, pattern, words, wanted_tokens),
      else: title
  end

  defp replace_embedded_series(title, pattern, words, wanted_tokens) do
    regex = Regex.compile!("\\b(" <> pattern <> ")\\b", "iu")

    Regex.replace(regex, title, fn _whole, name ->
      if belongs_to_wanted_title?(words, wanted_tokens), do: name <> " ", else: " "
    end)
  end

  defp belongs_to_wanted_title?(sequence, wanted_tokens) do
    span = length(sequence)

    wanted_tokens
    |> Enum.chunk_every(span, 1, :discard)
    |> Enum.any?(&(&1 == sequence))
  end

  # Each character of the (already ASCII-folded) word may be followed by any run of Unicode
  # combining marks ("\p{Mn}*", nonspacing marks) or an apostrophe — the release keeps its
  # original diacritics ("Café"), which NFD decomposes to base letter + mark rather than
  # dropping, unlike the folded series name this pattern is built from; `tokens/1` DROPS
  # apostrophes rather than treating them as separators, so "Dragon's" folds to "dragons" but the
  # release keeps the apostrophe between "n" and "s". Matching the bare ASCII letters against
  # that raw text never lined up either way, so a diacritic- or apostrophe-bearing series name's
  # ordinal went unstripped and became false wanted-number evidence.
  defp word_pattern(word) do
    word
    |> String.graphemes()
    |> Enum.map_join("", &(Regex.escape(&1) <> "[\u2019'\\p{Mn}]*"))
  end

  # NFD-decompose so a release's own diacritics align with the ASCII-folded series-name pattern
  # character-by-character; malformed UTF-8 falls back to its decodable prefix rather than
  # raising, the same discipline `Cinder.Books.TitleFold.nfd/1` documents.
  defp nfd(string) do
    case :unicode.characters_to_nfd_binary(string) do
      binary when is_binary(binary) -> binary
      {_kind, ok_part, _rest} -> ok_part
    end
  end

  # A bare 1-3 digit token between separators is ambiguous: overwhelmingly it is release-side
  # series-position noise ("Sanderson - The Stormlight Archive 01 - The Way of Kings"), but a
  # work whose own title carries a number writes it the exact same way ("Fahrenheit 451",
  # "Catch-22", "The 39 Steps") — stripping it unconditionally erased the wanted title's own
  # number and rejected the exact requested book (#517). The distinguishing evidence is the
  # wanted title itself: a digit the release alone contributes is noise; a digit the request
  # itself asked for is not, so it is kept rather than swept away with genuine series markers.
  defp strip_series_number(title, wanted_numbers) do
    Regex.replace(~r/(?<=[-–—:.,]|\s)\d{1,3}(?=\s*[-–—:.,]|\s|$)/, title, fn digits ->
      if digits in wanted_numbers, do: digits, else: " "
    end)
  end

  defp wanted_numeric_tokens(work) do
    work |> Map.fetch!(:title) |> tokens() |> Enum.filter(&Regex.match?(~r/^\d{1,3}$/, &1))
  end

  defdelegate tokens(string), to: TitleFold
end
