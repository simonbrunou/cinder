defmodule Cinder.Catalog.ImportedSourceChangesetTest do
  use ExUnit.Case, async: true
  alias Cinder.Catalog.{Episode, Movie}

  test "movie transition_changeset casts imported_source" do
    cs = Movie.transition_changeset(%Movie{}, %{status: :available, imported_source: "bluray"})
    assert cs.changes.imported_source == "bluray"
  end

  test "episode transition_changeset casts imported_source" do
    cs = Episode.transition_changeset(%Episode{}, %{imported_source: "webdl"})
    assert cs.changes.imported_source == "webdl"
  end
end
