defmodule Cinder.Acquisition.AudiobookRelease do
  @moduledoc """
  A candidate audiobook release: the indexer-reported fields plus the attributes parsed from its
  name.

  The `Cinder.Acquisition.BookRelease` sibling for audiobooks, and a separate struct rather than
  more nil columns on that one, for the same reason `BookRelease`'s own moduledoc gives against
  merging into `Cinder.Acquisition.Release`: an audiobook release has no resolution, source, or
  codec, and a book release has no `narrator`.

  `formats` is a list, not one value, for the same multi-format-bundle reason `BookRelease`
  documents.

  `narrator` is a best-effort, informational-only field parsed from `"(Narrated by Ray Porter)"` /
  `"[Read by ...]"` patterns in the release name. It is never a scorer gate — see
  `Cinder.Acquisition.AudiobookScorer`'s moduledoc for why.

  `query_origins` records identity-scoped and free-text provenance exactly as `BookRelease` does.
  """
  alias Cinder.Acquisition.AudiobookParser

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
          abridged?: boolean() | nil,
          narrator: String.t() | nil
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
    :abridged?,
    :narrator
  ]

  @doc """
  Builds an `AudiobookRelease` from an indexer result map, parsing name-derived attributes from
  the `:title`.
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
    |> struct(AudiobookParser.parse(title))
  end
end
