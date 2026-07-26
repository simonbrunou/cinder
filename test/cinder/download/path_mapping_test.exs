defmodule Cinder.Download.PathMappingTest do
  use ExUnit.Case, async: true

  alias Cinder.Download.PathMapping

  test "swaps a matching remote prefix for the local prefix" do
    assert PathMapping.translate(
             "/downloads/Movie/Movie.mkv",
             "/downloads",
             "/media/downloads"
           ) == "/media/downloads/Movie/Movie.mkv"
  end

  test "passes a non-matching path through unchanged" do
    path = "/other/Movie.mkv"
    assert PathMapping.translate(path, "/downloads", "/media/downloads") == path
  end

  test "normalizes trailing slashes on both prefixes" do
    assert PathMapping.translate(
             "/downloads/Movie.mkv",
             "/downloads/",
             "/media/downloads/"
           ) == "/media/downloads/Movie.mkv"
  end

  test "blank or unset mappings are a no-op" do
    path = "/downloads/Movie.mkv"

    assert PathMapping.translate(path, "", "/media/downloads") == path
    assert PathMapping.translate(path, "/downloads", "  ") == path
    assert PathMapping.translate(path, nil, nil) == path
  end
end
