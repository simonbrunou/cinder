defmodule Cinder.Acquisition.Audiobooks do
  @moduledoc """
  Audiobook release search: the `:audiobook` query plan, run by `Cinder.Acquisition.BookSearch`.

  The `Cinder.Acquisition.Ebooks` sibling for audiobooks. It searches, parses, and explains. It
  does **not** select, grab, or write anything: there is deliberately no
  `best_audiobook_release/2`, for the reason `BookSearch` gives.

  ## The plan

  Each `:audiobook` edition's ASIN, then its ISBN, is probed, up to `BookSearch`'s cap, before
  the structured and free-text queries: every ASIN across the editions comes before any ISBN.
  Audible ASIN is the dominant audiobook identifier; ISBN is the fallback for indie audiobooks
  that only ever had a print ISBN. Only `:audiobook` editions: an e-book edition's ISBN/ASIN
  names a different manifestation, and a release matching it is not an audiobook. A plain-map
  work carries its identifiers, ASIN-priority order, under `:identifiers`.
  """

  alias Cinder.Acquisition.{AudiobookRelease, BookSearch}
  alias Cinder.Books.Work

  @plan %{
    media_kind: :audiobook,
    identifier_providers: ["asin", "isbn"],
    identifiers_key: :identifiers
  }

  @doc "The most indexer queries one audiobook search can issue; see `BookSearch.max_queries/0`."
  @spec max_queries() :: pos_integer()
  defdelegate max_queries, to: BookSearch

  @doc """
  Searches the configured indexer for audiobook releases of `work`.

  `work` is a `Cinder.Books.Work` with `:editions` (and their `:identifiers`) and `:credits`
  (with `:author`) preloaded, or a plain map with `:title`, `:authors`, and optionally
  `:identifiers` (ASIN/ISBN strings, ASIN-priority order) and `:series`.

  Returns `{:ok, [%AudiobookRelease{}], complete?}`, or `{:error, reason}` when every query
  failed — see `BookSearch.search/2`.
  """
  @spec search(Work.t() | map()) :: {:ok, [AudiobookRelease.t()], boolean()} | {:error, term()}
  def search(work), do: BookSearch.search(work, @plan)

  @doc """
  Searches, then evaluates every candidate against `work` — see `BookSearch.candidates/3`.
  `opts` are the scorer's (`:language`, `:blocked_terms`, ...).
  """
  @spec candidates(Work.t() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def candidates(work, opts \\ []), do: BookSearch.candidates(work, @plan, opts)
end
