defmodule Cinder.Acquisition.Indexer.Cardigann.Magnet do
  @moduledoc """
  The info-hash magnet of a Cardigann definition: a search row's `infohash` field (#1671) and a
  grab's `download.infohash` block (#1679) both build `magnet:?xt=urn:btih:<hash>&dn=<title>`,
  the title form-encoded, with no tracker. Prowlarr's `MagnetLinkBuilder.BuildPublicMagnetLink`
  adds its public trackers; Cinder adds none.
  """

  @doc "The magnet of `hash`, trimmed, and `title`, or nil for a blank hash."
  @spec from_infohash(String.t(), String.t()) :: String.t() | nil
  def from_infohash(hash, title) when is_binary(hash) and is_binary(title) do
    case String.trim(hash) do
      "" -> nil
      hash -> "magnet:?xt=urn:btih:" <> hash <> "&dn=" <> URI.encode_www_form(title)
    end
  end
end
