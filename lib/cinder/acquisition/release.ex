defmodule Cinder.Acquisition.Release do
  @moduledoc """
  A candidate release: the indexer-reported fields (`title`, `size`,
  `download_url`, `download_url_origin`, `protocol`, `tvdb_id`, `query_origins`) plus the
  attributes parsed from its name. The shared shape passed between the indexer, parser, and scorer.

  `query_origins` records identity-scoped and free-text query provenance; it is not proof, because
  a provider may ignore the requested id. The title guards read it to pick a rule per release
  (`free_text_only?/1`, `Cinder.Acquisition.title_guard/2`). `tvdb_id`, when present, is the
  indexer result's explicit series identity and can preserve AKA-titled matches safely.

  `protocol` (`:torrent | :usenet`) routes the release to the matching download
  client; it defaults to `:torrent` when the indexer map omits it.

  `indexer_id`, `indexer_source` (`"prowlarr"` or `"native"`), `indexer_name` (for display
  only), `download_url_origin` and `credentials_version` name the indexer that returned the
  release, and `put_provenance/2` copies them from one release to another. `new/1` reads a map
  whose `indexer_source` is absent or nil as Prowlarr's.

  `Kernel.inspect/1` leaves out `download_url`, which can hold an indexer's API key.
  """
  alias Cinder.Acquisition.{AudiobookRelease, EbookRelease, Parser}

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
    :tvdb_id,
    :published_at,
    :query_origins,
    :coordinates,
    :role,
    :resolved_episode_ids,
    :resolution_evidence,
    :mapping_snapshot,
    :resolution,
    :source,
    :codec,
    :group,
    :language,
    :audio_languages,
    :audio_claim_complete?,
    :embedded_subtitle_languages,
    :embedded_subtitle_claim,
    :release_policy_snapshot,
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
      download_url_origin: Map.get(indexer_map, :download_url_origin),
      protocol: Map.get(indexer_map, :protocol, :torrent),
      category_ids: Map.get(indexer_map, :category_ids),
      indexer_id: Map.get(indexer_map, :indexer_id),
      indexer_source: Map.get(indexer_map, :indexer_source) || "prowlarr",
      indexer_name: Map.get(indexer_map, :indexer_name),
      credentials_version: Map.get(indexer_map, :credentials_version),
      tvdb_id: Map.get(indexer_map, :tvdb_id),
      published_at: Map.get(indexer_map, :published_at),
      query_origins: Map.get(indexer_map, :query_origins)
    }
    |> struct(Parser.parse(title))
  end

  @doc """
  Whether only a free-text query found `release`: its `query_origins` is a non-empty list without
  `:id_scoped`. A release with no recorded origin, `nil` (as Prowlarr's `search/1` rows carry)
  or `[]`, is not.
  The IMDb movie guard reads such a release by the Title.Year rule (#1632).
  """
  @spec free_text_only?(map()) :: boolean()
  def free_text_only?(%{query_origins: [_ | _] = origins}), do: :id_scoped not in origins
  def free_text_only?(_release), do: false

  @provenance [
    :indexer_id,
    :indexer_source,
    :indexer_name,
    :download_url_origin,
    :credentials_version
  ]

  @doc """
  Puts on `release` the provenance fields of `copy`: `indexer_id`, `indexer_source`,
  `indexer_name`, `download_url_origin` and `credentials_version`. Every other field stays
  `release`'s.

  Works on structs and on the plain maps an indexer source returns. A field a plain-map `copy`
  lacks stays as `release` has it.
  """
  def put_provenance(release, copy) when is_map(release) and is_map(copy),
    do: Map.merge(release, Map.take(copy, @provenance))

  @doc """
  Builds the `Release` a book grab reserves (`Cinder.Download.grab_book_target/3`) from an
  `EbookRelease` or an `AudiobookRelease`: its title, size, link and protocol, and its provenance
  (`put_provenance/2`), so a new download intent stores its integer indexer id as a TV grab's
  does.

  Every other field stays nil, the mapping and policy snapshots included: both are video-pipeline
  evidence (an episode-numbering decision and an Anime language policy), and
  `Cinder.Download.Intent`'s validators accept them nil.
  """
  def from_book(%book{} = release) when book in [EbookRelease, AudiobookRelease] do
    put_provenance(
      %__MODULE__{
        title: release.title,
        size: release.size,
        download_url: release.download_url,
        protocol: release.protocol
      },
      release
    )
  end
end
