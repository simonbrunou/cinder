defmodule Cinder.Acquisition.BookScorer do
  @moduledoc """
  Judges one book release against one requested work, and ranks the survivors.

  `evaluate/3` returns `{:accept, evidence}` or `{:reject, reason}` — never a bare boolean and
  never a silent drop. The B4 contract requires that "wrong title/author/language/format and
  ambiguous edition releases are rejected with deterministic reasons", and a rejection reason a
  caller can render is what makes a manual-search panel usable: the operator sees *why* the
  obvious release was refused instead of watching it vanish.

  ## Fail closed, unlike the video scorer

  `Cinder.Acquisition.Scorer` deliberately lets a `nil` parsed source through — "a parser miss must
  never strand a grab" — because an untagged video release is still a playable file. The same
  valve here would be a bug. A book release of unknown format may be a PDF scan of a paperback, a
  DRM'd AZW, or a `.txt`, none of which the household's Booklore instance can use, and none of
  which is distinguishable from an EPUB by size. So:

  - no recognized format ⇒ `:format_unknown`;
  - a recognized format outside the profile ⇒ `:format_rejected`;
  - no author evidence ⇒ `:author_mismatch`;
  - no title evidence ⇒ `:title_mismatch`.

  Format acceptance follows the parity contract's e-book profile — EPUB, AZW3 and MOBI, EPUB
  preferred, no conversion.

  ## Author and title evidence

  Both are **token-set** tests over a fold (case, diacritics, punctuation, leading article),
  reusing the reasoning `Cinder.Books.Identity` sets out at length: "Cixin Liu" and "Liu Cixin"
  are the same person, so a substring or ordered comparison rejects correct releases. Every token
  of the author's name must appear in the release name, and every token of the work title must
  too.

  The title test is **containment plus a bounded remainder**, and the remainder half is the part
  that matters. Plain containment — "every token of the wanted title appears in the release name" —
  accepts every sequel and superset the series has:

      wanted "Dune"             accepts "Frank Herbert - Dune Messiah (epub)"
      wanted "The Way of Kings" accepts "Brandon Sanderson - The Way of Kings Prime (epub)"
      wanted "It"               accepts "Stephen King - It Chapter Two Companion (epub)"

  Each of those is a different book by the same author, which is precisely the wrong-work import
  the contract forbids ("fuzzy title matching ... cannot authorize a grab when identities
  conflict"). Equality is not usable either, because a release name legitimately carries a year,
  a format, a group and a series around the title.

  So: bracketed and parenthesised groups are dropped as metadata, the matched author's tokens are
  subtracted, and of what remains, every wanted token must be present **and every leftover token
  must be recognizable metadata** — a year, a format, an edition annotation, or a token of a
  series this work belongs to. An unrecognized leftover word means the release names something
  the request did not, so it is a different work and is rejected.

  This is deliberately biased toward false negatives. A rejected good release costs the operator
  a manual pick and says exactly why; an accepted wrong one puts the wrong book in the library.
  B4a is manual-selection-only, so the cheap side of that trade is the safe one.

  ## Size band

  64 KB – 200 MB, module attributes rather than settings. `movies_min_size` has no meaning for a
  book and the settings registry deliberately generates size bands for video kinds only
  (`LibraryKind.video?/1`). The floor rejects the placeholder/stub torrent; the ceiling rejects the
  multi-gigabyte "complete works" pack, which is a different release from the one requested even
  when it is a genuine one.

  ## Ranking

  Format preference, then language exactness, then retail marker, then **smaller** size. Smaller
  is the inverse of the video scorer, on purpose: for a video a larger file is usually a better
  encode, but a 40 MB EPUB of a 300-page novel is a scan or an image-embedded conversion, and the
  6 MB one is the publisher's file. Ties break on `published_at` (newest first) then title, so the
  order is total and does not depend on indexer result order.
  """

  alias Cinder.Acquisition.BookParser
  alias Cinder.Acquisition.BookRelease
  alias Cinder.Acquisition.Parser
  alias Cinder.Books.TitleFold

  # The parity contract's e-book profile, best first. EPUB preferred; no conversion.
  @accepted_formats [:epub, :azw3, :mobi]

  @min_size 64 * 1024
  @max_size 200 * 1024 * 1024

  # An untagged release is this language by scene convention — see `check_language/2`.
  @default_language "en"

  # Function words that mark descriptive prose rather than a title-case noun phrase.
  @function_words ~w(a an the of and or in on to for from with without at by is are its it
                     how why what when who where life story history guide)

  # The single words in `BookParser`'s collection patterns. A work whose own title contains one of
  # these is asking for something that legitimately reads as a collection, so the marker stops
  # being evidence against the release. Multi-word patterns ("complete series", "Books 1-5") are
  # deliberately absent: no single work is titled that.
  @collection_words ~w(omnibus anthology collection boxset boxsets)

  # Leftover words that are release metadata rather than part of a work's identity. Kept small and
  # literal: every entry here is a word this scorer will ignore when deciding whether a release
  # names a DIFFERENT book, so a loose entry ("book", "novel") would re-admit the sequels the
  # remainder test exists to reject.
  #
  # `abridged` is here AND is a rejection reason of its own (`check_abridgement/2`): it is not part
  # of the work's NAME — "Beloved Abridged" is not a different book from "Beloved" — but it is a
  # different TEXT, so it belongs to the edition gate rather than the title gate. Leaving it out
  # here made it read as a title token and produced a misleading `:title_mismatch`.
  @edition_annotations ~w(
    retail ebook epub azw3 azw mobi pdf djvu fb2 lit cbz cbr rtf
    edition ed abridged unabridged illustrated annotated revised reprint
    v1 v2 v3 vol volume by
  )

  # The parser's own format vocabulary, so a format token can never read as a title word.
  @format_tokens BookParser.known_formats() |> Enum.map(&Atom.to_string/1)

  @type evidence :: %{
          format: atom(),
          formats: [atom()],
          language: String.t() | nil,
          retail?: boolean(),
          size: non_neg_integer() | nil,
          query_origins: [atom()] | nil
        }

  @type reason ::
          :format_unknown
          | :format_rejected
          | :author_mismatch
          | :title_mismatch
          | :collection_ambiguous
          | :language_mismatch
          | :wrong_protocol
          | :title_unfoldable
          | :abridged_edition
          | :format_contradictory
          | :size_out_of_band
          | :blocked_term

  @doc "The e-book formats the profile accepts, most preferred first."
  @spec accepted_formats() :: [atom()]
  def accepted_formats, do: @accepted_formats

  @doc "The inclusive size band, in bytes, as `{min, max}`."
  @spec size_band() :: {pos_integer(), pos_integer()}
  def size_band, do: {@min_size, @max_size}

  @doc """
  Judges `release` against `work`.

  `work` is a map with `:title` and `:authors` (a list of display names — normally the work's
  credited authors). `opts`:

    * `:language` — an ISO code or release tag the release must match. A release with no parsed
      language passes: an untagged book release is overwhelmingly English-language, and the same
      reasoning `Cinder.Acquisition.Language` documents applies. An explicitly *different*
      language is rejected.
    * `:blocked_terms` — case-insensitive substrings that reject the release outright.
    * `:protocols` — the protocols with a configured download client (`[:torrent]`, `[:usenet]`,
      or both). A release on any other protocol is rejected `:wrong_protocol` rather than offered
      as a candidate that cannot be grabbed. Omitted ⇒ every protocol is acceptable.

  Rules are checked cheapest-and-most-decisive first, so the reason a caller renders is the most
  informative one available rather than whichever check happened to run first.
  """
  @spec evaluate(BookRelease.t(), map(), keyword()) ::
          {:accept, evidence()} | {:reject, reason()}
  def evaluate(%BookRelease{} = release, work, opts \\ []) do
    with :ok <- check_blocked(release, Keyword.get(opts, :blocked_terms) || []),
         {:ok, format} <- check_format(release),
         :ok <- check_protocol(release, Keyword.get(opts, :protocols)),
         :ok <- check_author(release, Map.get(work, :authors) || []),
         :ok <- check_collection(release, work),
         :ok <- check_abridgement(release, work),
         :ok <- check_title(release, work),
         :ok <- check_language(release, Keyword.get(opts, :language)),
         :ok <- check_size(release) do
      {:accept,
       %{
         format: format,
         formats: release.formats || [],
         language: release.language,
         retail?: release.retail? || false,
         size: release.size,
         query_origins: release.query_origins
       }}
    end
  end

  @doc """
  Evaluates every release and partitions the results.

  Returns `%{accepted: [{release, evidence}], rejected: [{release, reason}]}` with `accepted`
  in ranked order (best first) and `rejected` in input order. The rejected list is part of the
  answer, not debugging residue — it is what the operator reads when the release they expected is
  not in the accepted list.
  """
  @spec evaluate_all([BookRelease.t()], map(), keyword()) :: %{
          accepted: [{BookRelease.t(), evidence()}],
          rejected: [{BookRelease.t(), reason()}]
        }
  def evaluate_all(releases, work, opts \\ []) do
    {accepted, rejected} =
      releases
      |> Enum.map(&{&1, evaluate(&1, work, opts)})
      |> Enum.split_with(fn {_release, result} -> match?({:accept, _evidence}, result) end)

    %{
      accepted:
        accepted
        |> Enum.map(fn {release, {:accept, evidence}} -> {release, evidence} end)
        |> Enum.sort_by(fn {release, evidence} ->
          rank(release, evidence, Keyword.get(opts, :language))
        end),
      rejected: Enum.map(rejected, fn {release, {:reject, reason}} -> {release, reason} end)
    }
  end

  # Ascending sort, so every component is written "smaller is better".
  defp rank(%BookRelease{} = release, evidence, wanted_language) do
    {
      Enum.find_index(@accepted_formats, &(&1 == evidence.format)),
      language_rank(evidence.language, wanted_language),
      if(evidence.retail?, do: 0, else: 1),
      release.size || @max_size,
      published_rank(release.published_at),
      release.title || ""
    }
  end

  # Newest first, with unknown dates last rather than first — an indexer that reports no date must
  # not outrank one that does.
  # Language EXACTNESS, not mere presence. Ranking `language != nil` ahead of `nil` sorted a
  # [FRENCH] release above the untagged English one on an install that asked for nothing — and an
  # untagged book release is overwhelmingly English, so being tagged at all must not be a
  # promotion. With no language requested: untagged first, MULTI next, explicitly foreign last.
  # With one requested: exact match first, MULTI next, untagged after, contradicting last (that
  # last case is only reachable through `evaluate_all/3`, since `check_language/2` rejects it).
  defp language_rank(nil, nil), do: 0
  defp language_rank("MULTI", nil), do: 1
  defp language_rank(_tagged, nil), do: 2

  defp language_rank(language, wanted) do
    cond do
      language == tag_for(wanted) -> 0
      language == "MULTI" -> 1
      is_nil(language) -> 2
      true -> 3
    end
  end

  defp published_rank(nil), do: 0
  defp published_rank(%DateTime{} = published_at), do: -DateTime.to_unix(published_at)

  defp check_blocked(_release, []), do: :ok

  defp check_blocked(%BookRelease{title: title}, terms) do
    down = String.downcase(title || "")

    if Enum.any?(terms, &blocked_term?(down, &1)),
      do: {:reject, :blocked_term},
      else: :ok
  end

  defp blocked_term?(down, term) do
    normalized = term |> to_string() |> String.trim() |> String.downcase()
    normalized != "" and String.contains?(down, normalized)
  end

  # The contract fails closed on "unknown OR CONTRADICTORY formats". A multi-format bundle of
  # ACCEPTED formats is not a contradiction — "(epub, azw3)" is one release offering two readable
  # copies, and taking the preferred one is right. But an accepted format advertised alongside a
  # REJECTED one is a contradiction: "[EPUB/PDF]" may be a bundle, or a PDF scan whose uploader
  # tagged it EPUB, and nothing in the name says which. Size cannot separate them either. Taking
  # the EPUB on faith is exactly the guessed import the contract forbids, so it is refused for
  # operator review with its own reason.
  defp check_format(%BookRelease{formats: formats}) do
    formats = formats || []
    {accepted, rejected} = Enum.split_with(formats, &(&1 in @accepted_formats))

    cond do
      formats == [] -> {:reject, :format_unknown}
      accepted == [] -> {:reject, :format_rejected}
      rejected != [] -> {:reject, :format_contradictory}
      true -> {:ok, Enum.find(@accepted_formats, &(&1 in accepted))}
    end
  end

  defp check_author(_release, []), do: {:reject, :author_mismatch}

  defp check_author(%BookRelease{title: title}, authors) do
    release_tokens = tokens(title)

    if Enum.any?(authors, &author_present?(&1, release_tokens)),
      do: :ok,
      else: {:reject, :author_mismatch}
  end

  defp author_present?(author, release_tokens) do
    author_tokens = tokens(author)
    author_tokens != [] and author_tokens -- release_tokens == []
  end

  defp check_title(%BookRelease{title: release_title}, work) do
    wanted = work |> Map.fetch!(:title) |> tokens() |> drop_article()

    core =
      release_title
      |> strip_noise(work)
      |> tokens()
      |> subtract_matched_author(Map.get(work, :authors) || [])
      |> drop_article()

    leftovers = Enum.reject(core -- wanted, &metadata_token?(&1, work))

    cond do
      # Folding to ASCII DISCARDS non-Latin script rather than failing on it, so a title that is
      # only partly non-ASCII keeps just its Latin residue: "ノルウェイの森 1" and "海辺のカフカ 1"
      # both key to ["1"]. `Cinder.Books.Identity` refuses these for the same reason and names the
      # bug it caused there — a confident wrong work. Its own reason, because "mismatch" would
      # tell the operator the release is wrong when the truth is that we cannot compare the two.
      TitleFold.lossy?(Map.fetch!(work, :title)) or TitleFold.lossy?(release_title) ->
        {:reject, :title_unfoldable}

      wanted == [] ->
        {:reject, :title_mismatch}

      wanted -- core != [] ->
        {:reject, :title_mismatch}

      leftovers == [] ->
        :ok

      subtitle_only?(release_title, wanted, leftovers, work) ->
        :ok

      true ->
        {:reject, :title_mismatch}
    end
  end

  # Everything a release name carries that is not part of any work's identity: bracketed groups
  # (year, format, tracker, translator), a trailing scene `-GROUP` tag, and series-position idioms
  # ("Book 1", "Vol. 2", "#3", a bare "01" between separators).
  defp strip_noise(nil, _work), do: ""

  defp strip_noise(title, work) do
    title
    |> drop_bracketed_groups(work)
    |> String.replace(~r/-[A-Za-z0-9]+$/, " ")
    |> String.replace(~r/\b(?:book|bk|vol|volume|part|pt|no|nr)\b[ .#]*\d{1,3}\b/i, " ")
    |> String.replace(~r/#\d{1,3}\b/, " ")
    |> String.replace(~r/(?<=[-–—:.,]|\s)\d{1,3}(?=\s*[-–—:.,]|\s|$)/, " ")
  end

  # Dropping EVERY bracketed group unconditionally made the brackets a bypass: "Dune (Messiah)"
  # and "Dune (Book Two of the Chronicles)" both erased to "Dune" and were accepted for a request
  # for Dune. A bracket is only noise when we can say what is inside it.
  #
  # Two groups are droppable:
  #   * every token is recognized metadata — "(epub)", "(2019, retail)", "(Stormlight Archive)";
  #   * a single unknown token that follows a metadata group — the trailing tracker/scene tag
  #     ("[MyAnonaMouse]", "[BitBook]"), which by convention comes after the format.
  #
  # Anything else stays in the string as title evidence, so the remainder test judges it. Position
  # is what separates the two single-token cases: a sequel name sits where the title is, before
  # the format tag, while a tracker tag trails it.
  defp drop_bracketed_groups(title, work) do
    ~r/[\[\(\{]([^\]\)\}]*)[\]\)\}]?/
    |> Regex.split(title, include_captures: true, trim: true)
    |> Enum.reduce({[], false}, &keep_segment(&1, &2, work))
    |> then(fn {kept, _seen} -> kept |> Enum.reverse() |> Enum.join() end)
  end

  defp keep_segment(segment, {kept, metadata_seen?}, work) do
    case Regex.run(~r/^[\[\(\{]([^\]\)\}]*)[\]\)\}]?$/, segment) do
      [_group, inner] -> keep_group(inner, kept, metadata_seen?, work)
      nil -> {[segment | kept], metadata_seen?}
    end
  end

  defp keep_group(inner, kept, metadata_seen?, work) do
    inner_tokens = tokens(inner)

    cond do
      inner_tokens != [] and Enum.all?(inner_tokens, &metadata_token?(&1, work)) ->
        {[" " | kept], true}

      metadata_seen? and length(inner_tokens) <= 1 ->
        {[" " | kept], metadata_seen?}

      true ->
        {[" " <> inner <> " " | kept], metadata_seen?}
    end
  end

  # A release may name the work's subtitle when the request did not: "Sapiens" and
  # "Sapiens: A Brief History of Humankind" are one work, and providers disagree about whether the
  # subtitle belongs in the title field. Forgiven only when every wanted token sits in the segment
  # BEFORE the first colon — so the extra words are the subtitle of the work that was asked for,
  # not a different work whose name merely contains it. "Dune Messiah" has no colon and is still
  # rejected; a leading "Series: Title" release keeps its own leftovers under scrutiny because
  # the wanted tokens are then not in the head.
  #
  # The head check alone was not enough: a colon is also how a SEQUEL is written. "Dune: Messiah"
  # passed it, which is the same wrong-work accept the remainder test exists to stop. So the tail
  # must also LOOK like a subtitle — see `descriptive_subtitle?/1`.
  defp subtitle_only?(release_title, wanted, leftovers, work) do
    case String.split(strip_noise(release_title, work), ~r/:/, parts: 2) do
      [head, subtitle] ->
        head_tokens =
          head
          |> tokens()
          |> subtract_matched_author(Map.get(work, :authors) || [])
          |> drop_article()

        wanted -- head_tokens == [] and
          Enum.all?(head_tokens -- wanted, &metadata_token?(&1, work)) and
          leftovers != [] and
          descriptive_subtitle?(subtitle)

      _no_colon ->
        false
    end
  end

  # A real subtitle is descriptive prose — "A Brief History of Humankind", "The Story of a
  # Childhood". A sequel's name is a noun phrase: "Messiah", "House Atreides". Requiring at least
  # three tokens AND a function word separates the two on every corpus shape available here.
  #
  # This is a heuristic standing in for evidence B4a does not have. The real discriminator is the
  # provider's own alternate/full titles, which arrive with edition identity in B4b; until then a
  # release like "Dune: House Atreides" (three tokens, no function word) fails closed, which is
  # the direction the contract requires when identity is ambiguous.
  defp descriptive_subtitle?(subtitle) do
    subtitle_tokens = tokens(subtitle)

    length(subtitle_tokens) >= 3 and Enum.any?(subtitle_tokens, &(&1 in @function_words))
  end

  # A language name or code is release metadata, not part of any work's identity: "[ENGLISH]",
  # "(FRENCH)". Derived from the parser's own registry rather than a second hand-kept list, so a
  # language the parser can tag is a language the title check can discount.
  defp language_token?(token) do
    upper = String.upcase(token)

    upper == "MULTI" or
      Enum.any?(Parser.language_tags(), fn {code, tag} -> upper == tag or token == code end)
  end

  # Remove the tokens of the one author that matched, so the byline does not read as title words.
  # Longest name first, for the reason `Cinder.Books.Identity.subtract_contributors/2` documents:
  # a short spelling can otherwise consume a surname the long spelling needed.
  defp subtract_matched_author(release_tokens, authors) do
    authors
    |> Enum.map(&tokens/1)
    |> Enum.sort_by(&{-length(&1), &1})
    |> Enum.find(fn author_tokens ->
      author_tokens != [] and author_tokens -- release_tokens == []
    end)
    |> case do
      nil -> release_tokens
      author_tokens -> release_tokens -- author_tokens
    end
  end

  # A leftover token that does not name a different work: a year, a format the parser knows, an
  # edition annotation, or a word from a series this work belongs to. `series` is whatever the
  # caller loaded (`Cinder.Books.Work`'s `series_memberships`); absent, series-named releases
  # simply fail closed like any other unrecognized word.
  defp metadata_token?(token, work) do
    token in @edition_annotations or
      language_token?(token) or
      Regex.match?(~r/^(?:19|20)\d{2}$/, token) or
      token in @format_tokens or
      token in series_tokens(work)
  end

  defp series_tokens(work) do
    work
    |> Map.get(:series)
    |> List.wrap()
    |> Enum.flat_map(&tokens/1)
  end

  # A collection marker is evidence of ambiguity only when the REQUEST did not ask for one. Works
  # whose own titles carry these words exist and are ordinary requests — "The Norton Anthology of
  # Poetry", "The Complete Sherlock Holmes", "Collection Agency" — and an unconditional reject made
  # every one of them permanently unrequestable, with a reason that blamed the release for saying
  # what the work is called. So the marker is ignored when the wanted title carries the same word,
  # and still refuses a pack that volunteers one the request never mentioned.
  defp check_collection(%BookRelease{collection?: true} = release, work) do
    wanted = work |> Map.fetch!(:title) |> tokens() |> MapSet.new()

    if release.title |> tokens() |> Enum.any?(&(&1 in @collection_words and &1 in wanted)),
      do: :ok,
      else: {:reject, :collection_ambiguous}
  end

  defp check_collection(%BookRelease{}, _work), do: :ok

  # An abridged text is a DIFFERENT text, not a lesser copy of the same one — the contract puts
  # "abridged/unabridged ambiguity" in the same sentence as omnibus and anthology and requires an
  # explained rejection rather than a silent fallback. Accepted only when the request itself asks
  # for one (`abridged: true`), which nothing in B4a sets yet; the flag exists so B4b's edition
  # matching has somewhere to say so rather than having to re-litigate this.
  defp check_abridgement(%BookRelease{abridged?: true}, work) do
    if Map.get(work, :abridged) == true, do: :ok, else: {:reject, :abridged_edition}
  end

  defp check_abridgement(%BookRelease{}, _work), do: :ok

  # The graceful-degradation guard `Cinder.Acquisition` applies on every video path: a release whose
  # protocol has no configured download client can never be grabbed, so offering it as a candidate
  # would strand the operator at the moment they picked it. `nil` protocols ⇒ no gate, matching
  # `Cinder.Acquisition.release_verdict/3`, which also skips the check for an untagged release.
  defp check_protocol(_release, nil), do: :ok
  defp check_protocol(%BookRelease{protocol: nil}, _protocols), do: :ok

  defp check_protocol(%BookRelease{protocol: protocol}, protocols) when is_list(protocols) do
    if protocol in protocols, do: :ok, else: {:reject, :wrong_protocol}
  end

  defp check_protocol(%BookRelease{}, _protocols), do: :ok

  # No requested language ⇒ no gate. An untagged release passes a gate that IS set: a book release
  # rarely marks its language at all, and the marker's absence is not evidence of a wrong one.
  # A release tagged with a DIFFERENT language is rejected — that is a positive contradiction.
  defp check_language(_release, nil), do: :ok
  defp check_language(%BookRelease{language: "MULTI"}, _wanted), do: :ok

  # An untagged release is English by convention (a non-English release is tagged; English is the
  # unmarked default), so it satisfies an English request and NOTHING ELSE. Passing every request
  # was a fail-open: a household asking for the French edition was handed an untagged file that is
  # almost certainly English. `Cinder.Acquisition.Language.satisfies_lang?/2` has drawn this exact
  # line for video since the "untagged assumed to be the original" bug, and books had silently
  # taken the weaker rule.
  defp check_language(%BookRelease{language: nil}, wanted) do
    if tag_for(wanted) == tag_for(@default_language),
      do: :ok,
      else: {:reject, :language_mismatch}
  end

  defp check_language(%BookRelease{language: language}, wanted) do
    if language == tag_for(wanted), do: :ok, else: {:reject, :language_mismatch}
  end

  # A requested language may arrive as ISO 639-1 ("en"), ISO 639-2 ("eng"/"fre"), or the release
  # tag itself ("ENGLISH"). Book editions are the 639-2 case in practice: Open Library publishes
  # `/languages/eng`, so `Cinder.Books.Metadata.OpenLibrary` stores "eng" and a caller passing
  # `edition.language` straight through hit `String.upcase/1`'s "ENG", which matches no tag the
  # parser emits — a correctly-tagged English release was rejected as the wrong language.
  #
  # `Parser.audio_codes/0` is already the 639-1 -> [639-1, 639-2...] table the video path uses for
  # the same normalization, so this reuses it rather than starting a second language table.
  defp tag_for(wanted) do
    wanted = wanted |> to_string() |> String.downcase()

    canonical =
      Enum.find_value(Parser.audio_codes(), wanted, fn {code, aliases} ->
        if wanted == code or wanted in aliases, do: code
      end)

    Map.get(Parser.language_tags(), canonical, String.upcase(wanted))
  end

  # A nil size passes the band: the indexer simply did not report one, and refusing every release
  # from an indexer that omits `size` would be a size rule silently acting as an indexer filter.
  defp check_size(%BookRelease{size: nil}), do: :ok

  defp check_size(%BookRelease{size: size}) when size >= @min_size and size <= @max_size, do: :ok
  defp check_size(%BookRelease{}), do: {:reject, :size_out_of_band}

  defdelegate tokens(string), to: TitleFold

  # Drop a leading article from the WANTED title only — Open Library stores "Little Prince" where
  # the release says "The Little Prince", and vice versa. Dropping it from the wanted side alone
  # is enough, because the test is containment: a release that keeps the article still contains
  # every remaining token.
  defdelegate drop_article(words), to: TitleFold
end
