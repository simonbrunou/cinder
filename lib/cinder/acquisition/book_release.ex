defmodule Cinder.Acquisition.BookRelease do
  @moduledoc """
  A candidate book release: the indexer-reported fields plus the attributes parsed from its name.

  The books sibling of `Cinder.Acquisition.Release`, and a separate struct rather than more nil
  columns on that one. A book release has no resolution, source, codec, season or episode list,
  and a video release has no format set or author segment; `Cinder.LibraryKind` already keeps the
  two families apart deliberately (`video?: false` opts a book kind out of every video
  derivation), and collapsing them here would put that back.

  `formats` is a list, not one value: `Author - Title (EPUB, MOBI, AZW3)` is one release carrying
  three formats, and picking one of them would either drop an acceptable format or invent a
  preference the release never stated.

  `query_origins` records identity-scoped and free-text provenance exactly as `Release` does — it
  is diagnostic rather than proof, because an indexer may ignore the structured author/title
  fields and match the text anyway.
  """
  alias Cinder.Acquisition.BookParser

  @type t :: %__MODULE__{
          title: String.t(),
          size: non_neg_integer() | nil,
          download_url: String.t() | nil,
          download_url_origin: String.t() | nil,
          protocol: :torrent | :usenet,
          category_ids: [integer()] | nil,
          indexer_id: integer() | nil,
          published_at: DateTime.t() | nil,
          query_origins: [atom()] | nil,
          formats: [atom()] | nil,
          language: String.t() | nil,
          retail?: boolean() | nil,
          collection?: boolean() | nil,
          abridged?: boolean() | nil
        }

  defstruct [
    :title,
    :size,
    :download_url,
    :download_url_origin,
    :protocol,
    :category_ids,
    :indexer_id,
    :published_at,
    :query_origins,
    :formats,
    :language,
    :retail?,
    :collection?,
    :abridged?
  ]

  @doc """
  Builds a `BookRelease` from an indexer result map, parsing name-derived attributes from the
  `:title`.
  """
  def new(%{title: title} = indexer_map) do
    %__MODULE__{
      title: title,
      size: Map.get(indexer_map, :size),
      download_url: Map.get(indexer_map, :download_url),
      download_url_origin: Map.get(indexer_map, :download_url_origin),
      protocol: Map.get(indexer_map, :protocol, :torrent),
      category_ids: Map.get(indexer_map, :category_ids),
      indexer_id: Map.get(indexer_map, :indexer_id),
      published_at: Map.get(indexer_map, :published_at),
      query_origins: Map.get(indexer_map, :query_origins)
    }
    |> struct(BookParser.parse(title))
  end
end
