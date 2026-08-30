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

  Title containment is not symmetric with `Books.Identity`'s equality test, and cannot be: a
  release name legitimately carries a series name, a year, a format and a group around the title,
  so requiring equality would reject nearly everything. Containment alone would accept an omnibus
  that contains the requested title among others — which is why `collection?` exists and is
  refused separately as `:collection_ambiguous` rather than being folded into the title test. That
  keeps the contract's "omnibus/anthology ambiguity must produce an explained rejection" as its
  own visible reason.

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

  alias Cinder.Acquisition.BookRelease
  alias Cinder.Acquisition.Parser

  # The parity contract's e-book profile, best first. EPUB preferred; no conversion.
  @accepted_formats [:epub, :azw3, :mobi]

  @min_size 64 * 1024
  @max_size 200 * 1024 * 1024

  @articles ~w(the a an le la les el los der die das)

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

  Rules are checked cheapest-and-most-decisive first, so the reason a caller renders is the most
  informative one available rather than whichever check happened to run first.
  """
  @spec evaluate(BookRelease.t(), map(), keyword()) ::
          {:accept, evidence()} | {:reject, reason()}
  def evaluate(%BookRelease{} = release, work, opts \\ []) do
    with :ok <- check_blocked(release, Keyword.get(opts, :blocked_terms) || []),
         {:ok, format} <- check_format(release),
         :ok <- check_author(release, Map.get(work, :authors) || []),
         :ok <- check_title(release, Map.fetch!(work, :title)),
         :ok <- check_collection(release),
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
        |> Enum.sort_by(fn {release, evidence} -> rank(release, evidence) end),
      rejected: Enum.map(rejected, fn {release, {:reject, reason}} -> {release, reason} end)
    }
  end

  # Ascending sort, so every component is written "smaller is better".
  defp rank(%BookRelease{} = release, evidence) do
    {
      Enum.find_index(@accepted_formats, &(&1 == evidence.format)),
      if(evidence.language, do: 0, else: 1),
      if(evidence.retail?, do: 0, else: 1),
      release.size || @max_size,
      published_rank(release.published_at),
      release.title || ""
    }
  end

  # Newest first, with unknown dates last rather than first — an indexer that reports no date must
  # not outrank one that does.
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

  defp check_format(%BookRelease{formats: formats}) do
    formats = formats || []

    case Enum.find(@accepted_formats, &(&1 in formats)) do
      nil when formats == [] -> {:reject, :format_unknown}
      nil -> {:reject, :format_rejected}
      format -> {:ok, format}
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

  defp check_title(%BookRelease{title: release_title}, work_title) do
    wanted = work_title |> tokens() |> drop_article()
    present = tokens(release_title)

    if wanted != [] and wanted -- present == [],
      do: :ok,
      else: {:reject, :title_mismatch}
  end

  defp check_collection(%BookRelease{collection?: true}), do: {:reject, :collection_ambiguous}
  defp check_collection(%BookRelease{}), do: :ok

  # No requested language ⇒ no gate. An untagged release passes a gate that IS set: a book release
  # rarely marks its language at all, and the marker's absence is not evidence of a wrong one.
  # A release tagged with a DIFFERENT language is rejected — that is a positive contradiction.
  defp check_language(_release, nil), do: :ok
  defp check_language(%BookRelease{language: nil}, _wanted), do: :ok
  defp check_language(%BookRelease{language: "MULTI"}, _wanted), do: :ok

  defp check_language(%BookRelease{language: language}, wanted) do
    if language == tag_for(wanted), do: :ok, else: {:reject, :language_mismatch}
  end

  defp tag_for(wanted) do
    wanted = to_string(wanted)
    Map.get(Parser.language_tags(), wanted, String.upcase(wanted))
  end

  # A nil size passes the band: the indexer simply did not report one, and refusing every release
  # from an indexer that omits `size` would be a size rule silently acting as an indexer filter.
  defp check_size(%BookRelease{size: nil}), do: :ok

  defp check_size(%BookRelease{size: size}) when size >= @min_size and size <= @max_size, do: :ok
  defp check_size(%BookRelease{}), do: {:reject, :size_out_of_band}

  # The same fold `Cinder.Books.Identity` uses: NFD-decompose so "Misérables" matches
  # "Miserables", drop apostrophes, drop everything that is not a letter or digit, split.
  defp tokens(nil), do: []

  defp tokens(string) do
    string
    |> nfd()
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[^\x00-\x7f]/u, "")
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  # NFD first, and not only for the diacritic fold: the regexes above raise on malformed UTF-8,
  # and a garbled indexer title must never raise out of a scorer the search loop calls per result.
  defp nfd(string) do
    case :unicode.characters_to_nfd_binary(string) do
      binary when is_binary(binary) -> binary
      {_kind, ok_part, _rest} -> ok_part
    end
  end

  # Drop a leading article from the WANTED title only — Open Library stores "Little Prince" where
  # the release says "The Little Prince", and vice versa. Dropping it from the wanted side alone
  # is enough, because the test is containment: a release that keeps the article still contains
  # every remaining token.
  defp drop_article([article | rest]) when rest != [],
    do: if(article in @articles, do: rest, else: [article | rest])

  defp drop_article(words), do: words
end
