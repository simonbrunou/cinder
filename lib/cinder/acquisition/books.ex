defmodule Cinder.Acquisition.Books do
  @moduledoc """
  Bounded book-release query planning and candidate evaluation.

  The books sibling of `Cinder.Acquisition`'s movie/TV search paths, and the whole of B4a's public
  surface. It searches, parses, and explains. It does **not** select, grab, or write anything.

  ## No automatic selection, on purpose

  There is deliberately no `best_book_release/2` here. The roadmap gates it:

  > Ship manual release search/selection first; enable automatic choice only after corpus
  > precision meets the B0 threshold.

  Expressing that gate as the *absence of the function* rather than a disabled flag means no
  caller can reach automatic grabbing by flipping a boolean, and the reviewable unit that adds it
  is also the one that has to show the precision measurement.

  ## Query order is evidence order

  Descending evidence quality, per B4:

  1. **ISBN** — each `:ebook` edition's ISBN-13/ISBN-10, as a free-text probe. An ISBN names one
     manifestation exactly; a release whose name carries it is about that edition and no other.
  2. **Structured author + title** — Newznab's `type=book` `author`/`title` fields.
  3. **Bounded free text** — `"Title Author"`, for indexers that ignore the structured fields.

  The bound that does the work is the ISBN cap: a work with forty editions must not fan out into
  forty indexer requests, and past the first few, additional ISBNs are alternate printings of the
  same text while each costs a round-trip against every configured indexer. Three ISBN probes plus
  the two fixed queries is the whole plan, so `max_queries/0` is *derived* from that cap rather
  than being a second, independently-drifting number.

  ## Partial failure is reported, not hidden

  `search/1` returns `{:ok, releases, complete?}`. `complete? == false` means at least one query
  errored, so an empty or thin result set may be an outage rather than an absence — the same
  distinction `Cinder.Acquisition.Anime.search_movie/4` carries as its `failed?` flag, and the
  same one `Cinder.Books.Identity` draws between "no reliable match" and "providers unavailable".
  Only an all-queries-failed search returns `{:error, reason}`.
  """

  require Logger

  alias Cinder.Acquisition.{BookRelease, BookScorer}
  alias Cinder.Books.{Edition, Identifier, Work}

  @max_isbn_queries 3

  # The structured author/title query and the free-text fallback: one each, always planned.
  @fixed_queries 2

  @doc """
  The most indexer queries one book search can issue.

  Derived, not declared: an independent constant here could disagree with the plan and would then
  either truncate a query shape silently or fence nothing at all.
  """
  @spec max_queries() :: pos_integer()
  def max_queries, do: @max_isbn_queries + @fixed_queries

  @doc """
  Searches the configured indexer for releases of `work`.

  `work` is a `Cinder.Books.Work` with `:editions` (and their `:identifiers`) and `:credits`
  (with `:author`) preloaded, or a plain map with `:title` and `:authors`.

  Returns `{:ok, [%BookRelease{}], complete?}`, or `{:error, reason}` when every query failed.
  Releases are deduped by `download_url`, with `query_origins` merged so a release found by both
  an ISBN probe and a free-text query keeps both provenances.

  Takes no options: the query plan is derived entirely from the work, and the scoring options
  belong to `candidates/2`. An `opts` here would be a parameter that reads as meaningful and
  changes nothing.
  """
  @spec search(Work.t() | map()) :: {:ok, [BookRelease.t()], boolean()} | {:error, term()}
  def search(work) do
    work
    |> normalize()
    |> plan()
    |> run()
  end

  @doc """
  Searches, then evaluates every candidate against `work`.

  Returns `{:ok, %{accepted: [...], rejected: [...], complete?: boolean}}` — see
  `Cinder.Acquisition.BookScorer.evaluate_all/3` for the two lists, and `search/1` for
  `complete?`. `opts` are the scorer's (`:language`, `:blocked_terms`).
  """
  @spec candidates(Work.t() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def candidates(work, opts \\ []) do
    normalized = normalize(work)

    with {:ok, releases, complete?} <- search(normalized) do
      result = BookScorer.evaluate_all(releases, normalized, opts)
      {:ok, Map.put(result, :complete?, complete?)}
    end
  end

  # --- query planning ---

  defp plan(%{title: title, authors: authors, isbns: isbns}) do
    author = List.first(authors)

    isbn_queries =
      isbns
      |> Enum.take(@max_isbn_queries)
      |> Enum.map(fn isbn -> {:isbn, fn -> indexer().search_book_query(isbn, []) end} end)

    structured = [{:structured, fn -> indexer().search_book(author, title, []) end}]

    free_text = [
      {:free_text, fn -> indexer().search_book_query(free_text_query(title, author), []) end}
    ]

    isbn_queries ++ structured ++ free_text
  end

  defp free_text_query(title, nil), do: title
  defp free_text_query(title, author), do: "#{title} #{author}"

  defp run(queries) do
    {batches, failures} =
      Enum.reduce(queries, {[], 0}, fn {label, query}, {batches, failures} ->
        case query.() do
          {:ok, raw} ->
            {[Enum.map(raw, &BookRelease.new/1) | batches], failures}

          {:error, reason} ->
            Logger.info("books search: #{label} query failed: #{inspect(reason)}")
            {batches, failures + 1}
        end
      end)

    # Reverse before flattening: query order is evidence order, and dedupe keeps first-seen, so an
    # ISBN-probe hit must stay ahead of the same release found by free text.
    results = batches |> Enum.reverse() |> List.flatten()

    if failures == length(queries) do
      {:error, :indexer_unavailable}
    else
      {:ok, dedupe(results), failures == 0}
    end
  end

  # Dedupe by download_url, preserving first-seen order and unioning query_origins so a release
  # reached by two different queries records both — the provenance a caller uses to tell an
  # identity-scoped hit from a free-text one.
  defp dedupe(releases) do
    releases
    |> Enum.reduce({[], %{}}, fn release, {keys, by_url} ->
      key = release.download_url

      case Map.fetch(by_url, key) do
        {:ok, existing} ->
          origins =
            Enum.uniq((existing.query_origins || []) ++ (release.query_origins || []))

          {keys, Map.put(by_url, key, %{existing | query_origins: origins})}

        :error ->
          {[key | keys], Map.put(by_url, key, release)}
      end
    end)
    |> then(fn {keys, by_url} ->
      keys |> Enum.reverse() |> Enum.map(&Map.fetch!(by_url, &1))
    end)
  end

  # --- work normalization ---

  # Accepts a loaded Work or a plain map, so a caller with metadata in hand (the manual-search
  # panel resolving a provider work) does not have to persist it first.
  defp normalize(%Work{} = work) do
    %{
      title: work.title,
      authors: author_names(work),
      isbns: isbns(work),
      series: series_names(work)
    }
  end

  defp normalize(%{title: title} = work) do
    %{
      title: title,
      authors: Map.get(work, :authors) || [],
      isbns: Map.get(work, :isbns) || [],
      series: Map.get(work, :series) || []
    }
  end

  # The series this work belongs to, for `BookScorer`'s title remainder — a release naming
  # "The Stormlight Archive 01 - The Way of Kings" is not naming a different work. Unpreloaded
  # degrades to `[]`, matching `author_names/1` and `isbns/1`: the scorer then fails closed on a
  # series-named release rather than raising.
  defp series_names(%Work{series_memberships: memberships}) when is_list(memberships),
    do: memberships |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp series_names(%Work{}), do: []

  # AUTHOR credits only. Promoting every credit made a translator or editor satisfy the scorer's
  # author gate, which is the contract's role-aware credit model collapsing into "anyone named on
  # the book" — a translator's name appears on many unrelated works. Both adapters set
  # `role: "author"` explicitly (`OpenLibrary`/`Hardcover`), so this drops nothing real.
  #
  # A work whose credits are all non-author degrades to `[]`, and `BookScorer.check_author/2`
  # then rejects every release rather than accepting on title alone — fail-closed, matching what
  # `Cinder.Books.Identity` does with no contributor evidence.
  defp author_names(%Work{credits: credits}) when is_list(credits) do
    credits
    |> Enum.flat_map(fn
      %{role: "author", author: %{name: name}} when is_binary(name) -> [name]
      _not_an_author -> []
    end)
    |> Enum.uniq()
  end

  defp author_names(%Work{}), do: []

  # ISBN-13 before ISBN-10 (a modern indexer's release names carry the 13), newest edition first.
  # Only `:ebook` editions: an audiobook edition's ISBN names a recording, and a release matching
  # it is not an e-book.
  #
  # "Newest" is `release_date`, NOT the row id: import order is provider response order, not
  # publication order, so sorting by id meant `@max_isbn_queries` could cut the newest edition and
  # keep three older printings. Undated editions sort last (a missing date is not evidence of
  # recency), with the id as a stable tie-break so the plan is deterministic.
  defp isbns(%Work{editions: editions}) when is_list(editions) do
    editions
    |> Enum.filter(&match?(%Edition{media_kind: :ebook}, &1))
    |> Enum.sort_by(&{release_date_rank(&1.release_date), -&1.id})
    |> Enum.flat_map(&edition_isbns/1)
    |> Enum.uniq()
  end

  defp isbns(%Work{}), do: []

  defp release_date_rank(nil), do: {1, 0}
  defp release_date_rank(%Date{} = date), do: {0, -Date.to_gregorian_days(date)}

  defp edition_isbns(%Edition{identifiers: identifiers}) when is_list(identifiers) do
    identifiers
    |> Enum.flat_map(fn
      %Identifier{provider: "isbn", foreign_id: isbn} when is_binary(isbn) -> [isbn]
      _other -> []
    end)
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp edition_isbns(%Edition{}), do: []

  defp indexer, do: Application.fetch_env!(:cinder, :indexer)
end
