defmodule Cinder.Acquisition.Audiobooks do
  @moduledoc """
  Bounded audiobook-release query planning and candidate evaluation.

  The `Cinder.Acquisition.Books` sibling for audiobooks. It searches, parses, and explains. It
  does **not** select, grab, or write anything.

  ## No automatic selection, on purpose

  There is deliberately no `best_audiobook_release/2` here, for the identical reason `Books`
  gives: the roadmap gates automatic choice behind a corpus precision measurement B7a does not
  have. Expressing that gate as the absence of the function means no caller can reach automatic
  grabbing by flipping a boolean.

  ## Query order is evidence order

  Descending evidence quality:

  1. **ASIN, then ISBN** — each `:audiobook` edition's ASIN, then its ISBN, as free-text probes.
     Audible ASIN is the dominant audiobook identifier; ISBN is the fallback for indie audiobooks
     that only ever had a print ISBN. Capped at `@max_identifier_queries` combined (ASIN entries
     first), the identical fan-out guard `Books.max_isbn_queries` uses.
  2. **Structured author + title** — the Newznab book-search type's `author`/`title` fields,
     scoped to the audiobook category by the indexer adapter.
  3. **Bounded free text** — `"Title Author"`, for indexers that ignore the structured fields.

  `max_queries/0` is *derived* from the plan, not a second independently-drifting constant — see
  `Books.max_queries/0`'s own note.

  ## Partial failure is reported, not hidden

  `search/1` returns `{:ok, releases, complete?}`, identical semantics to `Books.search/1`. Only
  an all-queries-failed search returns `{:error, reason}`.
  """

  require Logger

  alias Cinder.Acquisition.{AudiobookRelease, AudiobookScorer}
  alias Cinder.Books.{Edition, Identifier, Work}

  @max_identifier_queries 3

  # The structured author/title query and the free-text fallback: one each, always planned.
  @fixed_queries 2

  @doc """
  The most indexer queries one audiobook search can issue.

  Derived, not declared — see `Cinder.Acquisition.Books.max_queries/0`'s own note on why an
  independent constant here would risk disagreeing with the real plan.
  """
  @spec max_queries() :: pos_integer()
  def max_queries, do: @max_identifier_queries + @fixed_queries

  @doc """
  Searches the configured indexer for audiobook releases of `work`.

  `work` is a `Cinder.Books.Work` with `:editions` (and their `:identifiers`) and `:credits`
  (with `:author`) preloaded, or a plain map with `:title`, `:authors`, and optionally
  `:identifiers` (ASIN/ISBN strings, ASIN-priority order) and `:series`.

  Returns `{:ok, [%AudiobookRelease{}], complete?}`, or `{:error, reason}` when every query
  failed. Releases are deduped by `download_url`, with `query_origins` merged.
  """
  @spec search(Work.t() | map()) :: {:ok, [AudiobookRelease.t()], boolean()} | {:error, term()}
  def search(work) do
    work
    |> normalize()
    |> plan()
    |> run()
  end

  @doc """
  Searches, then evaluates every candidate against `work`.

  Returns `{:ok, %{accepted: [...], rejected: [...], complete?: boolean}}` — see
  `Cinder.Acquisition.AudiobookScorer.evaluate_all/3` for the two lists, and `search/1` for
  `complete?`. `opts` are the scorer's (`:language`, `:blocked_terms`).
  """
  @spec candidates(Work.t() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def candidates(work, opts \\ []) do
    normalized = normalize(work)

    with {:ok, releases, complete?} <- search(normalized) do
      result = AudiobookScorer.evaluate_all(releases, normalized, opts)
      {:ok, Map.put(result, :complete?, complete?)}
    end
  end

  # --- query planning ---

  defp plan(%{title: title, authors: authors, identifiers: identifiers}) do
    author = List.first(authors)

    identifier_queries =
      identifiers
      |> Enum.take(@max_identifier_queries)
      |> Enum.map(fn id ->
        {:identifier, fn -> indexer().search_audiobook_query(id, []) end}
      end)

    structured = [{:structured, fn -> indexer().search_audiobook(author, title, []) end}]

    free_text = [
      {:free_text, fn -> indexer().search_audiobook_query(free_text_query(title, author), []) end}
    ]

    identifier_queries ++ structured ++ free_text
  end

  defp free_text_query(title, nil), do: title
  defp free_text_query(title, author), do: "#{title} #{author}"

  defp run(queries) do
    {batches, failures} =
      Enum.reduce(queries, {[], 0}, fn {label, query}, {batches, failures} ->
        case query.() do
          {:ok, raw} ->
            {[Enum.map(raw, &AudiobookRelease.new/1) | batches], failures}

          {:error, reason} ->
            Logger.info("audiobooks search: #{label} query failed: #{inspect(reason)}")
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

  defp normalize(%Work{} = work) do
    %{
      title: work.title,
      authors: author_names(work),
      identifiers: identifiers(work),
      series: series_names(work)
    }
  end

  defp normalize(%{title: title} = work) do
    %{
      title: title,
      authors: Map.get(work, :authors) || [],
      identifiers: Map.get(work, :identifiers) || [],
      series: Map.get(work, :series) || []
    }
  end

  defp series_names(%Work{series_memberships: memberships}) when is_list(memberships),
    do: memberships |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp series_names(%Work{}), do: []

  # AUTHOR credits only — see `Books.author_names/1`'s own note on why a translator/editor credit
  # must not satisfy this gate.
  defp author_names(%Work{credits: credits}) when is_list(credits) do
    credits
    |> Enum.flat_map(fn
      %{role: "author", author: %{name: name}} when is_binary(name) -> [name]
      _not_an_author -> []
    end)
    |> Enum.uniq()
  end

  defp author_names(%Work{}), do: []

  # ASIN before ISBN (Audible ASIN is the dominant audiobook identifier), newest edition first
  # within each — the identical "newest first, undated last" ordering `Books.isbns/1` documents,
  # applied to `:audiobook` editions only: an e-book edition's ISBN/ASIN names a different
  # manifestation, and a release matching it is not an audiobook.
  defp identifiers(%Work{editions: editions}) when is_list(editions) do
    audiobook_editions =
      editions
      |> Enum.filter(&match?(%Edition{media_kind: :audiobook}, &1))
      |> Enum.sort_by(&{release_date_rank(&1.release_date), -&1.id})

    asins = Enum.flat_map(audiobook_editions, &edition_identifiers(&1, "asin"))
    isbns = Enum.flat_map(audiobook_editions, &edition_identifiers(&1, "isbn"))

    Enum.uniq(asins ++ isbns)
  end

  defp identifiers(%Work{}), do: []

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

  # ISBN-13 before ISBN-10 (a modern indexer's release names carry the 13) — the identical
  # `Books.edition_isbns/1` tie-break. ASIN has no length ambiguity, so this is a no-op for it.
  defp sort_identifiers(values, "isbn"), do: Enum.sort_by(values, &String.length/1, :desc)
  defp sort_identifiers(values, _provider), do: values

  defp indexer, do: Application.fetch_env!(:cinder, :indexer)
end
