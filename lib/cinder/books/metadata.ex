defmodule Cinder.Books.Metadata do
  @moduledoc """
  Behaviour for books metadata: search for candidate works, then fetch one work in full.

  Unlike the single-impl service behaviours (`Cinder.Catalog.TMDB` and friends), this one is
  configured as an **ordered list** — the B0 corpus decision requires Open Library as primary plus
  a Hardcover-compatible secondary, and the whole point of the pair is that they disagree:

      config :cinder, #{inspect(__MODULE__)},
        providers: [Cinder.Books.Metadata.OpenLibrary, Cinder.Books.Metadata.Hardcover]

  `Cinder.Books.Identity` walks the list in order and stops at the first *reliable* answer.
  Adapters normalize and nothing more; deciding whether a candidate is good enough is the
  resolver's job, never the adapter's.
  """

  @typedoc """
  A search hit, carrying only what the resolver needs to judge it. `contributors` are display
  names paired with the provider's own author id — an author with no provider id cannot be
  identified, and is dropped rather than invented.
  """
  @type candidate :: %{
          provider: atom(),
          foreign_id: String.t(),
          title: String.t(),
          contributors: [contributor()],
          first_published_year: pos_integer() | nil,
          edition_count: non_neg_integer()
        }

  @type contributor :: %{
          foreign_id: String.t() | nil,
          name: String.t(),
          role: String.t()
        }

  @typedoc """
  One work in full. `editions` holds only the provider's **digital** manifestations — Cinder's
  media kinds are `:ebook`/`:audiobook`, so a paperback has nowhere to land and is dropped
  (`book_editions.media_kind` is CHECK-constrained to the two, B2a).
  """
  @type work :: %{
          provider: atom(),
          foreign_id: String.t(),
          title: String.t(),
          first_published_on: Date.t() | nil,
          overview: String.t() | nil,
          contributors: [contributor()],
          contributors_incomplete: boolean(),
          editions: [edition()],
          series: [%{name: String.t(), position: String.t() | nil}]
        }

  @type edition :: %{
          foreign_id: String.t(),
          media_kind: :ebook | :audiobook,
          title: String.t(),
          language: String.t() | nil,
          format: String.t() | nil,
          publisher: String.t() | nil,
          release_date: Date.t() | nil,
          abridged: boolean() | nil,
          isbn13: String.t() | nil,
          asin: String.t() | nil
        }

  @doc "Free-text search. Returns candidates in the provider's own relevance order."
  @callback search(query :: String.t()) :: {:ok, [candidate()]} | {:error, term()}

  @doc "One work in full, by this provider's own work id."
  @callback get_work(foreign_id :: String.t()) :: {:ok, work()} | {:error, term()}

  @doc "This provider's short name, used to namespace `book_identifiers` rows."
  @callback provider() :: atom()

  @doc "The configured providers, in resolution order."
  # fetch_env! at runtime, not compile_env! — the Mox mocks are defined at runtime.
  def providers do
    :cinder
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:providers)
  end
end
