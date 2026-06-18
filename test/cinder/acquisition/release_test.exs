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
end
