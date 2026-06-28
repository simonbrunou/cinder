defmodule Cinder.Catalog.BlockedReleaseTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.BlockedRelease

  test "changeset/2 casts release_title, reason and the owning ids" do
    cs =
      BlockedRelease.changeset(%BlockedRelease{}, %{
        release_title: "Some.Release.1080p",
        reason: "wrong_audio_language",
        movie_id: 7
      })

    assert cs.valid?
    assert cs.changes.release_title == "Some.Release.1080p"
    assert cs.changes.reason == "wrong_audio_language"
    assert cs.changes.movie_id == 7
  end

  test "changeset/2 requires release_title" do
    refute BlockedRelease.changeset(%BlockedRelease{}, %{reason: "x", series_id: 1}).valid?
  end
end
