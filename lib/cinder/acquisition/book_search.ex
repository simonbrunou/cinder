defmodule Cinder.Acquisition.BookSearch do
  @moduledoc """
  Bounded release search and candidate evaluation for the book family, run from one book kind's
  query plan.

  `Cinder.Acquisition.Books` (e-books) and `Cinder.Acquisition.Audiobooks` each hold one plan and
  are the modules callers use. This module runs a plan: it searches, parses, and explains. It does
  **not** select, grab, or write anything.

  ## No automatic selection, on purpose

  There is deliberately no `best_book_release/2` here or in either kind's module. The roadmap
  gates it:

  > Ship manual release search/selection first; enable automatic choice only after corpus
  > precision meets the B0 threshold.

  Expressing that gate as the *absence of the function* rather than a disabled flag means no
  caller can reach automatic grabbing by flipping a boolean, and the reviewable unit that adds it
  is also the one that has to show the precision measurement.

  ## A query plan

  A plan is three constants:

    * `media_kind` — the book kind. Only that kind's editions supply identifiers. It also picks
      the indexer callbacks (`search_book/3` and `search_book_query/2`, or the `search_audiobook`
      pair) and the release struct (`BookRelease` or `AudiobookRelease`), which
      `Cinder.Acquisition.BookScorer` reads the kind back from. Those map one to one onto the
      kind, so they are not plan fields.
    * `identifier_providers` — the identifier providers to probe, in priority order.
    * `identifiers_key` — the key a plain-map work carries its identifiers under.

  ## Query order is evidence order

  1. **Identifiers** — the kind's editions' identifiers as free-text probes, provider by provider
     in the plan's order. An identifier names one manifestation exactly; a release whose name
     carries it is about that edition and no other.
  2. **Structured author + title** — Newznab's `type=book` `author`/`title` fields, scoped to the
     kind's category by the indexer adapter.
  3. **Bounded free text** — `"Title Author"`, for indexers that ignore the structured fields.

  The bound that does the work is the identifier cap: a work with forty editions must not fan out
  into forty indexer requests, and past the first few, additional identifiers are alternate
  printings or recordings of the same text while each costs a round-trip against every configured
  indexer. Three identifier probes plus the two fixed queries is every query one search issues,
  so `max_queries/0` is *derived* from that cap rather than being a second, independently-drifting
  number.

  ## Partial failure is reported, not hidden

  `search/2` returns `{:ok, releases, complete?}`. `complete? == false` means at least one query
  errored, so an empty or thin result set may be an outage rather than an absence — the same
  distinction `Cinder.Acquisition.Anime.search_movie/4` carries as its `failed?` flag, and the
  same one `Cinder.Books.Identity` draws between "no reliable match" and "providers unavailable".
  Only an all-queries-failed search returns `{:error, :indexer_unavailable}`.
  """

  require Logger

  alias Cinder.Acquisition.{AudiobookRelease, BookKind, BookRelease, BookScorer}
  alias Cinder.Books.{Edition, Identifier, Work}

  @max_identifier_queries 3

  # The structured author/title query and the free-text fallback: one each, in every search.
  @fixed_queries 2

  @typedoc "One book kind's query plan; see the moduledoc."
  @type plan :: %{
          media_kind: BookKind.media_kind(),
          identifier_providers: [String.t(), ...],
          identifiers_key: atom()
        }

  @type release :: BookRelease.t() | AudiobookRelease.t()

  @doc """
  The most indexer queries one book search can issue, for either book kind.

  Derived, not declared: an independent constant here could disagree with the queries a search
  runs and would then either truncate a query shape silently or fence nothing at all.
  """
  @spec max_queries() :: pos_integer()
  def max_queries, do: @max_identifier_queries + @fixed_queries

  @doc """
  Searches the configured indexer for releases of `work` in the plan's book kind.

  `work` is a `Cinder.Books.Work` with `:editions` (and their `:identifiers`) and `:credits`
  (with `:author`) preloaded, or a plain map with `:title`, `:authors`, and optionally `:series`
  and the identifiers under the plan's `identifiers_key`.

  Returns `{:ok, releases, complete?}`, every release the plan's kind of struct, or
  `{:error, :indexer_unavailable}` when every query failed. Releases are deduped by
  `download_url`, with `query_origins` merged so a release found by both an identifier probe and a
  free-text query keeps both provenances.
  """
  @spec search(Work.t() | map(), plan()) ::
          {:ok, [release()], boolean()} | {:error, :indexer_unavailable}
  def search(work, plan), do: work |> normalize(plan) |> search_normalized(plan)

  @doc """
  Searches, then evaluates every candidate against `work`.

  Returns `{:ok, %{accepted: [...], rejected: [...], complete?: boolean}}` — see
  `Cinder.Acquisition.BookScorer.evaluate_all/3` for the two lists, and `search/2` for
  `complete?`. `opts` are the scorer's (`:language`, `:blocked_terms`, ...).
  """
  @spec candidates(Work.t() | map(), plan(), keyword()) ::
          {:ok, map()} | {:error, :indexer_unavailable}
  def candidates(work, plan, opts) do
    # Normalized once: going back through `search/2` would read the normalized map's
    # `:identifiers` under the plan's `identifiers_key` and drop every probe of a plan whose key
    # differs (the e-book plan's `:isbns`).
    normalized = normalize(work, plan)

    with {:ok, releases, complete?} <- search_normalized(normalized, plan) do
      result = BookScorer.evaluate_all(releases, normalized, opts)
      {:ok, Map.put(result, :complete?, complete?)}
    end
  end

  # --- running the queries ---

  defp search_normalized(
         %{title: title, authors: authors, identifiers: identifiers},
         %{media_kind: kind}
       ) do
    author = List.first(authors)

    identifier_queries =
      identifiers
      |> Enum.take(@max_identifier_queries)
      |> Enum.map(fn id -> {:identifier, fn -> text_query(kind, id) end} end)

    structured = [{:structured, fn -> structured_query(kind, author, title) end}]
    free_text = [{:free_text, fn -> text_query(kind, free_text_query(title, author)) end}]

    run(identifier_queries ++ structured ++ free_text, kind)
  end

  defp free_text_query(title, nil), do: title
  defp free_text_query(title, author), do: "#{title} #{author}"

  defp run(queries, kind) do
    {batches, failures} =
      Enum.reduce(queries, {[], 0}, fn {label, query}, {batches, failures} ->
        case query.() do
          {:ok, raw} ->
            {[Enum.map(raw, &release(kind, &1)) | batches], failures}

          {:error, reason} ->
            Logger.info("#{log_label(kind)}: #{label} query failed: #{inspect(reason)}")
            {batches, failures + 1}
        end
      end)

    # Reverse before flattening: query order is evidence order, and dedupe keeps first-seen, so an
    # identifier-probe hit must stay ahead of the same release found by free text.
    results = batches |> Enum.reverse() |> List.flatten()

    if failures == length(queries) do
      {:error, :indexer_unavailable}
    else
      {:ok, dedupe(results), failures == 0}
    end
  end

  # The indexer callbacks, release struct and log label of each book kind.
  defp structured_query(:ebook, author, title), do: indexer().search_book(author, title, [])

  defp structured_query(:audiobook, author, title),
    do: indexer().search_audiobook(author, title, [])

  defp text_query(:ebook, query), do: indexer().search_book_query(query, [])
  defp text_query(:audiobook, query), do: indexer().search_audiobook_query(query, [])

  defp release(:ebook, raw), do: BookRelease.new(raw)
  defp release(:audiobook, raw), do: AudiobookRelease.new(raw)

  defp log_label(:ebook), do: "books search"
  defp log_label(:audiobook), do: "audiobooks search"

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

  # Accepts a loaded Work or a plain map, so a caller with metadata in hand does not have to
  # persist it first.
  defp normalize(%Work{} = work, plan) do
    %{
      title: work.title,
      authors: author_names(work),
      identifiers: identifiers(work, plan),
      series: series_names(work)
    }
  end

  defp normalize(%{title: title} = work, %{identifiers_key: key}) do
    %{
      title: title,
      authors: Map.get(work, :authors) || [],
      identifiers: Map.get(work, key) || [],
      series: Map.get(work, :series) || []
    }
  end

  # The series this work belongs to, for `BookScorer`'s title remainder — a release naming
  # "The Stormlight Archive 01 - The Way of Kings" is not naming a different work. Unpreloaded
  # degrades to `[]`, matching `author_names/1` and `identifiers/2`: the scorer then fails closed
  # on a series-named release rather than raising.
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

  # Provider by provider in the plan's order, newest edition first within each. Only the plan's
  # kind of edition: another kind's identifier names a different manifestation, and a release
  # matching it is not of this kind.
  #
  # "Newest" is `release_date`, NOT the row id: import order is provider response order, not
  # publication order, so sorting by id meant `@max_identifier_queries` could cut the newest
  # edition and keep three older printings. Undated editions sort last (a missing date is not
  # evidence of recency), with the id as a stable tie-break so the probe order is deterministic.
  defp identifiers(%Work{editions: editions}, %{media_kind: kind, identifier_providers: providers})
       when is_list(editions) do
    kind_editions =
      editions
      |> Enum.filter(&match?(%Edition{media_kind: ^kind}, &1))
      |> Enum.sort_by(&{release_date_rank(&1.release_date), -&1.id})

    providers
    |> Enum.flat_map(fn provider ->
      Enum.flat_map(kind_editions, &edition_identifiers(&1, provider))
    end)
    |> Enum.uniq()
  end

  defp identifiers(%Work{}, _plan), do: []

  defp release_date_rank(nil), do: {1, 0}
  defp release_date_rank(%Date{} = date), do: {0, -Date.to_gregorian_days(date)}

  defp edition_identifiers(%Edition{identifiers: identifiers}, provider)
       when is_list(identifiers) do
    identifiers
    |> Enum.flat_map(fn
      %Identifier{provider: ^provider, foreign_id: value} when is_binary(value) -> [value]
      _other -> []
    end)
    |> sort_identifiers(provider)
  end

  defp edition_identifiers(%Edition{}, _provider), do: []

  # ISBN-13 before ISBN-10: a modern indexer's release names carry the 13. ASIN has no length
  # ambiguity, so its values keep their order.
  defp sort_identifiers(values, "isbn"), do: Enum.sort_by(values, &String.length/1, :desc)
  defp sort_identifiers(values, _provider), do: values

  defp indexer, do: Application.fetch_env!(:cinder, :indexer)
end
