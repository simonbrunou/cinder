defmodule Cinder.Acquisition.ReleaseTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Release

  test "new/1 merges indexer fields with parsed name attributes" do
    indexer_map = %{
      title: "Inception.2010.1080p.BluRay.x264-RARBG",
      size: 8_000_000_000,
      download_url: "http://prowlarr/download/1",
      seeders: 42
    }

    assert %Release{
             title: "Inception.2010.1080p.BluRay.x264-RARBG",
             size: 8_000_000_000,
             download_url: "http://prowlarr/download/1",
             seeders: 42,
             resolution: "1080p",
             codec: "x264",
             group: "RARBG",
             language: nil
           } = Release.new(indexer_map)
  end

  test "new/1 carries the indexer protocol" do
    assert %Release{protocol: :usenet} =
             Release.new(%{title: "Inception.2010.1080p.WEB-DL-GRP", protocol: :usenet})
  end

  test "new/1 defaults protocol to :torrent when the indexer map omits it" do
    assert %Release{protocol: :torrent} =
             Release.new(%{title: "Inception.2010.1080p.WEB-DL-GRP"})
  end

  test "new/1 carries parsed TV season/episodes" do
    assert %Release{season: 1, episodes: [2], resolution: "1080p"} =
             Release.new(%{title: "Show.S01E02.1080p.WEB-DL-GRP"})
  end
end
