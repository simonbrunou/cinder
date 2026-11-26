defmodule Cinder.TorrentFixture do
  @moduledoc """
  A torrent body for the tests of a download fetch, which `Cinder.Download.Client.DownloadCheck`
  hands to a client only once `Cinder.Download.Torrent.infohash/1` reads it (#1658).
  """

  @doc "A one-file torrent: a bencoded dictionary whose `info` dictionary has one piece."
  def minimal,
    do:
      "d4:infod6:lengthi1e4:name1:a12:piece lengthi16384e6:pieces20:" <>
        String.duplicate("a", 20) <> "ee"
end
