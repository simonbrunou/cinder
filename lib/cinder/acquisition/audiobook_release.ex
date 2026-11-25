defmodule Cinder.Acquisition.AudiobookRelease do
  @moduledoc """
  A candidate audiobook release: the indexer-reported fields plus the attributes parsed from its
  name.

  The `Cinder.Acquisition.EbookRelease` sibling for audiobooks, and a separate struct rather than
  more nil columns on that one, for the same reason `EbookRelease`'s own moduledoc gives against
  merging into `Cinder.Acquisition.Release`: an audiobook release has no resolution, source, or
  codec, and an e-book release has no `narrator`.

  `formats` is a list, not one value, for the same multi-format-bundle reason `EbookRelease`
  documents.

  `narrator` is a best-effort, informational-only field parsed from `"(Narrated by Ray Porter)"` /
  `"[Read by ...]"` patterns in the release name. It is never a scorer gate — see
  `Cinder.Acquisition.BookScorer`'s moduledoc for why.

  `query_origins` records identity-scoped and free-text provenance exactly as `EbookRelease` does.

  The indexer provenance fields, the Prowlarr default of `indexer_source` in `new/1`, and the link
  `Kernel.inspect/1` leaves out are `Cinder.Acquisition.Release`'s.
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
          indexer_source: String.t() | nil,
          indexer_name: String.t() | nil,
          credentials_version: integer() | nil,
          published_at: DateTime.t() | nil,
          query_origins: [atom()] | nil,
          formats: [atom()] | nil,
          language: String.t() | nil,
          retail?: boolean() | nil,
          collection?: boolean() | nil,
          collection_numbers: [String.t()] | nil,
          abridged?: boolean() | nil,
          narrator: String.t() | nil
        }

  # The link can hold an indexer's API key, so `Kernel.inspect/1` leaves it out.
  @derive {Inspect, except: [:download_url]}
  defstruct [
    :title,
    :size,
    :download_url,
    :download_url_origin,
    :protocol,
    :category_ids,
    :indexer_id,
    :indexer_source,
    :indexer_name,
    :credentials_version,
    :published_at,
    :query_origins,
    :formats,
    :language,
    :retail?,
    :collection?,
    :collection_numbers,
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
      indexer_source: Map.get(indexer_map, :indexer_source) || "prowlarr",
      indexer_name: Map.get(indexer_map, :indexer_name),
      credentials_version: Map.get(indexer_map, :credentials_version),
      published_at: Map.get(indexer_map, :published_at),
      query_origins: Map.get(indexer_map, :query_origins)
    }
    |> struct(BookParser.parse(title, :audiobook))
  end
end
