defmodule Cinder.Acquisition.Release do
  @moduledoc """
  A candidate release: the indexer-reported fields (`title`, `size`,
  `download_url`, `protocol`) plus the attributes parsed from its name.
  The shared shape passed between the indexer, parser, and scorer.

  `protocol` (`:torrent | :usenet`) routes the release to the matching download
  client; it defaults to `:torrent` when the indexer map omits it.
  """
  alias Cinder.Acquisition.Parser

  defstruct [
    :title,
    :size,
    :download_url,
    :protocol,
    :resolution,
    :source,
    :codec,
    :group,
    :language,
    :season,
    :episodes
  ]

  @doc """
  Builds a `Release` from an indexer result map, parsing name-derived attributes
  from the `:title`.
  """
  def new(%{title: title} = indexer_map) do
    %__MODULE__{
      title: title,
      size: Map.get(indexer_map, :size),
      download_url: Map.get(indexer_map, :download_url),
      protocol: Map.get(indexer_map, :protocol, :torrent)
    }
    |> struct(Parser.parse(title))
  end
end
