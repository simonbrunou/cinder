defmodule Cinder.Acquisition.Ebooks do
  @moduledoc """
  E-book release search: the `:ebook` query plan, run by `Cinder.Acquisition.BookSearch`.

  The e-book sibling of `Cinder.Acquisition`'s movie/TV search paths, and the whole of B4a's
  public surface. It searches, parses, and explains. It does **not** select, grab, or write
  anything: there is deliberately no `best_book_release/2`, for the reason `BookSearch` gives.

  ## The plan

  Each `:ebook` edition's ISBN-13/ISBN-10 is probed, up to `BookSearch`'s cap, before the
  structured and free-text queries. An ISBN names one manifestation exactly; a release whose name
  carries it is about that edition and no other. Only `:ebook` editions: an audiobook edition's
  ISBN names a recording, and a release matching it is not an e-book. A plain-map work carries
  its ISBNs under `:isbns`.
  """

  alias Cinder.Acquisition.{BookSearch, EbookRelease}
  alias Cinder.Books.Work

  @plan %{media_kind: :ebook, identifier_providers: ["isbn"], identifiers_key: :isbns}

  @doc "The most indexer queries one e-book search can issue; see `BookSearch.max_queries/0`."
  @spec max_queries() :: pos_integer()
  defdelegate max_queries, to: BookSearch

  @doc """
  Searches the configured indexer for e-book releases of `work`.

  `work` is a `Cinder.Books.Work` with `:editions` (and their `:identifiers`) and `:credits`
  (with `:author`) preloaded, or a plain map with `:title`, `:authors`, and optionally `:isbns`
  and `:series`.

  Returns `{:ok, [%EbookRelease{}], complete?}`, or `{:error, reason}` when every query failed —
  see `BookSearch.search/2`.

  Takes no options: the queries are derived entirely from the plan and the work, and the scoring
  options belong to `candidates/2`. An `opts` here would be a parameter that reads as meaningful
  and changes nothing.
  """
  @spec search(Work.t() | map()) :: {:ok, [EbookRelease.t()], boolean()} | {:error, term()}
  def search(work), do: BookSearch.search(work, @plan)

  @doc """
  Searches, then evaluates every candidate against `work` — see `BookSearch.candidates/3`.
  `opts` are the scorer's (`:language`, `:blocked_terms`, ...).
  """
  @spec candidates(Work.t() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def candidates(work, opts \\ []), do: BookSearch.candidates(work, @plan, opts)
end
