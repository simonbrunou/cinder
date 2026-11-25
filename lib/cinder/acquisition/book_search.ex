defmodule Cinder.Acquisition.BookSearch do
  @moduledoc """
  Bounded release search and candidate evaluation for the book family, run from one book kind's
  query plan.

  `Cinder.Acquisition.Ebooks` (e-books) and `Cinder.Acquisition.Audiobooks` each hold one plan and
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
      the indexer callbacks (`search_ebook/3` and `search_ebook_query/2`, or the `search_audiobook`
      pair) and the release struct (`EbookRelease` or `AudiobookRelease`), which
      `Cinder.Acquisition.BookScorer` reads the kind back from. Those map one to one onto the
      kind, so they are not plan fields.
    * `identifier_providers` — the identifier providers to probe, in priority order.
    * `identifiers_key` — the key a plain-map work carries its identifiers under. A
      `Cinder.Acquisition.BookSearch.NormalizedWork` always carries them under `identifiers`.

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

  `search/3` returns `{:ok, releases, complete?}`. `complete? == false` means the search is
  incomplete (`Cinder.Acquisition.IndexerSource.Report.incomplete?/1`: a query errored, or an
  indexer failed), so an empty or thin result set may be an outage rather than an absence. That
  is the same distinction `Cinder.Acquisition.Anime.search_movie/4` carries as its `incomplete?`
  flag, and the same one `Cinder.Books.Identity` draws between "no reliable match" and "providers
  unavailable". A query whose indexers were all backing off (`{:indexers_backing_off, retry_at}`)
  or that had no indexer (`:no_indexers`) does not make the search incomplete. When no query
  answered, the search returns the error `Report.combine/1` picks: the first error among the
  queries that is neither of those two, such as `{:prowlarr_status, 500}` under Prowlarr; else
  the backoff that ends first; else `:no_indexers`. When that first error is
  `{:no_indexer_answered, report}`, its report merges every such error's report.

  ## One source per search

  Every query of one search goes to one indexer source: the module `opts[:indexer_source]` names,
  else `Cinder.Acquisition.IndexerSource.configured/0`, read once when the search starts.
  """

  require Logger

  alias Cinder.Acquisition.{AudiobookRelease, BookKind, BookScorer, EbookRelease, IndexerSource}
  alias Cinder.Acquisition.BookSearch.NormalizedWork
  alias Cinder.Acquisition.IndexerSource.Report
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

  @type release :: EbookRelease.t() | AudiobookRelease.t()

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
  (with `:author`) preloaded, a plain map with `:title`, `:authors`, and optionally `:series`
  and the identifiers under the plan's `identifiers_key`, or a
  `Cinder.Acquisition.BookSearch.NormalizedWork`, which is searched as it is.

  `opts[:indexer_source]` is the source module every query of the search goes to, else
  `Cinder.Acquisition.IndexerSource.configured/0`.

  Returns `{:ok, releases, complete?}`, every release the plan's kind of struct, or, when no
  query answered, `{:error, reason}`, the reason the moduledoc's "Partial failure" picks.
  Releases are deduped by `download_url`, with `query_origins` merged so a release found by both
  an identifier probe and a free-text query keeps both provenances.
  """
  @spec search(Work.t() | NormalizedWork.t() | map(), plan(), keyword()) ::
          {:ok, [release()], boolean()} | {:error, term()}
  def search(work, plan, opts \\ []) do
    {indexer, _opts} = IndexerSource.pop_opt(opts)

    with {:ok, releases, report} <- search_with(indexer, work, plan),
         do: {:ok, releases, not Report.incomplete?(report)}
  end

  defp search_with(indexer, work, %{media_kind: kind} = plan) do
    %NormalizedWork{title: title, authors: authors, identifiers: identifiers} =
      normalize(work, plan)

    author = List.first(authors)

    identifier_queries =
      identifiers
      |> Enum.take(@max_identifier_queries)
      |> Enum.map(fn id -> {:identifier, fn -> text_query(indexer, kind, id) end} end)

    structured = [{:structured, fn -> structured_query(indexer, kind, author, title) end}]

    free_text = [
      {:free_text, fn -> text_query(indexer, kind, free_text_query(title, author)) end}
    ]

    run(identifier_queries ++ structured ++ free_text, kind)
  end

  @doc """
  Searches, then evaluates every candidate against `work`.

  Returns `{:ok, %{accepted: [...], rejected: [...], complete?: boolean, report: report}}` — see
  `Cinder.Acquisition.BookScorer.evaluate_all/3` for the two lists, `search/3` for `complete?`
  and its error, and `Cinder.Acquisition.IndexerSource.Report` for `report`, every query's report
  merged in query order. `opts` are the scorer's (`:language`, `:blocked_terms`, ...), plus
  `search/3`'s `indexer_source:`, which the scorer never receives.
  """
  @spec candidates(Work.t() | NormalizedWork.t() | map(), plan(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def candidates(work, plan, opts) do
    {indexer, opts} = IndexerSource.pop_opt(opts)
    work = normalize(work, plan)

    with {:ok, releases, report} <- search_with(indexer, work, plan) do
      result = BookScorer.evaluate_all(releases, work, opts)
      {:ok, Map.merge(result, %{complete?: not Report.incomplete?(report), report: report})}
    end
  end

  # --- running the queries ---

  defp free_text_query(title, nil), do: title
  defp free_text_query(title, author), do: "#{title} #{author}"

  # Every query runs, in query order; `Report.combine/1` keeps the answers in that order. Query
  # order is evidence order, and dedupe keeps first-seen, so an identifier-probe hit stays ahead
  # of the same release found by free text.
  defp run(queries, kind) do
    answers =
      Enum.map(queries, fn {label, query} ->
        case Report.from_result(query.()) do
          {:ok, raw, report} ->
            {:ok, Enum.map(raw, &release(kind, &1)), report}

          {:error, reason} = error ->
            Logger.info("#{log_label(kind)}: #{label} query failed: #{inspect(reason)}")
            error
        end
      end)

    with {:ok, batches, report} <- Report.combine(answers),
         do: {:ok, batches |> List.flatten() |> dedupe(), report}
  end

  # The indexer callbacks, release struct and log label of each book kind.
  defp structured_query(indexer, :ebook, author, title),
    do: indexer.search_ebook(author, title, [])

  defp structured_query(indexer, :audiobook, author, title),
    do: indexer.search_audiobook(author, title, [])

  defp text_query(indexer, :ebook, query), do: indexer.search_ebook_query(query, [])
  defp text_query(indexer, :audiobook, query), do: indexer.search_audiobook_query(query, [])

  defp release(:ebook, raw), do: EbookRelease.new(raw)
  defp release(:audiobook, raw), do: AudiobookRelease.new(raw)

  defp log_label(:ebook), do: "ebooks search"
  defp log_label(:audiobook), do: "audiobooks search"

  # Dedupe by download_url, preserving first-seen order and unioning query_origins so a release
  # reached by two different queries records both — the provenance a caller uses to tell an
  # identity-scoped hit from a free-text one. Every other field is the first copy's, so the
  # release names the indexer of that copy (its id, source, name, link origin and credentials
  # version) even when another indexer also returned the link.
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
  # persist it first. A NormalizedWork comes back as it is: it must not reach the plain-map
  # clause, which reads its identifiers under the plan's `identifiers_key`.
  defp normalize(%Work{} = work, plan) do
    %NormalizedWork{
      title: work.title,
      authors: author_names(work),
      identifiers: identifiers(work, plan),
      series: series_names(work)
    }
  end

  defp normalize(%NormalizedWork{} = work, _plan), do: work

  defp normalize(%{title: title} = work, %{identifiers_key: key}) do
    %NormalizedWork{
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
end
